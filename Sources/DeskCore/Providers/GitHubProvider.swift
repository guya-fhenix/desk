import Foundation

public struct GitHubSnapshot: Codable, Sendable {
    public var login: String
    public var mine: [PullRequest]
    public var reviewRequests: [PullRequest]
    /// Open PRs by other people in the tracked repos, whether or not anyone asked you to review them.
    public var openForReview: [PullRequest]
    public var mergedRecent: [PullRequest]
    public var reviewedByMe: [PullRequest]
    public var fetchedAt: Date

    public init(
        login: String, mine: [PullRequest], reviewRequests: [PullRequest], openForReview: [PullRequest] = [],
        mergedRecent: [PullRequest], reviewedByMe: [PullRequest], fetchedAt: Date
    ) {
        self.login = login
        self.mine = mine
        self.reviewRequests = reviewRequests
        self.openForReview = openForReview
        self.mergedRecent = mergedRecent
        self.reviewedByMe = reviewedByMe
        self.fetchedAt = fetchedAt
    }

    public var allOpen: [PullRequest] {
        var seen = Set<String>()
        return (mine + reviewRequests + openForReview).filter { seen.insert($0.url).inserted }
    }
}

/// One repository of the org, as GitHub lists it. Settings picks the tracked ones from here.
public struct GitHubRepo: Codable, Sendable, Hashable, Identifiable {
    public var id: String { slug }
    /// `owner/name`, lowercased — the form `trackedRepos` stores and remotes are matched against.
    public var slug: String
    public var name: String
    public var isArchived: Bool
    public var pushedAt: Date?

    public init(slug: String, name: String, isArchived: Bool = false, pushedAt: Date? = nil) {
        self.slug = slug.lowercased()
        self.name = name
        self.isArchived = isArchived
        self.pushedAt = pushedAt
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
    /// Not private: the one write path lives in `GitHubWrite.swift`, apart from these reads.
    let ghPath: String
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

    /// What became of one pull request, asked for by name. Only used for a review whose PR has left every
    /// search: a PR nobody asked you to review and you never submitted on drops out of all of them the
    /// moment it merges, and absence alone is far too thin to delete a review on.
    public func pullRequestState(repo: String, number: Int) async throws -> PullRequestState {
        let parts = repo.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { throw GitHubError.graphQL(["not an owner/name repository: \(repo)"]) }
        let data = try await graphQL(
            query: GitHubQueries.pullRequestStateQuery,
            variables: ["owner": String(parts[0]), "name": String(parts[1]), "number": number]
        )
        return try GitHubDecoding.pullRequestState(from: data)
    }

    /// Every repository in the org, newest push first, so Settings can offer them.
    public func repositories() async throws -> [GitHubRepo] {
        var repos: [GitHubRepo] = []
        var after: String?
        // The org list is paged; a few hundred repos is two or three round trips.
        repeat {
            var variables: [String: any Sendable] = ["org": org]
            if let after { variables["after"] = after }
            let data = try await graphQL(query: GitHubQueries.repositoriesQuery, variables: variables)
            let page = try GitHubDecoding.repositories(from: data)
            repos += page.repos
            after = page.next
        } while after != nil
        return repos
    }

    /// Four separate requests: one combined query exceeds GitHub's 10 s GraphQL limit. With no repo
    /// tracked there is nothing to ask about, so it answers empty without spending a call.
    public func snapshot(repos: [String], since: Date, now: Date = Date()) async throws -> GitHubSnapshot {
        let login = try await viewerLogin()
        guard !repos.isEmpty else {
            return GitHubSnapshot(login: login, mine: [], reviewRequests: [], mergedRecent: [], reviewedByMe: [], fetchedAt: now)
        }
        let queries = GitHubQueries.searches(login: login, repos: repos, since: since)
        async let mine = search(queries.mine, first: 50)
        async let reviews = search(queries.reviews, first: 50)
        async let merged = search(queries.merged, first: 100)
        async let reviewed = search(queries.reviewed, first: 100)
        async let open = search(queries.openForReview, first: 100)
        return try await GitHubSnapshot(
            login: login, mine: mine, reviewRequests: reviews, openForReview: open,
            mergedRecent: merged, reviewedByMe: reviewed, fetchedAt: now
        )
    }

    private func search(_ query: String, first: Int) async throws -> [PullRequest] {
        let data = try await graphQL(query: GitHubQueries.searchQuery, variables: ["q": query, "first": first])
        return try GitHubDecoding.pullRequests(from: data)
    }

    private static let attempts = 3

    /// GitHub answers with a 5xx now and then; `gh` prints it as "HTTP 502" and exits 1. A retry after a
    /// short pause almost always succeeds, and it keeps one bad response from marking the source red
    /// for a whole poll interval.
    ///
    /// `retrying: false` is for writes, which must run exactly once: a 502 returned after the mutation
    /// landed would otherwise post it twice.
    func graphQL(query: String, variables: [String: any Sendable], retrying: Bool = true) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        var attempt = 0
        while true {
            let result = try await Shell.run(ghPath, ["api", "graphql", "--input", "-"], stdin: body)
            if result.stdout.first == UInt8(ascii: "{") { return result.stdout }
            attempt += 1
            guard retrying, attempt < Self.attempts, GitHubError.isTransient(stderr: result.stderr) else {
                throw ShellError.failed(command: "gh api graphql", status: result.status, stderr: result.stderr)
            }
            try await Task.sleep(for: .seconds(Double(attempt) * 2))
        }
    }
}

