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
    /// Node ids of the resolved ones, which is how a proposed fix learns its thread was dealt with elsewhere.
    public var resolvedThreads: Set<String>
    /// Your draft review on this PR, if you have one.
    public var pendingReview: PendingReview?
    /// Its label names. CodeRabbit sets `risk:*` and `needs-human` by REVIEW.md, which the review queue goes by.
    public var labels: [String]
    /// Unresolved threads CodeRabbit started: its actionable findings, since its nitpicks stay in its review body.
    public var codeRabbitThreads: Int

    /// CodeRabbit's login as the app spells a bot's, `[bot]` and all.
    public static let codeRabbit = "coderabbitai[bot]"

    /// CodeRabbit says a person has to read this one: it goes first in the review queue.
    public var needsHuman: Bool { labels.contains("needs-human") }
    /// CodeRabbit's risk tier, "low" to "critical", once it has set one.
    public var risk: String? { labels.first { $0.hasPrefix("risk:") }.map { String($0.dropFirst("risk:".count)) } }

    public init(
        number: Int, title: String, body: String = "", url: String, repo: String, isDraft: Bool = false,
        state: PullRequestState = .open, createdAt: Date, updatedAt: Date, mergedAt: Date? = nil,
        baseRef: String, headRef: String, headSha: String = "", additions: Int = 0, deletions: Int = 0,
        author: String, reviewDecision: ReviewDecision = .none, mergeState: MergeState = .unknown,
        checks: CheckState = .none, checkCount: Int = 0, reviews: [Review] = [],
        requestedReviewers: [String] = [], reviewRequestEvents: [ReviewRequestEvent] = [], unresolvedThreads: Int = 0,
        resolvedThreads: Set<String> = [], pendingReview: PendingReview? = nil, labels: [String] = [],
        codeRabbitThreads: Int = 0
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
        self.resolvedThreads = resolvedThreads
        self.pendingReview = pendingReview
        self.labels = labels
        self.codeRabbitThreads = codeRabbitThreads
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

/// One check on a pull request's head commit: an Actions job, another app's check run, or a commit status. What a PR
/// page's Checks card lists, fetched for the one PR on view rather than with every search.
public struct PullRequestCheck: Sendable, Hashable, Identifiable {
    /// Worst first, which is the order the Checks card lists them in.
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
}

/// Where one reviewer stands on a PR, as the PR page's Reviewers card lists them.
public struct ReviewerStatus: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable { case approved, changesRequested, commented, dismissed, pending }

    public var name: String
    public var state: State
    public var id: String { name }

    public init(name: String, state: State) {
        self.name = name
        self.state = state
    }
}

extension PullRequest {
    /// Everyone who reviewed, by where they last stood — an approval or a change request outweighs a later comment,
    /// as GitHub counts it — then everyone asked who has not answered since, as pending. A re-request puts a reviewer
    /// back to pending. The author's own replies are not a review.
    public var reviewerStatuses: [ReviewerStatus] {
        var standing: [String: ReviewerStatus.State] = [:]
        var order: [String] = []
        for review in reviews.sorted(by: { $0.submittedAt < $1.submittedAt }) where review.author != author {
            let state: ReviewerStatus.State
            switch review.state {
            case "APPROVED": state = .approved
            case "CHANGES_REQUESTED": state = .changesRequested
            case "DISMISSED": state = .dismissed
            case "COMMENTED":
                if let held = standing[review.author], held != .commented { continue }
                state = .commented
            default: continue
            }
            if standing[review.author] == nil { order.append(review.author) }
            standing[review.author] = state
        }
        let asked = Set(requestedReviewers)
        return order.filter { !asked.contains($0) }.compactMap { name in standing[name].map { ReviewerStatus(name: name, state: $0) } }
            + requestedReviewers.map { ReviewerStatus(name: $0, state: .pending) }
    }

    /// Why GitHub would refuse a squash merge now, in the words the Merge button shows under it; nil when it would
    /// take one. Clean, unstable (a check that is not required failed) and hooks-pending all merge.
    public var mergeBlocker: String? {
        if isDraft || mergeState == .draft { return "A draft: mark it ready for review first" }
        switch mergeState {
        case .clean, .unstable, .hasHooks: return nil
        case .dirty: return "Conflicts with \(baseRef)"
        case .behind: return "Behind \(baseRef): update the branch first"
        case .unknown: return "GitHub is still working out whether it can merge"
        case .draft: return "A draft: mark it ready for review first"
        case .blocked:
            switch reviewDecision {
            case .changesRequested: return "Changes requested"
            case .reviewRequired: return "Needs an approving review"
            default: return checks.isRed ? "Required checks are failing" : "Blocked by the rules on \(baseRef)"
            }
        }
    }
}

extension Array where Element == PullRequest {
    /// The PRs that need a person first, each group in the order it came in.
    public var needsHumanFirst: [PullRequest] { filter(\.needsHuman) + filter { !$0.needsHuman } }
}
