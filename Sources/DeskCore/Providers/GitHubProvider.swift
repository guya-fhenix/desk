import Foundation

public struct GitHubSnapshot: Codable, Sendable {
    public var login: String
    public var mine: [PullRequest]
    public var reviewRequests: [PullRequest]
    public var mergedRecent: [PullRequest]
    public var reviewedByMe: [PullRequest]
    public var fetchedAt: Date

    public init(login: String, mine: [PullRequest], reviewRequests: [PullRequest], mergedRecent: [PullRequest], reviewedByMe: [PullRequest], fetchedAt: Date) {
        self.login = login
        self.mine = mine
        self.reviewRequests = reviewRequests
        self.mergedRecent = mergedRecent
        self.reviewedByMe = reviewedByMe
        self.fetchedAt = fetchedAt
    }

    public var allOpen: [PullRequest] {
        var seen = Set<String>()
        return (mine + reviewRequests).filter { seen.insert($0.url).inserted }
    }
}

public enum GitHubError: Error, CustomStringConvertible, Sendable {
    case graphQL([String])
    case emptyResponse

    public var description: String {
        switch self {
        case .graphQL(let messages): return "GitHub: " + messages.joined(separator: "; ")
        case .emptyResponse: return "GitHub: empty response"
        }
    }
}

public actor GitHubProvider {
    private let ghPath: String
    private let org: String
    private var cachedLogin: String?

    public init(ghPath: String, org: String) {
        self.ghPath = ghPath
        self.org = org
    }

    public func viewerLogin() async throws -> String {
        if let cachedLogin { return cachedLogin }
        let data = try await graphQL(query: "{ viewer { login } }", variables: [:])
        let login = try GitHubDecoding.viewerLogin(from: data)
        cachedLogin = login
        return login
    }

    /// Four separate requests: one combined query exceeds GitHub's 10 s GraphQL limit.
    public func snapshot(since: Date, now: Date = Date()) async throws -> GitHubSnapshot {
        let login = try await viewerLogin()
        let queries = GitHubQueries.searches(login: login, org: org, since: since)
        async let mine = search(queries.mine, first: 50)
        async let reviews = search(queries.reviews, first: 50)
        async let merged = search(queries.merged, first: 100)
        async let reviewed = search(queries.reviewed, first: 100)
        return try await GitHubSnapshot(
            login: login, mine: mine, reviewRequests: reviews, mergedRecent: merged, reviewedByMe: reviewed, fetchedAt: now
        )
    }

    private func search(_ query: String, first: Int) async throws -> [PullRequest] {
        let data = try await graphQL(query: GitHubQueries.searchQuery, variables: ["q": query, "first": first])
        return try GitHubDecoding.pullRequests(from: data)
    }

    public func approve(url: String) async throws {
        try await Shell.output(ghPath, ["pr", "review", url, "--approve"])
    }

    private func graphQL(query: String, variables: [String: any Sendable]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let result = try await Shell.run(ghPath, ["api", "graphql", "--input", "-"], stdin: body)
        guard result.stdout.first == UInt8(ascii: "{") else {
            throw ShellError.failed(command: "gh api graphql", status: result.status, stderr: result.stderr)
        }
        return result.stdout
    }
}

public struct GitHubSearches: Sendable, Equatable {
    public var mine: String
    public var reviews: String
    public var merged: String
    public var reviewed: String
}

public enum GitHubQueries {
    public static func searches(login: String, org: String, since: Date) -> GitHubSearches {
        let day = since.formatted(.iso8601.year().month().day())
        return GitHubSearches(
            mine: "is:pr is:open author:\(login) org:\(org)",
            reviews: "is:pr is:open review-requested:\(login) org:\(org)",
            merged: "is:pr is:merged author:\(login) org:\(org) merged:>=\(day)",
            reviewed: "is:pr org:\(org) reviewed-by:\(login) -author:\(login) updated:>=\(day)"
        )
    }

    public static let searchQuery = """
    query($q: String!, $first: Int!) {
      search(query: $q, type: ISSUE, first: $first) { nodes { ...PR } }
    }
    fragment PR on PullRequest {
      number title url isDraft createdAt updatedAt mergedAt state baseRefName headRefName additions deletions
      author { login }
      repository { nameWithOwner }
      reviewDecision
      mergeStateStatus
      commits(last: 1) { nodes { commit { oid statusCheckRollup { state contexts(first: 0) { totalCount } } } } }
      reviews(first: 100) { nodes { state submittedAt author { login } } }
      reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { name } } } }
      timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], first: 50) {
        nodes { ... on ReviewRequestedEvent { createdAt requestedReviewer { __typename ... on User { login } ... on Team { name } } } }
      }
    }
    """
}

