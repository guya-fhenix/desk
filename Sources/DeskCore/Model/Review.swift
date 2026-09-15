import Foundation

public enum CommentState: String, Codable, Sendable, Hashable {
    case pending, approved, rejected

    public var title: String {
        switch self {
        case .pending: return "undecided"
        case .approved: return "approved"
        case .rejected: return "rejected"
        }
    }
}

/// What a comment points at, captured when it is written so a later push can be judged against it. The
/// neighbouring lines are what tell a line that merely moved from a line that changed.
public struct CommentAnchor: Codable, Sendable, Hashable {
    public var text: String
    public var before: [String]
    public var after: [String]
    /// The commit the line number refers to: the head for a RIGHT comment, the merge base for a LEFT one.
    public var sha: String

    public init(text: String, before: [String] = [], after: [String] = [], sha: String) {
        self.text = text
        self.before = before
        self.after = after
        self.sha = sha
    }
}

/// Where a comment sits. Two comments with the same key are the same finding, which is what lets a
/// re-run add findings without disturbing the ones already decided.
public struct CommentKey: Sendable, Hashable {
    public var path: String
    public var line: Int
    public var side: DiffSide

    public init(path: String, line: Int, side: DiffSide) {
        self.path = path
        self.line = line
        self.side = side
    }
}

/// One of Claude's findings, on its way to becoming a GitHub review comment or not.
public struct DraftComment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var path: String
    public var line: Int
    public var side: DiffSide
    public var severity: CommentSeverity
    /// Claude's words, never overwritten, so "the user rewrote this" stays visible.
    public var body: String
    /// The user's replacement. When set, this is what gets posted.
    public var editedBody: String?
    public var state: CommentState
    public var anchor: CommentAnchor
    /// The anchored line changed or vanished in a later push. Still shown; folded into the review body
    /// on submit rather than attached to a line that no longer says what it said.
    public var isOutdated: Bool
    /// The line number came from the model rather than from a match on the line it quoted, so it is a
    /// guess. Worth a hint in the UI and worth watching: a high rate means the prompt needs work.
    public var isUnverified: Bool
    public var firstRun: Int
    public var lastRun: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), path: String, line: Int, side: DiffSide, severity: CommentSeverity, body: String,
        editedBody: String? = nil, state: CommentState = .pending, anchor: CommentAnchor,
        isOutdated: Bool = false, isUnverified: Bool = false, run: Int = 1, now: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.side = side
        self.severity = severity
        self.body = body
        self.editedBody = editedBody
        self.state = state
        self.anchor = anchor
        self.isOutdated = isOutdated
        self.isUnverified = isUnverified
        firstRun = run
        lastRun = run
        createdAt = now
        updatedAt = now
    }

    /// What would be posted: the user's edit when there is one.
    public var text: String { editedBody ?? body }
    public var isUserEdited: Bool { editedBody != nil }
    public var key: CommentKey { CommentKey(path: path, line: line, side: side) }

    enum CodingKeys: String, CodingKey {
        case id, path, line, side, severity, body, editedBody, state, anchor
        case isOutdated, isUnverified, firstRun, lastRun, createdAt, updatedAt
    }

    /// Hand-written so a field added later reads as its default instead of throwing away every draft the
    /// user has already triaged. Same reasoning as `DeskConfig`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        line = try container.decodeIfPresent(Int.self, forKey: .line) ?? 0
        side = try container.decodeIfPresent(DiffSide.self, forKey: .side) ?? .right
        severity = try container.decodeIfPresent(CommentSeverity.self, forKey: .severity) ?? .minor
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        editedBody = try container.decodeIfPresent(String.self, forKey: .editedBody)
        state = try container.decodeIfPresent(CommentState.self, forKey: .state) ?? .pending
        anchor = try container.decodeIfPresent(CommentAnchor.self, forKey: .anchor) ?? CommentAnchor(text: "", sha: "")
        isOutdated = try container.decodeIfPresent(Bool.self, forKey: .isOutdated) ?? false
        isUnverified = try container.decodeIfPresent(Bool.self, forKey: .isUnverified) ?? false
        firstRun = try container.decodeIfPresent(Int.self, forKey: .firstRun) ?? 1
        lastRun = try container.decodeIfPresent(Int.self, forKey: .lastRun) ?? firstRun
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// Where a review is. Stored rather than derived: with a foreground process there is no session file to
/// read it back out of, so the runner is the only thing that knows.
public enum ReviewPhase: String, Codable, Sendable, Hashable {
    case queued, preparing, running, ready, failed, submitting, submitted

    public var label: String {
        switch self {
        case .queued: return "queued"
        case .preparing: return "preparing"
        case .running: return "reviewing"
        case .ready: return "ready"
        case .failed: return "failed"
        case .submitting: return "submitting"
        case .submitted: return "submitted"
        }
    }

    public var isBusy: Bool { self == .queued || self == .preparing || self == .running || self == .submitting }
}

/// One review actually posted to GitHub. Kept so the workspace can say what was sent and when.
public struct SubmittedRound: Codable, Sendable, Hashable {
    public var at: Date
    public var event: ReviewVerdict
    public var url: String
    public var inlineCount: Int
    /// Approved comments that could not be attached to a line and went into the body instead.
    public var foldedCount: Int

    public init(at: Date, event: ReviewVerdict, url: String, inlineCount: Int, foldedCount: Int) {
        self.at = at
        self.event = event
        self.url = url
        self.inlineCount = inlineCount
        self.foldedCount = foldedCount
    }
}