extension GitHubError {
    /// Server-side failures worth retrying, as `gh` reports them on stderr.
    public static func isTransient(stderr: String) -> Bool {
        ["HTTP 500", "HTTP 502", "HTTP 503", "HTTP 504"].contains { stderr.contains($0) }
    }
}

public struct GitHubSearches: Sendable, Equatable {
    public var mine: String
    public var reviews: String
    public var merged: String
    public var reviewed: String
    public var openForReview: String
}

public enum GitHubQueries {
    /// Scoped to the tracked repositories rather than the whole org, so an untracked repo is invisible
    /// to the app even when its PRs involve you.
    /// ponytail: repeated `repo:` qualifiers; GitHub caps search query length, so a very long tracked
    /// list would need batching into several searches.
    public static func searches(login: String, repos: [String], since: Date) -> GitHubSearches {
        let day = since.formatted(.iso8601.year().month().day())
        let scope = repos.map { "repo:\($0)" }.joined(separator: " ")
        return GitHubSearches(
            mine: "is:pr is:open author:\(login) \(scope)",
            reviews: "is:pr is:open review-requested:\(login) \(scope)",
            merged: "is:pr is:merged author:\(login) \(scope) merged:>=\(day)",
            reviewed: "is:pr \(scope) reviewed-by:\(login) -author:\(login) updated:>=\(day)",
            // Everything open that someone else wrote. Drafts are dropped server-side because this is the
            // widest search of the five and `first:` would otherwise fill up with them.
            openForReview: "is:pr is:open draft:false -author:\(login) \(scope) sort:created-asc"
        )
    }

