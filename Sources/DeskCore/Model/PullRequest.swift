import Foundation

public enum ReviewDecision: String, Codable, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
    case none = "NONE"
}

public enum MergeState: String, Codable, Sendable {
    case behind = "BEHIND"
    case blocked = "BLOCKED"
    case clean = "CLEAN"
    case dirty = "DIRTY"
    case draft = "DRAFT"
    case hasHooks = "HAS_HOOKS"
    case unknown = "UNKNOWN"
    case unstable = "UNSTABLE"
}

public enum CheckState: String, Codable, Sendable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case error = "ERROR"
    case pending = "PENDING"
    case expected = "EXPECTED"
    case none = "NONE"

    public var isRed: Bool { self == .failure || self == .error }
    public var isPending: Bool { self == .pending || self == .expected }
}

public enum PullRequestState: String, Codable, Sendable {
    case open = "OPEN"
    case merged = "MERGED"
    case closed = "CLOSED"
}

public struct Review: Codable, Sendable, Hashable {
    public var state: String
    public var submittedAt: Date
    public var author: String

    public init(state: String, submittedAt: Date, author: String) {
        self.state = state
        self.submittedAt = submittedAt
        self.author = author
    }
}

/// Your own unsubmitted review on a PR. GitHub shows a pending review to its author only, so any pending
/// review the snapshot sees is yours — and there is at most one per PR.
public struct PendingReview: Codable, Sendable, Hashable {
    /// GraphQL node id, the handle every review mutation takes.
    public var id: String
    /// The commit its comments were written against.
    public var commitId: String
    public var comments: Int
    /// Comments carrying the app's marker: Claude's, as opposed to ones you wrote.
    public var claudeComments: Int

    public init(id: String, commitId: String = "", comments: Int, claudeComments: Int = 0) {
        self.id = id
        self.commitId = commitId
        self.comments = comments
        self.claudeComments = claudeComments
    }
}

public struct ReviewRequestEvent: Codable, Sendable, Hashable {
    public var createdAt: Date
    public var reviewer: String
    public var isTeam: Bool

    public init(createdAt: Date, reviewer: String, isTeam: Bool) {
        self.createdAt = createdAt
        self.reviewer = reviewer
        self.isTeam = isTeam
    }
}

public struct Automation: Sendable, Hashable {
    public var logins: Set<String>
    public var titlePrefixes: [String]

    public init(logins: Set<String>, titlePrefixes: [String]) {
        self.logins = logins
        self.titlePrefixes = titlePrefixes
    }
}

public struct PullRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: String { url }
    public var number: Int
    public var title: String
    /// The PR description as the author wrote it, GitHub-flavoured markdown and all.
    public var body: String
    public var url: String
    public var repo: String
    public var isDraft: Bool
    public var state: PullRequestState
    public var createdAt: Date
    public var updatedAt: Date
    public var mergedAt: Date?
    public var baseRef: String
    public var headRef: String
    public var headSha: String
    public var additions: Int
    public var deletions: Int
    public var author: String
    public var reviewDecision: ReviewDecision
    public var mergeState: MergeState
    public var checks: CheckState
    public var checkCount: Int
    public var reviews: [Review]
    public var requestedReviewers: [String]
    public var reviewRequestEvents: [ReviewRequestEvent]
    /// Review conversations nobody has resolved yet, outdated ones included: GitHub counts them the same way.
    public var unresolvedThreads: Int
    /// Your draft review on this PR, if you have one.
    public var pendingReview: PendingReview?

    public init(
        number: Int, title: String, body: String = "", url: String, repo: String, isDraft: Bool = false,
        state: PullRequestState = .open, createdAt: Date, updatedAt: Date, mergedAt: Date? = nil,
        baseRef: String, headRef: String, headSha: String = "", additions: Int = 0, deletions: Int = 0,
        author: String, reviewDecision: ReviewDecision = .none, mergeState: MergeState = .unknown,
        checks: CheckState = .none, checkCount: Int = 0, reviews: [Review] = [],
        requestedReviewers: [String] = [], reviewRequestEvents: [ReviewRequestEvent] = [], unresolvedThreads: Int = 0,
        pendingReview: PendingReview? = nil
    ) {
        self.number = number
        self.title = title
        self.body = body
        self.url = url
        self.repo = repo
        self.isDraft = isDraft
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.mergedAt = mergedAt
        self.baseRef = baseRef
        self.headRef = headRef
        self.headSha = headSha
        self.additions = additions
        self.deletions = deletions
        self.author = author
        self.reviewDecision = reviewDecision
        self.mergeState = mergeState
        self.checks = checks
        self.checkCount = checkCount
        self.reviews = reviews
        self.requestedReviewers = requestedReviewers
        self.reviewRequestEvents = reviewRequestEvents
        self.unresolvedThreads = unresolvedThreads
        self.pendingReview = pendingReview
    }

    public var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    public var size: Int { additions + deletions }

    /// Whether every word of a search appears in the PR's `repo#number`, title or branch, ignoring case — so
    /// "#1082", "1082", "cofhe#10" and "slim head" all find the PR they name.
    public func matches(search: String) -> Bool {
        let haystack = "\(repoName)#\(number) \(title) \(headRef)".lowercased()
        return search.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { haystack.contains($0) }
    }

    /// Bot accounts, and PRs a workflow opens under a human token (detected by title).
    public func isAutomated(_ automation: Automation) -> Bool {
        author.hasSuffix("[bot]") || automation.logins.contains(author) || automation.titlePrefixes.contains { title.hasPrefix($0) }
    }
}

/// One check on a pull request's head commit: an Actions job, another app's check run, or a commit status. What the
/// details panel lists under a PR's checks, fetched for the one PR on view rather than with every search.
public struct PullRequestCheck: Sendable, Hashable, Identifiable {
    /// Worst first, which is the order the panel lists them in.
    public enum Outcome: Int, Sendable, Comparable {
        case failed, running, cancelled, passed, neutral, skipped

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public var name: String
    /// The Actions workflow that ran it; nil for another app's check or a commit status.
    public var workflow: String?
    public var outcome: Outcome
    public var url: String?
    public var startedAt: Date?
    public var completedAt: Date?
    /// The step a failed Actions job stopped at.
    public var failedStep: String?
    /// What it reported as errors: its failure-level annotations, or a status's description.
    public var errors: [String]

    public var id: String { url ?? "\(workflow ?? "")/\(name)" }

    public init(
        name: String, workflow: String? = nil, outcome: Outcome, url: String? = nil, startedAt: Date? = nil,
        completedAt: Date? = nil, failedStep: String? = nil, errors: [String] = []
    ) {
        self.name = name
        self.workflow = workflow
        self.outcome = outcome
        self.url = url
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.failedStep = failedStep
        self.errors = errors
    }

    /// One workflow's checks, worst first.
    public struct Group: Sendable, Hashable, Identifiable {
        public var workflow: String
        public var checks: [PullRequestCheck]
        public var id: String { workflow }
        public var outcome: Outcome { checks.map(\.outcome).min() ?? .passed }
    }

    /// Grouped by workflow — the ones with no workflow together under "Other checks" — the worst group first, and
    /// the worst check first inside each.
    public static func grouped(_ checks: [PullRequestCheck]) -> [Group] {
        Dictionary(grouping: checks) { $0.workflow ?? "Other checks" }
            .map { Group(workflow: $0.key, checks: $0.value.sorted { ($0.outcome, $0.name) < ($1.outcome, $1.name) }) }
            .sorted { ($0.outcome, $0.workflow) < ($1.outcome, $1.workflow) }
    }
}
