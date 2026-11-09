import DeskCore
import SwiftUI

/// The landing screen: what waits on you, your PRs and the reviews alike, under the section that says what to do —
/// ready to merge, your move, drafts to submit, to review — then the Jira moves the app suggests, the sprint's tickets nothing has
/// started, and your PRs that wait on someone else. The rows are the Pull Requests, Reviews and Jira screens' own; a
/// click, Return or → opens the PR's or the ticket's page here, and its back link, or ←, returns here. The reviews
/// follow the Reviews screen's filters.
struct UpNextTab: View {
    @Environment(AppModel.self) private var model
    /// A PR's url, or a ticket's key: one to start, or one with a suggested move.
    @State private var selection: String?
    /// The pages open over the list; empty shows the list.
    @State private var path: [Route] = []
    @FocusState private var listFocused: Bool
    /// The ticket and repository a plan has been asked for, while the note is still being written.
    @State private var planning: PlanRequest?
    @State private var planNote = ""
    /// With Reduce Motion on, the list jumps to the selected row instead of sliding there.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var filters = ReviewFilters()

    var body: some View {
        let plan = model.state.upNext(reviewDays: filters.window, hiding: filters.hidden, needingApproval: filters.needsApproval)
        let tickets = model.state.ticketsToStart
        let drifts = model.state.ticketDrifts
        // In the order the sections show, so the first row selected is the top one.
        let early = plan.filter { $0.section != .waiting }.flatMap(\.pullRequests).map(\.url)
        let waiting = plan.filter { $0.section == .waiting }.flatMap(\.pullRequests).map(\.url)
        let rows = early + drifts.map(\.id) + tickets.map(\.key) + waiting
        NavigationStack(path: $path) {
            list(plan: plan, tickets: tickets, drifts: drifts)
                .navigationDestination(for: Route.self) { RoutePage(route: $0, back: "Up Next", path: $path, plan: startPlan) }
        }
        .focusedSceneValue(\.routePath, $path)
        .selectsFirstRow(rows.first, selection: $selection)
        .sheet(item: $planning) { request in
            PlanSheet(request: request, model: model, note: $planNote) { planning = nil }
        }
    }

