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
    /// PR urls with a review running from this side, for spinners and disabled buttons.
    var busyReviews: Set<String> = []
    /// Ticket keys with a transition in flight, so a poll that lands mid-move does not start another.
    var movingTickets: Set<String> = []
    /// Why Jira refused the last move of a ticket, by key; cleared by a move that works or a dismissal.
    var ticketMoveErrors: [String: String] = [:]
    /// Ticket keys with a planning session starting, for the button that must not fire twice.
    var planningTickets: Set<String> = []
    /// PR urls with a background session being started, for the same reason.
    var startingSessions: Set<String> = []
    /// A finished review's findings waiting for the PR's session, by PR url: the session was working or waiting on you
    /// when the review landed, and an instruction never cuts in. Sent once a scan finds it idle. In memory only: a quit
    /// before then drops it, and the review itself stays in your draft on GitHub.
    private(set) var reviewHandoffs: [String: String] = [:]
    /// Why a waiting hand-off could not go out, by PR url: no session would start, or the session refused it. It waits
    /// for Try again on the review page rather than retrying every poll.
    var handoffErrors: [String: String] = [:]
    private var sendingHandoffs: Set<String> = []
    /// Your PRs this app merged or closed, by url, as they now stand and when. GitHub's search lags a write by up to a
    /// minute or so, and until it agrees each refresh is corrected by these, so a PR's page and the lists show how it
    /// ended at once instead of on some later poll.
    private var landed: [String: (pr: PullRequest, at: Date)] = [:]
    /// Your PRs with a flow instruction going out or a GitHub write in flight, by url.
    var busyFlows: Set<String> = []
    /// Why the last press on a PR's flow failed, by url, until the next press. Like the stage, nothing of it is saved.
    var flowErrors: [String: String] = [:]
    /// What you want done with each open thread on your PRs, by thread id: typed on the PR page, sent with Apply. In
    /// memory only; a note goes once Apply has sent it, or once its thread is resolved.
    var threadNotes: [String: String] = [:]
    /// Set to have the Pull Requests or Reviews screen open this PR's page; the screen clears it. Search, Up Next
    /// and a notification's Show use it.
    var selectPullRequest: String?
    /// Set to have the Jira screen select this ticket, by key, in its details panel; the screen clears it. Search uses it.
    var selectTicket: String?
    /// Why the session button last failed, per PR url or ticket key. It is the button's own tooltip: a press that
    /// does nothing is the one thing this must not be.
    var sessionErrors: [String: String] = [:]
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
        await mergeReviews()
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
                // A note on a thread that has since been resolved has nothing left to ask for.
                let open = Set(snapshot.mine.flatMap(\.threads).map(\.id))
                threadNotes = threadNotes.filter { open.contains($0.key) }
                await service.cleanupClosedReviews(
                    github: snapshot, reviewWorktrees: state.reviewWorktrees, repos: state.gitScan?.repos ?? []
                )
            case .git:
                let scan = await service.refreshGit()
                state.gitScan = scan
                state.claudeJobs = await service.claudeJobs()
                state.claudeLimits = await service.claudeLimits()
                state.reviewSkills = await service.reviewSkills(repos: scan.repos)
                state.errors[.git] = scan.errors.isEmpty ? nil : scan.errors.joined(separator: "\n")
                for error in scan.errors { Self.log.error("git: \(error, privacy: .public)") }
            case .jira:
                guard await service.jiraReady else {
                    state.errors[.jira] = nil
                    state.lastRefresh[.jira] = Date()
                    return
                }
                state.tickets = try await service.refreshJira(referencedKeys: state.referencedTicketKeys)
            }
            if source != .git { state.errors[source] = nil }
            state.lastRefresh[source] = Date()
        } catch {
            state.errors[source] = "\(error)"
            Self.log.error("\(source.title, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        await mergeReviews()
        state.recompute()
        deliverReviewHandoffs()
        notifier.deliver(state.nudges, post: config.notificationsEnabled && allSourcesReported)
    }

    private func mergeReviews() async {
        state.reviewRuns = await service.reviewRuns()
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

    /// Re-reads acli's sign-in state, for after the user has logged in from a terminal.
    func refreshJiraAccount() {
        Task {
            jiraAccount = await service.jiraAccount()
            await refresh(.jira)
        }
    }

    // MARK: Claude reviews

    /// Reviews one PR and posts what it found as your draft review on it. Always from a press.
    func review(_ pr: PullRequest) {
        guard let gitScan = state.gitScan else {
            state.reviewError = "Repos are still being scanned; try again in a moment."
            return
        }
        run(pr, gitScan: gitScan)
    }

    /// True when another review may start. `Shell` runs 8 processes at once and the git scan wants 6 of
    /// them, so a fifth review would stall every other source for minutes.
    var canStartReview: Bool { busyReviews.count < max(1, config.reviewConcurrency) }

    /// Whether the Review button for this PR may be pressed now: a local clone to run in, nothing already
    /// running on it, and a free slot.
    func canReview(_ pr: PullRequest) -> Bool { reviewBlocker(pr) == nil }

    /// Why Review is dead for this PR, in the words its button shows beside it; nil when it may be pressed.
    func reviewBlocker(_ pr: PullRequest) -> String? {
        if state.localRepo(for: pr) == nil { return "No local clone" }
        if busyReviews.contains(pr.url) || state.reviewRun(for: pr)?.phase.isBusy == true { return "Reviewing" }
        if !canStartReview { return "\(busyReviews.count) reviews running" }
        return nil
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

    /// Why Approve is dead on a draft; nil when it may be pressed.
    func approveBlocker(_ pr: PullRequest) -> String? {
        if let blocker = sendBlocker(pr) { return blocker }
        if state.reviewSkill(for: pr)?.isReady != true { return "Review skill missing" }
        return nil
    }

    private func run(_ pr: PullRequest, gitScan: GitScan) {
        guard !busyReviews.contains(pr.url), canStartReview else { return }
        busyReviews.insert(pr.url)
        Task {
            defer { busyReviews.remove(pr.url) }
            let run = await service.review(pr: pr, gitScan: gitScan)
            await mergeReviews()
            state.recompute()
            // The draft is on GitHub now, and the row reads it from there.
            await refresh(.github)
            if run.phase == .posted { handOff(run, of: pr) }
        }
    }

    /// Gives a review's findings to the PR's session to talk through: at once if it is idle, once it is if it is busy,
    /// and in a new session when the PR has none. The review itself stays the locked-down run that wrote the draft.
    private func handOff(_ run: ReviewRun, of pr: PullRequest) {
        guard !run.findings.isEmpty || !run.summary.isEmpty else { return }
        handoffErrors[pr.url] = nil
        reviewHandoffs[pr.url] = DeskService.reviewHandoffPrompt(for: pr, run: run, config: config)
        deliverReviewHandoffs()
    }

    /// Sends a hand-off that failed once more, on your press.
    func retryHandoff(_ pr: PullRequest) {
        handoffErrors[pr.url] = nil
        deliverReviewHandoffs()
    }

    /// Sends each waiting hand-off whose session is idle, by the flow's rule: never while it works or asks you
    /// something. A session with no id recorded yet cannot be resumed, so it waits too. Runs after every refresh.
    private func deliverReviewHandoffs() {
        // Not before GitHub has answered: until then every PR would look closed, and every hand-off would be dropped.
        guard let github = state.github else { return }
        for (url, text) in reviewHandoffs where !sendingHandoffs.contains(url) && handoffErrors[url] == nil {
            guard let pr = github.allOpen.first(where: { $0.url == url }) else {
                reviewHandoffs[url] = nil  // Closed or merged: nothing left to talk through.
                continue
            }
            guard let job = state.claudeJobs(for: pr).first else {
                // No session on the PR, or its session went while the review waited: a new one opens with the
                // findings, and the hand-off is done once it has started.
                guard state.localRepo(for: pr) != nil else {
                    handoffErrors[url] = "No local clone of \(pr.repo) to start a session in"
                    continue
                }
                startSession(for: pr, opening: text)
                continue
            }
            guard job.sessionId != nil, job.isIdle else { continue }
            let cwd = resumeDirectory(job, for: pr)
            sendingHandoffs.insert(url)
            Task {
                defer { sendingHandoffs.remove(url) }
                do {
                    try await service.send(text, to: job, cwd: cwd)
                    reviewHandoffs[url] = nil
                } catch {
                    handoffErrors[url] = "Couldn't hand the review to the session: \(error)"
                    Self.log.error("review hand-off: \(String(describing: error), privacy: .public)")
                }
                await refresh(.git)
            }
        }
    }

    /// The PR's Files tab, where a pending review's comments are read, edited and submitted.
    func openDraft(_ pr: PullRequest) { open("\(pr.url)/files") }

    /// Deletes the PR's review worktree when it is clean. The review on GitHub stays.
    func removeReviewWorktree(_ pr: PullRequest) {
        guard let gitScan = state.gitScan else { return }
        Task {
            do {
                try await service.removeReviewWorktree(for: pr, gitScan: gitScan)
            } catch {
                state.reviewError = "\(error)"
            }
            await mergeReviews()
            state.recompute()
            Task { await refresh(.git) }
        }
    }

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

    /// Takes what this app merged or closed out of the open lists, and puts a merge into the merged one, until GitHub's
    /// search says the same; after ten minutes it long has.
    private func applyLanded() {
        let now = Date()
        landed = landed.filter { now.timeIntervalSince($0.value.at) < 600 }
        guard var github = state.github, !landed.isEmpty else { return }
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

    func draftComments(for pr: PullRequest) async throws -> [DraftReviewComment] { try await service.draftComments(for: pr) }

    /// Opens the window on the screen a PR lives on, its row selected — your own in Pull Requests, one in the queue in
    /// Reviews — and GitHub for one on no screen here. A finished review's url points at its Files tab; the PR is the
    /// part before it.
    func show(_ url: String) {
        let pr = url.hasSuffix("/files") ? String(url.dropLast("/files".count)) : url
        if state.mine.contains(where: { $0.url == pr }) {
            pendingTab = .pullRequests
        } else if state.reviewQueue(.all).contains(where: { $0.url == pr }) {
            pendingTab = .reviews
        } else {
            open(url)
            return
        }
        selectPullRequest = pr
        AppDelegate.openDesk?()
    }

    func reveal(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    // MARK: Background sessions

    /// Starts a background Claude session on the PR's branch. The button that calls this is the one shown
    /// when no session mentions the PR yet; the row flips to Attach as soon as this one lands.
    /// `opening` goes after the usual brief: a review's findings, for one started to talk them through.
    func startSession(for pr: PullRequest, opening: String? = nil) {
        guard let repo = state.localRepo(for: pr), !startingSessions.contains(pr.url) else { return }
        startingSessions.insert(pr.url)
        // A checkout the user already has on that branch is the session's home; nothing else touches git.
        let existing = state.worktrees.first { $0.repoName == pr.repoName && $0.branch == pr.headRef }?.path
        Task {
            defer { startingSessions.remove(pr.url) }
            do {
                let job = try await service.startClaudeSession(pr: pr, repoRoot: repo.root, worktree: existing, opening: opening)
                // Held until the next scan reads the same session off disk. On your own PR it puts the PR in the flow.
                state.claudeJobs.insert(job, at: 0)
                sessionErrors[pr.url] = nil
                // Opened with a review's findings: that hand-off is done.
                if opening != nil, reviewHandoffs[pr.url] == opening { reviewHandoffs[pr.url] = nil }
                if existing == nil { Task { await refresh(.git) } }
            } catch {
                if opening != nil, reviewHandoffs[pr.url] == opening {
                    handoffErrors[pr.url] = "Couldn't start a session for the review: \(error)"
                } else {
                    sessionErrors[pr.url] = "\(error)"
                }
                Self.log.error("session: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Opens a background Claude session in Terminal. A background session is a daemon rather than a
    /// shell, so `claude attach` is the only way into one — and it works whether it is still running or
    /// has already finished.
    func attach(_ job: ClaudeJob, for pr: PullRequest) { attach(jobId: job.id, errorKey: pr.url) }

    /// `errorKey` is the PR url or ticket key whose button pressed it, which is where a failure is shown.
    func attach(jobId: String, errorKey: String) {
        let claude = config.resolvedClaudePath ?? "claude"
        let script = """
            tell application "Terminal"
                activate
                do script "'\(claude)' attach \(jobId)"
            end tell
            """
        Task {
            // Driving Terminal needs the user's permission the first time, and a refusal is a button
            // that does nothing: it has to be said out loud.
            if let error = await Self.osascript(script) {
                sessionErrors[errorKey] = "Could not open Terminal: \(error)"
                Self.log.error("attach \(jobId, privacy: .public): \(error, privacy: .public)")
            } else {
                sessionErrors[errorKey] = nil
            }
        }
    }

    // MARK: Flows

    /// Approve on a draft: its session gets the self-review.
    func approveDraft(_ pr: PullRequest) {
        guard approveBlocker(pr) == nil else { return }
        send(.selfReview, for: pr)
    }

    /// Approve on the self-review's fixes: the PR leaves draft and the review team is asked. Shown ready at once: the
    /// search lags the write, and the stage would offer Approve again until it caught up.
    func approveFixes(_ pr: PullRequest) {
        guard busyFlows.insert(pr.url).inserted else { return }
        flowErrors[pr.url] = nil
        Task {
            defer { busyFlows.remove(pr.url) }
            do {
                try await service.markReady(pr)
                if let index = state.github?.mine.firstIndex(where: { $0.url == pr.url }) { state.github?.mine[index].isDraft = false }
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

    /// The open threads of this PR you wrote a note on.
    func notedThreads(_ pr: PullRequest) -> [ReviewThread] {
        pr.threads.filter { !(threadNotes[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Apply under a PR's threads: one instruction to its session with every thread you wrote a note on. The session does
    /// the work and the replies on GitHub; the app never writes to a thread. The notes go once it is sent.
    func applyThreadNotes(_ pr: PullRequest) {
        let noted = notedThreads(pr)
        guard !noted.isEmpty, sendBlocker(pr) == nil else { return }
        send(.threadNotes, for: pr, threads: noted)
    }

    /// Sends the PR's session one flow instruction; the session going to work is what moves the stage. `threads` are the
    /// noted ones Apply sends, whose notes go once it is out.
    private func send(_ prompt: PromptID, for pr: PullRequest, threads: [ReviewThread] = []) {
        guard let session = state.session(for: pr), busyFlows.insert(pr.url).inserted else { return }
        flowErrors[pr.url] = nil
        let root = state.localRepo(for: pr)?.root ?? session.cwd
        let worktree = state.worktrees.first { $0.repoRoot == root && $0.branch == pr.headRef }?.path
        // Numbered by when it went out, so an earlier instruction's file is never this one's.
        let resultFile = DeskService.resultFile(jobId: session.id, step: Int(Date().timeIntervalSince1970))
        let text = DeskService.flowPrompt(
            prompt, pr: pr, worktree: worktree, resultFile: resultFile, threads: DeskService.threadList(threads, notes: threadNotes),
            config: config
        )
        let cwd = resumeDirectory(session, for: pr)
        Task {
            defer { busyFlows.remove(pr.url) }
            do {
                try await service.send(text, to: session, cwd: cwd)
                for thread in threads { threadNotes[thread.id] = nil }
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

    /// Runs one AppleScript, returning what went wrong or nil.
    private nonisolated static func osascript(_ script: String) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errors = Pipe()
            process.standardError = errors
            do {
                try process.run()
                let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                guard process.terminationStatus != 0 else { return nil }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return "\(error)"
            }
        }.value
    }

}
