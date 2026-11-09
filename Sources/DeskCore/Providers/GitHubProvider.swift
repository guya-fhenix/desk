import Foundation

public struct GitHubSnapshot: Codable, Sendable {
    public var login: String
    public var mine: [PullRequest]
    public var reviewRequests: [PullRequest]
    /// Open PRs by other people in the tracked repos, whether or not anyone asked you to review them.
    public var openForReview: [PullRequest]
    public var mergedRecent: [PullRequest]
    public var fetchedAt: Date

    public init(
        login: String, mine: [PullRequest], reviewRequests: [PullRequest], openForReview: [PullRequest] = [],
        mergedRecent: [PullRequest], fetchedAt: Date
    ) {
        self.login = login
        self.mine = mine
        self.reviewRequests = reviewRequests
        self.openForReview = openForReview
        self.mergedRecent = mergedRecent
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
        let data = try await graphQL(query: GitHubQueries.pullRequestStateQuery, variables: try Self.variables(repo, number))
        return try GitHubDecoding.pullRequestState(from: data)
    }

    /// A PR's conversation in full: every review thread with its replies, its comments and its reviews. One PR at a
    /// time, when its page or its review diff shows it.
    public func conversation(repo: String, number: Int) async throws -> Conversation {
        let data = try await graphQL(query: GitHubQueries.conversationQuery, variables: try Self.variables(repo, number))
        return try GitHubDecoding.conversation(from: data)
    }

    /// The variables of a query about one PR.
    private static func variables(_ repo: String, _ number: Int) throws -> [String: any Sendable] {
        let parts = repo.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { throw GitHubError.graphQL(["not an owner/name repository: \(repo)"]) }
        return ["owner": String(parts[0]), "name": String(parts[1]), "number": number]
    }

    /// Every check on the PR's head commit, with the failed step and the errors of each that failed. One PR at a
    /// time: steps and annotations for every PR of every search would push those past GitHub's 10 s limit.
    public func checks(repo: String, number: Int) async throws -> [PullRequestCheck] {
        let data = try await graphQL(query: GitHubQueries.checksQuery, variables: try Self.variables(repo, number))
        return try GitHubDecoding.checks(from: data)
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

    /// Separate requests: one combined query exceeds GitHub's 10 s GraphQL limit. With no repo
    /// tracked there is nothing to ask about, so it answers empty without spending a call.
    public func snapshot(repos: [String], since: Date, now: Date = Date()) async throws -> GitHubSnapshot {
        let login = try await viewerLogin()
        guard !repos.isEmpty else {
            return GitHubSnapshot(login: login, mine: [], reviewRequests: [], mergedRecent: [], fetchedAt: now)
        }
        let queries = GitHubQueries.searches(login: login, repos: repos, since: since)
        async let mine = search(queries.mine, first: 50, query: GitHubQueries.mineSearchQuery)
        async let reviews = search(queries.reviews, first: 50)
        async let merged = search(queries.merged, first: 100)
        async let open = search(queries.openForReview, first: 100)
        return try await GitHubSnapshot(
            login: login, mine: mine, reviewRequests: reviews, openForReview: open,
            mergedRecent: merged, fetchedAt: now
        )
    }

    /// A page of 100 with this fragment takes about 11 s and GitHub cuts GraphQL off at 10 s with a 502;
    /// a page of 25 takes about 3 s.
    private static let searchPageSize = 25

    private func search(_ search: String, first: Int, query: String = GitHubQueries.searchQuery) async throws -> [PullRequest] {
        var prs: [PullRequest] = []
        var after: String?
        repeat {
            var variables: [String: any Sendable] = ["q": search, "first": min(Self.searchPageSize, first - prs.count)]
            if let after { variables["after"] = after }
            let data = try await graphQL(query: query, variables: variables)
            let page = try GitHubDecoding.pullRequests(from: data)
            prs += page.prs
            after = page.next
        } while after != nil && prs.count < first
        return prs
    }

    private static let attempts = 3

    /// GitHub answers with a 5xx now and then; `gh` prints it as "HTTP 502" and exits 1. A retry after a
    /// short pause almost always succeeds, and it keeps one bad response from marking the source red
    /// for a whole poll interval.
    ///
    /// `retrying: false` is for writes, which must run exactly once: a 502 returned after the mutation
    /// landed would otherwise post it twice.
    ///
    /// `gh` prints a failed call's body to stdout too. Only one holding GraphQL's `errors` is an answer, which the
    /// decoders turn into its messages; any other failure is HTTP's, and gh's stderr is what says why.
    func graphQL(query: String, variables: [String: any Sendable], retrying: Bool = true) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        var attempt = 0
        while true {
            let result = try await Shell.run(ghPath, ["api", "graphql", "--input", "-"], stdin: body)
            if result.status == 0 || GitHubDecoding.hasErrors(result.stdout) { return result.stdout }
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
            // Newest first, so when `first:` cuts the list it drops the oldest merges, never this month's.
            merged: "is:pr is:merged author:\(login) \(scope) merged:>=\(day) sort:updated-desc",
            // Everything open that someone else wrote. Drafts are dropped server-side because this is the
            // widest search of the four and `first:` would otherwise fill up with them.
            openForReview: "is:pr is:open draft:false -author:\(login) \(scope) sort:created-asc"
        )
    }

