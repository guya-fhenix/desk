import Foundation
import os

public enum ReviewError: Error, CustomStringConvertible, Sendable {
    case claudeNotFound
    case noLocalClone(String)
    case noRecord
    case busy
    case headMoved
    case noReview(String)

    public var description: String {
        switch self {
        case .claudeNotFound: return "claude CLI not found. Install it or set the path in Settings."
        case .noLocalClone(let repo): return "no local clone of \(repo) under the repo roots"
        case .noRecord: return "no review for this pull request"
        case .busy: return "this review is still running"
        case .headMoved:
            return "the PR head moved while you were reviewing; the comments have been re-anchored, look them over and submit again"
        case .noReview(let text):
            return "claude returned no review: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"
        }
    }
}

/// Runs reviews and owns `reviews.json`.
///
/// One headless `claude -p` per run: no session, no job, nothing to attach to. Everything the screen
/// shows comes back in the run's own JSON, which is why the record — phase included — is the only
/// authority on where a review is.
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

    // MARK: Readiness

    /// PRs whose head moved since their review. Re-anchoring is the only thing this actor does without
    /// being asked, because it spends no tokens.
    public func staleAnchors(queue: [PullRequest], login: String, now: Date = Date()) -> [PullRequest] {
        ReviewReadiness.staleAnchors(ReviewReadinessInput(
            now: now, login: login, queue: queue, records: ledger.records, repos: []
        ))
    }

    /// How many runs are going, so the UI can stop a fifth from starving the process pool.
    public var running: Int { inFlight.count }

    public func spentToday(now: Date = Date()) -> Double { ledger.spent(since: now.addingTimeInterval(-86_400)) }

    // MARK: Reviewing

    /// Prepares the worktree, runs one headless review, and folds the result into the record. Always
    /// started by hand. Never throws: every failure becomes `record.error` and a `.failed` phase, which
    /// is what puts the row back into "ready to run".
    public func review(_ pr: PullRequest, repos: [RepoRef], now: Date = Date()) async {
        guard !inFlight.contains(pr.url) else { return }
        inFlight.insert(pr.url)
        defer { inFlight.remove(pr.url) }

        var record = ledger.records[pr.url] ?? ReviewRecord(pr: pr, worktreePath: "", repoRoot: "", now: now)
        record.title = pr.title
        record.author = pr.author
        record.baseRef = pr.baseRef
        record.error = nil
        record.submitError = nil
        record.lastRunAt = now
        record.phase = .preparing
        let run = record.runs + 1

        do {
            guard let claudePath = config.resolvedClaudePath else { throw ReviewError.claudeNotFound }
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
            let baseSha = await worktrees.mergeBase(baseRef: pr.baseRef, sha: sha, repoRoot: record.repoRoot) ?? ""
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
            // A refusal, a spend limit or a crash comes back as prose the parser cannot use. Recording
            // that as a finished review is the worst outcome available: the row would read "reviewed"
            // when nothing was reviewed, and it would stop asking to be run.
            if envelope.isError, parsed.output.isFallback {
                throw ReviewError.noReview(envelope.result)
            }

            // Existing comments move to the new head first, or their keys will not line up with the new
            // findings and the merge would duplicate every one of them.
            record.comments = await reanchor(record.comments, head: sha, base: baseSha, repoRoot: record.repoRoot, now: now)
            let resolved = Anchoring.resolve(parsed.output.comments, in: diff, baseSha: baseSha, run: run, now: now)
            record.comments = CommentMerge.merge(existing: record.comments, incoming: resolved, run: run, now: now)
            record.summary = parsed.output.summary
            record.verdict = parsed.output.verdict
            record.rawOutput = parsed.output.isFallback ? envelope.result : nil
            record.headSha = sha
            record.baseSha = baseSha
            record.runs = run
            record.consecutiveFailures = 0
            record.lastFinishedAt = Date()
            record.phase = .ready
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

    /// Re-points a record's comments at a head that moved, without running Claude. This is the whole of
    /// what a new commit does.
    public func refreshAnchors(_ pr: PullRequest, now: Date = Date()) async {
        guard !inFlight.contains(pr.url), var record = ledger.records[pr.url], !record.phase.isBusy else { return }
        guard !pr.headSha.isEmpty, pr.headSha != record.headSha, !record.repoRoot.isEmpty else { return }
        inFlight.insert(pr.url)
        defer { inFlight.remove(pr.url) }

        await worktrees.fetch(ref: "pull/\(pr.number)/head", repoRoot: record.repoRoot)
        let baseSha = await worktrees.mergeBase(baseRef: pr.baseRef, sha: pr.headSha, repoRoot: record.repoRoot) ?? record.baseSha
        record.comments = await reanchor(record.comments, head: pr.headSha, base: baseSha, repoRoot: record.repoRoot, now: now)
        record.headSha = pr.headSha
        record.baseSha = baseSha
        // The old diff described the old head; the workspace must not keep drawing it.
        await diffs.evict(repo: pr.repo, number: pr.number)
        save(record)
    }

    private func reanchor(_ comments: [DraftComment], head: String, base: String, repoRoot: String, now: Date) async -> [DraftComment] {
        var updated = comments
        for (side, sha) in [(DiffSide.right, head), (DiffSide.left, base)] where !sha.isEmpty {
            let paths = Set(updated.filter { $0.side == side && $0.anchor.sha != sha }.map(\.path))
            guard !paths.isEmpty else { continue }
            let contents = await worktrees.blobs(sha: sha, paths: Array(paths), repoRoot: repoRoot)
            updated = Anchoring.reanchored(updated, contents: contents, sha: sha, side: side, now: now)
        }
        return updated
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

    // MARK: The user's decisions

    /// One field at a time, and each returns the record it wrote. A whole-record write from the UI would
    /// race a run that is rewriting the same record's comments.
    public func setCommentState(prUrl: String, commentId: UUID, state: CommentState, now: Date = Date()) -> ReviewRecord? {
        mutate(prUrl) { $0.update(commentId, now: now) { $0.state = state } }
    }

    public func setCommentBody(prUrl: String, commentId: UUID, body: String, now: Date = Date()) -> ReviewRecord? {
        mutate(prUrl) { record in
            record.update(commentId, now: now) { comment in
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                // Back to Claude's words rather than an empty comment nobody can read.
                comment.editedBody = trimmed.isEmpty || trimmed == comment.body ? nil : trimmed
            }
        }
    }

    public func setVerdict(prUrl: String, verdict: ReviewVerdict) -> ReviewRecord? {
        mutate(prUrl) { $0.chosenVerdict = verdict }
    }

    /// The summary is posted under the user's name, so it has to be theirs to change.
    public func setSummary(prUrl: String, summary: String) -> ReviewRecord? {
        mutate(prUrl) { $0.summary = summary }
    }

    private func mutate(_ prUrl: String, _ change: (inout ReviewRecord) -> Void) -> ReviewRecord? {
        guard var record = ledger.records[prUrl] else { return nil }
        change(&record)
        save(record)
        return record
    }

    // MARK: Submitting

    /// Posts one review: the approved comments that still attach to a line, and the rest folded into the
    /// body so nothing the user approved is lost.
    public func submit(prUrl: String, now: Date = Date()) async throws -> ReviewRecord {
        guard var record = ledger.records[prUrl] else { throw ReviewError.noRecord }
        guard let github else { throw DeskError.ghNotFound }
        guard !record.phase.isBusy else { throw ReviewError.busy }

        record.phase = .submitting
        record.submitError = nil
        save(record)
        do {
            let diff = try await diffs.diff(repo: record.repo, number: record.number, headSha: record.headSha)
            let approved = record.comments.filter { $0.state == .approved }
            let attachable = approved.filter { !$0.isOutdated && diff.isCommentable(path: $0.path, line: $0.line, side: $0.side) }
            let attached = Set(attachable.map(\.id))
            let folded = approved.filter { !attached.contains($0.id) }
            let verdict = record.effectiveVerdict
            let submission = ReviewSubmission(
                repo: record.repo, number: record.number, commitId: record.headSha, event: verdict,
                body: ReviewBody.compose(
                    summary: record.summary, verdict: verdict, folded: folded,
                    inlineCount: attachable.count, repo: record.repo, sha: record.headSha
                ),
                comments: attachable.map {
                    ReviewSubmission.Inline(path: $0.path, line: $0.line, side: $0.side, body: $0.text)
                }
            )
            let posted = try await github.submitReview(submission)
            record.history.append(SubmittedRound(
                at: now, event: verdict, url: posted.url, inlineCount: attachable.count, foldedCount: folded.count
            ))
            record.phase = .submitted
            save(record)
            return record
        } catch {
            record.phase = .ready
            if case GitHubWriteError.staleCommit = error {
                // Never silently retarget the user's comments at code they have not read.
                record.submitError = ReviewError.headMoved.description
                save(record)
                throw ReviewError.headMoved
            }
            record.submitError = "\(error)"
            save(record)
            throw error
        }
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
    /// to `.queued`, which would restart a PR that reliably crashes the app, forever. A submit is not
    /// retried at all: the POST may already have landed.
    private static func recovered(_ ledger: ReviewLedger) -> ReviewLedger {
        var ledger = ledger
        for (url, var record) in ledger.records {
            switch record.phase {
            case .preparing, .running, .queued:
                record.phase = .failed
                record.error = "interrupted by a restart"
                record.consecutiveFailures += 1
            case .submitting:
                record.phase = .ready
                record.submitError = "interrupted while submitting — check the PR before sending it again"
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
