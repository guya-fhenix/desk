import Foundation
import os

public enum ReviewError: Error, CustomStringConvertible, Sendable {
    case claudeNotFound
    case noLocalClone(String)
    case noReview(String)

    public var description: String {
        switch self {
        case .claudeNotFound: return "claude CLI not found. Install it or set the path in Settings."
        case .noLocalClone(let repo): return "no local clone of \(repo) under the repo roots"
        case .noReview(let text):
            return "claude returned no review: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"
        }
    }
}

/// Runs reviews and owns `reviews.json`.
///
/// One headless `claude -p` per run: no session, no job, nothing to attach to. What it finds goes into your
/// pending review on the PR, and the record keeps only the run and the handle on that draft.
public actor ReviewRunner {
    private static let log = Logger(subsystem: "io.fhenix.desk", category: "reviews")

    public static let file = "reviews.json"

    private let support: AppSupport
    private let worktrees: ReviewWorktrees
    private let diffs: ReviewDiffs
    private var github: GitHubProvider?
    private var config: DeskConfig
    private var ledger: ReviewLedger
    /// PR urls with an operation running. A second press, or the next poll, is a no-op.
    private var inFlight: Set<String> = []
    /// Set when the ledger was discarded for a version change: the worktrees it named are now unclaimed.
    private var needsOrphanSweep = false

    public init(
        config: DeskConfig, support: AppSupport, github: GitHubProvider?,
        worktrees: ReviewWorktrees = ReviewWorktrees(), diffs: ReviewDiffs? = nil
    ) {
        self.config = config
        self.support = support
        self.github = github
        self.worktrees = worktrees
        self.diffs = diffs ?? ReviewDiffs(ghPath: config.resolvedGhPath, support: support)
        let cached = try? support.load(ReviewLedger.self, from: Self.file)
        if let cached, cached.isCurrent {
            ledger = Self.recovered(cached)
            if ledger.records != cached.records { try? support.save(ledger, to: Self.file) }
        } else {
            ledger = ReviewLedger()
            needsOrphanSweep = cached != nil
        }
    }

    public func update(config: DeskConfig, github: GitHubProvider?) async {
        self.config = config
        self.github = github
        await diffs.update(ghPath: config.resolvedGhPath)
    }

    public var records: [String: ReviewRecord] { ledger.records }

    public func record(for prUrl: String) -> ReviewRecord? { ledger.records[prUrl] }

    /// How many runs are going, so the UI can stop a fifth from starving the process pool.
    public var running: Int { inFlight.count }

    public func spentToday(now: Date = Date()) -> Double { ledger.spent(since: now.addingTimeInterval(-86_400)) }

    // MARK: Reviewing

    /// Prepares the worktree, runs one headless review, and posts what it found into your pending review
    /// on the PR. Always started by hand. Never throws: every failure becomes `record.error` and a
    /// `.failed` phase, which is what puts the row back into "ready to run".
    public func review(_ pr: PullRequest, repos: [RepoRef], now: Date = Date()) async {
        guard !inFlight.contains(pr.url) else { return }
        inFlight.insert(pr.url)
        defer { inFlight.remove(pr.url) }

        var record = ledger.records[pr.url] ?? ReviewRecord(pr: pr, worktreePath: "", repoRoot: "", now: now)
        record.title = pr.title
        record.author = pr.author
        record.baseRef = pr.baseRef
        record.error = nil
        record.lastRunAt = now
        record.phase = .preparing
        let run = record.runs + 1

        do {
            guard let claudePath = config.resolvedClaudePath else { throw ReviewError.claudeNotFound }
            // Checked before anything is spent: a review with nowhere to go is money for nothing.
            guard let github else { throw DeskError.ghNotFound }
            if record.repoRoot.isEmpty {
                guard let repo = Linker.repo(for: pr, in: repos) else { throw ReviewError.noLocalClone(pr.repo) }
                record.repoRoot = repo.root
                record.worktreePath = ReviewPlanner.worktreePath(reviewRoot: config.expandedReviewRoot, pr: pr)
            }
            // Checkpoint before anything slow, so a crash leaves a coherent record rather than a gap.
            save(record)

            let siblings = repos.filter { $0.root != record.repoRoot }
            async let otherRepos = worktrees.otherRepos(siblings)
            let sha = try await worktrees.prepare(pr: pr, repoRoot: record.repoRoot, path: record.worktreePath)
            let others = await otherRepos
            let diff = try await diffs.diff(repo: pr.repo, number: pr.number, headSha: sha)

            record.phase = .running
            save(record)

            var head = pr
            head.headSha = sha
            let arguments = ReviewCommand.reviewArguments(pr: head, otherRepos: others, config: config)
            let result = try await Shell.run(
                claudePath, arguments, cwd: record.worktreePath,
                // A closed pipe rather than the app's own stdin, which is undefined here and would cost a
                // three-second wait while claude decides nothing is coming.
                stdin: Data(),
                environment: ["CLAUDECODE": nil, "CLAUDE_CODE_ENTRYPOINT": nil],
                timeout: TimeInterval(config.reviewTimeoutMinutes) * 60
            )
            let envelope = try ClaudePrint.result(result.text, stderr: result.stderr)
            let parsed = await parse(envelope.result, claudePath: claudePath)
            let cost = envelope.costUSD + parsed.cost
            record.lastRunCostUSD = cost
            record.costUSD += cost
            ledger.record(cost: cost, prUrl: pr.url, now: now)
            // A refusal, a spend limit or a crash comes back as prose the parser cannot use, and prose has
            // no line to go on. Recording it as a finished review is the worst outcome available: the row
            // would read "reviewed" when nothing was reviewed, and it would stop asking to be run.
            if parsed.output.isFallback {
                throw ReviewError.noReview(envelope.result)
            }

            let resolved = Anchoring.resolve(parsed.output.comments, in: diff)
            let placed = DraftThreads.threads(resolved, in: diff)
            record.phase = .posting
            save(record)
            do {
                if let posted = try await github.postDraft(repo: pr.repo, number: pr.number, commitId: sha, threads: placed.threads) {
                    record.draft = ReviewDraft(id: posted.id, commitId: sha, postedAt: Date())
                    record.lastPosted = posted.added
                    record.lastSkipped = posted.skipped + placed.unplaced
                } else {
                    record.lastPosted = 0
                    record.lastSkipped = placed.unplaced
                }
            } catch GitHubWriteError.partial(let draftId, let added, let underlying) {
                // Half a draft is still a draft: keep following it, and say what is missing.
                record.draft = ReviewDraft(id: draftId, commitId: sha, postedAt: Date())
                record.lastPosted = added
                throw GitHubWriteError.partial(draftId: draftId, added: added, underlying: underlying)
            }
            record.headSha = sha
            record.runs = run
            record.consecutiveFailures = 0
            record.lastFinishedAt = Date()
            record.phase = .posted
            if envelope.isError, record.error == nil {
                // It answered, but not cleanly — a budget cap mid-review, say. Keep what it found and say so.
                record.error = "claude stopped early (\(envelope.subtype)); this review may be incomplete"
            }
        } catch {
            record.error = "\(error)"
            record.consecutiveFailures += 1
            record.phase = .failed
        }
        save(record)
    }

    /// One reformat pass when the answer will not parse, then the prose itself. A review that came back
    /// as markdown is still worth showing.
    private func parse(_ text: String, claudePath: String) async -> (output: ReviewOutput, cost: Double) {
        if let output = try? ReviewOutputParser.parse(text) { return (output, 0) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (.fallback(raw: text), 0) }
        guard let result = try? await Shell.run(
            claudePath, ReviewCommand.reformatArguments(), stdin: Data(text.utf8),
            environment: ["CLAUDECODE": nil, "CLAUDE_CODE_ENTRYPOINT": nil], timeout: 180
        ), let envelope = try? ClaudePrint.result(result.text, stderr: result.stderr) else {
            return (.fallback(raw: text), 0)
        }
        guard let output = try? ReviewOutputParser.parse(envelope.result) else {
            return (.fallback(raw: text), envelope.costUSD)
        }
        return (output, envelope.costUSD)
    }

    // MARK: Housekeeping

    public func cleanupClosed(github snapshot: GitHubSnapshot) async {
        guard config.cleanupReviewsOnMerge else { return }
        let seen = snapshot.mergedRecent + snapshot.reviewedByMe + snapshot.allOpen
        for record in ReviewPlanner.cleanups(records: ledger.records, closed: seen) {
            try? await remove(record)
        }
        // The searches only ever show a merged PR you authored or submitted a review on. One you reviewed
        // here and never sent vanishes from all five the moment it merges, so it has to be asked about by
        // name. An answer that does not arrive keeps the review: a review costs real money to produce, and
        // a failed query is not a closed pull request.
        guard let github else { return }
        for record in ReviewPlanner.unresolved(records: ledger.records, seen: seen) {
            guard let state = try? await github.pullRequestState(repo: record.repo, number: record.number),
                  state != .open
            else { continue }
            try? await remove(record)
        }
    }

    public func remove(_ record: ReviewRecord) async throws {
        do {
            if !record.repoRoot.isEmpty, !record.worktreePath.isEmpty {
                try await worktrees.remove(repoRoot: record.repoRoot, path: record.worktreePath)
            }
        } catch {
            var kept = record
            kept.error = "not removed: \(error)"
            save(kept)
            throw error
        }
        await diffs.evict(repo: record.repo, number: record.number)
        ledger.records.removeValue(forKey: record.prUrl)
        persist()
        // A review costs real money to produce, so its disappearance leaves a trace to look up.
        Self.log.notice("removed review \(record.label, privacy: .public) (\(record.runs) runs, \(record.costUSD, privacy: .public) USD)")
    }

    /// Removes review worktrees no record claims. Runs once after a ledger version reset, which is the
    /// only way they become unclaimed.
    public func sweepOrphans(repoRoots: [String]) async {
        guard needsOrphanSweep else { return }
        needsOrphanSweep = false
        await worktrees.pruneOrphans(
            repoRoots: repoRoots, reviewRoot: config.expandedReviewRoot,
            keeping: Set(ledger.records.values.map(\.worktreePath))
        )
        await diffs.prune()
    }

    /// A crash leaves a phase mid-flight. A run demotes to `.failed` so the retry backoff decides — never
    /// to `.queued`, which would restart a PR that reliably crashes the app, forever. A post is not retried
    /// on its own: some of it may already be on GitHub, and a re-run adds only what the draft lacks.
    private static func recovered(_ ledger: ReviewLedger) -> ReviewLedger {
        var ledger = ledger
        for (url, var record) in ledger.records {
            switch record.phase {
            case .preparing, .running, .queued:
                record.phase = .failed
                record.error = "interrupted by a restart"
                record.consecutiveFailures += 1
            case .posting:
                record.phase = .failed
                record.error = "interrupted while posting the draft — check the PR on GitHub before running again"
                record.consecutiveFailures += 1
            default:
                continue
            }
            ledger.records[url] = record
        }
        return ledger
    }

    private func save(_ record: ReviewRecord) {
        ledger.records[record.prUrl] = record
        persist()
    }

    private func persist() {
        try? support.save(ledger, to: Self.file)
    }
}
