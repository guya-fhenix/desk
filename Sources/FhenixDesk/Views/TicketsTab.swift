import DeskCore
import SwiftUI

/// Your Jira tickets as a board: the running sprint or the backlog, one column per status. Done is left
/// out: the board is about what is still open. Selecting a card opens it in the inspector, which is
/// where its description is read.
struct TicketsTab: View {
    @Environment(AppModel.self) private var model
    private let scale = AppTextStyle.scale
    /// Remembered, so a trip to another screen does not drop you back on the sprint.
    @AppStorage("tickets.placement") private var placement: TicketPlacement = .sprint
    /// By key, so a poll that replaces every ticket keeps the selection.
    @State private var selection: String?
    @State private var search = ""
    /// The ticket and repository a plan has been asked for, while the note is still being written.
    @State private var planning: PlanRequest?
    @State private var planNote = ""

    var body: some View {
        let groups = filtered(model.state.ticketGroups(placement))
        Screen {
            PageHeader(title: "Tickets") { HeaderControls(inspector: "tickets") }
            header
        } content: {
            Hairline()
            if groups.isEmpty {
                EmptyText(text: emptyText).padding(.vertical, 20)
                Spacer()
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(groups) { column($0) }
                    }
                    .padding(.vertical, 14)
                }
            }
        }
        // Wider than the others: this one is for reading a description, tables and all.
        .deskInspector("tickets", width: 420) {
            if let key = selection, let ticket = model.state.ticket(key) {
                TicketInspector(ticket: ticket, model: model, plan: plan)
            } else {
                EmptyText(text: "Select a ticket to read it.").padding()
                Spacer()
            }
        }
        .sheet(item: $planning) { request in
            PlanSheet(request: request, model: model, note: $planNote) { planning = nil }
        }
    }

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

    private var emptyText: String {
        if !search.isEmpty { return "No match." }
        return placement == .backlog ? "Nothing of yours in the backlog." : "Nothing of yours in the open sprint."
    }

    /// The sprint/backlog switch, each side counted over what the search leaves, like the Reviews scopes.
    private var header: some View {
        FilterBar {
            PillTabs(
                options: [TicketPlacement.sprint, .backlog].map { option in
                    let count = filtered(model.state.ticketGroups(option)).reduce(0) { $0 + $1.tickets.count }
                    return .init(value: option, title: option == .sprint ? "Sprint" : "Backlog", count: count)
                },
                selection: $placement
            )
        } trailing: {
            if let error = model.state.errors[.jira] {
                Text(error).scaled(.caption).foregroundStyle(.red).lineLimit(1).textSelection(.enabled).help(error)
            }
            SearchBox(prompt: "Key or summary", text: $search)
        }
    }

    /// One status: its header stays put while its cards scroll.
    private func column(_ group: TicketGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(color: TicketColor.of(group.category))
                Text(group.status).scaled(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("\(group.tickets.count)").scaled(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(group.tickets) { card($0) }
                }
            }
        }
        .padding(8)
        .frame(width: 270 * scale)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    private func card(_ ticket: Ticket) -> some View {
        let selected = selection == ticket.key
        let linked = model.state.pullRequests(forTicket: ticket.key).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(ticket.key).scaled(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if let priority = ticket.priority {
                    Text(priority).scaled(.caption).foregroundStyle(.tertiary)
                }
            }
            Text(ticket.summary).scaled(.callout).lineLimit(3)
            HStack(spacing: 8) {
                if linked > 0 {
                    // Inline rather than a Label: the symbol then keeps the text's line height.
                    Text("\(Image(systemName: "arrow.triangle.pull")) \(linked)")
                        .scaled(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize()
                        .help("\(linked) open \(linked == 1 ? "pull request names" : "pull requests name") this ticket")
                }
                Spacer()
                if let drift = model.state.drift(forKey: ticket.key) {
                    DriftBadge(drift: drift, model: model)
                }
                PlanButton(ticket: ticket, model: model) { plan(ticket, $0) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.rowSelected : Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { selection = ticket.key }
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
                    Text(ticket.summary).scaled(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) { StatusDot(color: TicketColor.of(ticket.category)); Text(ticket.status) }
                }
                if let priority = ticket.priority { LabeledContent("Priority", value: priority) }
                HStack {
                    Button("Open in Jira") { model.open(ticket.url) }
                    planMenu
                }
                .controlSize(.small)
            }
            if let drift = model.state.drift(forKey: ticket.key) {
                PanelSection("Jira is behind") {
                    Text(reason(drift)).scaled(.caption)
                    if let error = model.ticketMoveErrors[ticket.key] {
                        Text("The move failed: \(error)").scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    HStack { Spacer(); DriftBadge(drift: drift, model: model) }
                }
            }
            let flows = model.state.flows(forTicket: ticket.key)
            if !flows.isEmpty {
                PanelSection("Sessions") {
                    ForEach(flows) { flow in FlowRow(flow: flow, model: model) }
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
                        Button { model.open(pr.url) } label: { Text("\(pr.repoName)#\(pr.number) \(pr.title)").lineLimit(1) }
                            .buttonStyle(.link)
                    }
                }
            }
            PanelSection("Description") {
                if ticket.description.isEmpty {
                    Text("No description.").foregroundStyle(.secondary)
                } else {
                    MarkdownText(text: ticket.description)
                }
            }
        }
    }

    @ViewBuilder private var planMenu: some View {
        let repos = (model.state.gitScan?.repos ?? []).sorted { $0.name < $1.name }
        if model.planningTickets.contains(ticket.key) {
            ProgressView().controlSize(.mini)
        } else if !repos.isEmpty {
            Menu("Start in…") {
                ForEach(repos, id: \.root) { repo in RepoMenuItem(repo: repo, model: model) { plan(ticket, repo) } }
            }
            .fixedSize()
            .help(model.sessionErrors[ticket.key] ?? "Start \(ticket.key) in a background Claude session")
        }
    }

    private func reason(_ drift: TicketDrift) -> String {
        let prs = drift.pullRequests.map { "\($0.repoName)#\($0.number)" }.joined(separator: ", ")
        let because = drift.stage == .done ? "\(prs) merged" : "\(prs) open for review"
        return "Jira says “\(drift.ticket.status)”. \(because), so it should be “\(drift.target)”."
    }
}

