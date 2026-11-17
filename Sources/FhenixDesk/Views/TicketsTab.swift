import DeskCore
import SwiftUI

/// Jira tickets as a table: the running sprint or the backlog, one group per status in workflow order, yours unless the
/// assignee filter picks others. Done is left out: the list is about what is still open. Above the groups, the moves the
/// app suggests for your tickets, each waiting for your Move or Dismiss. The selected ticket's details sit in the column
/// on the right; Return, → or a double-click opens its page, and ⌘↩ opens it in Jira, as Search does.
struct TicketsTab: View {
    @Environment(AppModel.self) private var model
    private var filters = TicketFilters()
    /// By key, or a suggested move's `moveKey`, so a poll that replaces every ticket keeps the selection.
    @State private var selection: String?
    /// The pages open over the list; empty shows the list.
    @State private var path: [Route] = []
    @FocusState private var listFocused: Bool
    @State private var search = ""
    /// A row to bring into view: the ticket Search picked, which may sit far down the list.
    @State private var scrollTarget: String?

    var body: some View {
        let groups = filtered(model.state.ticketGroups(filters.placement, assignees: assignees))
        let moves = suggestedMoves
        RouteStack(path: $path, back: "Jira") {
            HStack(spacing: 0) {
                list(groups: groups, moves: moves)
                if let ticket = selection.flatMap(ticket(for:)) {
                    TicketDetails(ticket: ticket, model: model) { open(selection ?? ticket.key) }.id(ticket.key)
                }
            }
            .background(Theme.ground)
        }
        .focusedSceneValue(\.routePath, $path)
        // Search lands here with a ticket: its page, with its row behind it wherever it is — its sprint or backlog, your
        // tickets in the filter, the search box cleared — selected for the way back.
        .onChange(of: model.selectTicket, initial: true) { _, key in
            guard let key, let ticket = model.state.ticket(key) else { return }
            // One Jira places in neither has no row, but its page still shows it.
            if ticket.placement != .unknown { filters.placement = ticket.placement }
            if !assignees.isEmpty, !assignees.contains(.me) { filters.assignees = assignees.union([.me]) }
            search = ""
            selection = key
            scrollTarget = key
            path = [.ticket(key)]
            model.selectTicket = nil
        }
        .selectsFirstRow(moves.first?.moveKey ?? groups.first?.tickets.first?.key, selection: $selection)
        // Other people's backlog is fetched only while the screen shows it: turned on, it is fetched now, not at the next
        // poll.
        .onChange(of: filters.showsTeamBacklog) { _, shows in
            if shows { Task { await model.refresh(.jira) } }
        }
    }

