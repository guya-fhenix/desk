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

/// Where a run is. Stored rather than derived: with a foreground process there is no session file to read
/// it back out of, so the runner is the only thing that knows. Where the draft stands after that is
/// GitHub's to say — see `DraftStatus`.
public enum ReviewPhase: String, Codable, Sendable, Hashable {
    case queued, preparing, running, posting, posted, failed

    public var label: String {
        switch self {
        case .queued: return "queued"
        case .preparing: return "preparing"
        case .running: return "reviewing"
        case .posting: return "posting the draft"
        case .posted: return "posted"
        case .failed: return "failed"
        }
    }

    public var isBusy: Bool { self == .queued || self == .preparing || self == .running || self == .posting }
}

/// The pending review a run put its comments in. Enough to find it again and to tell, from the next
/// poll, whether it is still waiting, was sent, or was thrown away.
public struct ReviewDraft: Codable, Sendable, Hashable {
    /// GraphQL node id of the pending review.
    public var id: String
    /// The head the comments were written against.
    public var commitId: String
    /// When a run last added to it. A review of yours submitted after this is that draft, sent.
    public var postedAt: Date

    public init(id: String, commitId: String, postedAt: Date) {
        self.id = id
        self.commitId = commitId
        self.postedAt = postedAt
    }
}

/// One PR's Claude review: the runs and the draft they fed. The comments themselves live on GitHub.
public struct ReviewRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String { prUrl }
    public var prUrl: String
    /// owner/name
    public var repo: String
    public var number: Int
    /// Kept so the row still reads well after the PR leaves the review queue.
    public var title: String
    public var author: String
    public var baseRef: String

    public var worktreePath: String
    /// Main checkout of the repo: `git worktree add/remove` and every blob read run here.
    public var repoRoot: String

    /// The head the latest run reviewed.
    public var headSha: String
    public var draft: ReviewDraft?
    /// Comments the latest run added to the draft.
    public var lastPosted: Int
    /// Comments the latest run could not post: the model named a file this PR does not change, or the
    /// draft already had a comment on that line.
    public var lastSkipped: Int

    public var startedAt: Date
    /// Start of the latest run; a review request after this counts as a re-request.
    public var lastRunAt: Date
    public var lastFinishedAt: Date?
    public var runs: Int
    public var consecutiveFailures: Int
    public var costUSD: Double
    public var lastRunCostUSD: Double?
    public var phase: ReviewPhase
    public var error: String?

    public init(pr: PullRequest, worktreePath: String, repoRoot: String, now: Date) {
        prUrl = pr.url
        repo = pr.repo
        number = pr.number
        title = pr.title
        author = pr.author
        baseRef = pr.baseRef
        self.worktreePath = worktreePath
        self.repoRoot = repoRoot
        headSha = ""
        draft = nil
        lastPosted = 0
        lastSkipped = 0
        startedAt = now
        lastRunAt = now
        lastFinishedAt = nil
        runs = 0
        consecutiveFailures = 0
        costUSD = 0
        lastRunCostUSD = nil
        phase = .queued
        error = nil
    }

    public var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    public var owner: String { repo.split(separator: "/").first.map(String.init) ?? repo }
    public var label: String { "\(repoName)#\(number)" }
    /// Where the draft is read and finished: GitHub's Files tab, which is where pending comments show.
    public var filesURL: String { "\(prUrl)/files" }

    enum CodingKeys: String, CodingKey {
        case prUrl, repo, number, title, author, baseRef, worktreePath, repoRoot, headSha, draft, lastPosted
        case lastSkipped, startedAt, lastRunAt, lastFinishedAt, runs, consecutiveFailures, costUSD, lastRunCostUSD
        case phase, error
    }

    /// Hand-written so a field added later reads as its default: losing a record would lose the handle on
    /// a draft that is still waiting on GitHub. Same reasoning as `DeskConfig`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prUrl = try container.decodeIfPresent(String.self, forKey: .prUrl) ?? ""
        repo = try container.decodeIfPresent(String.self, forKey: .repo) ?? ""
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        baseRef = try container.decodeIfPresent(String.self, forKey: .baseRef) ?? ""
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath) ?? ""
        repoRoot = try container.decodeIfPresent(String.self, forKey: .repoRoot) ?? ""
        headSha = try container.decodeIfPresent(String.self, forKey: .headSha) ?? ""
        draft = try container.decodeIfPresent(ReviewDraft.self, forKey: .draft)
        lastPosted = try container.decodeIfPresent(Int.self, forKey: .lastPosted) ?? 0
        lastSkipped = try container.decodeIfPresent(Int.self, forKey: .lastSkipped) ?? 0
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt) ?? startedAt
        lastFinishedAt = try container.decodeIfPresent(Date.self, forKey: .lastFinishedAt)
        runs = try container.decodeIfPresent(Int.self, forKey: .runs) ?? 0
        consecutiveFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        lastRunCostUSD = try container.decodeIfPresent(Double.self, forKey: .lastRunCostUSD)
        phase = try container.decodeIfPresent(ReviewPhase.self, forKey: .phase) ?? .posted
        error = try container.decodeIfPresent(String.self, forKey: .error)
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

