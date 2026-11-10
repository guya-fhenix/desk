import Foundation
import os

public enum DeskError: Error, CustomStringConvertible, Sendable {
    case ghNotFound
    case jiraNotConfigured
    case jiraSignedOut
    case claudeNotFound
    case sessionNotStarted(String)
    case sessionStillRunning(String)
    case sessionNotResumed(String)

    public var description: String {
        switch self {
        case .ghNotFound: return "gh CLI not found. Install it or set the path in Settings."
        case .jiraNotConfigured: return "acli not found. Install it or set its path in Settings → Jira."
        case .jiraSignedOut: return "Not signed in to Jira. Run `acli jira auth login --web` in a terminal, then press Recheck in Settings → Jira."
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
    private static let log = Logger(subsystem: "io.fhenix.desk", category: "refresh")

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

    /// The saved config, or the defaults when there is none. A file that can't be read at all is copied to
    /// `config.json.bad` first, and `error` says so: the defaults then stand in without a word otherwise, and the next
    /// save would write over the only copy of what the user had.
    public static func loadConfig(support: AppSupport) -> (config: DeskConfig, error: String?) {
        do {
            return (try support.load(DeskConfig.self, from: configFile) ?? DeskConfig(), nil)
        } catch {
            let file = support.url(configFile)
            let bad = support.url(configFile + ".bad")
            try? FileManager.default.removeItem(at: bad)
            let kept = (try? FileManager.default.copyItem(at: file, to: bad)) != nil
            let start = "config.json couldn't be read, so Desk started on its defaults."
            return (DeskConfig(), kept
                ? "\(start) The broken file was kept as config.json.bad; config.json is rewritten only when you change a setting."
                : "\(start) It is rewritten only when you change a setting: fix it by hand before then to keep what it had.")
        }
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

    /// Whether acli is there at all. Without it Jira is left off, which is no failure; with it but signed out is one.
    public var hasJira: Bool { jira != nil }

    /// Which Atlassian account acli is signed in as, for Settings to show.
    public func jiraAccount() async -> JiraAccount? { await jira?.signedInAccount() }

    public func refreshGitHub(now: Date = Date()) async throws -> GitHubSnapshot {
        // How far back the merged-PR search reaches: far enough that a ticket whose pull requests have all
        // landed is still marked behind in Jira weeks later.
        let since = now.addingTimeInterval(-8 * 7 * 86_400)
        return try await gh().snapshot(repos: config.trackedRepoSlugs, since: since, now: now)
    }

    /// The org's repositories, for the Settings picker.
    public func repositories() async throws -> [GitHubRepo] {
        try await gh().repositories()
    }

    public func refreshGit() async -> GitScan {
        await git.scan(roots: config.expandedRepoRoots, slugs: config.trackedRepoSlugs)
    }

    public func cloneSlugs() async -> Set<String> { await git.cloneSlugs(roots: config.expandedRepoRoots) }

    /// Claude Code's background sessions on a PR or a ticket. Small local files, read with the git scan.
    public func claudeJobs() -> [ClaudeJob] { ClaudeJobs.scan(tickets: TicketKeyMatcher(projectKeys: config.jiraProjectKeys)) }

    /// Your Claude plan's limits, for the sidebar. A local file too, read with the git scan.
    public func claudeLimits() -> [ClaudeLimit] { ClaudeLimits.read() }

    /// Whether each clone's sessions can run the skills Desk's presses call, by repo root. A few small files per repo.
    public func reviewSkills(repos: [RepoRef]) async -> [String: ReviewSkill] {
        var skills: [String: ReviewSkill] = [:]
        for repo in repos where skills[repo.root] == nil {
            skills[repo.root] = ClaudePlugins.reviewSkill(repoRoot: repo.root, adopted: await Self.adoptedReviewFlow(repoRoot: repo.root))
        }
        return skills
    }

    /// Whether the repo has adopted the review flow — `REVIEW.md` and `.github/review/tier.sh`, what /pre-pr itself
    /// checks for. In the checkout, or else on origin's default branch: a clone's own checkout can sit on an old commit
    /// while the PRs are cut from a newer one.
    static func adoptedReviewFlow(repoRoot: String) async -> Bool {
        let files = ["REVIEW.md", ".github/review/tier.sh"]
        if files.allSatisfy({ FileManager.default.fileExists(atPath: "\(repoRoot)/\($0)") }) { return true }
        guard let git = Shell.which("git") else { return false }
        for file in files {
            let result = try? await Shell.run(git, ["-C", repoRoot, "cat-file", "-e", "origin/HEAD:\(file)"], environment: GitProvider.environment, timeout: 10)
            guard result?.status == 0 else { return false }
        }
        return true
    }

    /// The GitHub provider, or why there is none.
    private func gh() throws -> GitHubProvider {
        guard let github else { throw DeskError.ghNotFound }
        return github
    }

    /// The claude CLI, or why there is none.
    private func claude() throws -> ClaudeCLI {
        guard let path = config.resolvedClaudePath else { throw DeskError.claudeNotFound }
        return ClaudeCLI(path: path)
    }

    /// The PR's diff as GitHub computes it, for the review screen.
    public func diff(of pr: PullRequest) async throws -> [DiffFile] {
        try await gh().diff(repo: pr.repo, number: pr.number)
    }

    /// Starts a background Claude session on the PR's branch and returns it. `worktree` is a checkout the
    /// user already has on that branch; without one the branch gets a worktree of its own. The session
    /// starts in the repository's own checkout whatever the branch's checkout is: that is the directory
    /// Claude Code reads the project's settings, plugins and memory from, and a worktree is a different
    /// directory to it. The prompt sends it on to the branch, and carries the PR url, which is what ties
    /// the session to this PR until it has touched it itself. With `flow`, the session starts on that flow
    /// instruction, such as /pre-pr's run, instead of the plain PR session prompt.
    public func startClaudeSession(pr: PullRequest, repoRoot: String, worktree: String?, flow: PromptID? = nil) async throws -> ClaudeJob {
        let cli = try claude()
        let path: String
        if let worktree {
            path = worktree
        } else {
            path = try await worktrees.prepareBranch(pr: pr, repoRoot: repoRoot)
        }
        let branchPath = path == repoRoot ? nil : path
        // A new session has no job folder of its own yet to name; it knows its own as CLAUDE_JOB_DIR. The app reads
        // nothing from the file.
        let prompt = flow.map {
            Self.flowPrompt($0, pr: pr, worktree: branchPath, resultFile: "$CLAUDE_JOB_DIR/tmp/desk-step-\(Int(Date().timeIntervalSince1970)).json", config: config)
        } ?? Self.sessionPrompt(for: pr, worktree: branchPath, config: config)
        let id = try await cli.startBackground(prompt, cwd: repoRoot)
        return ClaudeJob(
            id: id, name: "\(pr.repoName)#\(pr.number)", state: "working", cwd: repoRoot,
            prKeys: Set([ClaudeJobs.prKey(pr.url)].compactMap { $0 }), updatedAt: Date(),
            startedOn: Set([ClaudeJobs.prKey(pr.url)].compactMap { $0 })
        )
    }

    /// Starts a background Claude session to plan a ticket, in a repository's own checkout. Nothing ties
    /// the session to the ticket: planning ends in a pull request, and the pull request is what this app
    /// follows — so pressing again is another session, deliberately.
    public func startTicketSession(ticket: Ticket, repoRoot: String, note: String = "") async throws -> String {
        try await claude().startBackground(Self.ticketPrompt(for: ticket, note: note, config: config), cwd: repoRoot)
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
            when: ["worktree": worktree != nil, "unresolved": pr.unresolvedThreads > 0, "conflict": pr.hasConflicts]
        )
    }


    // MARK: Flows

    /// Sends an idle background session its next instruction, keeping its id and its conversation.
    public func send(_ prompt: String, to job: ClaudeJob, cwd: String) async throws {
        try await claude().send(prompt, to: job, cwd: cwd)
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
        try await gh().markReady(repo: pr.repo, number: pr.number)
    }

    public func checks(for pr: PullRequest) async throws -> [PullRequestCheck] {
        try await gh().checks(repo: pr.repo, number: pr.number)
    }

    public func conversation(of pr: PullRequest) async throws -> Conversation {
        try await gh().conversation(repo: pr.repo, number: pr.number)
    }

    public func reply(in thread: ConversationThread, body: String) async throws {
        try await gh().reply(threadId: thread.id, body: body)
    }

    public func setResolved(_ thread: ConversationThread, _ resolved: Bool) async throws {
        try await gh().setResolved(threadId: thread.id, resolved)
    }

    public func comment(on pr: PullRequest, body: String) async throws {
        try await gh().comment(repo: pr.repo, number: pr.number, body: body)
    }

    public func retitle(_ pr: PullRequest, to title: String) async throws {
        try await gh().retitle(repo: pr.repo, number: pr.number, title: title)
    }

    public func editDescription(_ pr: PullRequest, body: String) async throws {
        try await gh().editBody(repo: pr.repo, number: pr.number, body: body)
    }

    public func close(_ pr: PullRequest) async throws {
        try await gh().close(repo: pr.repo, number: pr.number)
    }

    public func squashMerge(_ pr: PullRequest) async throws {
        try await gh().squashMerge(repo: pr.repo, number: pr.number, headSha: pr.headSha)
    }

    public func requestTeamReview(_ pr: PullRequest) async throws {
        try await gh().requestTeamReview(repo: pr.repo, number: pr.number, team: config.reviewTeam)
    }

    /// Your tickets, everyone else's in the projects, and the ones PRs name. Everyone else's backlog only with
    /// `teamBacklog`: when the Jira screen shows it. `previous` is what the last refresh had: everyone else's from it
    /// stand in when Jira does not answer for them, and `error` says so.
    public func refreshJira(
        referencedKeys: [String], teamBacklog: Bool, previous: [Ticket] = []
    ) async throws -> (tickets: [Ticket], error: String?) {
        guard let jira else { throw DeskError.jiraNotConfigured }
        let standIns = previous.filter { !$0.assignedToMe && ($0.placement == .sprint || (teamBacklog && $0.placement == .backlog)) }
        let open = try await jira.openIssues(projects: config.jiraProjectKeys, teamBacklog: teamBacklog, previousTeam: standIns)
        if let error = open.teamError { Self.log.error("jira team tickets: \(error, privacy: .public)") }
        let placed = open.tickets
        let placedKeys = Set(placed.map(\.key))
        // acli fails the whole query when every key in it is unknown or hidden, as one typo in a branch name makes it;
        // that must not throw away the tickets already fetched.
        let others: [Ticket]
        do {
            others = try await jira.issues(keys: referencedKeys.filter { !placedKeys.contains($0) })
        } catch {
            Self.log.error("jira referenced tickets: \(String(describing: error), privacy: .public)")
            others = []
        }
        return (placed + others, open.teamError)
    }

    /// The only call in the app that writes to Jira: planning a ticket, and moving one that has fallen
    /// behind its pull requests. A ticket still in To Do goes through the In Progress status when its workflow
    /// has no way straight to `status`.
    public func transitionTicket(key: String, to status: String, from category: TicketStatusCategory? = nil) async throws {
        guard let jira else { throw DeskError.jiraNotConfigured }
        try await jira.transition(key: key, to: status, via: category == .todo ? config.jiraInProgressStatus : nil)
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
