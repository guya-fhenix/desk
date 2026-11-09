import DeskCore
import SwiftUI

/// Jira tickets as a list: the running sprint or the backlog, one group per status in workflow order, yours unless
/// the assignee filter picks others. Done is left out: the list is about what is still open. Selecting a row previews it
/// in the details panel; Return, a double-click or → opens its page, as Up Next does, and ⌘↩ opens it in Jira, as Search
/// does. Above the groups, the moves the app suggests for your tickets, each waiting for your Move or Dismiss.
struct TicketsTab: View {
    @Environment(AppModel.self) private var model
    private var filters = TicketFilters()
    /// By key, so a poll that replaces every ticket keeps the selection.
    @State private var selection: String?
    /// The pages open over the list; empty shows the list.
    @State private var path: [Route] = []
    @FocusState private var listFocused: Bool
    @State private var search = ""
    /// The ticket and repository a plan has been asked for, while the note is still being written.
    @State private var planning: PlanRequest?
    @State private var planNote = ""
    /// A row to bring into view: the ticket Search picked, which may sit far down the list.
    @State private var scrollTarget: String?

    var body: some View {
        let groups = filtered(model.state.ticketGroups(filters.placement, assignees: assignees))
        let moves = suggestedMoves
        NavigationStack(path: $path) {
            list(groups: groups, moves: moves)
                .navigationDestination(for: Route.self) { RoutePage(route: $0, back: "Jira", path: $path, plan: plan) }
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
        .sheet(item: $planning) { request in
            PlanSheet(request: request, model: model, note: $planNote) { planning = nil }
        }
    }

    @ViewBuilder private func list(groups: [TicketGroup], moves: [TicketDrift]) -> some View {
        Screen {
            PageHeader(title: "Jira") { HeaderControls(inspector: "tickets") }
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
                            ListRow(selected: selection == ticket.key) {
                                TicketRow(ticket: ticket, model: model)
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
        }
        // Wider than the others: this one is for reading a description, tables and all. The list's preview only: a
        // ticket's page shows all of it.
        .deskInspector("tickets", width: 420) {
            if let ticket = selection.flatMap(ticket(for:)) {
                TicketInspector(ticket: ticket, model: model, plan: plan).id(ticket.key)
            } else {
                EmptyState(text: "Select a ticket to read it.").padding()
                Spacer()
            }
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

    private func plan(_ ticket: Ticket, _ repo: RepoRef) {
        planNote = ""
        planning = PlanRequest(ticket: ticket, repo: repo)
    }

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
}

/// One ticket in its status group: the status colour, the summary, and a monospaced line with key, priority and
/// how many open PRs name it; where its PRs say Jira should move it, on the right.
struct TicketRow: View {
    var ticket: Ticket
    var model: AppModel

    var body: some View {
        let linked = model.state.pullRequests(forTicket: ticket.key).count
        HStack(alignment: .center, spacing: 12) {
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
            // Start in… is on the ticket's details panel and page, not repeated on every row.
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
        return Text(Image(systemName: mark.symbol)).foregroundStyle(mark.color).bold() + Text(" \(name)")
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

/// The selected ticket: where it stands, what it says, which pull requests name it, and the presses that
/// act on it.
private struct TicketInspector: View {
    var ticket: Ticket
    var model: AppModel
    var plan: (Ticket, RepoRef) -> Void

    var body: some View {
        Panel {
            PanelSection {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ticket.key).scaled(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    EditableTitle(
                        prefix: "", title: ticket.summary, what: "the ticket", editable: true, style: .title3.weight(.semibold)
                    ) {
                        await model.editTicket(ticket, summary: $0)
                    } trailing: {
                        EmptyView()
                    }
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) { StatusDot(color: TicketColor.of(ticket.category)); Text(ticket.status) }
                }
                if let priority = ticket.priority { LabeledContent("Priority") { PriorityMark.text(priority) } }
                LabeledContent("Assignee") {
                    HStack(spacing: 6) {
                        AssigneeAvatar(ticket: ticket, size: 20)
                        Text(ticket.assignedToMe ? "You" : ticket.assignee ?? "Unassigned")
                    }
                }
                if let reporter = ticket.reporter { LabeledContent("Opened by", value: reporter) }
                HStack {
                    Button("Open in Jira") { model.open(ticket.url) }
                    StartInMenu(ticket: ticket, model: model, plan: plan)
                }
                .controlSize(.small)
            }
            if let drift = model.state.drift(forKey: ticket.key) {
                PanelSection("Suggested move") { MoveSuggestion(drift: drift, model: model) }
            }
            let sessions = model.state.sessions(forTicket: ticket.key)
            if !sessions.isEmpty {
                PanelSection("Sessions") {
                    ForEach(sessions) { SessionRow(session: $0, model: model) }
                    if let error = model.sessionErrors[ticket.key] {
                        Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            PanelSection("Pull requests") {
                let prs = model.state.pullRequests(forTicket: ticket.key)
                if prs.isEmpty { Text("None open.").foregroundStyle(.secondary) }
                ForEach(prs) { pr in
                    HStack(spacing: 6) {
                        ChecksBadge(pr: pr)
                        Button { model.open(pr.url) } label: { Text(verbatim: "\(pr.repoName)#\(pr.number) \(pr.title)").lineLimit(1) }
                            .buttonStyle(.link).handCursor()
                    }
                }
            }
            TicketDescription(ticket: ticket, model: model)
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

/// "Start in…": the repositories a ticket can be planned in, each opening the sheet that asks what the plan is for.
/// Filled on a ticket's page, where it is the page's action.
struct StartInMenu: View {
    var ticket: Ticket
    var model: AppModel
    var plan: (Ticket, RepoRef) -> Void
    var prominent = false

    var body: some View {
        let repos = (model.state.gitScan?.repos ?? []).sorted { $0.name < $1.name }
        if model.planningTickets.contains(ticket.key) {
            ProgressView().controlSize(.mini)
        } else if !repos.isEmpty {
            let menu = Menu("Start in…") {
                ForEach(repos, id: \.root) { repo in RepoMenuItem(repo: repo, model: model) { plan(ticket, repo) } }
            }
            Group {
                if prominent { menu.menuStyle(.button).buttonStyle(.borderedProminent) } else { menu }
            }
            .fixedSize()
            .help(model.sessionErrors[ticket.key] ?? "Start \(ticket.key) in a background Claude session")
        }
    }
}

/// A ticket's own page, opened from Up Next or the Jira screen and laid out as a PR's: its key set apart from its summary with Jira's
/// mark to open it there, a status line of where it stands with Start in… on the right; the description in the wide
/// column; its pull requests, sessions and how Jira has fallen behind beside it.
struct TicketPage: View {
    var ticket: Ticket
    var model: AppModel
    /// The screen it was opened from, which its back link names and returns to.
    var back: String
    var plan: (Ticket, RepoRef) -> Void
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
                // The page's action on the right, where a status line's presses go.
                Spacer(minLength: 8)
                StartInMenu(ticket: ticket, model: model, plan: plan, prominent: true)
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
                Text(session.state).scaled(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A repo in the menus that start a session. One whose sessions cannot run the team review skill says why on a
/// second line, in the menu's subtitle style, behind an orange warning: the session would start, but its
/// self-review would have no skill to call.
private struct RepoMenuItem: View {
    var repo: RepoRef
    var model: AppModel
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if let skill = model.state.reviewSkills[repo.root], !skill.has(skill.selfReview) {
                Label {
                    Text(repo.name)
                    Text(skill.text)
                } icon: {
                    Image(nsImage: Self.warning)
                }
            } else {
                Text(repo.name)
            }
        }
    }

    /// Menus draw symbols as templates, in the text colour; a palette image that is not a template keeps its orange.
    private static let warning: NSImage = {
        let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        let image = symbol?.withSymbolConfiguration(.init(paletteColors: [.systemOrange])) ?? NSImage()
        image.isTemplate = false
        return image
    }()
}

/// A plan asked for but not yet started: the repository is chosen, the note is not yet written.
struct PlanRequest: Identifiable {
    var ticket: Ticket
    var repo: RepoRef

    var id: String { "\(ticket.key)|\(repo.root)" }
}

/// The last step before a planning session starts. The ticket and its description go along whatever
/// happens here; this is for the part the ticket does not say — what to focus on, what to leave alone,
/// how far to take it.
struct PlanSheet: View {
    var request: PlanRequest
    var model: AppModel
    @Binding var note: String
    var dismiss: () -> Void

    @FocusState private var writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start \(request.ticket.key) in \(request.repo.name)").scaled(.headline)
            Text(request.ticket.summary).scaled(.callout).foregroundStyle(.secondary).lineLimit(2)
            if let skill = model.state.reviewSkills[request.repo.root], !skill.has(skill.selfReview) {
                Label(skill.text, systemImage: "exclamationmark.triangle.fill").scaled(.caption).foregroundStyle(.orange)
            }
            Text("Anything you want from the plan? The ticket and its description are sent either way.")
                .scaled(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $note)
                .scaled(.callout)
                .focused($writing)
                .frame(minHeight: 96)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            HStack(spacing: 8) {
                Text(model.config.jiraInProgressStatus.isEmpty
                    ? "Starts a background session."
                    : "Starts a background session and moves the ticket to “\(model.config.jiraInProgressStatus)”.")
                    .scaled(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    model.planTicket(request.ticket, in: request.repo, note: note)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                // Return belongs to the editor, so the press that starts it is ⌘-Return.
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(Theme.background)
        .onAppear { writing = true }
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