public enum GitHubDecoding {
    public static func viewerLogin(from data: Data) throws -> String {
        let response = try JSON.decoder().decode(Response<ViewerData>.self, from: data)
        if let errors = response.errors, !errors.isEmpty { throw GitHubError.graphQL(errors.map(\.message)) }
        guard let login = response.data?.viewer.login else { throw GitHubError.emptyResponse }
        return login
    }

    public static func pullRequests(from data: Data) throws -> [PullRequest] {
        let response = try JSON.decoder().decode(Response<SearchData>.self, from: data)
        if let errors = response.errors, !errors.isEmpty { throw GitHubError.graphQL(errors.map(\.message)) }
        guard let payload = response.data else { throw GitHubError.emptyResponse }
        return payload.search.nodes.map(pullRequest)
    }

    private static func pullRequest(_ node: PRNode) -> PullRequest {
        let commit = node.commits.nodes.first?.commit
        return PullRequest(
            number: node.number,
            title: node.title,
            url: node.url,
            repo: node.repository.nameWithOwner,
            isDraft: node.isDraft,
            state: PullRequestState(rawValue: node.state) ?? .open,
            createdAt: node.createdAt,
            updatedAt: node.updatedAt,
            mergedAt: node.mergedAt,
            baseRef: node.baseRefName,
            headRef: node.headRefName,
            headSha: commit?.oid ?? "",
            additions: node.additions,
            deletions: node.deletions,
            author: node.author?.login ?? "ghost",
            reviewDecision: node.reviewDecision.flatMap(ReviewDecision.init) ?? .none,
            mergeState: node.mergeStateStatus.flatMap(MergeState.init) ?? .unknown,
            checks: commit?.statusCheckRollup.flatMap { CheckState(rawValue: $0.state) } ?? .none,
            checkCount: commit?.statusCheckRollup?.contexts.totalCount ?? 0,
            reviews: node.reviews.nodes.compactMap { review in
                guard let submittedAt = review.submittedAt else { return nil }
                return Review(state: review.state, submittedAt: submittedAt, author: review.author?.login ?? "ghost")
            },
            requestedReviewers: node.reviewRequests.nodes.compactMap { $0.requestedReviewer?.displayName },
            reviewRequestEvents: node.timelineItems.nodes.compactMap { event in
                guard let createdAt = event.createdAt, let reviewer = event.requestedReviewer else { return nil }
                return ReviewRequestEvent(createdAt: createdAt, reviewer: reviewer.displayName, isTeam: reviewer.typename == "Team")
            }
        )
    }

    private struct Response<T: Decodable>: Decodable {
        var data: T?
        var errors: [GraphQLError]?
    }

    private struct GraphQLError: Decodable { var message: String }
    private struct ViewerData: Decodable { var viewer: Login }
    private struct Login: Decodable { var login: String }
    private struct Repository: Decodable { var nameWithOwner: String }

    private struct SearchData: Decodable { var search: SearchResult }

    private struct SearchResult: Decodable { var nodes: [PRNode] }

    private struct PRNode: Decodable {
        var number: Int
        var title: String
        var url: String
        var isDraft: Bool
        var createdAt: Date
        var updatedAt: Date
        var mergedAt: Date?
        var state: String
        var baseRefName: String
        var headRefName: String
        var additions: Int
        var deletions: Int
        var author: Login?
        var repository: Repository
        var reviewDecision: String?
        var mergeStateStatus: String?
        var commits: Commits
        var reviews: Reviews
        var reviewRequests: ReviewRequests
        var timelineItems: Timeline
    }

    private struct Commits: Decodable { var nodes: [CommitNode] }
    private struct CommitNode: Decodable { var commit: Commit }
    private struct Commit: Decodable {
        var oid: String
        var statusCheckRollup: Rollup?
    }
    private struct Rollup: Decodable {
        var state: String
        var contexts: Count
    }
    private struct Count: Decodable { var totalCount: Int }
    private struct Reviews: Decodable { var nodes: [ReviewNode] }
    private struct ReviewNode: Decodable {
        var state: String
        var submittedAt: Date?
        var author: Login?
    }
    private struct ReviewRequests: Decodable { var nodes: [ReviewRequestNode] }
    private struct ReviewRequestNode: Decodable { var requestedReviewer: Reviewer? }
    private struct Reviewer: Decodable {
        var typename: String
        var login: String?
        var name: String?

        var displayName: String { login ?? name ?? "unknown" }

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case login, name
        }
    }
    private struct Timeline: Decodable { var nodes: [TimelineNode] }
    private struct TimelineNode: Decodable {
        var createdAt: Date?
        var requestedReviewer: Reviewer?
    }
}