    @ViewBuilder private func list(groups: [TicketGroup], moves: [TicketDrift]) -> some View {
        let rows = moves.map(\.moveKey) + groups.flatMap(\.tickets).map(\.key)
        Screen {
            ScreenTitle(title: "Jira", subtitle: subtitle) { placement }
            filterBar.padding(.top, 18)
            // The columns of `TicketRow`.
            HStack(spacing: 12) {
                Text("Key").scaledFrame(width: 72, alignment: .leading)
                Text("Summary").frame(maxWidth: .infinity, alignment: .leading)
                Text("Status").scaledFrame(width: 108, alignment: .leading)
                Text("Priority").scaledFrame(width: 84, alignment: .leading)
                Text("PRs").scaledFrame(width: 84, alignment: .leading)
            }
                .scaled(.secondary).foregroundStyle(Theme.quiet)
                .padding(EdgeInsets(top: 0, leading: 10, bottom: 6, trailing: 10 + Theme.Space.m))
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                .padding(.top, 18)
                .accessibilityHidden(true)
        } content: {
            if groups.isEmpty && moves.isEmpty {
                emptyState.padding(.vertical, 20)
                Spacer()
            } else {
                StaleBanner(source: .jira)
                // Arrow keys, J and K move the selection; a double-click, Return or → opens the ticket's page.
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        if !moves.isEmpty {
                            HStack {
                                SectionLabel("Suggested moves", count: moves.count)
                                Spacer()
                                Button("Move all") { moves.forEach(model.moveTicket) }
                                    .buttonStyle(.desk(.secondary, .small))
                                    .disabled(moves.allSatisfy { model.movingTickets.contains($0.ticket.key) })
                            }
                            .padding(EdgeInsets(top: 14, leading: 10, bottom: 4, trailing: 10))
                            .plainListRow().selectionDisabled()
                            // Tagged by the move, not the ticket: the ticket has its own row in its status group below.
                            ForEach(moves, id: \.moveKey) { drift in
                                ListRow(selected: selection == drift.moveKey) { MoveRow(drift: drift, model: model, keyWidth: 72) }
                            }
                        }
                        ForEach(groups) { group in
                            SectionLabel(group.status, count: group.tickets.count)
                                .padding(EdgeInsets(top: moves.isEmpty && group.id == groups.first?.id ? 14 : 18, leading: 10, bottom: 4, trailing: 10))
                                .plainListRow().selectionDisabled()
                            ForEach(group.tickets) { ticket in
                                ListRow(selected: selection == ticket.key) {
                                    TicketRow(ticket: ticket, model: model, selected: selection == ticket.key)
                                }
                            }
                        }
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
                    .onKeyPress(keys: ["j", "k"]) { press in
                        guard press.modifiers.isEmpty else { return .ignored }
                        selection = UpNextTab.step(rows, from: selection, by: press.key == "j" ? 1 : -1)
                        return .handled
                    }
                    // ⌘↩ goes out to Jira, as it does in Search; the list's primary action never sees it.
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command), let ticket = selection.flatMap(ticket(for:)) else { return .ignored }
                        model.open(ticket.url)
                        return .handled
                    }
                    .contextMenu(forSelectionType: String.self) { keys in
                        if let ticket = keys.first.flatMap(ticket(for:)) {
                            Button("Open in Jira") { model.open(ticket.url) }
                            Button("Copy Link") { Clipboard.copy(ticket.url) }
                            Button("Copy Key") { Clipboard.copy(ticket.key) }
                        }
                    } primaryAction: { keys in
                        if let key = keys.first { open(key) }
                    }
                    .onChange(of: scrollTarget, initial: true) { _, key in
                        guard let key else { return }
                        proxy.scrollTo(key, anchor: .center)
                        scrollTarget = nil
                    }
                }
            }
            KeyHints(
                hints: [(["J", "K"], "move"), (["↩"], "open task"), (["⌘↩"], "open in Jira")],
                trailing: "Tickets are created in Jira; Desk moves one only when you press Move."
            )
        }
    }

    /// "fhenix.atlassian.net · project PRO": where the tickets come from.
    private var subtitle: String {
        let keys = model.config.jiraProjectKeys
        let project = keys.isEmpty ? nil : "\(keys.count == 1 ? "project" : "projects") \(keys.joined(separator: ", "))"
        return [model.jiraAccount?.site, project].compactMap { $0 }.joined(separator: " · ")
    }

    /// The sprint/backlog switch, each side counted over what the search leaves, like the Reviews scopes.
    private var placement: some View {
        Segmented(
            options: [TicketPlacement.sprint, .backlog].map { option in
                let count = filtered(model.state.ticketGroups(option, assignees: assignees)).reduce(0) { $0 + $1.tickets.count }
                return .init(value: option, title: option == .sprint ? "Sprint" : "Backlog", count: count)
            },
            selection: filters.$placement
        )
    }

    private var filterBar: some View {
        HStack(spacing: 20) {
            SearchBox(prompt: "Key or summary", text: $search)
            AssigneeFilter(
                selection: Binding(get: { assignees }, set: { filters.assignees = $0 }),
                me: model.state.ticketSelf,
                people: model.state.ticketAssignees
            )
            Spacer(minLength: 0)
        }
    }

    /// Its page, with its row selected behind it for the way back: a ticket's row, or a suggested move's.
    private func open(_ id: String) {
        guard let ticket = ticket(for: id) else { return }
        selection = id
        path.append(.ticket(ticket.key))
    }

    /// A row's ticket, from its key or, on a suggested move's row, its move.
    private func ticket(for id: String) -> Ticket? {
        model.state.ticket(id) ?? model.state.ticketDrifts.first { $0.moveKey == id }?.ticket
    }

    /// The suggested moves, when the assignee filter takes in your tickets (they are only ever yours), and the search
    /// matches.
    private var suggestedMoves: [TicketDrift] {
        guard assignees.isEmpty || assignees.contains(.me) else { return [] }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.state.ticketDrifts.filter { needle.isEmpty || "\($0.ticket.key) \($0.ticket.summary)".lowercased().contains(needle) }
    }

    private var assignees: Set<TicketAssignee> { filters.assignees }

    private func filtered(_ groups: [TicketGroup]) -> [TicketGroup] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            var group = group
            group.tickets = group.tickets.filter { "\($0.key) \($0.summary)".lowercased().contains(needle) }
            return group.tickets.isEmpty ? nil : group
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !search.isEmpty {
            EmptyState(icon: "magnifyingglass", text: "No ticket matches “\(search)”.", actionTitle: "Clear search", action: { search = "" })
        } else if let error = model.state.errors[.jira] {
            EmptyState(
                icon: "exclamationmark.triangle", text: "Couldn't load your tickets from Jira.", detail: error,
                actionTitle: "Open Settings → Jira", action: { model.openSettings(.jira) }
            )
        } else {
            let place = filters.placement == .backlog ? "the backlog" : "the open sprint"
            EmptyState(
                icon: "checkmark.circle",
                text: assignees == [.me] ? "Nothing of yours in \(place)." : "No tickets in \(place) for this assignee filter."
            )
        }
    }
}

