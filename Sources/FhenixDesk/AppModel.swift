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
    /// The PR whose review workspace fills the Reviews tab; nil shows the queue. It lives here rather than
    /// in the tab's own state so it survives a tab switch, so a nudge can open one, and so cleanup can drop
    /// the user out of a workspace whose record has just been removed.
    var openReviewURL: String?
    /// Set to ask the window to switch tabs; `DeskWindow` clears it. The menu bar and the nudges use it
    /// to land on the screen they mean.
    var pendingTab: DeskWindow.Tab?
    /// PR urls with a review starting or submitting from this side, for spinners and disabled buttons.
    var busyReviews: Set<String> = []
    /// Ticket keys with a transition in flight, for the button that must not fire twice.
    var movingTickets: Set<String> = []
    /// Ticket keys with a planning session starting, for the same reason.
    var planningTickets: Set<String> = []
    /// PR urls with a background session being started, for the same reason.
    var startingSessions: Set<String> = []
    /// Why the session button last failed, per PR url or ticket key. It is the button's own tooltip: a press that
    /// does nothing is the one thing this must not be.
    var sessionErrors: [String: String] = [:]
    /// What reviews have cost in the last 24 hours. Shown because every run is now a deliberate spend.
    var reviewSpendToday: Double = 0
    /// Records with a write in flight. A refresh must not overwrite these with the copy it read before
    /// the write landed — that is what makes an approved comment flip back to pending for one poll.
    private var pendingReviewWrites: Set<String> = []

    /// Browser-style zoom for the Desk window, remembered across launches. Not in `DeskConfig`: it is a
    /// comfort setting for this screen, not something the doctor or a provider should ever read.
    var textScale: Double = UserDefaults.standard.object(forKey: AppModel.textScaleKey) as? Double ?? 1 {
        didSet { UserDefaults.standard.set(textScale, forKey: AppModel.textScaleKey) }
    }
    private static let textScaleKey = "textScale"
    static let textScaleRange = 0.8...2.0

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
                await service.cleanupClosedReviews(github: snapshot)
            case .git:
                let scan = await service.refreshGit()
                state.gitScan = scan
                state.claudeJobs = await service.claudeJobs()
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
        notifier.deliver(state.nudges, post: config.notificationsEnabled && allSourcesReported)
        onUrgentCountChange?(urgentCount)
        if source == .github { refreshReviewAnchors() }
    }

    /// A record with a write in flight keeps the local copy: the snapshot just read from the actor was
    /// taken before that write landed, and assigning it wholesale would revert the user's click.
    private func mergeReviews() async {
        var fresh = await service.reviews()
        for url in pendingReviewWrites {
            if let local = state.reviews[url] { fresh[url] = local }
        }
        state.reviews = fresh
        reviewSpendToday = await service.reviewSpendToday()
        if let url = openReviewURL, state.reviews[url] == nil { openReviewURL = nil }
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

    /// Re-points the comments of any PR whose head moved. The only review work that happens on its own:
    /// it spends no tokens, and it is what keeps "outdated" honest between runs. Running a review is
    /// always a deliberate press.
    private func refreshReviewAnchors() {
        Task {
            let stale = await service.reviewsWithStaleAnchors(queue: state.reviewRequests, login: state.login)
            guard !stale.isEmpty else { return }
            for pr in stale { await service.refreshReviewAnchors(pr: pr) }
            await mergeReviews()
            state.recompute()
        }
    }

    /// Reviews one PR. Always from a press: the Review button, or Review again inside the workspace.
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

    private func run(_ pr: PullRequest, gitScan: GitScan) {
        guard !busyReviews.contains(pr.url), canStartReview else { return }
        busyReviews.insert(pr.url)
        Task {
            defer { busyReviews.remove(pr.url) }
            await service.review(pr: pr, gitScan: gitScan)
            await mergeReviews()
            state.recompute()
        }
    }

    func openWorkspace(_ prUrl: String) { openReviewURL = prUrl }

    /// Opens a review in the Desk window, from the menu bar or a notification.
    func openInWindow(_ prUrl: String) {
        openReviewURL = prUrl
        pendingTab = .reviews
    }

    func closeWorkspace() { openReviewURL = nil }

    /// The parsed diff for a review, loaded on demand: it is megabytes and would be copied on every poll
    /// if it lived in `state`.
    func diff(for record: ReviewRecord) async throws -> PullRequestDiff {
        try await service.reviewDiff(record)
    }

    // MARK: The user's decisions
    //
    // Each one writes locally first so the UI never lags a click, then takes the actor's record as
    // authoritative. Field-granular on purpose: a whole-record write would race a run rewriting the same
    // record's comments.

    func setComment(_ id: UUID, in prUrl: String, state newState: CommentState) {
        apply(prUrl) { $0.update(id) { $0.state = newState } } remote: {
            await self.service.setReviewCommentState(prUrl: prUrl, commentId: id, state: newState)
        }
    }

    func editComment(_ id: UUID, in prUrl: String, body: String, approve: Bool) {
        apply(prUrl) { record in
            record.update(id) { comment in
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                comment.editedBody = trimmed.isEmpty || trimmed == comment.body ? nil : trimmed
                if approve { comment.state = .approved }
            }
        } remote: {
            let updated = await self.service.setReviewCommentBody(prUrl: prUrl, commentId: id, body: body)
            guard approve else { return updated }
            return await self.service.setReviewCommentState(prUrl: prUrl, commentId: id, state: .approved)
        }
    }

    func setVerdict(_ verdict: ReviewVerdict, in prUrl: String) {
        apply(prUrl) { $0.chosenVerdict = verdict } remote: {
            await self.service.setReviewVerdict(prUrl: prUrl, verdict: verdict)
        }
    }

    func setSummary(_ summary: String, in prUrl: String) {
        apply(prUrl) { $0.summary = summary } remote: {
            await self.service.setReviewSummary(prUrl: prUrl, summary: summary)
        }
    }

    private func apply(
        _ prUrl: String, _ local: (inout ReviewRecord) -> Void, remote: @escaping () async -> ReviewRecord?
    ) {
        guard var record = state.reviews[prUrl] else { return }
        local(&record)
        state.reviews[prUrl] = record
        pendingReviewWrites.insert(prUrl)
        Task {
            defer { pendingReviewWrites.remove(prUrl) }
            if let updated = await remote() { state.reviews[prUrl] = updated }
            state.recompute()
        }
    }

    /// Posts the review. The only call in the app that writes to GitHub.
    func submitReview(_ prUrl: String) {
        guard !busyReviews.contains(prUrl) else { return }
        busyReviews.insert(prUrl)
        Task {
            defer { busyReviews.remove(prUrl) }
            do {
                state.reviews[prUrl] = try await service.submitReview(prUrl: prUrl)
                state.errors[.github] = nil
                // The PR's review decision has changed, so the snapshot is stale.
                await refresh(.github)
            } catch {
                state.errors[.github] = "\(error)"
                await mergeReviews()
            }
            state.recompute()
        }
    }

    func removeReview(_ record: ReviewRecord) {
        Task {
            do {
                try await service.removeReview(record)
            } catch {
                state.reviewError = "\(error)"
            }
            if openReviewURL == record.prUrl { openReviewURL = nil }
            await mergeReviews()
            state.recompute()
            Task { await refresh(.git) }
        }
    }

    // MARK: Jira

    /// Moves a ticket to where its pull requests say it belongs. A press, never a poll — and the refresh
    /// afterwards is what makes the row right: Jira decides what the status became, not this.
    func moveTicket(_ drift: TicketDrift) {
        let key = drift.ticket.key
        guard !movingTickets.contains(key) else { return }
        movingTickets.insert(key)
        Task {
            defer { movingTickets.remove(key) }
            do {
                try await service.transitionTicket(key: key, to: drift.target)
                state.errors[.jira] = nil
            } catch {
                state.errors[.jira] = "\(error)"
                Self.log.error("jira \(key, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            await refresh(.jira)
        }
    }

    /// One press of the − or + button. Clamped, so the buttons disable themselves at either end rather
    /// than letting the window zoom into uselessness.
    func zoomText(_ steps: Int) {
        let range = Self.textScaleRange
        textScale = min(max((textScale + Double(steps) * 0.1).rounded(toPlaces: 2), range.lowerBound), range.upperBound)
    }

    var canZoomText: (smaller: Bool, larger: Bool) {
        (textScale > Self.textScaleRange.lowerBound, textScale < Self.textScaleRange.upperBound)
    }

    /// Starts a background Claude session to plan a ticket, then moves the ticket to in progress so a
    /// later glance says somebody is already on it. The session is tied to nothing: press again and you
    /// get another, which is the point — it is the pull request it ends in that the app follows.
    ///
    /// The ticket only moves once the session is running. A press that started nothing must not leave
    /// Jira claiming work is underway.
    func planTicket(_ ticket: Ticket, in repo: RepoRef) {
        let key = ticket.key
        guard !planningTickets.contains(key) else { return }
        planningTickets.insert(key)
        Task {
            defer { planningTickets.remove(key) }
            do {
                _ = try await service.startTicketSession(ticket: ticket, repoRoot: repo.root)
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
    func attach(_ job: ClaudeJob, for pr: PullRequest) {
        let claude = config.resolvedClaudePath ?? "claude"
        let script = """
            tell application "Terminal"
                activate
                do script "'\(claude)' attach \(job.id)"
            end tell
            """
        Task {
            // Driving Terminal needs the user's permission the first time, and a refusal is a button
            // that does nothing: it has to be said out loud.
            if let error = await Self.osascript(script) {
                sessionErrors[pr.url] = "Could not open Terminal: \(error)"
                Self.log.error("attach \(job.id, privacy: .public): \(error, privacy: .public)")
            } else {
                sessionErrors[pr.url] = nil
            }
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

private extension Double {
    /// Keeps the stored scale free of the drift ten additions of 0.1 would otherwise leave behind, which
    /// is what would stop the clamp comparisons landing exactly on the ends.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
