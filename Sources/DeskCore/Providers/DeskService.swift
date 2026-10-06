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
        // One diff cache, shared by the runner and its housekeeping.
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
        await git.scan(roots: config.expandedRepoRoots, slugs: config.trackedRepoSlugs)
    }

    /// Claude Code's background sessions. Small local files, read with the git scan.
    public func claudeJobs() -> [ClaudeJob] { ClaudeJobs.scan() }

    /// Starts a background Claude session on the PR's branch and returns it. `worktree` is a checkout the
    /// user already has on that branch; without one the branch gets a worktree of its own. The session
    /// starts in the repository's own checkout whatever the branch's checkout is: that is the directory
    /// Claude Code reads the project's settings, plugins and memory from, and a worktree is a different
    /// directory to it. The prompt sends it on to the branch, and carries the PR url, which is what ties
    /// the session to this PR until it has touched it itself.
    public func startClaudeSession(pr: PullRequest, repoRoot: String, worktree: String?) async throws -> ClaudeJob {
        guard let claude = config.resolvedClaudePath else { throw DeskError.claudeNotFound }
        let path: String
        if let worktree {
            path = worktree
        } else {
            path = try await worktrees.prepareBranch(pr: pr, repoRoot: repoRoot)
        }
        let prompt = Self.sessionPrompt(for: pr, worktree: path == repoRoot ? nil : path, config: config)
        let output = try await Shell.output(claude, ["--bg", prompt], cwd: repoRoot, timeout: 120)
        guard let id = ClaudeJobs.startedID(in: output) else { throw DeskError.sessionNotStarted(output) }
        return ClaudeJob(
            id: id, name: "\(pr.repoName)#\(pr.number)", state: "working", cwd: repoRoot,
            prKeys: Set([ClaudeJobs.prKey(pr.url)].compactMap { $0 }), updatedAt: Date()
        )
    }

    /// Starts a background Claude session to plan a ticket, in a repository's own checkout. Nothing ties
    /// the session to the ticket: planning ends in a pull request, and the pull request is what this app
    /// follows — so pressing again is another session, deliberately.
    public func startTicketSession(ticket: Ticket, repoRoot: String, note: String = "") async throws -> String {
        guard let claude = config.resolvedClaudePath else { throw DeskError.claudeNotFound }
        let prompt = Self.ticketPrompt(for: ticket, note: note, config: config)
        let output = try await Shell.output(claude, ["--bg", prompt], cwd: repoRoot, timeout: 120)
        guard let id = ClaudeJobs.startedID(in: output) else { throw DeskError.sessionNotStarted(output) }
        return id
    }

    /// What a planning session is told. The description rides along so the session need not reach Jira —
    /// it has no credentials of its own, and this app already has the text. `note` is whatever you typed
    /// on the way in; the default text puts it closest to the instruction because it is the part the
    /// ticket does not say.
    public static func ticketPrompt(for ticket: Ticket, note: String = "", config: DeskConfig = DeskConfig()) -> String {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var values = ["key": ticket.key, "summary": ticket.summary, "url": ticket.url, "description": ticket.description, "note": note]
        values["descriptionBlock"] = ticket.description.isEmpty ? "" : config.prompt(.ticketDescription, values)
        values["noteBlock"] = note.isEmpty ? "" : config.prompt(.ticketNote, values)
        return config.prompt(.ticketPlan, values)
    }

    /// What a background session is started with. The two blocks are there only when the PR actually has
    /// that problem: Desk knows whether it does, so the session is told rather than asked to go looking.
    /// `worktree` is where the branch is checked out when that is not the directory the session starts in.
    public static func sessionPrompt(for pr: PullRequest, worktree: String? = nil, config: DeskConfig = DeskConfig()) -> String {
        var values = [
            "repo": pr.repo, "number": String(pr.number), "title": pr.title, "url": pr.url,
            "headRef": pr.headRef, "baseRef": pr.baseRef, "worktree": worktree ?? "",
            "threads": pr.unresolvedThreads == 1 ? "1 review thread is" : "\(pr.unresolvedThreads) review threads are",
        ]
        values["checkout"] = config.prompt(worktree == nil ? .sessionHere : .sessionInWorktree, values)
        values["unresolvedBlock"] = pr.unresolvedThreads > 0 ? config.prompt(.sessionUnresolved, values) : ""
        values["conflictBlock"] = pr.mergeState == .dirty ? config.prompt(.sessionConflict, values) : ""
        return config.prompt(.session, values)
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

    /// This session's review runs. Where each review stands after that is the PR's to say.
    public func reviewRuns() async -> [String: ReviewRun] { await reviews.runs }

    /// How many reviews are running, for the button that must not start a fifth.
    public func runningReviews() async -> Int { await reviews.running }

    /// Runs one review and posts what it found into your pending review on the PR. The app's only write
    /// to GitHub, and never more than a draft: submitting it is yours to do there.
    @discardableResult
    public func review(pr: PullRequest, gitScan: GitScan) async -> ReviewRun {
        await reviews.review(pr, repos: gitScan.repos)
    }

    public func removeReviewWorktree(for pr: PullRequest, gitScan: GitScan) async throws {
        try await reviews.removeWorktree(for: pr, repos: gitScan.repos)
    }

    public func cleanupClosedReviews(github: GitHubSnapshot, reviewWorktrees: [Worktree], repos: [RepoRef]) async {
        await reviews.cleanupClosed(github: github, reviewWorktrees: reviewWorktrees, repos: repos)
    }

}