/// The Jira screen's placement and assignee filter. The sidebar badge reads them too, so it counts the tickets the screen
/// opens on.
struct TicketFilters: DynamicProperty {
    /// Remembered, so a trip to another screen does not drop you back on the sprint.
    @AppStorage("tickets.placement") var placement: TicketPlacement = .sprint
    /// The assignee filter's picks, one raw value per line; empty is everyone. Remembered like the placement.
    @AppStorage("tickets.assignees") var storedAssignees = TicketAssignee.me.rawValue

    var assignees: Set<TicketAssignee> {
        get { Set(storedAssignees.split(separator: "\n").compactMap { TicketAssignee(rawValue: String($0)) }) }
        nonmutating set { storedAssignees = newValue.map(\.rawValue).sorted().joined(separator: "\n") }
    }

    /// Whether the screen shows other people's backlog: on Backlog, with anyone besides you in the filter (nothing
    /// picked is everyone). Only then is that backlog fetched — it is most of what a Jira refresh costs.
    var showsTeamBacklog: Bool { Self.showsTeamBacklog(placement: placement, assignees: assignees) }

    /// The same, read where no view is, as the model's refresh is.
    static var showsTeamBacklog: Bool {
        let defaults = UserDefaults.standard
        let placement = defaults.string(forKey: "tickets.placement").flatMap(TicketPlacement.init) ?? .sprint
        let stored = defaults.string(forKey: "tickets.assignees") ?? TicketAssignee.me.rawValue
        return showsTeamBacklog(placement: placement, assignees: Set(stored.split(separator: "\n").compactMap { TicketAssignee(rawValue: String($0)) }))
    }

    private static func showsTeamBacklog(placement: TicketPlacement, assignees: Set<TicketAssignee>) -> Bool {
        placement == .backlog && assignees != [.me]
    }
}

/// One ticket in its status group, in the table's columns: its key in DM Mono, the summary, the status as a chip, the
/// priority with its mark, and how many open PRs name it.
struct TicketRow: View {
    var ticket: Ticket
    var model: AppModel
    var selected = false

