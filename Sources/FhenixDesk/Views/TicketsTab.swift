import DeskCore
import SwiftUI

/// Your Jira tickets by status, split by whether they are in the running sprint or waiting in the
/// backlog. Done is left out: the screen is about what is still open. Selecting one opens it in the
/// inspector, which is where its description is read.
struct TicketsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale: Double
    /// By key, so a poll that replaces every ticket keeps the selection.
    @State private var selection: String?
    @State private var search = ""
    /// The ticket and repository a plan has been asked for, while the note is still being written.
    @State private var planning: PlanRequest?
    @State private var planNote = ""

    var body: some View {
        List(selection: $selection) {
            ForEach([TicketPlacement.sprint, .backlog], id: \.self) { placement in
                let groups = filtered(model.state.ticketGroups(placement))
                Section {
                    if groups.isEmpty {
                        EmptyText(text: emptyText(placement))
                    }
                    ForEach(groups) { group in
                        statusRow(group)
                        ForEach(group.tickets) { ticket in ticketRow(ticket).tag(ticket.key) }
                    }
                } header: {
                    HStack {
                        Text(placement == .sprint ? "Sprint" : "Backlog")
                        Spacer()
                        Text("\(groups.reduce(0) { $0 + $1.tickets.count })").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if let error = model.state.errors[.jira] {
                Section("Jira") { Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Key or summary")
        .navigationTitle("Tickets")
        .deskInspector("tickets") {
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

    private func emptyText(_ placement: TicketPlacement) -> String {
        if !search.isEmpty { return "No match." }
        return placement == .sprint ? "Nothing of yours in the open sprint." : "Nothing of yours in the backlog."
    }

    private func statusRow(_ group: TicketGroup) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: TicketColor.of(group.category))
            Text(group.status).scaled(.callout.weight(.semibold))
            Spacer()
            Text("\(group.tickets.count)").scaled(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.top, 2)
        .selectionDisabled()
    }

    private func ticketRow(_ ticket: Ticket) -> some View {
        HStack(spacing: 8) {
            Text(ticket.key)
                .scaled(.callout.monospaced())
                .frame(width: 84 * scale, alignment: .leading)
            Text(ticket.summary).lineLimit(1)
            Spacer()
            if let drift = model.state.drift(forKey: ticket.key) {
                DriftButton(drift: drift, model: model)
            }
            let linked = model.state.pullRequests(forTicket: ticket.key).count
            if linked > 0 {
                // Inline rather than a Label: the symbol then keeps the text's line height instead of
                // stretching the row past its separator.
                Text("\(Image(systemName: "arrow.triangle.pull")) \(linked)")
                    .scaled(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
                    .help("\(linked) open \(linked == 1 ? "pull request names" : "pull requests name") this ticket")
            }
            PlanButton(ticket: ticket, model: model) { plan(ticket, $0) }
            if let priority = ticket.priority {
                Text(priority).scaled(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 18)
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
/// act on it — the same two the row carries.
private struct TicketInspector: View {
    var ticket: Ticket
    var model: AppModel
    var plan: (Ticket, RepoRef) -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ticket.key).scaled(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(ticket.summary).scaled(.headline).fixedSize(horizontal: false, vertical: true)
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
                Section("Jira is behind") {
                    Text(reason(drift)).scaled(.caption)
                    HStack { Spacer(); DriftButton(drift: drift, model: model) }
                }
            }
            Section("Pull requests") {
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
            Section("Description") {
                if ticket.description.isEmpty {
                    Text("No description.").foregroundStyle(.secondary)
                } else {
                    MarkdownText(text: ticket.description)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var planMenu: some View {
        let repos = (model.state.gitScan?.repos ?? []).sorted { $0.name < $1.name }
        if model.planningTickets.contains(ticket.key) {
            ProgressView().controlSize(.mini)
        } else if !repos.isEmpty {
            Menu("Plan in…") {
                ForEach(repos, id: \.root) { repo in Button(repo.name) { plan(ticket, repo) } }
            }
            .fixedSize()
            .help(model.sessionErrors[ticket.key] ?? "Plan \(ticket.key) in a background Claude session")
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
            ProgressView().controlSize(.mini).help("Starting a session to plan \(ticket.key)")
        } else if !repos.isEmpty {
            Menu {
                ForEach(repos, id: \.root) { repo in
                    Button(repo.name) { onPick(repo) }
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
        return "Plan \(ticket.key) in a background Claude session\(move)"
    }
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
            Text("Plan \(request.ticket.key) in \(request.repo.name)").scaled(.headline)
            Text(request.ticket.summary).scaled(.callout).foregroundStyle(.secondary).lineLimit(2)
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
                Button("Plan") {
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
        .onAppear { writing = true }
    }
}