/// What one run cost. Kept as a rolling list so a day's spend across every PR can be capped.
public struct RunCost: Codable, Sendable, Hashable {
    public var at: Date
    public var usd: Double
    public var prUrl: String

    public init(at: Date, usd: Double, prUrl: String) {
        self.at = at
        self.usd = usd
        self.prUrl = prUrl
    }
}

/// reviews.json. Versioned so a shape change starts clean instead of failing to decode.
public struct ReviewLedger: Codable, Sendable {
    /// 3: comments moved out to a pending review on GitHub. Older ledgers hold comment triage this
    /// version has nowhere to put, so they start clean — nothing on GitHub is touched.
    public static let currentVersion = 3
    /// A week is enough for the rolling daily budget and keeps the file small.
    public static let spendRetention: TimeInterval = 7 * 86_400

    public var version: Int
    public var records: [String: ReviewRecord]
    public var spend: [RunCost]

    public init(records: [String: ReviewRecord] = [:], spend: [RunCost] = []) {
        version = Self.currentVersion
        self.records = records
        self.spend = spend
    }

    public var isCurrent: Bool { version == Self.currentVersion }

    public func spent(since: Date) -> Double {
        spend.filter { $0.at > since }.reduce(0) { $0 + $1.usd }
    }

    public mutating func record(cost: Double, prUrl: String, now: Date) {
        guard cost > 0 else { return }
        spend.append(RunCost(at: now, usd: cost, prUrl: prUrl))
        let cutoff = now.addingTimeInterval(-Self.spendRetention)
        spend.removeAll { $0.at < cutoff }
    }
}

/// Where a run's draft stands on GitHub, read off the PR the last poll brought back.
public enum DraftStatus: Sendable, Hashable {
    /// Still pending, with this many comments — yours and Claude's, as GitHub counts them now.
    case pending(comments: Int)
    /// You submitted a review after the draft was posted: that is the draft, sent. The GitHub review state.
    case submitted(state: String)
    /// No pending review of yours and nothing submitted since: the draft was cancelled on GitHub.
    case discarded
}

/// The parts of a review's state that are derived from the PR rather than stored on the record.
public struct ReviewStatus: Sendable, Hashable {
    public var phase: ReviewPhase
    /// Nil when there is no draft, or when the PR is not in the snapshot to read it from.
    public var draft: DraftStatus?
    /// The PR head moved since the last run, so the draft's comments sit on an older commit.
    public var headMoved: Bool
    /// The user's review was requested again after the last run, which is what asks for a re-run.
    public var reRequested: Bool
    public var costUSD: Double

    public init(phase: ReviewPhase, draft: DraftStatus?, headMoved: Bool, reRequested: Bool, costUSD: Double) {
        self.phase = phase
        self.draft = draft
        self.headMoved = headMoved
        self.reRequested = reRequested
        self.costUSD = costUSD
    }

    public static func derive(record: ReviewRecord, pr: PullRequest?, login: String) -> ReviewStatus {
        ReviewStatus(
            phase: record.phase,
            draft: pr.flatMap { draftStatus(record.draft, pr: $0, login: login) },
            headMoved: pr.map { !$0.headSha.isEmpty && !record.headSha.isEmpty && $0.headSha != record.headSha } ?? false,
            reRequested: pr?.reviewRequestEvents.contains { !$0.isTeam && $0.reviewer == login && $0.createdAt > record.lastRunAt } ?? false,
            costUSD: record.costUSD
        )
    }

    /// A pending review with the draft's id is the draft. Failing that, a review you submitted since it
    /// was posted is the draft sent — GitHub keeps the id, but the snapshot only lists submitted reviews by
    /// state and time, which is all this needs.
    public static func draftStatus(_ draft: ReviewDraft?, pr: PullRequest, login: String) -> DraftStatus? {
        guard let draft else { return nil }
        if let pending = pr.pendingReview, pending.id == draft.id { return .pending(comments: pending.comments) }
        let sent = pr.reviews.filter { $0.author == login && $0.submittedAt >= draft.postedAt }.max { $0.submittedAt < $1.submittedAt }
        if let sent { return .submitted(state: sent.state) }
        return .discarded
    }

    public var isBusy: Bool { phase.isBusy }
}