    var body: some View {
        let linked = model.state.pullRequests(forTicket: ticket.key).count
        HStack(spacing: 12) {
            Text(ticket.key).scaled(.code).foregroundStyle(Theme.quiet).lineLimit(1).scaledFrame(width: 72, alignment: .leading)
            Text(ticket.summary).scaled(selected ? .body.weight(.semibold) : .body).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(ticket.assignedToMe ? ticket.summary : "\(ticket.summary) · \(ticket.assignee ?? "Unassigned")")
            Text(ticket.status).scaled(.caption.weight(.medium)).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(selected ? Theme.chipOn : Theme.chip, in: RoundedRectangle(cornerRadius: 4))
                .scaledFrame(width: 108, alignment: .leading)
            (ticket.priority.map(PriorityMark.text) ?? Text("–").foregroundStyle(Theme.quiet)).lineLimit(1)
                .scaledFrame(width: 84, alignment: .leading)
            Text(linked > 0 ? "\(linked) open" : "None").scaled(.secondary).foregroundStyle(linked > 0 ? Theme.ink : Theme.quiet)
                .scaledFrame(width: 84, alignment: .leading)
        }
    }
}

/// A priority with Jira's mark before it, as the board draws its standard five: chevrons up in the danger and warn
/// colours for Highest and High, an equals sign for Medium, chevrons down in the accent for Low and Lowest. A name
/// outside those reads bare.
enum PriorityMark {
    static func text(_ name: String) -> Text {
        let mark: (symbol: String, color: Color)?
        switch name.lowercased() {
        case "highest": mark = ("chevron.up.2", Theme.danger)
        case "high": mark = ("chevron.up", Theme.warn)
        case "medium": mark = ("equal", Theme.quiet)
        case "low": mark = ("chevron.down", Theme.accentInk)
        case "lowest": mark = ("chevron.down.2", Theme.accentInk)
        default: mark = nil
        }
        guard let mark else { return Text(name) }
        return Text("\(Text(Image(systemName: mark.symbol)).foregroundStyle(mark.color).bold()) \(name)")
    }
}

/// The selected ticket in full: who opened it, its fields and the task it belongs to, the pull requests and sessions
/// behind it, the move the app suggests with its presses, and the description, editable; at the foot, the ways to its
/// page and to Jira.
private struct TicketDetails: View {
    var ticket: Ticket
    var model: AppModel
    var openPage: () -> Void

    var body: some View {
        DetailColumn(width: 380) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(Text(ticket.key).font(AppTextStyle.code.font(scale: model.textScale))) · Jira\(ticket.reporter.map { " · opened by \($0)" } ?? "")")
                            .scaled(.secondary).foregroundStyle(Theme.quiet)
                        Text(ticket.summary).scaled(.heading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    TicketFields(ticket: ticket, model: model)
                    TicketLinks(ticket: ticket, model: model)
                    if let drift = model.state.drift(forKey: ticket.key) {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Suggested move")
                            MoveSuggestion(drift: drift, model: model)
                        }
                    }
                    TicketDescription(ticket: ticket, model: model)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            HStack(spacing: 8) {
                Button(action: openPage) { HStack(spacing: 8) { Text("Open ticket"); ButtonKey(key: "↩") } }
                    .buttonStyle(.desk(.primary, .large, wide: true))
                    .help("The ticket's page (↩ or →)")
                Button { model.open(ticket.url) } label: {
                    HStack(spacing: 6) { Text("Open in Jira"); Image(systemName: "arrow.up.right.square").scaled(.caption) }
                }
                .buttonStyle(.desk(.secondary, .large))
                .help("⌘↩")
            }
        }
    }
}

/// A ticket's fields as label and value rows: status, priority, assignee, and the task it belongs to with whom it waits on.
private struct TicketFields: View {
    var ticket: Ticket
    var model: AppModel

    var body: some View {
        FieldRows(labelWidth: 96) {
            FieldRow("Status", ticket.status)
            if let priority = ticket.priority { FieldRow(label: "Priority") { PriorityMark.text(priority) } }
            FieldRow("Assignee", ticket.assignedToMe ? "You" : ticket.assignee ?? "Unassigned")
            if let task = model.state.tasks.first(where: { $0.id == ticket.key }) {
                FieldRow("Task", wait(task))
            }
        }
    }

