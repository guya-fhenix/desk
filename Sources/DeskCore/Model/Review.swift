import Foundation

/// One of Claude's findings with its line checked against the diff, on its way into the draft review.
/// Never stored: once posted, the draft on GitHub is the only copy, and it is yours to edit there.
public struct DraftComment: Sendable, Hashable {
    public var path: String
    public var line: Int
    public var side: DiffSide
    public var severity: CommentSeverity
    public var body: String
    /// The line number came from the model rather than from a match on the line it quoted, so it is a
    /// guess. The posted comment says so.
    public var isUnverified: Bool

    public init(path: String, line: Int, side: DiffSide, severity: CommentSeverity, body: String, isUnverified: Bool = false) {
        self.path = path
        self.line = line
        self.side = side
        self.severity = severity
        self.body = body
        self.isUnverified = isUnverified
    }
}

/// Where a run is. Held in memory only: the review it produces lives on GitHub, and a restart forgets a
/// run the same way it forgets the process that was doing it.
public enum ReviewPhase: String, Sendable, Hashable {
    case preparing, running, posting, posted, failed

    public var label: String {
        switch self {
        case .preparing: return "preparing"
        case .running: return "reviewing"
        case .posting: return "posting the draft"
        case .posted: return "posted"
        case .failed: return "failed"
        }
    }

    public var isBusy: Bool { self == .preparing || self == .running || self == .posting }
}

/// One run of Claude on a PR, this session. Everything that outlives it — the draft, what you did with
/// it — is read back from GitHub.
public struct ReviewRun: Sendable, Hashable {
    public var phase: ReviewPhase
    public var error: String?
    /// Comments this run added to your draft.
    public var posted: Int
    /// Comments it could not post: the model named a file this PR does not change, or the draft already
    /// had a comment on that line.
    public var skipped: Int

    public init(phase: ReviewPhase = .preparing, error: String? = nil, posted: Int = 0, skipped: Int = 0) {
        self.phase = phase
        self.error = error
        self.posted = posted
        self.skipped = skipped
    }
}

/// A local clone other than the PR's own that a review may consult. It is read at the remote default
/// branch the app fetched before launch, never at its working tree, which may be on any branch with
/// local edits.
public struct OtherRepo: Sendable, Hashable {
    public var name: String
    public var root: String
    /// `origin/main` or `origin/master`: whatever the clone's `origin/HEAD` names.
    public var ref: String
    /// False when the fetch before launch failed, so the ref is only as new as the last fetch that worked.
    public var fetched: Bool

    public init(name: String, root: String, ref: String, fetched: Bool) {
        self.name = name
        self.root = root
        self.ref = ref
        self.fetched = fetched
    }
}

/// Where your review of a PR stands on GitHub.
public enum DraftStatus: Sendable, Hashable {
    /// Your pending review: all its comments, and how many of them Claude wrote.
    case pending(comments: Int, claude: Int)
    /// Your latest submitted review, by its GitHub state.
    case submitted(state: String)
}

/// A PR's review, read off the PR the last poll brought back plus the run going on this session. Nothing
/// here is stored.
public struct ReviewStatus: Sendable, Hashable {
    public var run: ReviewRun?
    public var draft: DraftStatus?
    /// The PR head moved past the commit your pending review's comments were written against.
    public var headMoved: Bool
    /// Your review was requested after you last submitted one.
    public var reRequested: Bool

    public init(run: ReviewRun?, draft: DraftStatus?, headMoved: Bool, reRequested: Bool) {
        self.run = run
        self.draft = draft
        self.headMoved = headMoved
        self.reRequested = reRequested
    }

    public static func derive(pr: PullRequest, run: ReviewRun?, login: String) -> ReviewStatus {
        let answered = lastSubmitted(pr, by: login)
        let draft: DraftStatus?
        if let pending = pr.pendingReview {
            draft = .pending(comments: pending.comments, claude: pending.claudeComments)
        } else {
            draft = answered.map { .submitted(state: $0.state) }
        }
        return ReviewStatus(
            run: run,
            draft: draft,
            headMoved: pr.pendingReview.map { !$0.commitId.isEmpty && !pr.headSha.isEmpty && $0.commitId != pr.headSha } ?? false,
            reRequested: answered.map { requested(pr, by: login, after: $0.submittedAt) } ?? false
        )
    }

    /// The latest review you submitted on the PR.
    public static func lastSubmitted(_ pr: PullRequest, by login: String) -> Review? {
        pr.reviews.filter { $0.author == login }.max { $0.submittedAt < $1.submittedAt }
    }

    /// A request for you personally — a team request is not — made after `date`.
    public static func requested(_ pr: PullRequest, by login: String, after date: Date) -> Bool {
        pr.reviewRequestEvents.contains { !$0.isTeam && $0.reviewer == login && $0.createdAt > date }
    }

    public var isBusy: Bool { run?.phase.isBusy ?? false }
}
