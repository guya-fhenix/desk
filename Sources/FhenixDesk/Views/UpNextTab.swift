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
    /// The PR whose page is showing in place of the list; nil shows the list.
    @State private var opened: String?
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
        Group {
            if let key = opened, let ticket = model.state.ticket(key) {
                TicketPage(ticket: ticket, model: model, back: "Up Next", plan: startPlan) { opened = nil }
            } else if let url = opened, let pr = model.yourPullRequest(url) {
                PullRequestPage(pr: pr, model: model, back: "Up Next") { opened = nil }
            } else if let url = opened, let pr = model.state.github?.allOpen.first(where: { $0.url == url }) {
                ReviewPage(pr: pr, model: model, onMe: onMe(pr), back: "Up Next") { opened = nil }
            } else {
                list(plan: plan, tickets: tickets, drifts: drifts)
            }
        }
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
        Screen {
            PageHeader(title: "Up Next") {}
        } content: {
            if titles.isEmpty {
                // Says how fresh "nothing" is, and where to go next, rather than one grey line.
                EmptyState(
                    icon: "checkmark.circle", text: "All clear · synced \(Format.age(model.state.lastRefresh.values.max())) ago",
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
                .onAppear { listFocused = true }
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
        opened = id
    }

    /// Picking a repository from Start in… opens the sheet that asks what the plan is for.
    private func startPlan(_ ticket: Ticket, _ repo: RepoRef) {
        planNote = ""
        planning = PlanRequest(ticket: ticket, repo: repo)
    }

    /// GitHub put it on you, as opposed to its being open for anyone to review.
    private func onMe(_ pr: PullRequest) -> Bool { model.state.reviewRequests.contains { $0.url == pr.url } }
}