    /// "Waits on you · the master asked 12m ago".
    private func wait(_ task: WorkTask) -> String {
        let asks = model.state.asks.filter { $0.task == task.id }
        let who = switch task.waitingOn(asked: Set(model.state.asks.map(\.task))) {
        case .you: "Waits on you"
        case .worker: "Its worker is at it"
        case .reviewers: "Waits on reviewers"
        case .nobody: "Nothing waiting"
        }
        guard let asked = asks.compactMap(\.askedAt).max() else { return who }
        return "\(who) · the master asked \(Format.age(asked)) ago"
    }
}

/// A ticket's pull requests, each with its checks and where it stands, a click opening it on GitHub; and the sessions
/// started on it, each with Show in iTerm.
private struct TicketLinks: View {
    var ticket: Ticket
    var model: AppModel

    var body: some View {
        let prs = model.state.pullRequests(forTicket: ticket.key)
        let sessions = model.state.sessions(forTicket: ticket.key)
        if !prs.isEmpty {
            RuledList(title: "Pull requests", count: prs.count) {
                ForEach(prs) { pr in
                    Button { model.open(pr.url) } label: {
                        RuledRow {
                            ChecksBadge(pr: pr).frame(width: 16)
                            Text(verbatim: "\(pr.repoName) #\(pr.number)").scaled(.code).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(RowState.of(pr).title) · \(Format.age(pr.updatedAt))").scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).handCursor()
                    .help("\(pr.title) — open on GitHub")
                }
            }
        }
        if !sessions.isEmpty {
            RuledList(title: "Sessions", count: sessions.count) {
                ForEach(sessions) { TicketSessionRow(session: $0, model: model) }
            }
            if let error = model.sessionErrors[ticket.key] {
                Text(error).scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
        }
    }
}

/// One session started on the ticket: its state's mark, its name in DM Mono, its role, its flow's stage and its PR, and
/// Show in iTerm.
private struct TicketSessionRow: View {
    var session: ClaudeJob
    var model: AppModel

    var body: some View {
        let pr = model.state.pullRequest(of: session)
        let stage = model.state.stage(of: session).title.lowercased()
        RuledRow(minHeight: 38) {
            SessionMark(job: session).frame(width: 16)
            Text("\(Text(session.name).font(AppTextStyle.code.font(scale: model.textScale))) \(Text("· \(session.role.rawValue) · \(session.status)\(pr.map { " · \($0.repoName) #\($0.number)" } ?? "") · \(stage)").foregroundStyle(Theme.quiet))")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("\(session.name) · \(session.role.rawValue) · \(session.status)\(session.detail.map { " · \($0)" } ?? "")")
            Button("Show in iTerm") { model.show(jobId: session.id) }.buttonStyle(.desk(.secondary, .small))
        }
    }
}

/// A move the app suggests, as a row of the Jira screen's Suggested moves and Up Next's Jira moves: the ticket's key in
/// DM Mono, its summary, the move and the pull requests behind it, why Jira refused it if it did, and the two presses.
struct MoveRow: View {
    var drift: TicketDrift
    var model: AppModel
    /// The key's column: the Jira table's, or Up Next's wider one.
    var keyWidth: CGFloat

    var body: some View {
        let error = model.ticketMoveErrors[drift.ticket.key]
        HStack(alignment: .center, spacing: 12) {
            Text(drift.ticket.key).scaled(.code).foregroundStyle(Theme.quiet).frame(width: keyWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(drift.ticket.summary)\(Text(" · \(drift.ticket.status) → \(drift.target)").foregroundStyle(Theme.quiet))").lineLimit(1)
                Text(error.map { "Jira refused: \($0)" } ?? "Because \(drift.because)")
                    .scaled(.secondary).foregroundStyle(error == nil ? Theme.quiet : Theme.danger).lineLimit(1).help(error ?? drift.because)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MoveButtons(drift: drift, model: model)
        }
    }
}

/// Dismiss, then Move — Retry once Jira has refused it — or a spinner while it moves. Dismiss is remembered: the
/// suggestion comes back only if the ticket's pull requests point it somewhere else.
struct MoveButtons: View {
    var drift: TicketDrift
    var model: AppModel
    /// The page's and the details column's: the target spelled out, filled.
    var prominent = false

    var body: some View {
        HStack(spacing: 6) {
            if model.movingTickets.contains(drift.ticket.key) {
                ProgressView().controlSize(.small).help("Moving \(drift.ticket.key) to “\(drift.target)”")
            } else {
                Button("Dismiss") { model.dismissMove(drift) }
                    .buttonStyle(.desk(.secondary, .small))
                    .help("Hide this suggestion; it comes back only if the ticket's pull requests point somewhere else")
                let title = model.ticketMoveErrors[drift.ticket.key] != nil ? "Retry" : prominent ? "Move to “\(drift.target)”" : "Move"
                Button(title) { model.moveTicket(drift) }
                    .buttonStyle(.desk(prominent ? .primary : .secondary, .small))
            }
        }
        .fixedSize()
    }
}

/// The ticket page's and the details column's suggested move: why, in a sentence, why Jira refused it if it did, and
/// the presses.
struct MoveSuggestion: View {
    var drift: TicketDrift
    var model: AppModel

    var body: some View {
        Text("Jira says “\(drift.ticket.status)”. \(drift.because), so it should be “\(drift.target)”.")
            .scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
        if let error = model.ticketMoveErrors[drift.ticket.key] {
            Text("Jira refused: \(error)").scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled)
        }
        MoveButtons(drift: drift, model: model, prominent: true)
    }
}

/// A ticket's own page, opened from Up Next or the Jira screen and laid out as a PR's: its key set apart from its summary
/// with Jira's mark to open it there, a line of where it stands; the description in the wide column; its fields, pull
/// requests, sessions and the move the app suggests beside it.
struct TicketPage: View {
    var ticket: Ticket
    var model: AppModel
    /// The screen it was opened from, which its back link names and returns to.
    var back: String
    var onBack: () -> Void

    var body: some View {
        DetailPage(back: back, onBack: onBack) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Text(ticket.key).font(AppTextStyle.code.font(scale: model.textScale))) · Jira\(ticket.reporter.map { " · opened by \($0)" } ?? "")")
                    .scaled(.secondary).foregroundStyle(Theme.quiet)
                EditableTitle(prefix: "", title: ticket.summary, what: "the ticket", editable: true) {
                    await model.editTicket(ticket, summary: $0)
                } trailing: {
                    Button { model.open(ticket.url) } label: {
                        HStack(spacing: 6) { SidebarIcon(name: SidebarIcon.jira); Text("Open in Jira") }
                    }
                    .buttonStyle(.desk(.secondary, .small))
                    .help("Open in Jira")
                }
            }
            HStack(spacing: 8) {
                StageChip2(text: ticket.status)
                if let priority = ticket.priority { PriorityMark.text(priority).scaled(.secondary) }
                HStack(spacing: 6) {
                    AssigneeAvatar(ticket: ticket, size: 16)
                    Text(ticket.assignedToMe ? "You" : ticket.assignee ?? "Unassigned").scaled(.secondary)
                }
                if let drift = model.state.drift(forKey: ticket.key) { DriftBadge(drift: drift, model: model) }
                Spacer(minLength: 8)
            }
        } main: {
            TicketDescription(ticket: ticket, model: model)
        } side: {
            VStack(alignment: .leading, spacing: 22) {
                TicketFields(ticket: ticket, model: model)
                if model.state.pullRequests(forTicket: ticket.key).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Pull requests")
                        Text("None open").foregroundStyle(Theme.quiet)
                    }
                }
                TicketLinks(ticket: ticket, model: model)
                if let drift = model.state.drift(forKey: ticket.key) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Suggested move")
                        MoveSuggestion(drift: drift, model: model)
                    }
                }
            }
            .sideCard()
        }
    }
}