    public static let pullRequestStateQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) { state } }
    }
    """

    /// A PR's whole conversation. An outdated thread's `line` is null; `originalLine` is where it was written.
    /// ponytail: the first 100 threads, comments and reviews, and 100 comments a thread; page them if a PR ever has more.
    public static let conversationQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) {
        reviewThreads(first: 100) { nodes {
          id isResolved isOutdated path line originalLine diffSide viewerCanReply viewerCanResolve viewerCanUnresolve
          comments(first: 100) { nodes { id author { __typename login avatarUrl(size: 64) } body createdAt url } }
        } }
        comments(first: 100) { nodes { id author { __typename login avatarUrl(size: 64) } body createdAt url } }
        reviews(first: 100) { nodes { id state body submittedAt url author { __typename login avatarUrl(size: 64) } } }
      } }
    }
    """

    /// ponytail: the first 100 contexts and 50 steps of each; a PR with more checks than that loses the rest.
    public static let checksQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) {
        commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
          __typename
          ... on CheckRun {
            name status conclusion detailsUrl startedAt completedAt
            checkSuite { workflowRun { workflow { name } } }
            steps(first: 50) { nodes { name conclusion } }
            annotations(first: 10) { nodes { message annotationLevel } }
          }
          ... on StatusContext { context state targetUrl description createdAt }
        } } } } } }
      } }
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

    /// The open threads are only counted here.
    public static let searchQuery = searchQuery(threads: "reviewThreads(first: 100) { nodes { isResolved } }")

    /// Your own PRs' search: each thread in full, for the PR page's list, and the comments the /pre-pr evidence is one
    /// of. /pre-pr edits its one evidence comment in place, and posts it while the PR is a draft, so it is early on.
    /// ponytail: the first 50 comments; read the evidence by REST if a PR ever has more before it.
    public static let mineSearchQuery = searchQuery(threads: """
      reviewThreads(first: 100) { nodes { id isResolved isOutdated path line originalLine
        comments(first: 1) { totalCount nodes { author { __typename login } body url } } } }
      comments(first: 50) { nodes { author { __typename login } body } }
      """)

    private static func searchQuery(threads: String) -> String {
        """
    query($q: String!, $first: Int!, $after: String) {
      search(query: $q, type: ISSUE, first: $first, after: $after) { pageInfo { hasNextPage endCursor } nodes { ...PR } }
    }
    fragment PR on PullRequest {
      number title body url isDraft createdAt updatedAt mergedAt state baseRefName headRefName additions deletions
      author { __typename login }
      repository { nameWithOwner }
      reviewDecision
      mergeStateStatus
      baseRef { rules(first: 20) { nodes { type parameters { ... on PullRequestParameters { requiredApprovingReviewCount requireCodeOwnerReview } } } } }
      commits(last: 1) { nodes { commit {
        oid statusCheckRollup { state contexts(first: 100) { totalCount nodes {
          __typename
          ... on CheckRun { name status conclusion startedAt checkSuite { workflowRun { workflow { name } } } }
          ... on StatusContext { context state createdAt }
        } } }
        status { context(name: "\(ApprovalGate.context)") { description } }
      } } }
      reviews(first: 100) { nodes { state submittedAt author { __typename login } } }
      pending: reviews(states: PENDING, first: 1) {
        nodes { id commit { oid } comments { totalCount } }
      }
      reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { name } } } }
      timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], first: 50) {
        nodes { ... on ReviewRequestedEvent { createdAt requestedReviewer { __typename ... on User { login } ... on Team { name } } } }
      }
      \(threads)
      labels(first: 20) { nodes { name } }
    }
    """
    }
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

    public static func checks(from data: Data) throws -> [PullRequestCheck] {
        let response = try JSON.decoder().decode(Response<ChecksData>.self, from: data)
        if let errors = response.errors, !errors.isEmpty { throw GitHubError.graphQL(errors.map(\.message)) }
        guard let pr = response.data?.repository?.pullRequest else { throw GitHubError.emptyResponse }
        let nodes = pr.commits.nodes.first?.commit.statusCheckRollup?.contexts.nodes ?? []
        return PullRequestCheck.newest(nodes.map(check))
    }

    public static func conversation(from data: Data) throws -> Conversation {
        let response = try JSON.decoder().decode(Response<ConversationData>.self, from: data)
        if let errors = response.errors, !errors.isEmpty { throw GitHubError.graphQL(errors.map(\.message)) }
        guard let pr = response.data?.repository?.pullRequest else { throw GitHubError.emptyResponse }
        let threads = pr.reviewThreads.nodes.map { node in
            ConversationThread(
                id: node.id, path: node.path, line: node.line ?? node.originalLine,
                side: DiffSide(rawValue: node.diffSide ?? "") ?? .right, isResolved: node.isResolved,
                isOutdated: node.isOutdated, canReply: node.viewerCanReply,
                canToggle: node.isResolved ? node.viewerCanUnresolve : node.viewerCanResolve,
                comments: node.comments.nodes.map(conversationComment)
            )
        }
        let comments = pr.comments.nodes.map { ConversationEntry(kind: .comment, comment: conversationComment($0)) }
        // A review that only carries line comments says nothing of its own: they are in its threads. A pending one is
        // your draft, not yet said.
        let reviews = pr.reviews.nodes.compactMap { node -> ConversationEntry? in
            guard let submittedAt = node.submittedAt, node.state != "PENDING" else { return nil }
            if node.state == "COMMENTED", node.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            let comment = ConversationComment(
                id: node.id, author: node.author?.name ?? "ghost", avatar: node.author?.avatarUrl, body: node.body,
                createdAt: submittedAt, url: node.url
            )
            return ConversationEntry(kind: .review(state: node.state), comment: comment)
        }
        return Conversation(threads: threads, entries: (comments + reviews).sorted { $0.comment.createdAt < $1.comment.createdAt })
    }

    /// A deleted account's comment has no author; GitHub shows it as ghost's.
    private static func conversationComment(_ node: ConversationCommentNode) -> ConversationComment {
        ConversationComment(
            id: node.id, author: node.author?.name ?? "ghost", avatar: node.author?.avatarUrl, body: node.body,
            createdAt: node.createdAt, url: node.url
        )
    }

    /// Whether the body is GraphQL's own answer naming what went wrong, rather than a failed HTTP call's.
    static func hasErrors(_ data: Data) -> Bool {
        struct Answer: Decodable { var errors: [GraphQLError]? }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.errors?.isEmpty == false
    }

    /// A write's answer: only its errors matter.
    static func throwErrors(in data: Data) throws {
        struct Answer: Decodable { var errors: [GraphQLError]? }
        if let errors = try JSON.decoder().decode(Answer.self, from: data).errors, !errors.isEmpty {
            throw GitHubError.graphQL(errors.map(\.message))
        }
    }

    /// A check run or a commit status, as the Checks card and the search's checks state read it.
    private static func check(_ node: CheckNode) -> PullRequestCheck {
        if let context = node.context {
            return PullRequestCheck(
                name: context, outcome: outcome(state: node.state), url: node.targetUrl, startedAt: node.createdAt,
                errors: outcome(state: node.state) == .failed ? [node.description].compactMap { $0 } : []
            )
        }
        return PullRequestCheck(
            name: node.name ?? "Unnamed check", workflow: node.checkSuite?.workflowRun?.workflow.name,
            outcome: outcome(status: node.status, conclusion: node.conclusion),
            url: node.detailsUrl, startedAt: node.startedAt, completedAt: node.completedAt,
            failedStep: node.steps?.nodes.first { $0.conclusion == "FAILURE" }?.name,
            errors: (node.annotations?.nodes ?? []).filter { $0.annotationLevel == "FAILURE" }.map(\.message)
        )
    }

    /// A check run: not finished is running, whatever it waits on; action required and timed out are failures.
    static func outcome(status: String?, conclusion: String?) -> PullRequestCheck.Outcome {
        guard status == "COMPLETED" else { return .running }
        switch conclusion {
        case "SUCCESS": return .passed
        case "SKIPPED": return .skipped
        case "NEUTRAL", "STALE": return .neutral
        case "CANCELLED": return .cancelled
        default: return .failed
        }
    }

    /// A commit status.
    static func outcome(state: String?) -> PullRequestCheck.Outcome {
        switch state {
        case "SUCCESS": return .passed
        case "PENDING", "EXPECTED": return .running
        default: return .failed
        }
    }

    public static func pullRequests(from data: Data) throws -> (prs: [PullRequest], next: String?) {
        let response = try JSON.decoder().decode(Response<SearchData>.self, from: data)
        if let errors = response.errors, !errors.isEmpty { throw GitHubError.graphQL(errors.map(\.message)) }
        guard let search = response.data?.search else { throw GitHubError.emptyResponse }
        let next = search.pageInfo?.hasNextPage == true ? search.pageInfo?.endCursor : nil
        return (search.nodes.map(pullRequest), next)
    }

    private static func pullRequest(_ node: PRNode) -> PullRequest {
        let commit = node.commits.nodes.first?.commit
        // The newest run of each check, as the merge box judges them, when every check came back; past 100, nil, and the
        // state falls back to GitHub's own sum, which counts a superseded cancel as a failure.
        let runs = commit?.statusCheckRollup.flatMap { rollup in
            rollup.contexts.nodes.flatMap { nodes in
                nodes.count >= rollup.contexts.totalCount ? PullRequestCheck.newest(nodes.map(check)) : nil
            }
        }
        let reviews = node.reviews.nodes.compactMap { review -> Review? in
            guard let submittedAt = review.submittedAt else { return nil }
            return Review(state: review.state, submittedAt: submittedAt, author: review.author?.name ?? "ghost")
        }
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
            author: node.author?.name ?? "ghost",
            reviewDecision: node.reviewDecision.flatMap(ReviewDecision.init) ?? decision(from: reviews, required: node.baseRef?.requiredApprovals ?? 0),
            mergeState: node.mergeStateStatus.flatMap(MergeState.init) ?? .unknown,
            checks: runs.map { CheckState(newest: $0) } ?? commit?.statusCheckRollup.flatMap { CheckState(rawValue: $0.state) } ?? .none,
            checkCount: runs?.count ?? commit?.statusCheckRollup?.contexts.totalCount ?? 0,
            reviews: reviews,
            requestedReviewers: node.reviewRequests.nodes.compactMap { $0.requestedReviewer?.displayName },
            reviewRequestEvents: node.timelineItems.nodes.compactMap { event in
                guard let createdAt = event.createdAt, let reviewer = event.requestedReviewer else { return nil }
                return ReviewRequestEvent(createdAt: createdAt, reviewer: reviewer.displayName, isTeam: reviewer.typename == "Team")
            },
            unresolvedThreads: node.reviewThreads?.nodes.filter { !$0.isResolved }.count ?? 0,
            pendingReview: node.pending?.nodes.first.map { review in
                PendingReview(id: review.id, commitId: review.commit?.oid ?? "", comments: review.comments.totalCount)
            },
            labels: node.labels?.nodes.map(\.name) ?? [],
            threads: (node.reviewThreads?.nodes ?? []).filter { !$0.isResolved }.compactMap { thread in
                // Only your own PRs' search asks for the path and the comment.
                guard let id = thread.id, let path = thread.path, let first = thread.comments?.nodes.first, let body = first.body
                else { return nil }
                return ReviewThread(
                    id: id, path: path, line: thread.line ?? thread.originalLine, isOutdated: thread.isOutdated ?? false,
                    url: first.url ?? node.url, author: first.author?.name ?? "ghost", body: body,
                    comments: thread.comments?.totalCount ?? 1
                )
            },
            // The author's, as the review gate reads it: anyone can paste the marker into a comment.
            evidence: node.comments?.nodes.last { comment in
                comment.author?.name == node.author?.name
                    && comment.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(PrePR.evidenceMarker)
            }?.body,
            approvalStatus: commit?.status?.context.map { $0.description ?? "" }
        )
    }

    /// GitHub can leave `reviewDecision` null under a ruleset: cofhe's master asks for a code owner's review and
    /// still gets null, approved or not. Read it off the reviews then, as GitHub's own badge does: each reviewer's
    /// latest approval or change request stands, and a later plain comment doesn't undo it.
    private static func decision(from reviews: [Review], required: Int) -> ReviewDecision {
        var latest: [String: String] = [:]
        for review in reviews.sorted(by: { $0.submittedAt < $1.submittedAt })
        where ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains(review.state) {
            latest[review.author] = review.state
        }
        if latest.values.contains("CHANGES_REQUESTED") { return .changesRequested }
        let approvals = latest.values.count { $0 == "APPROVED" }
        if approvals > 0 && approvals >= required { return .approved }
        return required > 0 ? .reviewRequired : .none
    }

    private struct Response<T: Decodable>: Decodable {
        var data: T?
        var errors: [GraphQLError]?
    }

    private struct GraphQLError: Decodable { var message: String }
    private struct ViewerData: Decodable { var viewer: Login }
    /// GraphQL gives a bot's login without the `[bot]` the web and the REST API show, so `name` puts it back: that
    /// suffix is how the app tells a bot's PRs and reviews from a person's.
    private struct Login: Decodable {
        var login: String
        var typename: String?
        /// Only where the query asks for it: the conversation's.
        var avatarUrl: String?
        var name: String { typename == "Bot" ? "\(login)[bot]" : login }

        enum CodingKeys: String, CodingKey {
            case login
            case typename = "__typename"
            case avatarUrl
        }
    }
    private struct Repository: Decodable { var nameWithOwner: String }

    private struct ConversationData: Decodable { var repository: ConversationRepository? }
    private struct ConversationRepository: Decodable { var pullRequest: ConversationPR? }
    private struct ConversationPR: Decodable {
        var reviewThreads: ConversationNodes<ConversationThreadNode>
        var comments: ConversationNodes<ConversationCommentNode>
        var reviews: ConversationNodes<ConversationReviewNode>
    }
    private struct ConversationNodes<Node: Decodable>: Decodable { var nodes: [Node] }
    private struct ConversationThreadNode: Decodable {
        var id: String
        var isResolved: Bool
        var isOutdated: Bool
        var path: String
        var line: Int?
        var originalLine: Int?
        var diffSide: String?
        var viewerCanReply: Bool
        var viewerCanResolve: Bool
        var viewerCanUnresolve: Bool
        var comments: ConversationNodes<ConversationCommentNode>
    }
    private struct ConversationCommentNode: Decodable {
        var id: String
        var author: Login?
        var body: String
        var createdAt: Date
        var url: String
    }
    private struct ConversationReviewNode: Decodable {
        var id: String
        var state: String
        var body: String
        var submittedAt: Date?
        var url: String
        var author: Login?
    }

    private struct ChecksData: Decodable { var repository: ChecksRepository? }
    private struct ChecksRepository: Decodable { var pullRequest: ChecksPR? }
    private struct ChecksPR: Decodable { var commits: ChecksCommits }
    private struct ChecksCommits: Decodable { var nodes: [ChecksCommitNode] }
    private struct ChecksCommitNode: Decodable { var commit: ChecksCommit }
    private struct ChecksCommit: Decodable { var statusCheckRollup: ChecksRollup? }
    private struct ChecksRollup: Decodable { var contexts: CheckNodes }
    private struct CheckNodes: Decodable { var nodes: [CheckNode] }
    /// A check run or a commit status: the two share the list, so every field is optional.
    private struct CheckNode: Decodable {
        var name: String?
        var status: String?
        var conclusion: String?
        var detailsUrl: String?
        var startedAt: Date?
        var completedAt: Date?
        var checkSuite: CheckSuite?
        var steps: Steps?
        var annotations: Annotations?
        var context: String?
        var state: String?
        var targetUrl: String?
        var description: String?
        var createdAt: Date?
    }
    private struct CheckSuite: Decodable { var workflowRun: WorkflowRun? }
    private struct WorkflowRun: Decodable { var workflow: Workflow }
    private struct Workflow: Decodable { var name: String }
    private struct Steps: Decodable { var nodes: [Step] }
    private struct Step: Decodable {
        var name: String
        var conclusion: String?
    }
    private struct Annotations: Decodable { var nodes: [Annotation] }
    private struct Annotation: Decodable {
        var message: String
        var annotationLevel: String?
    }

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

    private struct SearchResult: Decodable {
        var pageInfo: PageInfo?
        var nodes: [PRNode]
    }

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
        var baseRef: BaseRef?
        var commits: Commits
        var reviews: Reviews
        /// Your own pending review, the only one GitHub shows. Optional so a query without it still decodes.
        var pending: PendingReviews?
        var reviewRequests: ReviewRequests
        var timelineItems: Timeline
        var reviewThreads: ReviewThreads?
        var labels: Labels?
        /// The PR's conversation, your own PRs' only.
        var comments: IssueComments?
    }

    private struct IssueComments: Decodable { var nodes: [IssueComment] }
    private struct IssueComment: Decodable {
        var author: Login?
        var body: String
    }

    private struct Labels: Decodable { var nodes: [Label] }
    private struct Label: Decodable { var name: String }

    private struct BaseRef: Decodable {
        var rules: Rules?

        /// The approvals the branch's rulesets ask for; a code owner's review counts as one.
        /// ponytail: a code-owner rule counts even where CODEOWNERS doesn't cover the changed files, and any approver
        /// meets it; read CODEOWNERS and team membership if a repo ever owns only part of its tree.
        var requiredApprovals: Int {
            (rules?.nodes ?? []).filter { $0.type == "PULL_REQUEST" }.map { rule in
                max(rule.parameters?.requiredApprovingReviewCount ?? 0, rule.parameters?.requireCodeOwnerReview == true ? 1 : 0)
            }.max() ?? 0
        }
    }
    private struct Rules: Decodable { var nodes: [Rule] }
    private struct Rule: Decodable {
        var type: String
        var parameters: RuleParameters?
    }
    private struct RuleParameters: Decodable {
        var requiredApprovingReviewCount: Int?
        var requireCodeOwnerReview: Bool?
    }

    private struct ReviewThreads: Decodable { var nodes: [ReviewThreadNode] }
    private struct ReviewThreadNode: Decodable {
        var id: String?
        var isResolved: Bool
        var isOutdated: Bool?
        var path: String?
        var line: Int?
        var originalLine: Int?
        /// The first comment only, for who started the thread and what it says.
        var comments: ThreadComments?
    }
    private struct ThreadComments: Decodable {
        var totalCount: Int?
        var nodes: [ThreadComment]
    }
    private struct ThreadComment: Decodable {
        var author: Login?
        var body: String?
        var url: String?
    }

    private struct Commits: Decodable { var nodes: [CommitNode] }
    private struct CommitNode: Decodable { var commit: Commit }
    private struct Commit: Decodable {
        var oid: String
        var statusCheckRollup: Rollup?
        /// The review gate's status alone, asked for by its context.
        var status: Status?
    }
    private struct Status: Decodable { var context: StatusContext? }
    private struct StatusContext: Decodable { var description: String? }
    private struct Rollup: Decodable {
        var state: String
        var contexts: RollupContexts
    }
    private struct RollupContexts: Decodable {
        var totalCount: Int
        var nodes: [CheckNode]?
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
    private struct PendingComments: Decodable { var totalCount: Int }
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
