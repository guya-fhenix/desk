import AppKit
import DeskCore
import Foundation
import Observation
import os

@MainActor
@Observable
final class AppModel {
    var state: DeskState
    var refreshing: Set<Source> = []
    /// Why the last settings write failed, in a sentence that says what to do; nil once one succeeds.
    var configError: String?
    /// The error itself, for the tooltip on that sentence.
    var configErrorDetail: String?
    /// The Atlassian account acli is signed in as, or nil when nobody is.
    var jiraAccount: JiraAccount?
    /// The org's repositories, for the Settings picker. Fetched on demand: the list changes rarely and
    /// the app needs no repo it is not tracking.
    var repositories: [GitHubRepo] = []
    var loadingRepositories = false
    var repositoriesError: String?
    /// Set to ask the window to switch tabs; `DeskWindow` clears it. The menu bar and the nudges use it
    /// to land on the screen they mean.
    var pendingTab: DeskWindow.Tab?
    /// True while the Desk window shows Settings in place of the workspace.
    var showingSettings = false
    /// True while the window shows first-run setup in place of everything else: on every launch until it is finished
    /// once, and again from Settings → General.
    var showingSetup = !UserDefaults.standard.bool(forKey: AppModel.setupDoneKey)
    private static let setupDoneKey = "setupCompleted"
    /// True while Search (⌘K) is open over the window.
    var showingFinder = false
    /// Bumped by View → Find (⌘F); the search box on screen takes focus when it changes.
    var searchFocusRequest = 0
    /// How many search boxes are on screen. Find falls back to Search (⌘K) on a screen that has none.
    var visibleSearchBoxes = 0
    /// Bumped by View → Show/Hide Details (⌥⌘I); the window flips the details panel of the screen it shows.
    var inspectorToggleRequest = 0
    /// What Settings is editing, kept here so leaving Settings and coming back keeps what you had typed.
    let settings = SettingsDraft()
    /// Ticket keys with a transition in flight, so a poll that lands mid-move does not start another.
    var movingTickets: Set<String> = []
    /// Why Jira refused the last move of a ticket, by key; cleared by a move that works or a dismissal.
    var ticketMoveErrors: [String: String] = [:]
    /// Ticket keys with a planning session starting, for the button that must not fire twice.
    var planningTickets: Set<String> = []
    /// PR urls with a background session being started, for the same reason.
    var startingSessions: Set<String> = []
    /// Your PRs this app merged or closed, by url, as they now stand and when. GitHub's search lags a write by up to a
    /// minute or so, and until it agrees each refresh is corrected by these, so a PR's page and the lists show how it
    /// ended at once instead of on some later poll.
    private var landed: [String: (pr: PullRequest, at: Date)] = [:]
    /// Your drafts this app marked ready, by url, and when: corrected the same way, or a lagging search would put the PR
    /// back at Fixes to check and offer Mark ready again.
    private var readied: [String: Date] = [:]
    /// Your PRs with a flow instruction going out or a GitHub write in flight, by url.
    var busyFlows: Set<String> = []
    /// Why the last press on a PR's flow failed, by url, until the next press. Like the stage, nothing of it is saved.
    var flowErrors: [String: String] = [:]
    /// Set to have the Pull Requests or Reviews screen open this PR's page; the screen clears it. Search, Up Next
    /// and a notification's Show use it.
    var selectPullRequest: String?
    /// Set to have the Jira screen select this ticket, by key, in its details panel; the screen clears it. Search uses it.
    var selectTicket: String?
    /// Why the session button last failed, per PR url or ticket key. It is the button's own tooltip: a press that
    /// does nothing is the one thing this must not be.
    var sessionErrors: [String: String] = [:]
    /// The terminal panel on the right: attached sessions and review sessions.
    let terminals = TerminalPanel()
    /// The PR whose diff the Reviews screen shows in place of its page, by url; nil shows the page.
    var reviewing: String?
    /// Each reviewed PR's diff, by url, and why fetching one failed.
    var diffs: [String: LoadedDiff] = [:]
    var diffErrors: [String: String] = [:]
    /// Where a review session's link asked the diff to go; the review screen moves there and clears it.
    var diffJump: DiffJump?
    /// Each PR's conversation, by url, as its page or review diff last fetched it, and why fetching one failed.
    var conversations: [String: Conversation] = [:]
    var conversationErrors: [String: String] = [:]
    private let support = AppSupport()
    private let service: DeskService
    private let notifier: Notifier
    private var loops: [Source: Task<Void, Never>] = [:]
    private nonisolated static let log = Logger(subsystem: "io.fhenix.desk", category: "refresh")