    @ViewBuilder private func list(plan: [UpNextGroup], tickets: [Ticket], drifts: [TicketDrift]) -> some View {
        // Starting something new comes after what is already under way, and before what waits on others.
        let early = plan.filter { $0.section != .waiting }
        let waiting = plan.first { $0.section == .waiting }
        let titles = early.map(\.section.title) + (drifts.isEmpty ? [] : [Self.jira]) + (tickets.isEmpty ? [] : [Self.start])
            + [waiting?.section.title].compactMap { $0 }
        // The sources that have neither answered nor failed yet: until GitHub has, an empty list means nothing.
        let pending = Source.allCases.filter { model.state.lastRefresh[$0] == nil && model.state.errors[$0] == nil }
        Screen {
            PageHeader(title: "Up Next") {}
        } content: {
            if pending.contains(.github) || (titles.isEmpty && !pending.isEmpty) { syncing(pending) }
            ForEach(Source.allCases, id: \.self) { source in
                if source == .github, model.state.github == nil, let error = model.state.errors[.github] {
                    // Nothing from GitHub has ever loaded, so this is no stale list: say what is missing.
                    EmptyState(
                        icon: "exclamationmark.triangle", text: "GitHub didn't answer, so Up Next can't say which PRs wait on you.",
                        detail: error, actionTitle: "Retry", action: { Task { await model.refresh(.github) } }
                    )
                    .padding(Theme.Space.m)
                    .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.vertical, Theme.Space.m)
                } else {
                    StaleBanner(source: source)
                }
            }
            if pending.contains(.github) {
                placeholders
            } else if titles.isEmpty, pending.isEmpty, model.state.errors.isEmpty {
                // Says how fresh "nothing" is, and where to go next, rather than one grey line.
                EmptyState(
                    icon: "checkmark.circle",
                    text: "All clear. \(Source.names(Source.allCases)) all synced \(Format.ago(model.state.lastRefresh.values.min())).",
                    actionTitle: "Browse the review queue", action: { model.pendingTab = .reviews }
                )
                .padding(.vertical, 20)
            }
            ScrollViewReader { proxy in
                // Arrow keys walk the rows; a click, Return or → opens the PR's or the ticket's page.
                List(selection: $selection) {
                    ForEach(early) { group in pullRequests(group, first: titles.first) }
                    if !drifts.isEmpty {
                        header(Self.jira, drifts.count, first: titles.first)
                        ForEach(drifts) { drift in
                            ListRow(selected: selection == drift.id, open: { open(drift.id) }) { MoveRow(drift: drift, model: model) }
                        }
                    }
                    if !tickets.isEmpty {
                        header(Self.start, tickets.count, first: titles.first)
                        ForEach(tickets) { ticket in
                            ListRow(selected: selection == ticket.key, open: { open(ticket.key) }) {
                                TicketRow(ticket: ticket, model: model)
                            }
                        }
                    }
                    if let waiting { pullRequests(waiting, first: titles.first) }
                }
                .deskList()
                // Focused on arrival and on the way back from a page, so the keys work without a click first.
                .focused($listFocused)
                .task(id: path.isEmpty) { if path.isEmpty { listFocused = true } }
                .onKeyPress(.rightArrow) {
                    guard let selection else { return .ignored }
                    open(selection)
                    return .handled
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let ticket = model.state.ticket(id) {
                        Button("Open in Jira") { model.open(ticket.url) }
                        Button("Copy Key") { Clipboard.copy(ticket.key) }
                    } else if let id = ids.first, let pr = model.state.github?.allOpen.first(where: { $0.url == id }) {
                        PullRequestMenu(pr: pr, model: model)
                    }
                } primaryAction: { ids in
                    if let id = ids.first { open(id) }
                }
                .onChange(of: selection, initial: true) { _, id in
                    if let id { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    /// "Reading GitHub and Jira… Git answered.": which sources Up Next still waits on, over the rows that stand in for
    /// theirs.
    private func syncing(_ pending: [Source]) -> some View {
        let answered = Source.allCases.filter { model.state.lastRefresh[$0] != nil }
        return HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.mini)
            Text("Reading \(Source.names(pending))…" + (answered.isEmpty ? "" : " \(Source.names(answered)) answered."))
        }
        .scaled(.secondary)
        .foregroundStyle(.secondary)
        .padding(.vertical, Theme.Space.m)
    }

    /// Grey bars where the first rows will be, so the screen reads as loading rather than empty.
    private var placeholders: some View {
        VStack(spacing: 0) {
            ForEach([CGFloat(360), 280, 320], id: \.self) { width in
                HStack(spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().frame(width: width, height: 10)
                        Capsule().frame(width: width - 90, height: 8).opacity(0.7)
                    }
                    Spacer()
                    Capsule().frame(width: 90, height: 10)
                }
                .foregroundStyle(Theme.raised)
                .padding(Theme.Space.m)
                .overlay(alignment: .bottom) { Hairline() }
            }
        }
        .accessibilityHidden(true)
    }

    private static let start = "Ready to start"
    private static let jira = "Jira moves"

    /// A section's heading, with room above it to set it off from the one before.
    private func header(_ title: String, _ count: Int, first: String?) -> some View {
        GroupHeader(title: title, count: count)
            .padding(.top, title == first ? 0 : Theme.Space.l)
            .plainListRow()
            .selectionDisabled()
    }

    /// A section of PRs, each row as its own screen draws it: a review as the review queue's, yours as Pull Requests'.
    @ViewBuilder private func pullRequests(_ group: UpNextGroup, first: String?) -> some View {
        header(group.section.title, group.pullRequests.count, first: first)
        ForEach(group.pullRequests, id: \.url) { pr in
            if group.section == .toReview || group.section == .draftsToSubmit {
                ListRow(selected: selection == pr.url, open: { open(pr.url) }) {
                    QueueRow(pr: pr, model: model, onMe: onMe(pr))
                }
            } else {
                PullRequestRow(row: StackedPullRequest(pullRequest: pr), model: model, selected: selection == pr.url) {
                    open(pr.url)
                }
            }
        }
    }

    /// Its page, with its row selected behind it for the way back. A PR's url, or a ticket's key.
    private func open(_ id: String) {
        selection = id
        path.append(model.state.ticket(id) == nil ? .pr(id) : .ticket(id))
    }

    /// Picking a repository from Start in… opens the sheet that asks what the plan is for.
    private func startPlan(_ ticket: Ticket, _ repo: RepoRef) {
        planNote = ""
        planning = PlanRequest(ticket: ticket, repo: repo)
    }

    /// GitHub put it on you, as opposed to its being open for anyone to review.
    private func onMe(_ pr: PullRequest) -> Bool { model.state.reviewRequests.contains { $0.url == pr.url } }
}