/// Whose tickets the list shows, the way Jira's board filters by assignee: "Assignee" and a row of faces — you, the
/// people with open tickets, nobody — each a toggle, so any mix can be on, with the ones past the first few behind
/// "+N". Nothing on is everyone's; "Clear filters" gets back there.
private struct AssigneeFilter: View {
    @Binding var selection: Set<TicketAssignee>
    var me: TicketPerson?
    var people: [TicketPerson]
    @State private var showingMore = false
    /// People shown as faces before the rest go behind "+N", as Jira's board does.
    private static let shown = 4
    private static let size: CGFloat = 24

    var body: some View {
        HStack(spacing: 8) {
            Text("Assignee").scaled(.secondary).foregroundStyle(Theme.quiet)
            FilterFace(name: "You", on: selection.contains(.me), toggle: { toggle(.me) }) {
                if let me { Avatar(login: me.name, url: me.avatar, size: Self.size) } else { NobodyAvatar(size: Self.size) }
            }
            ForEach(people.prefix(Self.shown)) { person in
                FilterFace(name: person.name, on: selection.contains(.person(person.name)), toggle: { toggle(.person(person.name)) }) {
                    Avatar(login: person.name, url: person.avatar, size: Self.size)
                }
            }
            FilterFace(name: "Unassigned", on: selection.contains(.unassigned), toggle: { toggle(.unassigned) }) {
                Image(systemName: "person").scaled(.caption).foregroundStyle(Theme.quiet)
                    .frame(width: Self.size, height: Self.size)
                    .overlay(Circle().strokeBorder(Theme.control, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
            }
            if people.count > Self.shown { more }
            if !selection.isEmpty {
                Button("Clear filters") { selection = [] }
                    .buttonStyle(.plain).handCursor().scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize()
                    .padding(.leading, 20)
            }
        }
    }

    /// The people past the first few, each a tick with their picture, in a popover that stays open while you tick.
    private var more: some View {
        let rest = Array(people.dropFirst(Self.shown))
        let on = rest.count { selection.contains(.person($0.name)) }
        return FilterFace(name: "\(rest.count) more", on: on > 0, toggle: { showingMore.toggle() }) {
            Text("+\(rest.count)").scaled(.caption.weight(.semibold)).foregroundStyle(Theme.quiet)
                .frame(width: Self.size, height: Self.size).background(Theme.selected, in: Circle())
        }
        .popover(isPresented: $showingMore, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rest) { person in
                        Toggle(isOn: Binding(get: { selection.contains(.person(person.name)) }, set: { _ in toggle(.person(person.name)) })) {
                            HStack(spacing: 8) { Avatar(login: person.name, url: person.avatar, size: 20); Text(person.name) }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(12)
            }
            .scaledFrame(width: 240)
            .frame(maxHeight: 320)
        }
    }

    private func toggle(_ value: TicketAssignee) {
        if selection.contains(value) { selection.remove(value) } else { selection.insert(value) }
    }
}

/// One face in the assignee filter: ringed in the accent while it is on, a gap of the ground between, lifted under the
/// pointer, its name in the tooltip.
private struct FilterFace<Face: View>: View {
    var name: String
    var on: Bool
    var toggle: () -> Void
    @ViewBuilder var face: Face
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: toggle) {
            face
                .padding(2)
                .overlay(Circle().strokeBorder(on ? Theme.accentInk : Color.clear, lineWidth: 1.5))
                .offset(y: hovering && !reduceMotion ? -2 : 0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The picture of whoever a ticket is assigned to, or Jira's silhouette when nobody is.
private struct AssigneeAvatar: View {
    var ticket: Ticket
    var size: CGFloat = 28

    var body: some View {
        if let name = ticket.assignee {
            Avatar(login: name, url: ticket.assigneeAvatar, size: size)
        } else {
            NobodyAvatar(size: size)
        }
    }
}
