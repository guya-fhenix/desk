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
    /// Sources asked to refresh while they already were, each to go once more when that one ends.
    private var refreshAgain: Set<Source> = []
    /// Jira refreshes that failed in a row, which stretch its next poll (`PollBackoff`); one success clears it.
    private var jiraFailures = 0
    /// When each source's poll next runs, so a source that keeps failing can say when it will be tried again.
    var nextPoll: [Source: Date] = [:]
    /// Why config.json couldn't be read at launch, or why the last settings write failed, in a sentence that says what to
    /// do; nil once a write succeeds.
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
    /// Tickets this app moved or edited, by key, as it expects Jira to show them, and when. Jira's search lags a write as
    /// GitHub's does, and until it agrees, for five minutes at most, each Jira refresh is corrected by these: a lagging
    /// one would otherwise put the move back on offer.
    private var ticketEdits: [String: (edit: TicketEdit, at: Date)] = [:]
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
    /// What config.json holds, as far as the app knows: the config it loaded or last wrote. Only a config that differs is
    /// written, so starting on defaults, after a missing or broken file, writes nothing until you change a setting.
    private var savedConfig: DeskConfig
    private let service: DeskService
    private let notifier: Notifier
    private var loops: [Source: Task<Void, Never>] = [:]
    private var updateCheck: Task<Void, Never>?
    /// A newer Desk, once GitHub's latest release is later than this app; the sidebar suggests updating to it.
    var update: AppUpdate.Available?
    private nonisolated static let log = Logger(subsystem: "io.fhenix.desk", category: "refresh")

    init() {
        let (config, configError) = DeskService.loadConfig(support: support)
        state = DeskState(config: config)
        savedConfig = config
        service = DeskService(config: config, support: support)
        notifier = Notifier(support: support)
        state.dismissedMoves = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedMovesKey) ?? [])
        Task { await self.start() }
        Notifier.onShow = { [weak self] url in self?.show(url) }
        // Settings is where the sentence shows.
        self.configError = configError
        showingSettings = configError != nil
    }

    var config: DeskConfig {
        get { state.config }
        set { state.config = newValue }
    }

    /// What Up Next has waiting on you, inside the Reviews screen's filters, which Up Next's reviews follow.
    func upNextCount(_ filters: ReviewFilters) -> Int {
        state.upNextCount(reviewDays: filters.window, hiding: filters.hidden, needingApproval: filters.needsApproval)
    }

    /// The polls start first: reading the Jira account can wait out acli's whole timeout offline, and the window would
    /// stay empty all that time.
    func start() async {
        for source in Source.allCases where loops[source] == nil {
            loops[source] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refresh(source)
                    let seconds = self.interval(for: source)
                    self.nextPoll[source] = Date().addingTimeInterval(TimeInterval(seconds))
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }
        }
        // At launch, then every six hours. A build without a bundle (`swift run`) has no version to compare.
        if updateCheck == nil, let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            updateCheck = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if let gh = self.config.resolvedGhPath, let latest = await AppUpdate.latest(gh: gh) {
                        self.update = AppUpdate.available(latest: latest, current: current)
                    }
                    try? await Task.sleep(for: .seconds(6 * 3600))
                }
            }
        }
        jiraAccount = await service.jiraAccount()
    }

    private func interval(for source: Source) -> Int {
        switch source {
        case .github: return max(config.githubPollSeconds, 30)
        case .git: return max(config.gitPollSeconds, 15)
        case .jira: return PollBackoff.seconds(interval: max(config.jiraPollSeconds, 60), failures: jiraFailures)
        }
    }

    func refreshAll() {
        for source in Source.allCases {
            Task { await refresh(source) }
        }
    }

    /// A refresh asked for while one of the same source runs goes once more after it: the running fetch began before
    /// whatever change asked, and would otherwise leave the state from before it.
    func refresh(_ source: Source) async {
        guard refreshing.insert(source).inserted else {
            refreshAgain.insert(source)
            return
        }
        defer {
            refreshing.remove(source)
            if refreshAgain.remove(source) != nil { Task { await refresh(source) } }
        }
        do {
            switch source {
            case .github:
                let snapshot = try await service.refreshGitHub()
                state.github = snapshot
                applyLanded()
                // Your own PRs came back; a search of the others that failed kept its last list, and says why here.
                state.errors[.github] = snapshot.error
                if let error = snapshot.error { Self.log.error("GitHub: \(error, privacy: .public)") }
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
                let jira = try await service.refreshJira(
                    referencedKeys: state.referencedTicketKeys, teamBacklog: TicketFilters.showsTeamBacklog, previous: state.tickets
                )
                state.tickets = jira.tickets
                applyTicketEdits()
                // Your own tickets came back; other people's, if Jira did not answer for them, kept their last list, and
                // say why here.
                state.errors[.jira] = jira.error
            }
            state.lastRefresh[source] = Date()
        } catch {
            state.errors[source] = "\(error)"
            Self.log.error("\(source.title, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        // Jira failing again and again is asked less and less often, which is what lets a throttle on the account lift.
        if source == .jira { jiraFailures = state.errors[.jira] == nil ? 0 : jiraFailures + 1 }
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

    /// Writes the config when it changed and hands it to the sources, which a recheck after a sign-in wants either way.
    func saveConfig() {
        do {
            if config != savedConfig {
                try support.save(config, to: DeskService.configFile)
                savedConfig = config
                configError = nil
                configErrorDetail = nil
            }
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

    /// Why nothing can be sent to this PR's session now; nil when it can.
    func sendBlocker(_ pr: PullRequest) -> String? { state.sendBlocker(pr, sending: busyFlows.contains(pr.url)) }

    /// Why Run /pre-pr is dead on a draft; nil when it may be pressed.
    func prePRBlocker(_ pr: PullRequest) -> String? {
        state.prePRBlocker(pr, sending: busyFlows.contains(pr.url), startingSession: startingSessions.contains(pr.url))
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
            ticketMoveErrors[key] = await perform(.jira) {
                try await service.transitionTicket(key: key, to: drift.target, from: drift.ticket.category)
            } patch: {
                expect(TicketEdit(status: drift.target, category: drift.stage == .done ? .done : nil), on: key)
            }
            if let error = ticketMoveErrors[key] {
                Self.log.error("jira \(key, privacy: .public): \(error, privacy: .public)")
            } else {
                Self.log.info("jira \(key, privacy: .public) moved to \(drift.target, privacy: .public)")
            }
        }
    }

    /// Shows a write to a ticket at once, and keeps it shown until Jira agrees.
    private func expect(_ edit: TicketEdit, on key: String) {
        let merged = ticketEdits[key].map { $0.edit.merging(edit) } ?? edit
        ticketEdits[key] = (merged, Date())
        state.apply(ticketEdits: [key: merged])
    }

    /// Lays the ticket writes over a fresh Jira answer, less those it agrees with and those five minutes old. Only on a
    /// fresh answer: over the tickets as already corrected, every write would look agreed with.
    private func applyTicketEdits() {
        let now = Date()
        ticketEdits = ticketEdits.filter { now.timeIntervalSince($0.value.at) < 300 }
        for key in state.apply(ticketEdits: ticketEdits.mapValues(\.edit)) { ticketEdits[key] = nil }
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
    /// here is worth saying out loud but never undoes the session that has just started. It is the ticket's, beside its
    /// sessions: on the Jira source it would be cleared by the refresh that follows, and say nothing of the ticket.
    private func startProgress(on ticket: Ticket) async {
        let target = config.jiraInProgressStatus
        guard !target.isEmpty, ticket.status != target, ticket.category != .done else { return }
        let error = await perform(.jira) {
            try await service.transitionTicket(key: ticket.key, to: target)
        } patch: {
            expect(TicketEdit(status: target), on: ticket.key)
        }
        if let error {
            sessionErrors[ticket.key] = "Session started, but Jira refused the move to \(target): \(error)"
            Self.log.error("plan \(ticket.key, privacy: .public): \(error, privacy: .public)")
        }
    }

    func open(_ url: String?) {
        guard let url, let parsed = URL(string: url) else { return }
        NSWorkspace.shared.open(parsed)
    }

    /// One write of yours: the write, then `patch` to show what it did at once, then, whether it worked or not, a refresh of
    /// `source` to confirm it. The refresh is queued behind one already running, and corrected by `applyLanded` or
    /// `applyTicketEdits` until the source agrees; it runs on a failure too, which can come after the write landed. Why the
    /// write failed, or nil: each caller words that and keeps it where its view looks.
    private func perform(_ source: Source, write: () async throws -> Void, patch: () -> Void = {}) async -> String? {
        var failure: String?
        do {
            try await write()
            patch()
        } catch {
            failure = "\(error)"
        }
        state.recompute()
        Task { await refresh(source) }
        return failure
    }

    /// Renames your PR on GitHub and shows the new title at once rather than on the next poll. Why it failed, or nil.
    func retitle(_ pr: PullRequest, to title: String) async -> String? {
        let error = await perform(.github) { try await service.retitle(pr, to: title) } patch: {
            if let index = state.github?.mine.firstIndex(where: { $0.url == pr.url }) { state.github?.mine[index].title = title }
        }
        return error.map { "Couldn't rename it: \($0)" }
    }

    /// Rewrites your PR's description on GitHub and shows it at once, the next poll confirming it. Why it failed, or nil.
    func editDescription(_ pr: PullRequest, body: String) async -> String? {
        let error = await perform(.github) { try await service.editDescription(pr, body: body) } patch: {
            if let index = state.github?.mine.firstIndex(where: { $0.url == pr.url }) { state.github?.mine[index].body = body }
        }
        return error.map { "Couldn't save it: \($0)" }
    }

    /// Squash-merges a PR from its page, and shows it merged at once. Why it failed, or nil. A press while another write
    /// to the PR runs does nothing, so a merge never goes out twice. GitHub refuses it if the head moved past the commit
    /// the page showed.
    func squashMerge(_ pr: PullRequest) async -> String? {
        guard busyFlows.insert(pr.url).inserted else { return nil }
        defer { busyFlows.remove(pr.url) }
        let error = await perform(.github) { try await service.squashMerge(pr) } patch: { land(pr, as: .merged) }
        return error.map { "Couldn't merge it: \($0)" }
    }

    /// Saves an edit to a ticket's summary or description and shows it at once, until Jira agrees. Why it failed, or nil.
    func editTicket(_ ticket: Ticket, summary: String? = nil, description: String? = nil) async -> String? {
        await perform(.jira) {
            try await service.editTicket(key: ticket.key, summary: summary, description: description)
        } patch: {
            expect(TicketEdit(summary: summary, description: description), on: ticket.key)
        }
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
    }

    /// Lays what this app merged, closed or marked ready over GitHub's answer until its search says the same; after ten
    /// minutes it long has.
    private func applyLanded() {
        let now = Date()
        landed = landed.filter { now.timeIntervalSince($0.value.at) < 600 }
        readied = readied.filter { now.timeIntervalSince($0.value) < 600 }
        state.apply(landed: landed.values.map(\.pr), readied: Set(readied.keys))
    }

    /// Closes a PR from its page without merging it. Why it failed, or nil.
    func close(_ pr: PullRequest) async -> String? {
        let error = await perform(.github) { try await service.close(pr) } patch: { land(pr, as: .closed) }
        return error.map { "Couldn't close it: \($0)" }
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
        if let error = await perform(.github, write: action) { return "\(failure): \(error)" }
        await loadConversation(pr)
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
        // A checkout the user already has on that branch is the session's home; nothing else touches git. A fork's branch
        // is never one of yours, whatever its name: it gets its PR head, detached.
        let existing = pr.isCrossRepository ? nil : state.worktrees.first { $0.repoName == pr.repoName && $0.branch == pr.headRef }?.path
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
        do {
            try DeskService.installShowHelper()
        } catch {
            sessionErrors[pr.url] = "Can't start the review session: couldn't write \(DeskService.showHelper.path): \(error)"
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

    /// A review session's `fhenixdesk://show/…`: that PR's diff, at that line. A PR Desk does not know is ignored —
    /// any app can open the link, so it only ever moves the diff. Whether it was a PR Desk knows.
    func open(_ url: URL) -> Bool {
        guard let link = DeskLink(url) else { return false }
        guard let pr = state.pullRequest(for: link) else {
            Self.log.info("link for an unknown PR: \(url.absoluteString, privacy: .public)")
            return false
        }
        reviewing = pr.url
        loadDiff(pr)
        diffJump = DiffJump(url: pr.url, path: link.path, side: link.side, line: link.line)
        showingSettings = false
        pendingTab = .reviews
        selectPullRequest = pr.url
        return true
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
            flowErrors[pr.url] = await perform(.github) {
                try await service.markReady(pr)
                // Ready from here on, even if asking the team below fails.
                readied[pr.url] = Date()
                applyLanded()
                try await service.requestTeamReview(pr)
            }
        }
    }

    /// Fix it on a PR that conflicts with its base or whose CI failed: its session gets the fix. Nothing goes out on its
    /// own: a fix that did not take is pressed again or left, as you choose.
    func fix(_ prompt: PromptID, for pr: PullRequest) {
        guard sendBlocker(pr) == nil else { return }
        send(prompt, for: pr)
    }

    /// Sends the PR's session one flow instruction; the session going to work is what moves the stage. Not `perform`: the
    /// press stays busy until the git scan has read the session at work, or a second press could stop it mid-turn.
    private func send(_ prompt: PromptID, for pr: PullRequest) {
        guard let session = state.session(for: pr), busyFlows.insert(pr.url).inserted else { return }
        flowErrors[pr.url] = nil
        let root = state.localRepo(for: pr)?.root ?? session.cwd
        // A fork's branch name may be one of this clone's own (its `master`), so a fork's worktree is found by its path.
        let worktree = pr.isCrossRepository
            ? state.worktrees.first { $0.path == BranchWorktrees.worktreePath(for: pr, repoRoot: root) }?.path
            : state.worktrees.first { $0.repoRoot == root && $0.branch == pr.headRef }?.path
        // Numbered by when it went out, so an earlier instruction's file is never this one's.
        let resultFile = ClaudeJobs.resultFile(jobId: session.id, step: Int(Date().timeIntervalSince1970))
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
        return session.sessionId.flatMap { ClaudeJobs.resumeDirectory(sessionId: $0, candidates: candidates) } ?? root
    }

}
