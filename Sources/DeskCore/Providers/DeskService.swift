import Foundation
import os

public enum DeskError: Error, CustomStringConvertible, Sendable {
    case ghNotFound
    case jiraNotConfigured
    case jiraSignedOut
    case claudeNotFound
    case tmuxNotFound
    /// Opening the terminal app on the layout failed, and why, in a sentence.
    case terminal(String)
    case sessionNotStarted(String)
    /// Stop master was pointed at a session that is not the master Desk started: another name, or another folder.
    case notTheMaster(String)
    /// Start again was pointed at a session that is not the review learning pass Desk started.
    case notReviewLearning(String)
    /// The repo the review learning pass runs in has no clone among the tracked repositories.
    case noClone(String)

    public var description: String {
        switch self {
        case .tmuxNotFound: return "tmux not found. Install it with Homebrew (brew install tmux): the master and its workers run in its desk session."
        case .ghNotFound: return "gh CLI not found. Install it or set the path in Settings."
        case .jiraNotConfigured: return "acli not found. Install it or set its path in Settings → Jira."
        case .jiraSignedOut: return "Not signed in to Jira. Run `acli jira auth login --web` in a terminal, then press Recheck in Settings → Jira."
        case .claudeNotFound: return "claude CLI not found. Install it or set the path in Settings."
        case .sessionNotStarted(let output): return "claude --bg printed no session id: \(output.prefix(200))"
        case .notTheMaster(let name): return "The session \(name) is not the master Desk started in its master folder, so Desk left it running. Stop it with claude stop."
        case .notReviewLearning(let name): return "The session \(name) is not the review learning pass Desk started, so Desk left it running."
        case .noClone(let repo): return "No clone of \(repo) among the repositories Desk tracks. Track it in Settings → GitHub."
        case .terminal(let why): return why
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
    /// `keepIn`: the tracked clones, where, as in your repo roots themselves, a session with no PR or ticket is still a
    /// task.
    public func claudeJobs(keepIn: [String] = []) -> [ClaudeJob] {
        ClaudeJobs.scan(
            tickets: TicketKeyMatcher(projectKeys: config.jiraProjectKeys), keepIn: keepIn, roots: config.expandedRepoRoots,
            masterFolder: MasterFolder(support: support).path
        )
    }

    /// Your Claude plan's limits, for the sidebar. A local file too, read with the git scan.
    public func claudeLimits() -> [ClaudeLimit] { ClaudeLimits.read() }

    /// Whether review sessions can start, and on which skill: fhenix-workflow as installed for your user in the Claude
    /// Code Desk runs, the same in every repo. A couple of small files.
    public func reviewSkill() -> ReviewSkill { ClaudePlugins.reviewSkill(pluginDir: config.pluginDir) }

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

    // ponytail: the master and its workers run in auto mode, the mode Desk is used in; a setting when someone needs another.
    public static let masterPermissionMode = "auto"

    /// What every worker starts with: the master's own permission mode, since a worker in another mode holds the
    /// master's messages for approval, and the plugin folder while skills are being tried.
    public static func workerFlags(config: DeskConfig) -> [String] {
        ["--permission-mode", masterPermissionMode] + config.pluginDirFlags
    }

    /// The master's prompt: its skill, and the worker flags as one shell-ready line for it to copy.
    public static func masterPrompt(config: DeskConfig) -> String {
        let flags = workerFlags(config: config).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        return "Use the fhenix-workflow:coordinate-tasks skill. Start every worker with these flags: \(flags)"
    }

    /// Starts the master session in `folder`, named `master` so Desk's Master tab and the workers find it.
    public func startMaster(in folder: String) async throws -> ClaudeJob {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let id = try await claude().startBackground(
            Self.masterPrompt(config: config), cwd: folder, flags: ["-n", SessionRole.masterName] + Self.workerFlags(config: config)
        )
        return ClaudeJob(
            id: id, name: SessionRole.masterName, state: "working", cwd: folder, prKeys: [], updatedAt: Date(), role: .master
        )
    }

    /// Stops the master and takes it off Claude Code's list, so the next one is a new session rather than this one
    /// attached again. Its workers run on; a new master picks them up from the graph. Any other session is refused
    /// before a command runs: removing a worker deletes its worktree and branch with it. So is a master outside the
    /// master folder, one you started by hand: Desk shows it, and only removes the one it started.
    public func stopMaster(_ session: ClaudeJob) async throws {
        guard MasterFolder(support: support).holds(session) else { throw DeskError.notTheMaster(session.name) }
        try await claude().remove(session.id)
    }

    /// Starts a run of the review learning pass in `clone`, the repo's local clone: a folder for the run, the session
    /// on its skill with that folder to write to, and the start on record. A start that fails leaves no run behind.
    public func startReviewLearning(in clone: String, now: Date = Date()) async throws -> ClaudeJob {
        let folder = ReviewLearningFolder(support: support)
        let run = try folder.newRun(now: now)
        do {
            // The prompt after `--`: `--add-dir` takes several folders, and would take the prompt for one more.
            let id = try await claude().startBackground(
                ReviewLearning.prompt(run: run), cwd: clone,
                flags: ["-n", ReviewLearning.sessionName] + Self.workerFlags(config: config) + ["--add-dir", run.path, "--"]
            )
            try folder.recordStart(ReviewLearning.Start(startedAt: now, jobId: id), in: run)
            return ClaudeJob(
                id: id, name: ReviewLearning.sessionName, state: "working", cwd: clone, prKeys: [], updatedAt: now, role: .learning
            )
        } catch {
            try? FileManager.default.removeItem(at: run)
            throw error
        }
    }

    /// Stops a review learning session and takes it off Claude Code's list, before Start again starts a new run. Any
    /// other session is refused: removing one deletes what it was working in.
    public func removeReviewLearning(_ session: ClaudeJob) async throws {
        guard session.role == .learning, session.name == ReviewLearning.sessionName else { throw DeskError.notReviewLearning(session.name) }
        try await claude().remove(session.id)
    }

    public func markReady(_ pr: PullRequest) async throws {
        try await gh().markReady(repo: pr.repo, number: pr.number)
    }

    public func convertToDraft(_ pr: PullRequest) async throws {
        try await gh().convertToDraft(repo: pr.repo, number: pr.number)
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

    public func merge(_ pr: PullRequest, method: MergeMethod) async throws {
        try await gh().merge(repo: pr.repo, number: pr.number, headSha: pr.headSha, method: method)
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

    /// The project's statuses, for Setup and Settings to pick the three moves from.
    public func jiraStatuses(project: String) async throws -> [JiraStatus] {
        guard let jira else { throw DeskError.jiraNotConfigured }
        return try await jira.statuses(project: project)
    }

    public func jiraProjectKeys() async throws -> [String] {
        guard let jira else { throw DeskError.jiraNotConfigured }
        return try await jira.projectKeys()
    }
}
