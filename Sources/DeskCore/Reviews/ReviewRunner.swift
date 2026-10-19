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

/// Runs reviews. Keeps nothing on disk but the worktrees.
///
/// One headless `claude -p` per run: no session, no job, nothing to attach to. What it finds goes into your
/// pending review on the PR; where that review stands afterwards is read back from GitHub, so the only
/// state here is the runs going on this session.
public actor ReviewRunner {
    private static let log = Logger(subsystem: "io.fhenix.desk", category: "reviews")

    private let worktrees: ReviewWorktrees
    private let diffs: ReviewDiffs
    private var github: GitHubProvider?
    private var config: DeskConfig
    /// This session's runs, by PR url. A second press on a busy one, or the next poll, is a no-op.
    public private(set) var runs: [String: ReviewRun] = [:]

    public init(
        config: DeskConfig, support: AppSupport, github: GitHubProvider?,
        worktrees: ReviewWorktrees = ReviewWorktrees(), diffs: ReviewDiffs? = nil
    ) {
        self.config = config
        self.github = github
        self.worktrees = worktrees
        self.diffs = diffs ?? ReviewDiffs(ghPath: config.resolvedGhPath, support: support)
        // Where earlier versions kept comment triage and spend. Nothing reads it any more.
        try? FileManager.default.removeItem(at: support.url("reviews.json"))
    }

    public func update(config: DeskConfig, github: GitHubProvider?) async {
        self.config = config
        self.github = github
        await diffs.update(ghPath: config.resolvedGhPath)
    }

    /// How many runs are going, so the UI can stop a fifth from starving the process pool.
    public var running: Int { runs.values.count { $0.phase.isBusy } }

    // MARK: Reviewing

    /// Prepares the worktree, runs one headless review, and posts what it found into your pending review
    /// on the PR. Always started by hand. Never throws: every failure becomes the run's error and a
    /// `.failed` phase, which is what puts the row back into "needs review".
    @discardableResult
    public func review(_ pr: PullRequest, repos: [RepoRef]) async -> ReviewRun {
        if let current = runs[pr.url], current.phase.isBusy { return current }
        var run = ReviewRun()
        runs[pr.url] = run

        do {
            guard let claudePath = config.resolvedClaudePath else { throw ReviewError.claudeNotFound }
            // Checked before anything is spent: a review with nowhere to go is money for nothing.
            guard let github else { throw DeskError.ghNotFound }
            guard let repo = Linker.repo(for: pr, in: repos) else { throw ReviewError.noLocalClone(pr.repo) }
            let path = ReviewPlanner.worktreePath(reviewRoot: config.expandedReviewRoot, pr: pr)

            let siblings = repos.filter { $0.root != repo.root }
            async let otherRepos = worktrees.otherRepos(siblings)
            let sha = try await worktrees.prepare(pr: pr, repoRoot: repo.root, path: path)
            let others = await otherRepos
            let diff = try await diffs.diff(repo: pr.repo, number: pr.number, headSha: sha)

            run.phase = .running
            runs[pr.url] = run

            var head = pr
            head.headSha = sha
            let arguments = ReviewCommand.reviewArguments(pr: head, otherRepos: others, config: config)
            let result = try await Shell.run(
                claudePath, arguments, cwd: path,
                // A closed pipe rather than the app's own stdin, which is undefined here and would cost a
                // three-second wait while claude decides nothing is coming.
                stdin: Data(),
                environment: ["CLAUDECODE": nil, "CLAUDE_CODE_ENTRYPOINT": nil],
                timeout: TimeInterval(config.reviewTimeoutMinutes) * 60
            )
            let envelope = try ClaudePrint.result(result.text, stderr: result.stderr)
            let parsed = await parse(envelope.result, claudePath: claudePath)
            // A refusal, a spend limit or a crash comes back as prose the parser cannot use, and prose has
            // no line to go on. Calling that a finished review is the worst outcome available: the row
            // would read "reviewed" when nothing was reviewed, and it would stop asking to be run.
            if parsed.isFallback {
                throw ReviewError.noReview(envelope.result)
            }

            let placed = DraftThreads.threads(Anchoring.resolve(parsed.comments, in: diff), in: diff)
            run.summary = parsed.summary
            run.findings = placed.threads
            run.phase = .posting
            runs[pr.url] = run
            do {
                let posted = try await github.postDraft(repo: pr.repo, number: pr.number, commitId: sha, threads: placed.threads)
                run.posted = posted?.added ?? 0
                run.skipped = (posted?.skipped ?? 0) + placed.unplaced
            } catch let error as GitHubWriteError {
                if case .partial(let added, _) = error { run.posted = added }
                throw error
            }
            run.phase = .posted
            if envelope.isError {
                // It answered, but not cleanly — an error mid-review, say. What it found is posted.
                run.error = "claude stopped early (\(envelope.subtype)); this review may be incomplete"
            }
        } catch {
            run.error = "\(error)"
            run.phase = .failed
        }
        runs[pr.url] = run
        return run
    }

    /// One reformat pass when the answer will not parse. Prose that still will not parse has no line to go
    /// on, so it comes back as a fallback and the run fails with the prose in its error.
    private func parse(_ text: String, claudePath: String) async -> ReviewOutput {
        if let output = try? ReviewOutputParser.parse(text) { return output }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let result = try? await Shell.run(
                  claudePath, ReviewCommand.reformatArguments(config: config), stdin: Data(text.utf8),
                  environment: ["CLAUDECODE": nil, "CLAUDE_CODE_ENTRYPOINT": nil], timeout: 180
              ),
              let envelope = try? ClaudePrint.result(result.text, stderr: result.stderr),
              let output = try? ReviewOutputParser.parse(envelope.result)
        else { return .fallback(raw: text) }
        return output
    }

    // MARK: Housekeeping

    /// Removes the review worktrees of PRs that are no longer open. The worktrees on disk are the list:
    /// their path names the PR, so nothing needs remembering to find them.
    public func cleanupClosed(github snapshot: GitHubSnapshot, reviewWorktrees: [Worktree], repos: [RepoRef]) async {
        guard config.cleanupReviewsOnMerge else { return }
        let seen = Dictionary(
            (snapshot.mergedRecent + snapshot.allOpen).map { ($0.url.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for worktree in reviewWorktrees {
            let slug = repos.first { $0.root == worktree.repoRoot }.flatMap { GitParsing.repoSlug(fromRemote: $0.remote) } ?? ""
            guard let target = ReviewPlanner.pullRequest(ofWorktree: worktree.path, reviewRoot: config.expandedReviewRoot, repoSlug: slug),
                  runs[target.url]?.phase.isBusy != true
            else { continue }
            let state: PullRequestState?
            if let pr = seen[target.url] {
                state = pr.state
            } else {
                // The searches only ever show a merged PR you authored; one you review vanishes from all
                // of them the moment it merges, so it is asked about by name. No answer keeps the
                // worktree: a failed query is not a closed pull request.
                state = try? await github?.pullRequestState(repo: slug, number: target.number)
            }
            guard let state, state != .open else { continue }
            try? await removeWorktree(repoRoot: worktree.repoRoot, path: worktree.path, prUrl: target.url)
        }
        await diffs.prune()
    }

    /// Deletes a PR's review worktree, when it is clean, and forgets this session's run on it. The review on
    /// GitHub is untouched.
    public func removeWorktree(for pr: PullRequest, repos: [RepoRef]) async throws {
        guard let repo = Linker.repo(for: pr, in: repos) else { throw ReviewError.noLocalClone(pr.repo) }
        try await removeWorktree(
            repoRoot: repo.root, path: ReviewPlanner.worktreePath(reviewRoot: config.expandedReviewRoot, pr: pr), prUrl: pr.url
        )
        await diffs.evict(repo: pr.repo, number: pr.number)
    }

    private func removeWorktree(repoRoot: String, path: String, prUrl: String) async throws {
        try await worktrees.remove(repoRoot: repoRoot, path: path)
        runs.removeValue(forKey: prUrl)
        Self.log.notice("removed review worktree \(path, privacy: .public)")
    }
}