public struct ReviewCounts: Sendable, Hashable {
    public var pending = 0
    public var approved = 0
    public var rejected = 0
    public var outdated = 0
    public var blocking = 0

    public var total: Int { pending + approved + rejected }
}

/// One PR's review: what Claude found, what the user decided, and what was sent.
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

    /// The head the latest run reviewed. Becomes the review's `commit_id`.
    public var headSha: String
    /// Merge base of the latest run, which is what a LEFT-side line number counts against.
    public var baseSha: String

    /// Claude's suggestion.
    public var verdict: ReviewVerdict?
    /// The user's choice, once they make one.
    public var chosenVerdict: ReviewVerdict?
    public var summary: String
    public var comments: [DraftComment]
    /// The model's unparsed answer, kept when parsing failed so the prose is never lost.
    public var rawOutput: String?

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
    /// Kept apart from `error` so a failed post stays on screen next to the button that failed.
    public var submitError: String?
    public var history: [SubmittedRound]

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
        baseSha = ""
        verdict = nil
        chosenVerdict = nil
        summary = ""
        comments = []
        rawOutput = nil
        startedAt = now
        lastRunAt = now
        lastFinishedAt = nil
        runs = 0
        consecutiveFailures = 0
        costUSD = 0
        lastRunCostUSD = nil
        phase = .queued
        error = nil
        submitError = nil
        history = []
    }

    public var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    public var owner: String { repo.split(separator: "/").first.map(String.init) ?? repo }
    public var label: String { "\(repoName)#\(number)" }
    public var isSubmitted: Bool { phase == .submitted }
    public var submission: SubmittedRound? { history.last }
    /// What Submit would send: the user's choice, else Claude's, else the least assertive verdict.
    public var effectiveVerdict: ReviewVerdict { chosenVerdict ?? verdict ?? .comment }

    public var counts: ReviewCounts {
        var counts = ReviewCounts()
        for comment in comments {
            switch comment.state {
            case .pending: counts.pending += 1
            case .approved: counts.approved += 1
            case .rejected: counts.rejected += 1
            }
            if comment.isOutdated { counts.outdated += 1 }
            if comment.severity.isBlocking, comment.state != .rejected { counts.blocking += 1 }
        }
        return counts
    }

    public func comment(_ id: UUID) -> DraftComment? { comments.first { $0.id == id } }

    public mutating func update(_ id: UUID, now: Date = Date(), _ change: (inout DraftComment) -> Void) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        change(&comments[index])
        comments[index].updatedAt = now
    }

    enum CodingKeys: String, CodingKey {
        case prUrl, repo, number, title, author, baseRef, worktreePath, repoRoot, headSha, baseSha
        case verdict, chosenVerdict, summary, comments, rawOutput, startedAt, lastRunAt, lastFinishedAt
        case runs, consecutiveFailures, costUSD, lastRunCostUSD, phase, error, submitError, history
    }

    /// Hand-written for the same reason as `DraftComment`'s: a new field must not cost the user every
    /// comment they have already approved or rewritten.
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
        baseSha = try container.decodeIfPresent(String.self, forKey: .baseSha) ?? ""
        verdict = try container.decodeIfPresent(ReviewVerdict.self, forKey: .verdict)
        chosenVerdict = try container.decodeIfPresent(ReviewVerdict.self, forKey: .chosenVerdict)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        comments = try container.decodeIfPresent([DraftComment].self, forKey: .comments) ?? []
        rawOutput = try container.decodeIfPresent(String.self, forKey: .rawOutput)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt) ?? startedAt
        lastFinishedAt = try container.decodeIfPresent(Date.self, forKey: .lastFinishedAt)
        runs = try container.decodeIfPresent(Int.self, forKey: .runs) ?? 0
        consecutiveFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        lastRunCostUSD = try container.decodeIfPresent(Double.self, forKey: .lastRunCostUSD)
        phase = try container.decodeIfPresent(ReviewPhase.self, forKey: .phase) ?? .ready
        error = try container.decodeIfPresent(String.self, forKey: .error)
        submitError = try container.decodeIfPresent(String.self, forKey: .submitError)
        history = try container.decodeIfPresent([SubmittedRound].self, forKey: .history) ?? []
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
    public static let currentVersion = 2
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

/// The parts of a review's state that are genuinely derived from the PR rather than stored on the record.
public struct ReviewStatus: Sendable, Hashable {
    public var phase: ReviewPhase
    /// The PR head moved since the last run. Informational: it re-anchors comments, it never re-runs Claude.
    public var headMoved: Bool
    /// The user's review was requested again after the last run, which is what does trigger a re-run.
    public var reRequested: Bool
    public var counts: ReviewCounts
    public var costUSD: Double

    public init(phase: ReviewPhase, headMoved: Bool, reRequested: Bool, counts: ReviewCounts, costUSD: Double) {
        self.phase = phase
        self.headMoved = headMoved
        self.reRequested = reRequested
        self.counts = counts
        self.costUSD = costUSD
    }

    public static func derive(record: ReviewRecord, pr: PullRequest?, login: String) -> ReviewStatus {
        ReviewStatus(
            phase: record.phase,
            headMoved: pr.map { !$0.headSha.isEmpty && !record.headSha.isEmpty && $0.headSha != record.headSha } ?? false,
            reRequested: pr?.reviewRequestEvents.contains { !$0.isTeam && $0.reviewer == login && $0.createdAt > record.lastRunAt } ?? false,
            counts: record.counts,
            costUSD: record.costUSD
        )
    }

    public var isBusy: Bool { phase.isBusy }
}
