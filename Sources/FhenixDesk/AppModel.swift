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
    /// The app's text at this multiple of the boards' sizes, as wide as the window's screen calls for
    /// (`ScreenTextScale`): the window sets it, and every view reads it through `\.textScale`, or here, inside a `Text`.
    var textScale: CGFloat = 1

    /// The Jira projects you can see, for Settings' and Setup's project menu: empty until read, or when the read failed.
    var jiraProjects: [String] = []
    /// A project's statuses as Jira lists them, with the key they were read for: Settings and Setup pick the three moves
    /// from them. The key being read now, and why the last read failed.
    var jiraStatuses: (key: String, statuses: [JiraStatus])?
    var readingJiraStatuses: String?
    var jiraStatusesError: String?

    func loadJiraProjects() {
        Task { if let keys = try? await service.jiraProjectKeys() { jiraProjects = keys.sorted() } }
    }

    /// Reads a project's statuses, unless they were read for it already. A search per status: some seconds.
    func loadJiraStatuses(for key: String, force: Bool = false) async {
        guard !key.isEmpty, force || jiraStatuses?.key != key, readingJiraStatuses != key else { return }
        readingJiraStatuses = key
        defer { if readingJiraStatuses == key { readingJiraStatuses = nil } }
        do {
            jiraStatuses = (key, try await service.jiraStatuses(project: key))
            jiraStatusesError = nil
        } catch {
            jiraStatusesError = "Couldn't read \(key)'s statuses: \(error)"
        }
    }
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
    /// True while the window shows the Master screen: the iTerm layout, the master's questions, what Desk told it.
    var showingMaster = false

    func showMasterScreen() {
        showingSettings = false
        showingMaster = true
    }
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
    /// What Settings is editing, kept here so leaving Settings and coming back keeps what you had typed.
    let settings = SettingsDraft()
    /// Ticket keys with a transition in flight, so a poll that lands mid-move does not start another.
    var movingTickets: Set<String> = []
    /// Why Jira refused the last move of a ticket, by key; cleared by a move that works or a dismissal.
    var ticketMoveErrors: [String: String] = [:]
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
    /// Your PRs with a GitHub write in flight, a merge or a change to draft or ready, by url.
    var busyFlows: Set<String> = []
    /// Why the last press on a PR's flow failed, by url, until the next press. Like the stage, nothing of it is saved.
    var flowErrors: [String: String] = [:]
    /// Set to have the Pull Requests or Reviews screen open this PR's page; the screen clears it. Search, Focus
    /// and a notification's Show use it.
    var selectPullRequest: String?
    /// Set to have the Jira screen select this ticket, by key, in its details panel; the screen clears it. Search uses it.
    var selectTicket: String?
    /// Why the session button last failed, per PR url or ticket key. It is the button's own tooltip: a press that
    /// does nothing is the one thing this must not be.
    var sessionErrors: [String: String] = [:]
    /// The keys of the panes the `desk` tmux layout has, as of the last sync: which sessions show there, and which review
    /// sessions run.
    var panes: Set<String> = []
    /// Why the last Show in iTerm failed, in a sentence; nil once one works.
    var terminalError: String?
    /// A sync of the `desk` layout under way, so the next waits for it.
    private var syncingTerminals = false
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
    /// Where the master session runs, and the files Desk writes for it.
    var masterFolder: MasterFolder { MasterFolder(support: support) }
    /// The last `graph.json` written, so an unchanged one is not written again every 15 seconds.
    private var writtenGraph: TaskGraph?
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
        try? masterFolder.trimEvents()
        writeMasterSettings()
        applyAppearance()
        Task { await self.start() }
        Notifier.onShow = { [weak self] url in
            guard url == Notifier.focusURL else {
                self?.show(url)
                return
            }
            self?.pendingTab = .focus
            AppDelegate.openDesk?()
        }
        // Settings is where the sentence shows.
        self.configError = configError
        showingSettings = configError != nil
    }

    var config: DeskConfig {
        get { state.config }
        set { state.config = newValue }
    }

    /// The Focus page's items, inside the Reviews screen's filters, which its reviews follow.
    func focus(_ filters: ReviewFilters) -> [FocusItem] {
        state.focus(reviewDays: filters.window, hiding: filters.hidden, needingApproval: filters.needsApproval)
    }

    /// What Focus has at Now and Next: its badge, and the menu bar's count.
    func focusCount(_ filters: ReviewFilters) -> Int {
        state.focusCount(reviewDays: filters.window, hiding: filters.hidden, needingApproval: filters.needsApproval)
            + (reviewLearning?.needsYou == true ? 1 : 0)
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
                    // With the window closed, covered or on another desktop, nothing shows what the local scan reads,
                    // and it is a hundred-odd git processes a time: it waits for the window, or two minutes, which
                    // keeps the sessions a notification goes by fresh. A look every few seconds sees the window back.
                    let slept = ContinuousClock.now
                    while source == .git, !Self.deskVisible, ContinuousClock.now - slept < .seconds(120), !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                    }
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

    /// Whether any of the Desk window can be seen.
    private static var deskVisible: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue == DeskWindow.id && $0.occlusionState.contains(.visible) }
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
                state.claudeJobs = await service.claudeJobs(keepIn: scan.repos.map(\.root))
                state.asks = masterFolder.asks()
                readReviewLearning()
                state.focusRanking = masterFolder.focusRanking(keeping: state.focusRanking)
                state.claudeLimits = await service.claudeLimits()
                state.workflowSkill = await service.reviewSkill()
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
        // A new ranking from the master: remember what it ranked, so only what changes after it is lifted. Only once
        // every source has answered: remembered while one had only failed, everything it brings later would look new.
        if Source.allCases.allSatisfy({ state.lastRefresh[$0] != nil }), state.focusRanking?.rankedAt != focusSeenAt {
            focusSeenAt = state.focusRanking?.rankedAt
            state.focusSeen = state.focusRanking == nil ? nil : state.focusKinds()
        }
        let posted = notifier.deliver(state.nudges, post: config.notificationsEnabled && allSourcesReported)
        writeMasterFiles(posted: posted)
        if allSourcesReported, case .due(let lastFinished, _) = reviewLearning {
            notifier.deliverReviewLearningDue(lastFinished: lastFinished, post: config.notificationsEnabled)
        }
        // The sessions were just scanned: the iTerm layout follows them. Only once every source answered, so the tasks'
        // workers are known, and never before you opened the layout.
        if source == .git, allSourcesReported { await syncTerminals() }
    }

    /// The `rankedAt` of the ranking `state.focusSeen` was remembered for.
    private var focusSeenAt: Date?

    private var allSourcesReported: Bool {
        Source.allCases.allSatisfy { state.lastRefresh[$0] != nil || state.errors[$0] != nil }
    }

    /// `graph.json` once every source has answered, so the master never routes by half a graph, and again whenever the
    /// tasks change; and each nudge just posted as a line of `events.jsonl`, while events are on.
    private func writeMasterFiles(posted: [Nudge]) {
        guard allSourcesReported else { return }
        let graph = state.taskGraph()
        if graph.tasks != writtenGraph?.tasks || graph.prs != writtenGraph?.prs {
            do {
                try masterFolder.write(graph)
                writtenGraph = graph
            } catch {
                Self.log.error("graph.json: \(String(describing: error), privacy: .public)")
            }
        }
        guard config.sendEvents, !posted.isEmpty else { return }
        do {
            try masterFolder.append(state.masterEvents(for: posted))
        } catch {
            Self.log.error("events.jsonl: \(String(describing: error), privacy: .public)")
        }
    }

    /// The master folder's `.claude/settings.json`, with the folders the master can see.
    private func writeMasterSettings() {
        do {
            try masterFolder.writeSettings(additionalDirectories: config.masterFolderList)
        } catch {
            Self.log.error("master settings: \(String(describing: error), privacy: .public)")
        }
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

    /// Light, Dark or the system's, for every window, menu and popover, and the accent. The accent is read when a colour
    /// draws, so the window is rebuilt on its change (`DeskWindow` keys its content by it).
    func applyAppearance() {
        Theme.accentHex = config.accent
        NSApplication.shared.appearance = switch config.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Writes the config when it changed and hands it to the sources, which a recheck after a sign-in wants either way.
    func saveConfig() {
        applyAppearance()
        do {
            if config != savedConfig {
                try support.save(config, to: DeskService.configFile)
                if config.masterFolderList != savedConfig.masterFolderList { writeMasterSettings() }
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

    /// Merges a PR from its page the way you picked, and shows it merged at once. Why it failed, or nil. A press while
    /// another write to the PR runs does nothing, so a merge never goes out twice. GitHub refuses it if the head moved past
    /// the commit the page showed.
    func merge(_ pr: PullRequest, method: MergeMethod) async -> String? {
        guard busyFlows.insert(pr.url).inserted else { return nil }
        defer { busyFlows.remove(pr.url) }
        let error = await perform(.github) { try await service.merge(pr, method: method) } patch: { land(pr, as: .merged) }
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

    /// Turns a ready PR of yours back into a draft, shown as one at once. Why it failed, or nil.
    func convertToDraft(_ pr: PullRequest) async -> String? {
        let error = await perform(.github) { try await service.convertToDraft(pr) } patch: {
            readied[pr.url] = nil
            if let index = state.github?.mine.firstIndex(where: { $0.url == pr.url }) { state.github?.mine[index].isDraft = true }
        }
        return error.map { "Couldn't make it a draft: \($0)" }
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

    // MARK: Review learning

    /// Where the weekly review learning pass stands, read with every scan of the sessions; nil until the first, since a
    /// started run looks abandoned before Desk knows which sessions are there.
    var reviewLearning: ReviewLearning.Status?
    /// Why the pass last failed to start, until it starts.
    var reviewLearningError: String?
    private(set) var startingReviewLearning = false

    /// A session that failed never started the pass; any other, at work or idle, is still there.
    private var reviewLearningSessions: [ClaudeJob] { state.claudeJobs.filter { $0.role == .learning && $0.state != "failed" } }

    private func readReviewLearning() {
        reviewLearning = ReviewLearning.status(
            runs: ReviewLearningFolder(support: support).runs(), live: Set(reviewLearningSessions.map(\.id))
        )
    }

    /// Starts a run of the pass in the repo's clone and shows its session in iTerm. While a run is started and not
    /// finished this is Start again: its session is stopped and removed first, for one that hangs or was stopped by
    /// hand and still reads as there.
    func startReviewLearning() {
        guard !startingReviewLearning else { return }
        // ponytail: the clone comes from the tracked repositories' scan; a search of every repo root when someone runs
        // the pass without tracking the repo.
        let clone = state.gitScan?.repos.first { GitParsing.repoSlug(fromRemote: $0.remote) == ReviewLearning.repo.lowercased() }
        guard let clone else {
            reviewLearningError = DeskError.noClone(ReviewLearning.repo).description
            return
        }
        startingReviewLearning = true
        reviewLearningError = nil
        Task {
            defer { startingReviewLearning = false }
            do {
                if case .running(_, let id) = reviewLearning, let old = reviewLearningSessions.first(where: { $0.id == id }) {
                    try await service.removeReviewLearning(old)
                    state.claudeJobs.removeAll { $0.id == id }
                }
                let session = try await service.startReviewLearning(in: clone.root)
                // Held until the next scan reads it off disk, as Start master's is.
                state.claudeJobs.insert(session, at: 0)
                readReviewLearning()
                show(jobId: session.id)
            } catch {
                reviewLearningError = "Couldn't start the review learning pass: \(error)"
                Self.log.error("review learning: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The running pass's session in front, in iTerm.
    func openReviewLearning() {
        if case .running(_, let id) = reviewLearning { show(jobId: id) }
    }

    /// The last finished run's report, in whatever opens Markdown.
    func openReviewLearningReport() {
        if case .upToDate(_, _, let report) = reviewLearning { NSWorkspace.shared.open(report) }
    }

    // MARK: Master

    /// Why the Master tab last failed to open, until it opens.
    var masterError: String?
    private(set) var startingMaster = false

    /// Where a restart of the master stands, while one runs.
    enum MasterRestart { case waitingForHandoff, restarting }
    private(set) var masterRestart: MasterRestart?
    private var restartTask: Task<Void, Never>?
    /// Restart was pressed, on the Master screen or in Search, and waits for your yes on the Master screen.
    var confirmingMasterRestart = false

    /// The master in a word or two, for the sidebar, the menu bar and Settings: whether one runs, never what it is doing
    /// or what it asked. That is in its pane, and in `claude agents`.
    var masterStatus: String {
        switch masterRestart {
        case .waitingForHandoff: return "Writing its handoff…"
        case .restarting: return "Restarting…"
        case nil: return startingMaster ? "Starting…" : state.master == nil ? "Not running" : "Running"
        }
    }

    /// Shows the master's pane in iTerm. With no master running, it starts one in the master folder first. Closing
    /// iTerm, or the pane, leaves the master running.
    func openMaster() {
        guard config.resolvedClaudePath != nil else {
            masterError = DeskError.claudeNotFound.description
            return
        }
        masterError = nil
        if let master = state.master {
            show(jobId: master.id)
            return
        }
        guard !startingMaster else { return }
        startingMaster = true
        Task {
            defer { startingMaster = false }
            do {
                let master = try await service.startMaster(in: masterFolder.path)
                // Held until the next scan reads it off disk.
                state.claudeJobs.insert(master, at: 0)
                show(jobId: master.id)
            } catch {
                masterError = "\(error)"
                Self.log.error("master: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Whether Stop master and Restart may act on `master`: the service's own check, made first so that a master you
    /// started by hand in another folder is left alone, with the reason on the Master screen.
    private func isDesksMaster(_ master: ClaudeJob) -> Bool {
        if masterFolder.holds(master) { return true }
        masterError = DeskError.notTheMaster(master.name).description
        return false
    }

    /// Stops the master, on your press on the Master screen; its pane closes at the next sync.
    func stopMaster() {
        guard let master = state.master, masterRestart == nil, isDesksMaster(master) else { return }
        Task {
            do {
                try await service.stopMaster(master)
                masterError = nil
                await refresh(.git)
            } catch {
                masterError = "Couldn't stop the master: \(error)"
            }
        }
    }

    /// A new master in place of the one that runs, for when its conversation has grown long. With `handoff`, Desk first
    /// types the request for `handoff.md` into the master's pane, the file its skill writes for the next master, and
    /// waits for it for as long as it takes: only you give up on it, by pressing again without the handoff or by
    /// `cancelRestart`. Then the master is stopped and removed, and a new one started as Start master starts it. The
    /// workers run on throughout.
    func restartMaster(handoff: Bool) {
        // Checked before the handoff is asked for: a master Desk won't stop is not told it is about to be restarted.
        guard let master = state.master, masterRestart != .restarting else { return }
        confirmingMasterRestart = false
        guard isDesksMaster(master) else { return }
        restartTask?.cancel()
        masterError = nil
        restartTask = Task {
            do {
                if handoff {
                    masterRestart = .waitingForHandoff
                    let asked = Date()
                    try await askForHandoff(master)
                    while !masterFolder.handoffWritten(since: asked) { try await Task.sleep(for: .seconds(1)) }
                }
                masterRestart = .restarting
                try await service.stopMaster(master)
                state.claudeJobs.removeAll { $0.id == master.id }
                // Held until the next scan reads it off disk, as Start master's is.
                state.claudeJobs.insert(try await service.startMaster(in: masterFolder.path), at: 0)
                await refresh(.git)
            } catch is CancellationError {
                // Cancelled by a press that started another restart, which owns the state now, or by Cancel.
                return
            } catch {
                masterError = "Couldn't restart the master: \(error)"
                Self.log.error("master restart: \(String(describing: error), privacy: .public)")
            }
            masterRestart = nil
        }
    }

    /// Gives up waiting for the handoff; the master runs on as it was.
    func cancelRestart() {
        guard masterRestart == .waitingForHandoff else { return }
        restartTask?.cancel()
        masterRestart = nil
    }

    /// The master's pane in front, so you see it write, and the request typed into it.
    private func askForHandoff(_ master: ClaudeJob) async throws {
        guard let tmux else { throw DeskError.tmuxNotFound }
        let wasOpen = panes.contains(master.id)
        await showNow(jobId: master.id)
        // A pane just opened is still attaching, and drops what is typed before its prompt is up.
        if !wasOpen { try await Task.sleep(for: .seconds(5)) }
        guard try await tmux.type(MasterFolder.handoffRequest, into: master.id) else {
            throw DeskError.terminal(terminalError ?? "the master's pane isn't open")
        }
    }

    // MARK: Terminals

    /// The `desk` window's two panes: the master on the left, while one runs, and `claude agents` on the right.
    var layoutPanes: [PaneSpec] { TmuxLayout.panes(master: state.master) }

    /// tmux, where it is installed.
    var tmux: Tmux? { Shell.which("tmux").map { Tmux(path: $0) } }

    /// Keeps the `desk` window as it should be, once it exists — Desk makes it only when you ask to see a session.
    func syncTerminals() async {
        guard !syncingTerminals, let tmux, let claude = config.resolvedClaudePath else { return }
        syncingTerminals = true
        defer { syncingTerminals = false }
        guard await tmux.hasSession() else {
            panes = []
            return
        }
        do {
            try await keepLayout(tmux, claude: claude)
        } catch {
            Self.log.error("tmux: \(String(describing: error), privacy: .public)")
        }
        await readPanes(tmux)
    }

    /// The `desk` window's two panes and nothing else of Desk's: `claude agents` opened when it's gone, the master's when
    /// a master runs and its pane is gone, a pane of a master that's gone (restarted under a new id) or of a session put
    /// there before the layout was fixed closed, and the window arranged in two halves when anything changed. A pane Desk
    /// didn't make stays. The windows of sessions you showed are yours to close.
    private func keepLayout(_ tmux: Tmux, claude: String) async throws {
        let window = try await tmux.panes().filter { $0.window == TmuxLayout.window }
        let wanted = Set(layoutPanes.map(\.key))
        var changed = false
        for pane in window where !pane.key.isEmpty && !wanted.contains(pane.key) {
            try? await tmux.close(pane.paneId)
            changed = true
        }
        if !window.contains(where: { $0.key == PaneSpec.agentsKey }) {
            try await tmux.open(.agents, command: TmuxLayout.agentsCommand(claude: claude))
            changed = true
        }
        if let master = state.master, !window.contains(where: { $0.key == master.id }) {
            try await tmux.open(PaneSpec(key: master.id, name: "master", isMaster: true), command: TmuxLayout.attachCommand(claude: claude, id: master.id))
            changed = true
        }
        if changed { try? await tmux.arrange() }
    }

    /// A background session in front: the master in its half of the `desk` window, any other in `claude agents`' place in
    /// the other half.
    func show(jobId: String) { Task { await showNow(jobId: jobId) } }

    /// `show(jobId:)`, waited for: what `--terminals show` runs.
    func showNow(jobId: String) async {
        guard let claude = config.resolvedClaudePath else {
            terminalError = DeskError.claudeNotFound.description
            return
        }
        let job = state.claudeJobs.first { $0.id == jobId }
        // The one master, as Stop master and the layout take it: a second session named master shows like any other.
        let isMaster = jobId == state.master?.id
        let spec = PaneSpec(key: jobId, name: isMaster ? "master" : job?.name ?? jobId, isMaster: isMaster)
        await presentNow(spec, command: TmuxLayout.attachCommand(claude: claude, id: jobId))
    }

    /// Runs AppleScript through `osascript`, off the main thread and with a timeout, so an iTerm that is busy (a dialog
    /// up) can't freeze the window. macOS asks the one-time "control iTerm" consent for Fhenix Desk, which started it. A
    /// refusal says where to give it.
    private func runAppleScript(_ source: String) async throws {
        let result = try await Shell.run("/usr/bin/osascript", ["-e", source], timeout: 30)
        guard result.status != 0 else { return }
        if result.stderr.contains("-1743") {
            throw DeskError.terminal("Desk isn't allowed to control iTerm: allow it in System Settings → Privacy & Security → Automation → Fhenix Desk, then press again.")
        }
        throw DeskError.terminal("iTerm didn't open the window: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// A command run in your terminal app, in a window of its own: Setup's installs and sign-ins.
    func runInTerminal(_ command: String, name: String) {
        Task {
            do {
                let script = try TerminalOpener.writeScript(TerminalOpener.commandScript(command), in: support.directory, name: name)
                try await Shell.output("/usr/bin/open", TerminalOpener.openArguments(app: config.terminalApp, script: script))
                terminalError = nil
            } catch {
                terminalError = "Couldn't open \(config.terminalApp == .iTerm ? "iTerm" : "Terminal"): \(error)"
            }
        }
    }

    /// `spec`'s pane in front, opening it with `command` when it isn't there.
    private func present(_ spec: PaneSpec, command: String) {
        Task { await presentNow(spec, command: command) }
    }

    /// The session made when there is none, the `desk` window brought to its two panes, `spec`'s pane opened when it
    /// isn't there — the master's in that window, any other in a window of its own — and focused, and a terminal attached
    /// when none is, or brought forward.
    private func presentNow(_ spec: PaneSpec, command: String) async {
        do {
            guard let tmux else { throw DeskError.tmuxNotFound }
            guard let claude = config.resolvedClaudePath else { throw DeskError.claudeNotFound }
            if !(await tmux.hasSession()) { try await tmux.create(.agents, command: TmuxLayout.agentsCommand(claude: claude)) }
            try await keepLayout(tmux, claude: claude)
            let current = try await tmux.panes()
            if spec.isMaster || spec.isReview {
                // The master in its half; a review, which runs where it shows, in a window of its own.
                if !current.contains(where: { $0.key == spec.key }) {
                    if spec.isMaster {
                        try await tmux.open(spec, command: command)
                        try? await tmux.arrange()
                    } else {
                        try await tmux.openWindow(spec, command: command)
                    }
                }
                _ = try await tmux.focus(spec.key)
            } else if let agents = current.first(where: { $0.window == TmuxLayout.window && $0.key == PaneSpec.agentsKey }) {
                // Any other session in claude agents' place, until you leave it.
                if agents.showing != spec.key {
                    try await tmux.show(spec.key, in: agents.paneId, command: TmuxLayout.showCommand(claude: claude, tmux: tmux.path, id: spec.key))
                }
                _ = try await tmux.focus(PaneSpec.agentsKey)
            }
            await readPanes(tmux)
            try await bringTerminal(tmux)
            terminalError = nil
        } catch {
            terminalError = "Couldn't show it in \(config.terminalApp == .iTerm ? "iTerm" : "Terminal"): \(error)"
            Self.log.error("terminal: \(String(describing: error), privacy: .public)")
        }
    }

    /// What the layout has, for the screens: its panes' keys.
    private func readPanes(_ tmux: Tmux) async {
        panes = Set(((try? await tmux.panes()) ?? []).map(\.key))
    }

    /// A terminal on the session: attached when none is — iTerm2 through tmux's control mode, its control window set to
    /// hide once it connects, so only the layout shows; Terminal.app through a script — or brought forward.
    private func bringTerminal(_ tmux: Tmux) async throws {
        let attached = await tmux.clients() > 0
        // Set every time, cheap: an iTerm attached before Desk set it hides its control window on its next attach.
        if config.terminalApp == .iTerm { _ = try? await Shell.output("/usr/bin/defaults", TerminalOpener.iTermBuryArguments) }
        if !attached, config.terminalApp == .iTerm {
            try await runAppleScript(TerminalOpener.iTermScript(tmux: tmux.path))
        } else {
            let script = attached ? nil : try TerminalOpener.writeScript(
                TerminalOpener.script(app: config.terminalApp, tmux: tmux.path), in: support.directory)
            try await Shell.output("/usr/bin/open", TerminalOpener.openArguments(app: config.terminalApp, script: script))
        }
    }

    // MARK: Reviews

    /// The window a review session runs in, keyed by its group of PRs, one or several.
    private static func groupTab(_ group: ReviewGroup) -> String { PaneSpec.reviewKey("group:\(group.id)") }

    /// The PRs reviewed together, newest last, each group with its own review session.
    var reviewGroups: [ReviewGroup] = []

    /// The newest group a PR is reviewed in.
    func reviewGroup(for pr: PullRequest) -> ReviewGroup? { reviewGroups.last { $0.contains(pr.url) } }

    /// The pane where this PR's review session runs: its group's.
    private func runningReviewTab(_ pr: PullRequest) -> String? {
        reviewGroup(for: pr).map(Self.groupTab).flatMap { panes.contains($0) ? $0 : nil }
    }

    /// The review session's pane in front.
    func showReview(_ pr: PullRequest) {
        guard let key = runningReviewTab(pr) else { return }
        showPane(key)
    }

    /// A pane already in the layout, in front: a review session's, whose command is its own.
    func showPane(_ key: String) {
        present(PaneSpec(key: key, name: "review"), command: "true")
    }

    /// A review session's own window: it runs there, in its clone, until you quit it.
    private func openReview(key: String, name: String, claude: String, arguments: [String], directory: String) {
        present(PaneSpec(key: key, name: name), command: TmuxLayout.reviewCommand(claude: claude, arguments: arguments, directory: directory))
    }

    func reviewRunning(_ pr: PullRequest) -> Bool { runningReviewTab(pr) != nil }

    /// Whether this PR can be reviewed here, alone or with others and your notes: its clone's sessions have
    /// `review-teammate-task`.
    func canReviewTogether(_ pr: PullRequest) -> Bool { state.reviewSkill(for: pr)?.groupReview == true }

    /// Shows a PR's diff on the Reviews screen: how the review screen moves between the PRs of a group.
    func showInReview(_ pr: PullRequest) {
        reviewing = pr.url
        loadDiff(pr)
        showingSettings = false
        pendingTab = .reviews
        selectPullRequest = pr.url
    }

    /// Review together: one regular Claude session on `review-teammate-task` for every PR picked, from any repos and
    /// authors, told your notes, and the first one's diff beside it. It starts in the first PR's clone with the others'
    /// clones added, on the plugin folder when one is set; the same PRs again open the session already running.
    func startReview(_ picked: [PullRequest], notes: String) {
        let prs = ReviewGroup.ordered(picked, parents: state.stackParents)
        guard let first = prs.first else { return }
        let group = ReviewGroup(pullRequests: prs, notes: notes)
        for pr in prs {
            sessionErrors[pr.url] = nil
            loadDiff(pr)
        }
        reviewGroups.removeAll { $0.id == group.id }
        reviewGroups.append(group)
        showInReview(first)
        let tab = Self.groupTab(group)
        if panes.contains(tab) {
            present(PaneSpec(key: tab, name: "review"), command: "true")
            return
        }
        guard let claude = config.resolvedClaudePath else {
            sessionErrors[first.url] = DeskError.claudeNotFound.description
            return
        }
        guard let repo = state.localRepo(for: first) else {
            sessionErrors[first.url] = "No clone of \(first.repo) here: the review session starts in the repository's checkout."
            return
        }
        // Read again here rather than from the last scan, so a plugin updated a moment ago counts.
        guard ClaudePlugins.reviewSkill(pluginDir: config.pluginDir).groupReview else {
            sessionErrors[first.url] = "A review session needs the \(ClaudePlugins.reviewTeammateTask) skill: fhenix-workflow 1.0, "
                + "or a plugin folder that has it in Settings → Master → Load plugins from."
            return
        }
        var others: [String] = []
        for pr in prs.dropFirst() {
            if let root = state.localRepo(for: pr)?.root, root != repo.root, !others.contains(root) { others.append(root) }
        }
        var tickets: [String] = []
        for pr in prs {
            if let ticket = DeskService.reviewTicket(for: pr, tickets: state.tickets, projectKeys: config.jiraProjectKeys),
               !tickets.contains(ticket) { tickets.append(ticket) }
        }
        openReview(
            key: tab, name: prs.count == 1 ? "review \(first.repoName)#\(first.number)" : "review \(prs.count) PRs", claude: claude,
            arguments: DeskService.groupReviewArguments(group, tickets: tickets, otherClones: others, config: config), directory: repo.root
        )
    }

    /// Start review on a teammate's PR: a review of one on `review-teammate-task`, with its diff on the Reviews screen, or
    /// the session already running for it.
    func startReview(_ pr: PullRequest) {
        sessionErrors[pr.url] = nil
        reviewing = pr.url
        loadDiff(pr)
        if runningReviewTab(pr) != nil {
            showReview(pr)
            return
        }
        startReview([pr], notes: "")
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

    // MARK: Ready and draft

    /// Ready for review on a draft, from the ⋯ menu: as GitHub's own button, shown ready at once. Asking reviewers is the
    /// worker's, on your word through the master.
    func markReady(_ pr: PullRequest) {
        guard busyFlows.insert(pr.url).inserted else { return }
        flowErrors[pr.url] = nil
        Task {
            defer { busyFlows.remove(pr.url) }
            flowErrors[pr.url] = await perform(.github) {
                try await service.markReady(pr)
                readied[pr.url] = Date()
                applyLanded()
            }
        }
    }
}
