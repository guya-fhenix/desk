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
    public var id: String
    /// The commit its comments were written against.
    public var commitId: String
    public var comments: Int

    public init(id: String, commitId: String = "", comments: Int) {
        self.id = id
        self.commitId = commitId
        self.comments = comments
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
    /// Its label names. CodeRabbit sets `risk:*` and `needs-human` by REVIEW.md, which the review queue goes by.
    public var labels: [String]
    /// The unresolved threads in full, for your PR's page. Only your own PRs' search asks for them: empty on the rest,
    /// where `unresolvedThreads` still counts them.
    public var threads: [ReviewThread]
    /// The body of the author's /pre-pr evidence comment; nil without one, and on PRs not yours.
    public var evidence: String?
    /// The description of the `review-gate/approvals` status on the head commit; nil where the repo posts none.
    public var approvalStatus: String?

    /// CodeRabbit's login as the app spells a bot's, `[bot]` and all.
    public static let codeRabbit = "coderabbitai[bot]"

    /// CodeRabbit says a person has to read this one: it goes first in the review queue.
    public var needsHuman: Bool { labels.contains("needs-human") }
    /// /pre-pr passed it: no Important finding of its is open. Without the label, a self-reviewed draft still has one.
    public var isLocallyReviewed: Bool { labels.contains(PrePR.reviewedLabel) }
    /// CodeRabbit's risk tier, "low" to "critical", once it has set one.
    public var risk: String? { labels.first { $0.hasPrefix("risk:") }.map { String($0.dropFirst("risk:".count)) } }
    /// The review gate's verdict, where the repo has one.
    public var approvalGate: ApprovalGate? { approvalStatus.map(ApprovalGate.init(description:)) }
    /// Has the approvals it needs: by the review gate where the repo has one, by GitHub's review decision where not.
    public var approvalsMet: Bool { approvalGate?.isMet ?? (reviewDecision == .approved) }
    /// Still short of approvals, not known yet, or in a repo without the review gate: the review queue's default.
    public var needsApproval: Bool { approvalGate?.isMet != true }

    public init(
        number: Int, title: String, body: String = "", url: String, repo: String, isDraft: Bool = false,
        state: PullRequestState = .open, createdAt: Date, updatedAt: Date, mergedAt: Date? = nil,
        baseRef: String, headRef: String, headSha: String = "", additions: Int = 0, deletions: Int = 0,
        author: String, reviewDecision: ReviewDecision = .none, mergeState: MergeState = .unknown,
        checks: CheckState = .none, checkCount: Int = 0, reviews: [Review] = [],
        requestedReviewers: [String] = [], reviewRequestEvents: [ReviewRequestEvent] = [], unresolvedThreads: Int = 0,
        pendingReview: PendingReview? = nil, labels: [String] = [], threads: [ReviewThread] = [], evidence: String? = nil,
        approvalStatus: String? = nil
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
        self.labels = labels
        self.threads = threads
        self.evidence = evidence
        self.approvalStatus = approvalStatus
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

/// The `review-gate/approvals` commit status, read from its description: until a repo turns on Enforce the status is
/// always a success, so the words are what say where the PR stands. Its forms, each maybe followed by "; " and a note:
/// "Draft: approvals are checked once the PR is ready", "Waiting for CodeRabbit's review of the latest commit",
/// "<tier> risk: no approval needed", "<tier> risk: <have> of <needed> approvals on the latest commit".
public struct ApprovalGate: Sendable, Hashable {
    public static let context = "review-gate/approvals"

    public enum State: Sendable, Hashable {
        case draft
        /// CodeRabbit has not reviewed the latest commit, so no approval counts yet.
        case waitingForCodeRabbit
        /// `have` of `needed` approvals on the latest commit; "no approval needed" is 0 of 0.
        case counted(have: Int, needed: Int)
        /// Words this app does not know.
        case unknown
    }

    public var state: State
    /// The risk tier the description names, "low" to "high".
    public var tier: String?

    public init(description: String) {
        let head = description.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        tier = nil
        if head.hasPrefix("Draft:") {
            state = .draft
        } else if head.hasPrefix("Waiting for CodeRabbit") {
            state = .waitingForCodeRabbit
        } else if let match = head.wholeMatch(of: /(\w+) risk: (.+)/) {
            tier = String(match.output.1)
            if match.output.2 == "no approval needed" {
                state = .counted(have: 0, needed: 0)
            } else if let count = match.output.2.wholeMatch(of: /(\d+) of (\d+) approvals? on the latest commit/),
                      let have = Int(count.output.1), let needed = Int(count.output.2) {
                state = .counted(have: have, needed: needed)
            } else {
                state = .unknown
            }
        } else {
            state = .unknown
        }
    }

    /// Enough approvals on the latest commit, or none needed.
    public var isMet: Bool {
        if case .counted(let have, let needed) = state { return have >= needed }
        return false
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

extension PullRequestCheck {
    /// The newest run of each check, as GitHub's merge box judges a commit: a run of the same check on the same commit — a
    /// re-run, or a newer event whose run cancelled the older one — replaces the one before. A check is its workflow and
    /// its name; a run with no start time counts as the oldest. GitHub's own sum of a commit, its rollup state, counts every
    /// run, so a superseded cancel turns it red while the merge box shows all green.
    public static func newest(_ checks: [PullRequestCheck]) -> [PullRequestCheck] {
        var kept: [String: PullRequestCheck] = [:]
        var order: [String] = []
        for check in checks {
            let key = "\(check.workflow ?? "")\u{0}\(check.name)"
            if let current = kept[key] {
                if (check.startedAt ?? .distantPast) > (current.startedAt ?? .distantPast) { kept[key] = check }
            } else {
                kept[key] = check
                order.append(key)
            }
        }
        return order.compactMap { kept[$0] }
    }
}

extension CheckState {
    /// What the newest runs add up to: a failed or cancelled one is a failure, then one still running is pending, then
    /// success; no checks at all is none.
    public init(newest checks: [PullRequestCheck]) {
        if checks.isEmpty {
            self = .none
        } else if checks.contains(where: { $0.outcome == .failed || $0.outcome == .cancelled }) {
            self = .failure
        } else if checks.contains(where: { $0.outcome == .running }) {
            self = .pending
        } else {
            self = .success
        }
    }
}
