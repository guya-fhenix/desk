import Foundation

public enum DeskError: Error, CustomStringConvertible, Sendable {
    case ghNotFound
    case jiraNotConfigured
    case claudeNotFound
    case sessionNotStarted(String)

    public var description: String {
        switch self {
        case .ghNotFound: return "gh CLI not found. Install it or set the path in Settings."
        case .jiraNotConfigured: return "Jira: set the site, email, and API token in Settings."
        case .claudeNotFound: return "claude CLI not found. Install it or set the path in Settings."
        case .sessionNotStarted(let output): return "claude --bg printed no session id: \(output.prefix(200))"
        }
    }
}

/// Owns the providers and the on-disk caches. The app and the doctor share it.
public actor DeskService {
    public static let configFile = "config.json"

    private var config: DeskConfig
    private let support: AppSupport
    private var github: GitHubProvider?
    private let git = GitProvider()
    private var jira: JiraProvider?
    private let reviews: ReviewRunner
    private let diffs: ReviewDiffs
    /// Shared with the runner: two git commands in one repo must not race, and that is what serialises them.
    private let worktrees = ReviewWorktrees()

    public init(config: DeskConfig, support: AppSupport) {
        self.config = config
        self.support = support
        let providers = Self.makeProviders(config)
        (github, jira) = providers
        // One diff cache, shared: the runner fetches diffs and the workspace reads them back.
        let diffs = ReviewDiffs(ghPath: config.resolvedGhPath, support: support)
        self.diffs = diffs
        reviews = ReviewRunner(config: config, support: support, github: providers.0, worktrees: worktrees, diffs: diffs)
    }

    public static func loadConfig(support: AppSupport) -> DeskConfig {
        (try? support.load(DeskConfig.self, from: configFile)) ?? DeskConfig()
    }

    public func update(config: DeskConfig) async {
        self.config = config
        (github, jira) = Self.makeProviders(config)
        await diffs.update(ghPath: config.resolvedGhPath)
        await reviews.update(config: config, github: github)
    }

    private static func makeProviders(_ config: DeskConfig) -> (GitHubProvider?, JiraProvider?) {
        let github = config.resolvedGhPath.map { GitHubProvider(ghPath: $0, org: config.githubOrg) }
        return (github, config.resolvedAcliPath.map { JiraProvider(acliPath: $0) })
    }

    /// Jira works when acli is installed and signed in; there is no credential of ours to check.
    public var jiraReady: Bool {
        get async { await jira?.signedInAccount() != nil }
    }

    /// Which Atlassian account acli is signed in as, for Settings to show.
    public func jiraAccount() async -> JiraAccount? { await jira?.signedInAccount() }

    public func refreshGitHub(now: Date = Date()) async throws -> GitHubSnapshot {
        guard let github else { throw DeskError.ghNotFound }
        let since = now.addingTimeInterval(-TimeInterval(config.metricsWeeks) * 7 * 86_400)
        return try await github.snapshot(repos: config.trackedRepoSlugs, since: since, now: now)
    }

    /// The org's repositories, for the Settings picker.
    public func repositories() async throws -> [GitHubRepo] {
        guard let github else { throw DeskError.ghNotFound }
        return try await github.repositories()
    }

    public func refreshGit() async -> GitScan {
        let scan = await git.scan(roots: config.expandedRepoRoots, slugs: config.trackedRepoSlugs)
        // Only does anything once, after a ledger version reset left worktrees nobody claims.
        await reviews.sweepOrphans(repoRoots: scan.repos.map(\.root))
        return scan
    }

    /// Claude Code's background sessions. Small local files, read with the git scan.
    public func claudeJobs() -> [ClaudeJob] { ClaudeJobs.scan() }

    /// Starts a background Claude session on the PR's branch and returns it. `worktree` is a checkout the
    /// user already has on that branch; without one the branch gets a worktree of its own. The prompt
    /// carries the PR url, which is what ties the session to this PR until it has touched it itself.
    public func startClaudeSession(pr: PullRequest, repoRoot: String, worktree: String?) async throws -> ClaudeJob {
        guard let claude = config.resolvedClaudePath else { throw DeskError.claudeNotFound }
        let path: String
        if let worktree {
            path = worktree
        } else {
            path = try await worktrees.prepareBranch(pr: pr, repoRoot: repoRoot)
        }
        let prompt = """
            Working on \(pr.repo)#\(pr.number) — \(pr.title)
            \(pr.url)

            Its branch \(pr.headRef) is checked out here. Read the pull request and the review threads on \
            it, say what is left to do, then wait for instructions.
            """
        let output = try await Shell.output(claude, ["--bg", prompt], cwd: path, timeout: 120)
        guard let id = ClaudeJobs.startedID(in: output) else { throw DeskError.sessionNotStarted(output) }
        return ClaudeJob(
            id: id, name: "\(pr.repoName)#\(pr.number)", state: "working", cwd: path,
            prKeys: Set([ClaudeJobs.prKey(pr.url)].compactMap { $0 }), updatedAt: Date()
        )
    }

    public func refreshJira(referencedKeys: [String]) async throws -> [Ticket] {
        guard let jira else { throw DeskError.jiraNotConfigured }
        let mine = try await jira.myOpenIssues()
        let mineKeys = Set(mine.map(\.key))
        let others = try await jira.issues(keys: referencedKeys.filter { !mineKeys.contains($0) })
        return mine + others
    }

    /// The only call in the app that writes to Jira. Always from a press.
    public func transitionTicket(key: String, to status: String) async throws {
        guard let jira else { throw DeskError.jiraNotConfigured }
        try await jira.transition(key: key, to: status)
    }

    public func jiraProjectKeys() async throws -> [String] {
        guard let jira else { throw DeskError.jiraNotConfigured }
        return try await jira.projectKeys()
    }

    // MARK: Reviews

    public func reviews() async -> [String: ReviewRecord] { await reviews.records }

    /// PRs whose comments need re-pointing at a head that moved. The only review work the app does
    /// without being asked, because it spends no tokens.
    public func reviewsWithStaleAnchors(queue: [PullRequest], login: String) async -> [PullRequest] {
        await reviews.staleAnchors(queue: queue, login: login)
    }

    /// How many reviews are running, for the button that must not start a fifth.
    public func runningReviews() async -> Int { await reviews.running }

    /// What reviews have cost in the last 24 hours, across every PR.
    public func reviewSpendToday() async -> Double { await reviews.spentToday() }

    public func review(pr: PullRequest, gitScan: GitScan) async {
        await reviews.review(pr, repos: gitScan.repos)
    }

    public func refreshReviewAnchors(pr: PullRequest) async {
        await reviews.refreshAnchors(pr)
    }

    public func reviewDiff(_ record: ReviewRecord) async throws -> PullRequestDiff {
        try await diffs.diff(repo: record.repo, number: record.number, headSha: record.headSha)
    }

    public func setReviewCommentState(prUrl: String, commentId: UUID, state: CommentState) async -> ReviewRecord? {
        await reviews.setCommentState(prUrl: prUrl, commentId: commentId, state: state)
    }

    public func setReviewCommentBody(prUrl: String, commentId: UUID, body: String) async -> ReviewRecord? {
        await reviews.setCommentBody(prUrl: prUrl, commentId: commentId, body: body)
    }

    public func setReviewVerdict(prUrl: String, verdict: ReviewVerdict) async -> ReviewRecord? {
        await reviews.setVerdict(prUrl: prUrl, verdict: verdict)
    }

    public func setReviewSummary(prUrl: String, summary: String) async -> ReviewRecord? {
        await reviews.setSummary(prUrl: prUrl, summary: summary)
    }

    /// The only call in the app that writes to GitHub.
    public func submitReview(prUrl: String) async throws -> ReviewRecord {
        try await reviews.submit(prUrl: prUrl)
    }

    public func removeReview(_ record: ReviewRecord) async throws { try await reviews.remove(record) }

    public func cleanupClosedReviews(github: GitHubSnapshot) async { await reviews.cleanupClosed(github: github) }

}