/// Starts a background Claude session to plan this ticket, in a repository you pick — a ticket names no
/// repository, and a plan is worth little without the code it is about.
///
/// Nothing binds the session to the ticket, so this stays a plain press rather than a state: the session
/// is expected to reach a pull request, and that is what the app follows from then on.
private struct PlanButton: View {
    var ticket: Ticket
    var model: AppModel
    /// Picking the repository does not start anything: it opens the sheet that asks what the plan is for.
    var onPick: (RepoRef) -> Void

    var body: some View {
        let repos = (model.state.gitScan?.repos ?? []).sorted { $0.name < $1.name }
        if model.planningTickets.contains(ticket.key) {
            ProgressView().controlSize(.mini).help("Starting a session on \(ticket.key)")
        } else if !repos.isEmpty {
            Menu {
                ForEach(repos, id: \.root) { repo in
                    RepoMenuItem(repo: repo, model: model) { onPick(repo) }
                }
            } label: {
                // The hollow terminal the Pull Requests screen uses for "no session yet, pressing starts
                // one". It never fills here: a planning session is tied to nothing to fill it.
                Image(systemName: "terminal")
                    .foregroundStyle(model.sessionErrors[ticket.key] == nil ? Color.secondary : .red)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(model.sessionErrors[ticket.key] ?? help)
        }
    }

    private var help: String {
        let status = model.config.jiraInProgressStatus
        let move = status.isEmpty ? "" : ", and move it to “\(status)”"
        return "Start \(ticket.key) in a background Claude session\(move)"
    }
}

/// One session started from this ticket: where its flow stands, the PR once it has one, and the way in.
private struct FlowRow: View {
    var flow: Flow
    var model: AppModel

    var body: some View {
        let job = model.state.job(id: flow.jobId)
        let pr = model.state.mine.first { $0.url == flow.prURL }
        LabeledContent {
            Button("Attach") { model.attach(jobId: flow.jobId, errorKey: flow.ticketKey ?? flow.jobId) }.controlSize(.small)
        } label: {
            HStack(spacing: 6) {
                StageChip(stage: flow.stage).fixedSize()
                if let pr {
                    Button { model.open(pr.url) } label: { Text("\(pr.repoName)#\(pr.number)") }.buttonStyle(.link)
                } else {
                    Text(URL(fileURLWithPath: flow.repoRoot).lastPathComponent)
                }
                if let job { Text(job.state).scaled(.caption).foregroundStyle(.secondary) }
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
            if let skill = model.state.reviewSkills[repo.root], !skill.isReady {
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
private struct PlanRequest: Identifiable {
    var ticket: Ticket
    var repo: RepoRef

    var id: String { "\(ticket.key)|\(repo.root)" }
}

/// The last step before a planning session starts. The ticket and its description go along whatever
/// happens here; this is for the part the ticket does not say — what to focus on, what to leave alone,
/// how far to take it.
private struct PlanSheet: View {
    var request: PlanRequest
    var model: AppModel
    @Binding var note: String
    var dismiss: () -> Void

    @FocusState private var writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start \(request.ticket.key) in \(request.repo.name)").scaled(.headline)
            Text(request.ticket.summary).scaled(.callout).foregroundStyle(.secondary).lineLimit(2)
            if let skill = model.state.reviewSkills[request.repo.root], !skill.isReady {
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
                    .foregroundStyle(.tertiary)
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
        .preferredColorScheme(.dark)
        .onAppear { writing = true }
    }
}
