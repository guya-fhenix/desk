import DeskCore
import SwiftUI

/// Jira tickets as a list: the running sprint or the backlog, one group per status in workflow order, yours unless
/// the assignee filter picks others. Done is left out: the list is about what is still open. A click, Space or Return
/// opens a ticket in place, under its row, and closes the one open before; → opens its page, and ⌘↩ opens it in Jira,
/// as Search does. Above the groups, the moves the app suggests for your tickets, each waiting for your Move or Dismiss.
struct TicketsTab: View {
    @Environment(AppModel.self) private var model
    private var filters = TicketFilters()
    /// By key, so a poll that replaces every ticket keeps the selection.
    @State private var selection: String?
    /// The one ticket open under its row, by key.
    @State private var expanded: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            list(groups: groups, moves: moves)
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
        Screen {
            PageHeader(title: "Jira") {}
            header
        } content: {
            Hairline()
            if groups.isEmpty && moves.isEmpty {
                emptyState.padding(.vertical, 20)
                Spacer()
            } else {
                StaleBanner(source: .jira)
                // Arrow keys move the selection; a double-click, Return or → opens the ticket's page.
                ScrollViewReader { proxy in
                List(selection: $selection) {
                    if !moves.isEmpty {
                        GroupHeader(title: "Suggested moves", count: moves.count) {
                            Button("Move all") { moves.forEach(model.moveTicket) }
                                .controlSize(.small)
                                .disabled(moves.allSatisfy { model.movingTickets.contains($0.ticket.key) })
                        }
                        .plainListRow().selectionDisabled()
                        // Tagged by the move, not the ticket: the ticket has its own row in its status group below.
                        ForEach(moves, id: \.moveKey) { drift in
                            ListRow(selected: selection == drift.moveKey) { MoveRow(drift: drift, model: model) }
                        }
                    }
                    ForEach(groups) { group in
                        GroupHeader(title: group.status, count: group.tickets.count).plainListRow().selectionDisabled()
                        ForEach(group.tickets) { ticket in
                            let open = expanded == ticket.key
                            ListRow(selected: selection == ticket.key, open: { toggle(ticket.key) }) {
                                TicketRow(ticket: ticket, model: model, expanded: open)
                            }
                            if open {
                                TicketDetails(ticket: ticket, model: model) { self.open(ticket.key) }
                                    .plainListRow().selectionDisabled()
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
                .onKeyPress(.space) {
                    guard let selection, model.state.ticket(selection) != nil else { return .ignored }
                    toggle(selection)
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
                    // A ticket's row opens in place; a suggested move's, which has no place to open in, opens its page.
                    guard let key = keys.first else { return }
                    if model.state.ticket(key) != nil { toggle(key) } else { open(key) }
                }
                .onChange(of: scrollTarget, initial: true) { _, key in
                    guard let key else { return }
                    proxy.scrollTo(key, anchor: .center)
                    scrollTarget = nil
                }
                }
            }
        }
    }

    /// Opens the ticket under its row, closing the one open before, or closes it when it is the one open.
    private func toggle(_ key: String) {
        selection = key
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expanded = expanded == key ? nil : key }
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

    /// The sprint/backlog switch, each side counted over what the search leaves, like the Reviews scopes.
    private var header: some View {
        FilterBar {
            PillTabs(
                options: [TicketPlacement.sprint, .backlog].map { option in
                    let count = filtered(model.state.ticketGroups(option, assignees: assignees)).reduce(0) { $0 + $1.tickets.count }
                    return .init(value: option, title: option == .sprint ? "Sprint" : "Backlog", count: count)
                },
                selection: filters.$placement
            )
        } trailing: {
            SearchBox(prompt: "Key or summary", text: $search)
            AssigneeFilter(
                selection: Binding(get: { assignees }, set: { filters.assignees = $0 }),
                me: model.state.ticketSelf,
                people: model.state.ticketAssignees
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

/// One ticket in its status group: the status colour, the summary, and a monospaced line with key, priority and
/// how many open PRs name it; where its PRs say Jira should move it, on the right. On the Jira screen a chevron first
/// says whether it is open under its row.
struct TicketRow: View {
    var ticket: Ticket
    var model: AppModel
    /// Nil where the row does not open in place.
    var expanded: Bool? = nil

    /// Where the text after the chevron and the picture starts, for what opens under the row to line up with it.
    static let textInset: CGFloat = Theme.Space.m + 12 + 12 + 28 + 12

    var body: some View {
        let linked = model.state.pullRequests(forTicket: ticket.key).count
        HStack(alignment: .center, spacing: 12) {
            if let expanded {
                Image(systemName: "chevron.right")
                    .scaled(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                    .accessibilityHidden(true)
            }
            // Whose it is, as a picture; the status is already the group's heading.
            AssigneeAvatar(ticket: ticket)
            VStack(alignment: .leading, spacing: 5) {
                Text(ticket.summary).scaled(.rowTitle).lineLimit(1)
                // Whose it is, unless it is yours: the filter may be showing other people's.
                MetaLine(parts: [Text(ticket.key), Text(ticket.status)] + [ticket.priority.map(PriorityMark.text)].compactMap { $0 }
                    + (ticket.assignedToMe ? [] : [Text(ticket.assignee ?? "Unassigned")])
                    + (linked > 0 ? [Text("\(linked) open \(linked == 1 ? "PR" : "PRs")")] : []))
            }
            Spacer(minLength: 8)
            if let drift = model.state.drift(forKey: ticket.key) {
                DriftBadge(drift: drift, model: model)
            }
        }
    }
}

/// A priority with Jira's mark before it, as Jira draws its standard five: red chevrons up for Highest and High,
/// an orange equals sign for Medium, blue chevrons down for Low and Lowest. A name outside those reads bare.
enum PriorityMark {
    static func text(_ name: String) -> Text {
        let mark: (symbol: String, color: Color)?
        switch name.lowercased() {
        case "highest": mark = ("chevron.up.2", .red)
        case "high": mark = ("chevron.up", .red)
        case "medium": mark = ("equal", .orange)
        case "low": mark = ("chevron.down", .blue)
        case "lowest": mark = ("chevron.down.2", .blue)
        default: mark = nil
        }
        guard let mark else { return Text(name) }
        return Text("\(Text(Image(systemName: mark.symbol)).foregroundStyle(mark.color).bold()) \(name)")
    }
}

enum TicketColor {
    static func of(_ category: TicketStatusCategory) -> Color {
        switch category {
        case .todo: return .secondary
        case .inProgress: return .blue
        case .done: return .green
        case .unknown: return .orange
        }
    }
}

/// A ticket open under its row, with only what the row leaves out: who opened it, the pull requests and sessions behind
/// its counts, why the app suggests its move with the presses, and the description; and the ways to its page and to
/// Jira. Its key, summary, status, priority and assignee are the row's.
private struct TicketDetails: View {
    var ticket: Ticket
    var model: AppModel
    var openPage: () -> Void

    var body: some View {
        let prs = model.state.pullRequests(forTicket: ticket.key)
        let sessions = model.state.sessions(forTicket: ticket.key)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                if let reporter = ticket.reporter { Text("Opened by \(reporter)").scaled(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: Theme.Space.s)
                Button("Open page", action: openPage).help("The ticket's page (→)")
                Button("Open in Jira") { model.open(ticket.url) }.help("⌘↩")
            }
            .controlSize(.small)
            if !prs.isEmpty {
                part("Pull requests") {
                    ForEach(prs) { pr in
                        HStack(spacing: 6) {
                            ChecksBadge(pr: pr)
                            Button { model.open(pr.url) } label: { Text(verbatim: "\(pr.repoName)#\(pr.number) \(pr.title)").lineLimit(1) }
                                .buttonStyle(.link).handCursor()
                        }
                    }
                }
            }
            if !sessions.isEmpty {
                part("Sessions") {
                    ForEach(sessions) { SessionRow(session: $0, model: model) }
                    if let error = model.sessionErrors[ticket.key] {
                        Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            if let drift = model.state.drift(forKey: ticket.key) {
                part("Suggested move") {
                    HStack(spacing: Theme.Space.s) {
                        Text("Because \(drift.because)").scaled(.caption)
                        Spacer(minLength: Theme.Space.s)
                        MoveButtons(drift: drift, model: model)
                    }
                    if let error = model.ticketMoveErrors[ticket.key] {
                        Text("Jira refused: \(error)").scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            TicketDescription(ticket: ticket, model: model)
        }
        .padding(.leading, TicketRow.textInset)
        .padding(.trailing, Theme.Space.m)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func part(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).scaled(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// A move the app suggests, as a row of the Jira screen's Suggested moves and Up Next's Jira moves: whose ticket and
/// what it is, the move and the pull requests behind it, why Jira refused it if it did, and the two presses.
struct MoveRow: View {
    var drift: TicketDrift
    var model: AppModel

    var body: some View {
        let error = model.ticketMoveErrors[drift.ticket.key]
        HStack(alignment: .center, spacing: 12) {
            AssigneeAvatar(ticket: drift.ticket)
            VStack(alignment: .leading, spacing: 5) {
                Text(drift.ticket.summary).scaled(.rowTitle).lineLimit(1)
                MetaLine(parts: [Text(drift.ticket.key), Text("\(drift.ticket.status) → \(drift.target)"), Text(drift.because)])
                if let error {
                    Text("Jira refused: \(error)").scaled(.caption).foregroundStyle(.red).lineLimit(1).help(error)
                }
            }
            Spacer(minLength: 8)
            MoveButtons(drift: drift, model: model)
        }
    }
}

/// Dismiss, then Move — Retry once Jira has refused it — or a spinner while it moves. Dismiss is remembered: the
/// suggestion comes back only if the ticket's pull requests point it somewhere else.
struct MoveButtons: View {
    var drift: TicketDrift
    var model: AppModel
    /// The page's and the details panel's: the target spelled out, filled.
    var prominent = false

    var body: some View {
        HStack(spacing: 6) {
            if model.movingTickets.contains(drift.ticket.key) {
                ProgressView().controlSize(.small).help("Moving \(drift.ticket.key) to “\(drift.target)”")
            } else {
                Button("Dismiss") { model.dismissMove(drift) }
                    .help("Hide this suggestion; it comes back only if the ticket's pull requests point somewhere else")
                let title = model.ticketMoveErrors[drift.ticket.key] != nil ? "Retry" : prominent ? "Move to “\(drift.target)”" : "Move"
                if prominent {
                    Button(title) { model.moveTicket(drift) }.buttonStyle(.borderedProminent)
                } else {
                    Button(title) { model.moveTicket(drift) }
                }
            }
        }
        .controlSize(prominent ? .regular : .small)
        .fixedSize()
    }
}

/// The ticket page's and details panel's card for a suggested move: why, in a sentence, why Jira refused it if it did,
/// and the presses.
struct MoveSuggestion: View {
    var drift: TicketDrift
    var model: AppModel

    var body: some View {
        Text("Jira says “\(drift.ticket.status)”. \(drift.because), so it should be “\(drift.target)”.").scaled(.caption)
        if let error = model.ticketMoveErrors[drift.ticket.key] {
            Text("Jira refused: \(error)").scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        HStack {
            Spacer()
            MoveButtons(drift: drift, model: model, prominent: true)
        }
    }
}

/// A ticket's own page, opened from Up Next or the Jira screen and laid out as a PR's: its key set apart from its summary with Jira's
/// mark to open it there, a status line of where it stands; the description in the wide
/// column; its pull requests, sessions and how Jira has fallen behind beside it.
struct TicketPage: View {
    var ticket: Ticket
    var model: AppModel
    /// The screen it was opened from, which its back link names and returns to.
    var back: String
    var onBack: () -> Void

    var body: some View {
        // As on a PR page: the icon's middle on the middle of the title's capitals.
        let sessions = model.state.sessions(forTicket: ticket.key)
        DetailPage(back: back, onBack: onBack) {
            EditableTitle(prefix: ticket.key, title: ticket.summary, what: "the ticket", editable: true) {
                await model.editTicket(ticket, summary: $0)
            } trailing: {
                Button { model.open(ticket.url) } label: {
                    HStack(spacing: 3) {
                        SidebarIcon(name: SidebarIcon.jira)
                        Image(systemName: "arrow.up.right").scaled(.caption)
                    }
                }
                .buttonStyle(IconButtonStyle()).handCursor()
                .help("Open in Jira")
                .accessibilityLabel("Open in Jira")
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    StatusDot(color: TicketColor.of(ticket.category))
                    Text(ticket.status)
                }
                .pill()
                if let priority = ticket.priority { PriorityMark.text(priority).pill() }
                HStack(spacing: 6) {
                    AssigneeAvatar(ticket: ticket, size: 16)
                    Text(ticket.assignedToMe ? "You" : ticket.assignee ?? "Unassigned")
                }
                .pill()
                if let drift = model.state.drift(forKey: ticket.key) { DriftBadge(drift: drift, model: model) }
                Spacer(minLength: 8)
            }
            if let error = model.sessionErrors[ticket.key] {
                Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        } main: {
            TicketDescription(ticket: ticket, model: model)
        } side: {
            let prs = model.state.pullRequests(forTicket: ticket.key)
            SideCard(title: "Pull requests", count: prs.isEmpty ? nil : prs.count) {
                if prs.isEmpty { Text("None open").foregroundStyle(.secondary) }
                ForEach(prs) { pr in
                    HStack(spacing: 6) {
                        ChecksBadge(pr: pr)
                        Button { model.open(pr.url) } label: { Text(verbatim: "\(pr.repoName)#\(pr.number) \(pr.title)").lineLimit(1) }
                            .buttonStyle(.link).handCursor()
                    }
                }
            }
            if !sessions.isEmpty {
                SideCard(title: "Sessions") {
                    ForEach(sessions) { SessionRow(session: $0, model: model) }
                }
            }
            if let drift = model.state.drift(forKey: ticket.key) {
                SideCard(title: "Suggested move") { MoveSuggestion(drift: drift, model: model) }
            }
        }
    }
}

/// One session started on this ticket: where its flow stands, the PR once it has one, and the way in.
private struct SessionRow: View {
    var session: ClaudeJob
    var model: AppModel

    var body: some View {
        let pr = model.state.pullRequest(of: session)
        LabeledContent {
            Button("Attach") { model.attach(jobId: session.id, errorKey: session.ticketKey ?? session.id) }.controlSize(.small)
        } label: {
            HStack(spacing: 6) {
                StageChip(stage: model.state.stage(of: session), sessionBusy: session.isBusy).fixedSize()
                if let pr {
                    Button { model.open(pr.url) } label: { Text(verbatim: "\(pr.repoName)#\(pr.number)") }.buttonStyle(.link).handCursor()
                } else {
                    Text(URL(fileURLWithPath: session.cwd).lastPathComponent)
                }
                Text(session.status).scaled(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Whose tickets the list shows, the way Jira's board filters by assignee: a row of overlapping pictures — you, the
/// people with open tickets, nobody — each a toggle, so any mix can be on, with the ones past the first few behind
/// "+N". Nothing on is everyone's; "Clear filters" gets back there.
private struct AssigneeFilter: View {
    @Binding var selection: Set<TicketAssignee>
    var me: TicketPerson?
    var people: [TicketPerson]
    @State private var showingMore = false
    /// People shown as pictures before the rest go behind "+N", as Jira's board does.
    private static let shown = 4

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: -6) {
                FilterFace(name: "You", on: selection.contains(.me), toggle: { toggle(.me) }) {
                    if let me { Avatar(login: me.name, url: me.avatar) } else { NobodyAvatar() }
                }
                ForEach(people.prefix(Self.shown)) { person in
                    FilterFace(name: person.name, on: selection.contains(.person(person.name)), toggle: { toggle(.person(person.name)) }) {
                        Avatar(login: person.name, url: person.avatar)
                    }
                }
                FilterFace(name: "Unassigned", on: selection.contains(.unassigned), toggle: { toggle(.unassigned) }) {
                    NobodyAvatar()
                }
                if people.count > Self.shown { more }
            }
            if !selection.isEmpty {
                Button("Clear filters") { selection = [] }.buttonStyle(.link).handCursor().fixedSize()
            }
        }
    }

    /// The people past the first few, each a tick with their picture, in a popover that stays open while you tick.
    private var more: some View {
        let rest = Array(people.dropFirst(Self.shown))
        let on = rest.count { selection.contains(.person($0.name)) }
        return FilterFace(name: "\(rest.count) more", on: on > 0, toggle: { showingMore.toggle() }) {
            Text("+\(rest.count)").scaled(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30).background(Theme.raised, in: Circle())
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
            .frame(width: 240)
            .frame(maxHeight: 320)
        }
    }

    private func toggle(_ value: TicketAssignee) {
        if selection.contains(value) { selection.remove(value) } else { selection.insert(value) }
    }
}

/// One picture in the assignee filter: ringed in the accent colour while it is on, lifted under the pointer, its name
/// in the tooltip, as Jira draws them. The ring in the background colour keeps overlapping pictures apart.
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
                .background(Circle().fill(Theme.background))
                .overlay(Circle().strokeBorder(on ? Theme.accent : Color.clear, lineWidth: 2))
                .offset(y: hovering && !reduceMotion ? -3 : 0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .zIndex(hovering ? 2 : on ? 1 : 0)
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