    public static let pullRequestStateQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) { state } }
    }
    """

    public static let repositoriesQuery = """
    query($org: String!, $after: String) {
      organization(login: $org) {
        repositories(first: 100, after: $after, orderBy: {field: PUSHED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes { name nameWithOwner isArchived pushedAt }
        }
      }
    }
    """

    public static let searchQuery = """
    query($q: String!, $first: Int!) {
      search(query: $q, type: ISSUE, first: $first) { nodes { ...PR } }
    }
    fragment PR on PullRequest {
      number title body url isDraft createdAt updatedAt mergedAt state baseRefName headRefName additions deletions
      author { login }
      repository { nameWithOwner }
      reviewDecision
      mergeStateStatus
      commits(last: 1) { nodes { commit { oid statusCheckRollup { state contexts(first: 0) { totalCount } } } } }
      reviews(first: 100) { nodes { state submittedAt author { login } } }
      pending: reviews(states: PENDING, first: 1) {
        nodes { id commit { oid } comments(first: 100) { totalCount nodes { body } } }
      }
      reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { name } } } }
      timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], first: 50) {
        nodes { ... on ReviewRequestedEvent { createdAt requestedReviewer { __typename ... on User { login } ... on Team { name } } } }
      }
      reviewThreads(first: 100) { nodes { isResolved } }
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

    public static func repositories(from data: Data) throws -> (repos: [GitHubRepo], next: String?) {
        let response = try JSON.decoder().decode(Response<OrgData>.self, from: data)
        if let errors = response.errors, !errors.isEmpty { throw GitHubError.graphQL(errors.map(\.message)) }
        guard let page = response.data?.organization.repositories else { throw GitHubError.emptyResponse }
        let repos = page.nodes.map {
            GitHubRepo(slug: $0.nameWithOwner, name: $0.name, isArchived: $0.isArchived, pushedAt: $0.pushedAt)
        }
        return (repos, page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil)
    }

    public static func pullRequestState(from data: Data) throws -> PullRequestState {
        let response = try JSON.decoder().decode(Response<PullRequestData>.self, from: data)
        if let errors = response.errors, !errors.isEmpty { throw GitHubError.graphQL(errors.map(\.message)) }
        guard let state = response.data?.repository?.pullRequest?.state else { throw GitHubError.emptyResponse }
        guard let parsed = PullRequestState(rawValue: state) else { throw GitHubError.graphQL(["unknown pull request state: \(state)"]) }
        return parsed
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
            body: node.body ?? "",
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
            },
            unresolvedThreads: node.reviewThreads?.nodes.filter { !$0.isResolved }.count ?? 0,
            pendingReview: node.pending?.nodes.first.map { review in
                PendingReview(
                    id: review.id, commitId: review.commit?.oid ?? "", comments: review.comments.totalCount,
                    claudeComments: review.comments.nodes.count { $0.body.contains(DraftThreads.marker) }
                )
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

    private struct PullRequestData: Decodable { var repository: RepositoryPR? }
    private struct RepositoryPR: Decodable { var pullRequest: PRState? }
    private struct PRState: Decodable { var state: String }

    private struct OrgData: Decodable { var organization: Org }
    private struct Org: Decodable { var repositories: RepoPage }
    private struct RepoPage: Decodable {
        var pageInfo: PageInfo
        var nodes: [RepoNode]
    }
    private struct PageInfo: Decodable {
        var hasNextPage: Bool
        var endCursor: String?
    }
    private struct RepoNode: Decodable {
        var name: String
        var nameWithOwner: String
        var isArchived: Bool
        var pushedAt: Date?
    }

    private struct SearchData: Decodable { var search: SearchResult }

    private struct SearchResult: Decodable { var nodes: [PRNode] }

    private struct PRNode: Decodable {
        var number: Int
        var title: String
        var body: String?
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
        /// Your own pending review, the only one GitHub shows. Optional so a query without it still decodes.
        var pending: PendingReviews?
        var reviewRequests: ReviewRequests
        var timelineItems: Timeline
        var reviewThreads: ReviewThreads?
    }

    private struct ReviewThreads: Decodable { var nodes: [ReviewThreadNode] }
    private struct ReviewThreadNode: Decodable { var isResolved: Bool }

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
    private struct PendingReviews: Decodable { var nodes: [PendingNode] }
    private struct PendingNode: Decodable {
        var id: String
        var commit: CommitRef?
        var comments: PendingComments
    }
    private struct CommitRef: Decodable { var oid: String }
    private struct PendingComments: Decodable {
        var totalCount: Int
        var nodes: [Body]
    }
    private struct Body: Decodable { var body: String }
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
