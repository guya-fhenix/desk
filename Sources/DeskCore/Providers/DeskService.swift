import Foundation

public enum DeskError: Error, CustomStringConvertible, Sendable {
    case ghNotFound
    case jiraNotConfigured
    case claudeNotFound
    case sessionNotStarted(String)
    case sessionStillRunning(String)
    case sessionNotResumed(String)

    public var description: String {
        switch self {
        case .ghNotFound: return "gh CLI not found. Install it or set the path in Settings."
        case .jiraNotConfigured: return "Jira: set the site, email, and API token in Settings."
        case .claudeNotFound: return "claude CLI not found. Install it or set the path in Settings."
        case .sessionNotStarted(let output): return "claude --bg printed no session id: \(output.prefix(200))"
        case .sessionStillRunning(let id): return "session \(id) did not stop, so nothing was sent to it"
        case .sessionNotResumed(let output): return "the session was not resumed under its own id: \(output.prefix(200))"
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
    private let worktrees = BranchWorktrees()

    public init(config: DeskConfig, support: AppSupport) {
        self.config = config
        self.support = support
        (github, jira) = Self.makeProviders(config)
    }

    public static func loadConfig(support: AppSupport) -> DeskConfig {
        (try? support.load(DeskConfig.self, from: configFile)) ?? DeskConfig()
    }

    public func update(config: DeskConfig) async {
        self.config = config
        (github, jira) = Self.makeProviders(config)
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
        // How far back the merged-PR search reaches: far enough that a ticket whose pull requests have all
        // landed is still marked behind in Jira weeks later.
        let since = now.addingTimeInterval(-8 * 7 * 86_400)
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

    /// Claude Code's background sessions on a PR or a ticket. Small local files, read with the git scan.
    public func claudeJobs() -> [ClaudeJob] { ClaudeJobs.scan(tickets: TicketKeyMatcher(projectKeys: config.jiraProjectKeys)) }

    /// Your Claude plan's limits, for the sidebar. A local file too, read with the git scan.
    public func claudeLimits() -> [ClaudeLimit] { ClaudeLimits.read() }

    /// Whether each clone's sessions can run the team review skill, by repo root. A few small files per repo.
    public func reviewSkills(repos: [RepoRef]) -> [String: ReviewSkill] {
        Dictionary(repos.map { ($0.root, ClaudePlugins.reviewSkill(repoRoot: $0.root)) }, uniquingKeysWith: { first, _ in first })
    }

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
        return config.prompt(
            .ticketPlan,
            ["key": ticket.key, "summary": ticket.summary, "url": ticket.url, "description": ticket.description, "note": note],
            when: ["description": !ticket.description.isEmpty, "note": !note.isEmpty]
        )
    }

    /// What a background session is started with. The problem sections are there only when the PR actually
    /// has that problem: Desk knows whether it does, so the session is told rather than asked to go looking.
    /// `worktree` is where the branch is checked out when that is not the directory the session starts in.
    public static func sessionPrompt(for pr: PullRequest, worktree: String? = nil, config: DeskConfig = DeskConfig()) -> String {
        let values = [
            "repo": pr.repo, "number": String(pr.number), "title": pr.title, "url": pr.url,
            "headRef": pr.headRef, "baseRef": pr.baseRef, "worktree": worktree ?? "",
            "threads": pr.unresolvedThreads == 1 ? "1 review thread is" : "\(pr.unresolvedThreads) review threads are",
        ]
        return config.prompt(
            .session, values,
            when: ["worktree": worktree != nil, "unresolved": pr.unresolvedThreads > 0, "conflict": pr.mergeState == .dirty]
        )
    }


    // MARK: Flows

    /// Sends an idle background session its next instruction, keeping its id and its conversation. A session that
    /// has finished its turn is still alive, and resuming a live one starts a copy instead, so it is stopped first
    /// and resumed only once `claude agents` no longer lists it running. Callers send only to a session that is
    /// `done`: stopping one that is working or asking something would cut it off.
    public func send(_ prompt: String, to job: ClaudeJob, cwd: String) async throws {
        guard let claude = config.resolvedClaudePath else { throw DeskError.claudeNotFound }
        guard let sessionId = job.sessionId else { throw DeskError.sessionNotResumed("no session id recorded for \(job.id) yet") }
        // Its exit status is not the test: a session that is not running may refuse the stop. Not running is the test.
        let pid = await agents(claude)?.first { $0["id"] as? String == job.id }?["pid"] as? Int32
        _ = try await Shell.run(claude, ["stop", job.id], timeout: 30)
        guard await waitUntilStopped(job.id, pid: pid, claude: claude) else { throw DeskError.sessionStillRunning(job.id) }
        let output = try await Shell.output(claude, ["--bg", "--resume", sessionId, prompt], cwd: cwd, timeout: 120)
        guard let id = ClaudeJobs.startedID(in: output), id == job.id else {
            // A copy would run the instruction beside the real session; it goes before anything else happens.
            if let copy = ClaudeJobs.startedID(in: output) {
                _ = try? await Shell.run(claude, ["stop", copy], timeout: 30)
                _ = try? await Shell.run(claude, ["rm", copy], timeout: 30)
            }
            throw DeskError.sessionNotResumed(output)
        }
    }

    /// `claude agents` drops a stopped session a second or two before its process exits, and a resume in that gap
    /// starts a copy: so the process `pid` going is the test too.
    private func waitUntilStopped(_ id: String, pid: Int32?, claude: String) async -> Bool {
        for _ in 0..<30 {
            guard let list = await agents(claude) else { return false }
            let listed = list.contains { $0["id"] as? String == id && $0["pid"] != nil }
            if !listed, pid.map({ kill($0, 0) != 0 }) ?? true { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private func agents(_ claude: String) async -> [[String: Any]]? {
        guard let output = try? await Shell.output(claude, ["agents", "--json"], timeout: 30) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [[String: Any]] ?? []
    }

    /// Where the session writes the result of instruction `step`: its own scratch folder, which it may always
    /// write to, and which goes when the session is deleted. The app reads nothing from it — the stage follows the
    /// session and the PR — and writing it is the instruction's last step.
    public static func resultFile(jobId: String, step: Int, home: String = ClaudeJobs.home) -> String {
        "\(home)/jobs/\(jobId)/tmp/desk-step-\(step).json"
    }

    /// The directory to resume a session from: the one whose Claude Code project folder holds its transcript. A
    /// session that entered a worktree keeps its conversation under that worktree, not where it started.
    public static func resumeDirectory(sessionId: String, candidates: [String], home: String = ClaudeJobs.home) -> String? {
        candidates.first { dir in
            let folder = dir.replacing(/[^A-Za-z0-9-]/, with: "-")
            return FileManager.default.fileExists(atPath: "\(home)/projects/\(folder)/\(sessionId).jsonl")
        }
    }

    /// The text of one flow instruction for this PR. `worktree` is where its branch is checked out, if anywhere.
    /// `threads` is the list Apply sends, from `threadList`.
    public static func flowPrompt(
        _ id: PromptID, pr: PullRequest, worktree: String?, resultFile: String, config: DeskConfig = DeskConfig()
    ) -> String {
        let values = [
            "repo": pr.repo, "number": String(pr.number), "title": pr.title, "url": pr.url, "baseRef": pr.baseRef,
            "headRef": pr.headRef, "worktree": worktree ?? "", "resultFile": resultFile,
        ]
        return config.prompt(id, values, when: ["worktree": worktree != nil, "draft": pr.isDraft])
    }

    public func markReady(_ pr: PullRequest) async throws {
        guard let github else { throw DeskError.ghNotFound }
        try await github.markReady(repo: pr.repo, number: pr.number)
    }

    public func checks(for pr: PullRequest) async throws -> [PullRequestCheck] {
        guard let github else { throw DeskError.ghNotFound }
        return try await github.checks(repo: pr.repo, number: pr.number)
    }

    public func retitle(_ pr: PullRequest, to title: String) async throws {
        guard let github else { throw DeskError.ghNotFound }
        try await github.retitle(repo: pr.repo, number: pr.number, title: title)
    }

    public func editDescription(_ pr: PullRequest, body: String) async throws {
        guard let github else { throw DeskError.ghNotFound }
        try await github.editBody(repo: pr.repo, number: pr.number, body: body)
    }

    public func close(_ pr: PullRequest) async throws {
        guard let github else { throw DeskError.ghNotFound }
        try await github.close(repo: pr.repo, number: pr.number)
    }

    public func squashMerge(_ pr: PullRequest) async throws {
        guard let github else { throw DeskError.ghNotFound }
        try await github.squashMerge(repo: pr.repo, number: pr.number)
    }

    public func requestTeamReview(_ pr: PullRequest) async throws {
        guard let github else { throw DeskError.ghNotFound }
        try await github.requestTeamReview(repo: pr.repo, number: pr.number, team: config.reviewTeam)
    }

    public func refreshJira(referencedKeys: [String]) async throws -> [Ticket] {
        guard let jira else { throw DeskError.jiraNotConfigured }
        async let mine = jira.myOpenIssues()
        async let team = jira.teamOpenIssues(projects: config.jiraProjectKeys)
        let placed = try await mine + team
        let placedKeys = Set(placed.map(\.key))
        let others = try await jira.issues(keys: referencedKeys.filter { !placedKeys.contains($0) })
        return placed + others
    }

    /// The only call in the app that writes to Jira: planning a ticket, and moving one that has fallen
    /// behind its pull requests.
    public func transitionTicket(key: String, to status: String) async throws {
        guard let jira else { throw DeskError.jiraNotConfigured }
        try await jira.transition(key: key, to: status)
    }

    /// Saves your edit to a ticket's summary or description.
    public func editTicket(key: String, summary: String? = nil, description: String? = nil) async throws {
        guard let jira else { throw DeskError.jiraNotConfigured }
        try await jira.edit(key: key, summary: summary, description: description)
    }

    public func jiraProjectKeys() async throws -> [String] {
        guard let jira else { throw DeskError.jiraNotConfigured }
        return try await jira.projectKeys()
    }
}
