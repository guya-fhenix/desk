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
    var configError: String?
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
    /// What Settings is editing, kept here so leaving Settings and coming back keeps what you had typed.
    let settings = SettingsDraft()
    /// PR urls with a review running from this side, for spinners and disabled buttons.
    var busyReviews: Set<String> = []
    /// Ticket keys with a transition in flight, so a poll that lands mid-move does not start another.
    var movingTickets: Set<String> = []
    /// Why the automatic move of a ticket failed, by key. Nothing retries it, so this is what says so.
    var ticketMoveErrors: [String: String] = [:]
    /// Ticket keys with a planning session starting, for the button that must not fire twice.
    var planningTickets: Set<String> = []
    /// PR urls with a background session being started, for the same reason.
    var startingSessions: Set<String> = []
    /// Flows with an instruction going out or a GitHub write in flight, by job id.
    var busyFlows: Set<String> = []
    /// Set to have the Pull Requests screen select this PR; the screen clears it. Up Next uses it to open a PR's
    /// details panel.
    var selectPullRequest: String?
    /// Why the session button last failed, per PR url or ticket key. It is the button's own tooltip: a press that
    /// does nothing is the one thing this must not be.
    var sessionErrors: [String: String] = [:]
    /// PR urls you ticked on the Pull Requests screen. Your own marks, unrelated to draft or review state: kept in
    /// memory only, and dropped once the PR leaves your open list.
    var checkedPullRequests: Set<String> = []

    private let support = AppSupport()
    private let service: DeskService
    private let notifier: Notifier
    private var loops: [Source: Task<Void, Never>] = [:]
    /// "key→status" for every ticket move tried this launch.
    private var attemptedMoves: Set<String> = []
    private nonisolated static let log = Logger(subsystem: "io.fhenix.desk", category: "refresh")

    init() {
        let config = DeskService.loadConfig(support: support)
        state = DeskState(config: config)
        service = DeskService(config: config, support: support)
        notifier = Notifier(support: support)
        state.flows = Self.loadFlows(support: support)
        Task { await self.start() }
    }

    var config: DeskConfig {
        get { state.config }
        set { state.config = newValue }
    }

    var urgentCount: Int { state.nudges.filter { $0.severity >= .warning }.count }

    /// Set by the menu bar item, which lives outside every SwiftUI scene and so cannot observe the
    /// model the way a view does.
    var onUrgentCountChange: ((Int) -> Void)?

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
                checkedPullRequests.formIntersection(snapshot.mine.map(\.url))
                await service.cleanupClosedReviews(
                    github: snapshot, reviewWorktrees: state.reviewWorktrees, repos: state.gitScan?.repos ?? []
                )
            case .git:
                let scan = await service.refreshGit()
                state.gitScan = scan
                state.claudeJobs = await service.claudeJobs(keeping: Set(state.flows.map(\.jobId)))
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
        advanceFlows()
        syncTickets()
        notifier.deliver(state.nudges, post: config.notificationsEnabled && allSourcesReported)
        onUrgentCountChange?(urgentCount)
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
        } catch {
            configError = "\(error)"
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
    func canReview(_ pr: PullRequest) -> Bool {
        guard state.localRepo(for: pr) != nil, !busyReviews.contains(pr.url) else { return false }
        guard state.reviewRun(for: pr)?.phase.isBusy != true else { return false }
        return canStartReview
    }

    private func run(_ pr: PullRequest, gitScan: GitScan) {
        guard !busyReviews.contains(pr.url), canStartReview else { return }
        busyReviews.insert(pr.url)
        Task {
            defer { busyReviews.remove(pr.url) }
            await service.review(pr: pr, gitScan: gitScan)
            await mergeReviews()
            state.recompute()
            // The draft is on GitHub now, and the row reads it from there.
            await refresh(.github)
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

    /// Moves every ticket that has fallen behind its pull requests to where they say it belongs. Not before
    /// every source has answered once: a half-loaded state is no basis for a write. The refresh after each
    /// move is what makes the board right: Jira decides what the status became, not this.
    /// ponytail: one try per ticket and target per launch, so a transition the workflow refuses is not
    /// re-sent every poll and a ticket you move back by hand stays put; a timed retry would need a backoff
    /// per ticket.
    private func syncTickets() {
        guard allSourcesReported else { return }
        for drift in state.ticketDrifts
        where !movingTickets.contains(drift.ticket.key) && attemptedMoves.insert("\(drift.ticket.key)→\(drift.target)").inserted {
            moveTicket(drift)
        }
    }

    private func moveTicket(_ drift: TicketDrift) {
        let key = drift.ticket.key
        movingTickets.insert(key)
        Task {
            defer { movingTickets.remove(key) }
            do {
                try await service.transitionTicket(key: key, to: drift.target)
                ticketMoveErrors[key] = nil
                Self.log.info("jira \(key, privacy: .public) moved to \(drift.target, privacy: .public)")
            } catch {
                ticketMoveErrors[key] = "\(error)"
                Self.log.error("jira \(key, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            await refresh(.jira)
        }
    }

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
                state.flows.append(Flow(jobId: id, ticketKey: key, repoRoot: repo.root, startedAt: Date()))
                saveFlows()
                // Held until the next scan reads the same session off disk.
                state.claudeJobs.insert(
                    ClaudeJob(id: id, name: key, state: "working", cwd: repo.root, prKeys: [], updatedAt: Date()), at: 0
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

    func reveal(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    // MARK: Background sessions

    /// Starts a background Claude session on the PR's branch. The button that calls this is the one shown
    /// when no session mentions the PR yet; the row flips to Attach as soon as this one lands.
    func startSession(for pr: PullRequest) {
        guard let repo = state.localRepo(for: pr), !startingSessions.contains(pr.url) else { return }
        startingSessions.insert(pr.url)
        // A checkout the user already has on that branch is the session's home; nothing else touches git.
        let existing = state.worktrees.first { $0.repoName == pr.repoName && $0.branch == pr.headRef }?.path
        Task {
            defer { startingSessions.remove(pr.url) }
            do {
                let job = try await service.startClaudeSession(pr: pr, repoRoot: repo.root, worktree: existing)
                // Held until the next scan reads the same session off disk.
                state.claudeJobs.insert(job, at: 0)
                // Only your own PRs have a flow; a session on a teammate's, from Reviews, is just a session.
                if state.mine.contains(where: { $0.url == pr.url }) { joinFlow(job, pr) }
                sessionErrors[pr.url] = nil
                if existing == nil { Task { await refresh(.git) } }
            } catch {
                sessionErrors[pr.url] = "\(error)"
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

    /// Moves every flow along on what the last polls said, saves only when something moved, then sends what the
    /// moves queued. Not before GitHub has answered: without it no PR can be found, and a merge cannot be told
    /// from a poll that failed.
    private func advanceFlows() {
        guard let github = state.github else { return }
        var effects: [(Flow, FlowEffect)] = []
        let moved = state.flows.map { flow in
            let input = FlowInput(
                job: state.job(id: flow.jobId), mine: github.mine, merged: github.mergedRecent, ticketKeys: state.ticketKeys,
                result: flow.awaiting == nil ? nil : DeskService.result(jobId: flow.jobId, step: flow.step),
                login: github.login, bots: config.botLoginSet
            )
            let (next, queued) = FlowEngine.advance(flow, input)
            effects += queued.map { (next, $0) }
            return next
        }
        let live = Self.prune(moved, github: github, jobs: state.claudeJobs, scanned: state.gitScan != nil)
        if live != state.flows {
            state.flows = live
            saveFlows()
        }
        for (flow, effect) in effects { perform(effect, for: flow) }
    }

    /// A flow ends with its PR: it is kept while GitHub still lists the PR, open or merged, so the ticket shows how
    /// it ended, and dropped once the PR is closed or has aged out of the merged list. A session that never opened
    /// a PR is kept until the session itself is deleted — and for its first hour whatever the scan says, which may
    /// not have read a session that has only just started.
    private static func prune(_ flows: [Flow], github: GitHubSnapshot, jobs: [ClaudeJob], scanned: Bool, now: Date = Date()) -> [Flow] {
        let known = Set((github.mine + github.mergedRecent).map(\.url))
        let sessions = Set(jobs.map(\.id))
        return flows.filter { flow in
            if let url = flow.prURL { return known.contains(url) }
            return !scanned || sessions.contains(flow.jobId) || now.timeIntervalSince(flow.startedAt) < 3_600
        }
    }

    private func perform(_ effect: FlowEffect, for flow: Flow) {
        switch effect {
        case .send(let prompt): send(prompt, for: flow)
        case .requestTeam: requestTeam(flow)
        }
    }

    /// Fixes went in and the PR is still not approved: the review team is asked again.
    private func requestTeam(_ flow: Flow) {
        guard let pr = state.pullRequest(of: flow) else { return }
        Task {
            do {
                try await service.requestTeamReview(pr)
            } catch {
                updateFlow(flow.id) { $0.note = "Could not ask \(config.reviewTeam) again: \(error)" }
            }
        }
    }

    /// Sends the instruction the engine just marked as gone out. A send that fails pauses the flow with the reason
    /// and puts the instruction back in the queue: retrying on every poll could keep stopping the session.
    private func send(_ prompt: FlowPrompt, for flow: Flow) {
        guard let job = state.job(id: flow.jobId), let pr = state.pullRequest(of: flow) else {
            requeue(prompt, flow, because: "The session or the PR is gone, so nothing was sent.")
            return
        }
        let worktrees = state.worktrees.filter { $0.repoRoot == flow.repoRoot }
        let branchWorktree = worktrees.first { $0.branch == pr.headRef }?.path
        let text = DeskService.flowPrompt(
            prompt, pr: pr, worktree: branchWorktree, resultFile: DeskService.resultFile(jobId: flow.jobId, step: flow.step),
            fixes: FlowEngine.approvedFixes(flow.proposals), config: config
        )
        let candidates = worktrees.map(\.path) + [job.cwd, flow.repoRoot].filter { !$0.isEmpty }
        let cwd = job.sessionId.flatMap { DeskService.resumeDirectory(sessionId: $0, candidates: candidates) } ?? flow.repoRoot
        busyFlows.insert(flow.id)
        Task {
            defer { busyFlows.remove(flow.id) }
            do {
                try await service.send(text, to: job, cwd: cwd)
                Self.log.info("flow \(flow.id, privacy: .public): sent \(prompt.rawValue, privacy: .public)")
            } catch {
                requeue(prompt, flow, because: "Could not send \(prompt.title.lowercased()): \(error)")
                Self.log.error("flow \(flow.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            await refresh(.git)
        }
    }

    private func requeue(_ prompt: FlowPrompt, _ flow: Flow, because reason: String) {
        updateFlow(flow.id) {
            $0.awaiting = nil
            $0.pending = prompt
            $0.paused = true
            $0.note = reason
        }
    }

    /// Approve on a draft: queues the self-review, which goes out as soon as the session is free.
    func approveDraft(_ flow: Flow) {
        guard let pr = state.pullRequest(of: flow), state.reviewSkill(for: pr)?.isReady == true else { return }
        updateFlow(flow.id) {
            // Not over a fix already queued or running: it would be dropped, and its PR head never tried again.
            guard $0.stage == .draft, $0.pending == nil, $0.awaiting == nil else { return }
            $0.stage = .selfReview
            // ponytail: the head as of the last poll; a push since then shows up in View changes too.
            $0.baseSha = pr.headSha
            $0.pending = .selfReview
            $0.note = nil
        }
        advanceFlows()
    }

    /// Approve on the self-review's fixes: the PR leaves draft and the review team is asked.
    func approveFixes(_ flow: Flow) {
        guard flow.stage == .fixesToCheck, let pr = state.pullRequest(of: flow), !busyFlows.contains(flow.id) else { return }
        busyFlows.insert(flow.id)
        Task {
            defer { busyFlows.remove(flow.id) }
            do {
                try await service.markReady(pr)
                try await service.requestTeamReview(pr)
                updateFlow(flow.id) {
                    $0.stage = .inReview
                    $0.reviewsSince = Date()
                    $0.note = nil
                }
            } catch {
                updateFlow(flow.id) { $0.note = "\(error)" }
            }
            await refresh(.github)
        }
    }

    func setPaused(_ flow: Flow, _ paused: Bool) {
        updateFlow(flow.id) {
            $0.paused = paused
            if !paused { $0.note = nil }
        }
        advanceFlows()
    }

    /// The session went quiet without writing its result: send the same instruction again…
    func resendAwaited(_ flow: Flow) {
        updateFlow(flow.id) {
            guard let awaiting = $0.awaiting else { return }
            $0.awaiting = nil
            $0.pending = awaiting
        }
        advanceFlows()
    }

    /// …or go on as if it had written nothing.
    func skipAwaited(_ flow: Flow) {
        let pr = state.pullRequest(of: flow)
        var effects: [FlowEffect] = []
        updateFlow(flow.id) {
            guard let awaiting = $0.awaiting else { return }
            effects = FlowEngine.finish(&$0, awaiting, result: nil, pr: pr)
        }
        for effect in effects { perform(effect, for: flow) }
        advanceFlows()
    }

    /// Merge on an approved PR: always a squash. The merge itself moves the flow to Merged, on the next poll.
    func merge(_ flow: Flow) {
        guard flow.stage == .approved, let pr = state.pullRequest(of: flow), !busyFlows.contains(flow.id) else { return }
        busyFlows.insert(flow.id)
        Task {
            defer { busyFlows.remove(flow.id) }
            do {
                try await service.squashMerge(pr)
                updateFlow(flow.id) { $0.note = nil }
            } catch {
                updateFlow(flow.id) { $0.note = "Could not merge: \(error)" }
            }
            await refresh(.github)
        }
    }

    /// Your call on one proposed fix: apply it or skip it.
    func decide(_ flow: Flow, proposal index: Int, apply: Bool) {
        updateFlow(flow.id) { if $0.proposals.indices.contains(index) { $0.proposals[index].apply = apply } }
    }

    /// Whether the fix's thread is resolved once it is in.
    func setResolve(_ flow: Flow, proposal index: Int, _ resolve: Bool) {
        updateFlow(flow.id) { if $0.proposals.indices.contains(index) { $0.proposals[index].resolve = resolve } }
    }

    /// Sends the fixes you approved to the session. Skipping all of them changes nothing, so the PR goes back to
    /// waiting for review without asking anyone again.
    func applyProposals(_ flow: Flow) {
        updateFlow(flow.id) {
            guard $0.stage == .fixesProposed, !$0.proposals.contains(where: { $0.apply == nil }) else { return }
            if $0.proposals.contains(where: { $0.apply == true }) {
                $0.stage = .applying
                $0.pending = .applyFixes
            } else {
                $0.stage = .inReview
                $0.proposals = []
            }
            $0.note = nil
        }
        advanceFlows()
    }

    /// Carries a PR in the flow with a session that works on it, at the stage GitHub says it is in — for a PR you
    /// did not start from a ticket. It replaces a flow the PR already had, whose session is gone.
    func joinFlow(_ job: ClaudeJob, _ pr: PullRequest) {
        guard let repo = state.localRepo(for: pr) else { return }
        state.flows.removeAll { $0.prURL == pr.url }
        state.flows.append(Flow(
            jobId: job.id, ticketKey: state.ticketKeys[pr.url]?.first, repoRoot: repo.root, prURL: pr.url,
            stage: pr.isDraft ? .draft : .inReview, startedAt: Date(), reviewsSince: Date()
        ))
        saveFlows()
    }

    private func updateFlow(_ id: String, _ change: (inout Flow) -> Void) {
        guard let index = state.flows.firstIndex(where: { $0.id == id }) else { return }
        change(&state.flows[index])
        saveFlows()
    }

    private func saveFlows() {
        do {
            try support.save(state.flows, to: DeskService.flowsFile)
        } catch {
            Self.log.error("flows: \(String(describing: error), privacy: .public)")
        }
    }

    /// A file that does not decode is moved aside rather than read as empty, or the next save would overwrite
    /// every stage in it.
    private static func loadFlows(support: AppSupport) -> [Flow] {
        do {
            return try support.load([Flow].self, from: DeskService.flowsFile) ?? []
        } catch {
            log.error("flows.json unreadable, moved aside: \(String(describing: error), privacy: .public)")
            let file = support.url(DeskService.flowsFile)
            try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("bad"))
            return []
        }
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