    init() {
        let config = DeskService.loadConfig(support: support)
        state = DeskState(config: config)
        service = DeskService(config: config, support: support)
        notifier = Notifier(support: support)
        state.dismissedMoves = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedMovesKey) ?? [])
        Task { await self.start() }
        Notifier.onShow = { [weak self] url in self?.show(url) }
    }

    var config: DeskConfig {
        get { state.config }
        set { state.config = newValue }
    }

    /// What Up Next has waiting on you: every section but Waiting, and the Jira moves it suggests. The filters are the
    /// Reviews screen's, which Up Next's reviews follow.
    func upNextCount(_ filters: ReviewFilters) -> Int {
        state.upNext(reviewDays: filters.window, hiding: filters.hidden, needingApproval: filters.needsApproval)
            .filter { $0.section != .waiting }.reduce(0) { $0 + $1.pullRequests.count }
            + state.ticketDrifts.count
    }

    func start() async {
        jiraAccount = await service.jiraAccount()
        for source in Source.allCases where loops[source] == nil {
            loops[source] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refresh(source)
                    let seconds = self.interval(for: source)
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }
        }
    }

    private func interval(for source: Source) -> Int {
        switch source {
        case .github: return max(config.githubPollSeconds, 30)
        case .git: return max(config.gitPollSeconds, 15)
        case .jira: return max(config.jiraPollSeconds, 60)
        }
    }

    func refreshAll() {
        for source in Source.allCases {
            Task { await refresh(source) }
        }
    }

    func refresh(_ source: Source) async {
        guard !refreshing.contains(source) else { return }
        refreshing.insert(source)
        defer { refreshing.remove(source) }
        do {
            switch source {
            case .github:
                let snapshot = try await service.refreshGitHub()
                state.github = snapshot
                applyLanded()
            case .git:
                let scan = await service.refreshGit()
                state.gitScan = scan
                state.claudeJobs = await service.claudeJobs()
                state.claudeLimits = await service.claudeLimits()
                state.reviewSkills = await service.reviewSkills(repos: scan.repos)
                state.errors[.git] = scan.errors.isEmpty ? nil : scan.errors.joined(separator: "\n")
                for error in scan.errors { Self.log.error("git: \(error, privacy: .public)") }
            case .jira:
                // No acli is Jira left off, and quiet. acli signed out is a failure: called a success, the dot went green
                // while nothing reached Jira.
                guard await service.hasJira else {
                    state.errors[.jira] = nil
                    state.lastRefresh[.jira] = Date()
                    return
                }
                guard await service.jiraReady else { throw DeskError.jiraSignedOut }
                state.tickets = try await service.refreshJira(referencedKeys: state.referencedTicketKeys)
            }
            if source != .git { state.errors[source] = nil }
            state.lastRefresh[source] = Date()
        } catch {
            state.errors[source] = "\(error)"
            Self.log.error("\(source.title, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        state.recompute()
        notifier.deliver(state.nudges, post: config.notificationsEnabled && allSourcesReported)
    }

    private var allSourcesReported: Bool {
        Source.allCases.allSatisfy { state.lastRefresh[$0] != nil || state.errors[$0] != nil }
    }

    func loadRepositories(force: Bool = false) {
        guard force || repositories.isEmpty, !loadingRepositories else { return }
        loadingRepositories = true
        Task {
            defer { loadingRepositories = false }
            do {
                repositories = try await service.repositories()
                repositoriesError = nil
            } catch {
                repositoriesError = "\(error)"
            }
        }
    }

    func saveConfig() {
        do {
            try support.save(config, to: DeskService.configFile)
            configError = nil
            configErrorDetail = nil
        } catch {
            configError = "Couldn't save settings: \(error.localizedDescription) Check that ~/Library/Application Support/Fhenix Desk is writable."
            configErrorDetail = "\(error)"
        }
        Task {
            await service.update(config: config)
            jiraAccount = await service.jiraAccount()
            refreshAll()
        }
    }

    func completeSetup() {
        UserDefaults.standard.set(true, forKey: Self.setupDoneKey)
        showingSetup = false
        saveConfig()
    }

    /// Ticks every repo of the org you have a clone of under the repo roots, keeping what is ticked already.
    func trackClones() {
        Task {
            let clones = await service.cloneSlugs()
            let draft = settings
            let picked = repositories.map(\.slug).filter(clones.contains)
            draft.config.trackedRepos = Array(Set(draft.config.trackedRepoSlugs + picked)).sorted()
        }
    }

    /// Re-reads acli's sign-in state, for after the user has logged in from a terminal.
    func refreshJiraAccount() {
        Task {
            jiraAccount = await service.jiraAccount()
            await refresh(.jira)
        }
    }

    /// Why nothing can be sent to this PR's session now, in the words beside the button that would; nil when it can.
    /// An instruction never cuts in: the session must be done with its turn.
    func sendBlocker(_ pr: PullRequest) -> String? {
        guard let session = state.session(for: pr) else { return "No session" }
        if busyFlows.contains(pr.url) { return "Sending…" }
        if session.state == "blocked" { return "The session is asking you something" }
        if !session.isIdle || session.sessionId == nil { return "The session is busy" }
        return nil
    }

    /// Why Run /pre-pr is dead on a draft; nil when it may be pressed. Without a session it starts one, which needs a
    /// clone of the repo.
    func prePRBlocker(_ pr: PullRequest) -> String? {
        if state.session(for: pr) == nil {
            if startingSessions.contains(pr.url) { return "Starting a session…" }
            if state.localRepo(for: pr) == nil { return "No clone of \(pr.repoName) here" }
        } else if let blocker = sendBlocker(pr) {
            return blocker
        }
        guard let skill = state.reviewSkill(for: pr), skill.has(skill.selfReview) else { return "Self-review skill missing" }
        return nil
    }

    /// The PR's Files tab, where a pending review's comments are read, edited and submitted.
    func openDraft(_ pr: PullRequest) { open("\(pr.url)/files") }

    // MARK: Jira

    /// Moves a ticket to where its pull requests say it belongs, on your press. Shown moved at once, the Jira refresh
    /// after it confirming; why Jira refused, if it did, stays on the suggestion until a retry works.
    func moveTicket(_ drift: TicketDrift) {
        let key = drift.ticket.key
        guard movingTickets.insert(key).inserted else { return }
        Task {
            defer { movingTickets.remove(key) }
            do {
                try await service.transitionTicket(key: key, to: drift.target)
                ticketMoveErrors[key] = nil
                if let index = state.tickets.firstIndex(where: { $0.key == key }) {
                    state.tickets[index].status = drift.target
                    if drift.stage == .done { state.tickets[index].category = .done }
                }
                state.recompute()
                Self.log.info("jira \(key, privacy: .public) moved to \(drift.target, privacy: .public)")
            } catch {
                ticketMoveErrors[key] = "\(error)"
                Self.log.error("jira \(key, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            await refresh(.jira)
        }
    }

    /// Hides a suggested move for good, or until the ticket's pull requests point it somewhere else.
    func dismissMove(_ drift: TicketDrift) {
        state.dismissedMoves.insert(drift.moveKey)
        UserDefaults.standard.set(state.dismissedMoves.sorted(), forKey: Self.dismissedMovesKey)
        ticketMoveErrors[drift.ticket.key] = nil
        state.recompute()
    }

    private static let dismissedMovesKey = "jira.dismissedMoves"

    /// Starts a background Claude session to plan a ticket, then moves the ticket to in progress so a
    /// later glance says somebody is already on it. The session is tied to nothing: press again and you
    /// get another, which is the point — it is the pull request it ends in that the app follows.
    ///
    /// The ticket only moves once the session is running. A press that started nothing must not leave
    /// Jira claiming work is underway.
    func planTicket(_ ticket: Ticket, in repo: RepoRef, note: String = "") {
        let key = ticket.key
        guard !planningTickets.contains(key) else { return }
        planningTickets.insert(key)
        Task {
            defer { planningTickets.remove(key) }
            do {
                let id = try await service.startTicketSession(ticket: ticket, repoRoot: repo.root, note: note)
                // Held until the next scan reads the same session off disk, the ticket's key out of its prompt.
                state.claudeJobs.insert(
                    ClaudeJob(id: id, name: key, state: "working", cwd: repo.root, prKeys: [], updatedAt: Date(), ticketKey: key), at: 0
                )
                sessionErrors[key] = nil
            } catch {
                sessionErrors[key] = "\(error)"
                Self.log.error("plan \(key, privacy: .public): \(String(describing: error), privacy: .public)")
                return
            }
            await startProgress(on: ticket)
        }
    }

    /// Moves a ticket to the in-progress status, unless it is already there or already finished. A refusal
    /// here is worth saying out loud but never undoes the session that has just started.
    private func startProgress(on ticket: Ticket) async {
        let target = config.jiraInProgressStatus
        guard !target.isEmpty, ticket.status != target, ticket.category != .done else { return }
        do {
            try await service.transitionTicket(key: ticket.key, to: target)
            state.errors[.jira] = nil
        } catch {
            state.errors[.jira] = "\(error)"
            Self.log.error("plan \(ticket.key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        await refresh(.jira)
    }

    func open(_ url: String?) {
        guard let url, let parsed = URL(string: url) else { return }
        NSWorkspace.shared.open(parsed)
    }

    /// Renames your PR on GitHub and shows the new title at once rather than on the next poll. Why it failed, or nil.
    func retitle(_ pr: PullRequest, to title: String) async -> String? {
        do {
            try await service.retitle(pr, to: title)
        } catch {
            return "Couldn't rename it: \(error)"
        }
        if let index = state.github?.mine.firstIndex(where: { $0.url == pr.url }) { state.github?.mine[index].title = title }
        state.recompute()
        Task { await refresh(.github) }
        return nil
    }

    /// Rewrites your PR's description on GitHub and shows it at once, the next poll confirming it. Why it failed, or nil.
    func editDescription(_ pr: PullRequest, body: String) async -> String? {
        do {
            try await service.editDescription(pr, body: body)
        } catch {
            return "Couldn't save it: \(error)"
        }
        if let index = state.github?.mine.firstIndex(where: { $0.url == pr.url }) { state.github?.mine[index].body = body }
        state.recompute()
        Task { await refresh(.github) }
        return nil
    }

    /// Squash-merges a PR from its page or its flow, and shows it merged at once. Why it failed, or nil.
    func squashMerge(_ pr: PullRequest) async -> String? {
        do {
            try await service.squashMerge(pr)
        } catch {
            return "Couldn't merge it: \(error)"
        }
        land(pr, as: .merged)
        Task { await refresh(.github) }
        return nil
    }

    /// Saves an edit to a ticket's summary or description and shows it at once, the next Jira poll confirming it. Why it
    /// failed, or nil.
    func editTicket(_ ticket: Ticket, summary: String? = nil, description: String? = nil) async -> String? {
        do {
            try await service.editTicket(key: ticket.key, summary: summary, description: description)
        } catch {
            return "\(error)"
        }
        if let index = state.tickets.firstIndex(where: { $0.key == ticket.key }) {
            if let summary { state.tickets[index].summary = summary }
            if let description { state.tickets[index].description = description }
        }
        state.recompute()
        Task { await refresh(.jira) }
        return nil
    }

    /// One of your PRs by url: open, merged this month, or closed from here a moment ago.
    func yourPullRequest(_ url: String) -> PullRequest? {
        (state.mine + state.recentlyMerged()).first { $0.url == url } ?? landed[url]?.pr
    }

    /// Records a merge or close this app made and shows it at once.
    private func land(_ pr: PullRequest, as outcome: PullRequestState) {
        var ended = pr
        ended.state = outcome
        if outcome == .merged { ended.mergedAt = Date() }
        landed[pr.url] = (ended, Date())
        applyLanded()
        state.recompute()
    }

    /// Takes what this app merged or closed out of the open lists, puts a merge into the merged one, and shows a draft it
    /// marked ready as ready, until GitHub's search says the same; after ten minutes it long has.
    private func applyLanded() {
        let now = Date()
        landed = landed.filter { now.timeIntervalSince($0.value.at) < 600 }
        readied = readied.filter { now.timeIntervalSince($0.value) < 600 }
        guard var github = state.github, !landed.isEmpty || !readied.isEmpty else { return }
        for index in github.mine.indices where readied[github.mine[index].url] != nil { github.mine[index].isDraft = false }
        for (url, entry) in landed {
            github.mine.removeAll { $0.url == url }
            github.reviewRequests.removeAll { $0.url == url }
            github.openForReview.removeAll { $0.url == url }
            if entry.pr.state == .merged, !github.mergedRecent.contains(where: { $0.url == url }) {
                github.mergedRecent.insert(entry.pr, at: 0)
            }
        }
        state.github = github
    }

    /// Closes a PR from its page without merging it. Why it failed, or nil.
    func close(_ pr: PullRequest) async -> String? {
        do {
            try await service.close(pr)
        } catch {
            return "Couldn't close it: \(error)"
        }
        land(pr, as: .closed)
        Task { await refresh(.github) }
        return nil
    }

    /// A PR's checks in full, for its page. Not kept: the page asks again each time it shows the PR.
    func checks(for pr: PullRequest) async throws -> [PullRequestCheck] { try await service.checks(for: pr) }

    /// Fetches a PR's conversation, for its page and its review diff, which ask again whenever the PR changes.
    func loadConversation(_ pr: PullRequest) async {
        do {
            conversations[pr.url] = try await service.conversation(of: pr)
            conversationErrors[pr.url] = nil
        } catch {
            if !Task.isCancelled { conversationErrors[pr.url] = "\(error)" }
        }
    }

    /// Replies in a thread as you. Why it failed, or nil.
    func reply(_ pr: PullRequest, in thread: ConversationThread, body: String) async -> String? {
        await write(pr, "Couldn't reply") { try await self.service.reply(in: thread, body: body) }
    }

    /// Resolves a thread, or opens a resolved one again. Why it failed, or nil.
    func setResolved(_ pr: PullRequest, _ thread: ConversationThread, _ resolved: Bool) async -> String? {
        await write(pr, resolved ? "Couldn't resolve it" : "Couldn't reopen it") { try await self.service.setResolved(thread, resolved) }
    }

    /// A comment on the PR's conversation, as you. Why it failed, or nil.
    func comment(_ pr: PullRequest, body: String) async -> String? {
        await write(pr, "Couldn't post it") { try await self.service.comment(on: pr, body: body) }
    }

    /// A write to the conversation, then the conversation again so it shows, and the search for the open-thread count.
    private func write(_ pr: PullRequest, _ failure: String, _ action: () async throws -> Void) async -> String? {
        do {
            try await action()
        } catch {
            return "\(failure): \(error)"
        }
        await loadConversation(pr)
        Task { await refresh(.github) }
        return nil
    }

    /// Opens the window on the screen a PR lives on, its row selected — your own in Pull Requests, one in the queue in
    /// Reviews — and GitHub for one on no screen here.
    func show(_ pr: String) {
        if state.mine.contains(where: { $0.url == pr }) {
            pendingTab = .pullRequests
        } else if state.reviewQueue(.all).contains(where: { $0.url == pr }) {
            pendingTab = .reviews
        } else {
            open(pr)
            return
        }
        selectPullRequest = pr
        AppDelegate.openDesk?()
    }

    // MARK: Background sessions

    /// Starts a background Claude session on the PR's branch. The button that calls this is the one shown
    /// when no session mentions the PR yet; the row flips to Attach as soon as this one lands.
    func startSession(for pr: PullRequest, flow: PromptID? = nil) {
        guard let repo = state.localRepo(for: pr), !startingSessions.contains(pr.url) else { return }
        startingSessions.insert(pr.url)
        // A checkout the user already has on that branch is the session's home; nothing else touches git.
        let existing = state.worktrees.first { $0.repoName == pr.repoName && $0.branch == pr.headRef }?.path
        Task {
            defer { startingSessions.remove(pr.url) }
            do {
                let job = try await service.startClaudeSession(pr: pr, repoRoot: repo.root, worktree: existing, flow: flow)
                // Held until the next scan reads the same session off disk. On your own PR it puts the PR in the flow.
                state.claudeJobs.insert(job, at: 0)
                sessionErrors[pr.url] = nil
                if existing == nil { Task { await refresh(.git) } }
            } catch {
                sessionErrors[pr.url] = "\(error)"
                Self.log.error("session: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Opens a background Claude session in the terminal panel. A background session is a daemon rather than a
    /// shell, so `claude attach` is the only way into one — and it works whether it is still running or
    /// has already finished. Closing the tab only detaches.
    func attach(_ job: ClaudeJob, for pr: PullRequest) { attach(jobId: job.id, errorKey: pr.url) }

    /// `errorKey` is the PR url or ticket key whose button pressed it, which is where a failure is shown.
    func attach(jobId: String, errorKey: String) {
        guard let claude = config.resolvedClaudePath else {
            sessionErrors[errorKey] = DeskError.claudeNotFound.description
            return
        }
        sessionErrors[errorKey] = nil
        let name = state.claudeJobs.first { $0.id == jobId }?.name ?? jobId
        terminals.open(id: "attach:\(jobId)", title: name, executable: claude, arguments: ["attach", jobId])
    }

    // MARK: Reviews

    private static func reviewTab(_ pr: PullRequest) -> String { "review:\(pr.url)" }

    func reviewRunning(_ pr: PullRequest) -> Bool { terminals.tab(Self.reviewTab(pr))?.running == true }

    /// Start review on a teammate's PR: its diff on the Reviews screen, and a regular Claude session on the
    /// review-pr skill in the terminal panel — or the one already running there. Not a background session: Claude's
    /// own agents view backgrounds it if you want. It starts in the repository's checkout, where Claude Code reads
    /// the project's plugins; the skill reads the PR's code at its head without checking anything out.
    func startReview(_ pr: PullRequest) {
        sessionErrors[pr.url] = nil
        reviewing = pr.url
        loadDiff(pr)
        if reviewRunning(pr) {
            terminals.select(Self.reviewTab(pr))
            return
        }
        guard let claude = config.resolvedClaudePath else {
            sessionErrors[pr.url] = DeskError.claudeNotFound.description
            return
        }
        guard let repo = state.localRepo(for: pr) else {
            sessionErrors[pr.url] = "No clone of \(pr.repo) here: the review session starts in the repository's checkout."
            return
        }
        // Read again here rather than from the last scan, so a plugin updated a moment ago counts.
        let skill = ClaudePlugins.reviewSkill(repoRoot: repo.root)
        guard skill.has(ClaudePlugins.reviewPR) else {
            sessionErrors[pr.url] = "Can't start the review session: \(skill.text)."
            return
        }
        let ticket = DeskService.reviewTicket(for: pr, tickets: state.tickets, projectKeys: config.jiraProjectKeys)
        terminals.open(
            id: Self.reviewTab(pr), title: "Review \(pr.repoName)#\(pr.number)", executable: claude,
            arguments: DeskService.reviewArguments(for: pr, ticket: ticket, config: config), directory: repo.root
        )
    }

    /// Fetches the PR's diff for the review screen: once per head, or again when `force`d.
    func loadDiff(_ pr: PullRequest, force: Bool = false) {
        guard force || diffs[pr.url] == nil else { return }
        diffErrors[pr.url] = nil
        Task {
            do {
                diffs[pr.url] = LoadedDiff(sha: pr.headSha, files: try await service.diff(of: pr))
            } catch {
                diffErrors[pr.url] = "\(error)"
            }
        }
    }

    /// The selected lines into the review session's input, for you to ask about.
    func askClaude(_ pr: PullRequest, _ text: String) {
        sessionErrors[pr.url] = terminals.paste(text, into: Self.reviewTab(pr)) ? nil : "No review session is running: press Start review."
    }

    /// A review session's `open fhenixdesk://show/…`: that PR's diff, at that line. A PR Desk does not know is ignored —
    /// any app can open the link, so it only ever moves the diff.
    func open(_ url: URL) {
        guard let link = DeskLink(url) else { return }
        let known = state.reviewRequests + state.openForReview + (state.github?.allOpen ?? [])
        guard let pr = known.first(where: { ClaudeJobs.prKey($0.url) == link.prKey }) else {
            Self.log.info("link for an unknown PR: \(url.absoluteString, privacy: .public)")
            return
        }
        reviewing = pr.url
        loadDiff(pr)
        diffJump = DiffJump(url: pr.url, path: link.path, side: link.side, line: link.line)
        showingSettings = false
        pendingTab = .reviews
        selectPullRequest = pr.url
    }

    // MARK: Flows

    /// Run /pre-pr on a draft: its session runs it once, or a new background session starts on it when the PR has none.
    /// Pressed again, it runs again.
    func runPrePR(_ pr: PullRequest) {
        guard prePRBlocker(pr) == nil else { return }
        if state.session(for: pr) == nil {
            startSession(for: pr, flow: .selfReview)
        } else {
            send(.selfReview, for: pr)
        }
    }

    /// Mark ready on a draft: it leaves draft and the review team is asked. Shown ready at once.
    func markReady(_ pr: PullRequest) {
        guard busyFlows.insert(pr.url).inserted else { return }
        flowErrors[pr.url] = nil
        Task {
            defer { busyFlows.remove(pr.url) }
            do {
                try await service.markReady(pr)
                readied[pr.url] = Date()
                applyLanded()
                try await service.requestTeamReview(pr)
            } catch {
                flowErrors[pr.url] = "\(error)"
            }
            state.recompute()
            await refresh(.github)
        }
    }

    /// Merge on an approved PR: always a squash.
    func merge(_ pr: PullRequest) {
        guard busyFlows.insert(pr.url).inserted else { return }
        Task {
            defer { busyFlows.remove(pr.url) }
            flowErrors[pr.url] = await squashMerge(pr)
        }
    }

    /// Fix it on a PR that conflicts with its base or whose CI failed: its session gets the fix. Nothing goes out on its
    /// own: a fix that did not take is pressed again or left, as you choose.
    func fix(_ prompt: PromptID, for pr: PullRequest) {
        guard sendBlocker(pr) == nil else { return }
        send(prompt, for: pr)
    }

    /// Sends the PR's session one flow instruction; the session going to work is what moves the stage.
    private func send(_ prompt: PromptID, for pr: PullRequest) {
        guard let session = state.session(for: pr), busyFlows.insert(pr.url).inserted else { return }
        flowErrors[pr.url] = nil
        let root = state.localRepo(for: pr)?.root ?? session.cwd
        let worktree = state.worktrees.first { $0.repoRoot == root && $0.branch == pr.headRef }?.path
        // Numbered by when it went out, so an earlier instruction's file is never this one's.
        let resultFile = DeskService.resultFile(jobId: session.id, step: Int(Date().timeIntervalSince1970))
        let text = DeskService.flowPrompt(
            prompt, pr: pr, worktree: worktree, resultFile: resultFile, config: config
        )
        let cwd = resumeDirectory(session, for: pr)
        Task {
            defer { busyFlows.remove(pr.url) }
            do {
                try await service.send(text, to: session, cwd: cwd)
                Self.log.info("flow \(pr.url, privacy: .public): sent \(prompt.rawValue, privacy: .public)")
            } catch {
                flowErrors[pr.url] = "Couldn't send it to the session: \(error)"
                Self.log.error("flow \(pr.url, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            await refresh(.git)
        }
    }

    /// Where to resume a PR's session from: whichever of the clone's worktrees, the session's own folder and the clone
    /// holds its transcript, or the clone.
    private func resumeDirectory(_ session: ClaudeJob, for pr: PullRequest) -> String {
        let root = state.localRepo(for: pr)?.root ?? session.cwd
        let candidates = state.worktrees.filter { $0.repoRoot == root }.map(\.path) + [session.cwd, root].filter { !$0.isEmpty }
        return session.sessionId.flatMap { DeskService.resumeDirectory(sessionId: $0, candidates: candidates) } ?? root
    }

}
