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

    public var isApproval: Bool { state == "APPROVED" }
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

    /// Bot accounts, and PRs a workflow opens under a human token (detected by title).
    public func isAutomated(_ automation: Automation) -> Bool {
        author.hasSuffix("[bot]") || automation.logins.contains(author) || automation.titlePrefixes.contains { title.hasPrefix($0) }
    }

    public func humanReviews(botLogins: Set<String>) -> [Review] {
        reviews.filter { $0.author != author && !$0.author.hasSuffix("[bot]") && !botLogins.contains($0.author) }
    }
}
