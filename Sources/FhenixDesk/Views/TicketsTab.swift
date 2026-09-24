import DeskCore
import SwiftUI

/// Your Jira tickets by status, split by whether they are in the running sprint or waiting in the
/// backlog. Done is left out: the screen is about what is still open.
struct TicketsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale: Double
    /// Which descriptions are open. By key, so a poll that replaces every ticket leaves them open.
    @State private var expanded: Set<String> = []
    /// The ticket and repository a plan has been asked for, while the note is still being written.
    @State private var planning: PlanRequest?
    @State private var planNote = ""

    var body: some View {
        List {
            ForEach([TicketPlacement.sprint, .backlog], id: \.self) { placement in
                let groups = model.state.ticketGroups(placement)
                Section {
                    if groups.isEmpty {
                        EmptyText(text: placement == .sprint ? "Nothing of yours in the open sprint." : "Nothing of yours in the backlog.")
                    }
                    ForEach(groups) { group in
                        statusRow(group)
                        ForEach(group.tickets) { ticket in ticketRow(ticket) }
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
        .navigationTitle("Tickets")
        .sheet(item: $planning) { request in
            PlanSheet(request: request, model: model, note: $planNote) { planning = nil }
        }
    }

    private func statusRow(_ group: TicketGroup) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: color(group.category))
            Text(group.status).scaled(.callout.weight(.semibold))
            Spacer()
            Text("\(group.tickets.count)").scaled(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private func ticketRow(_ ticket: Ticket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                disclosure(ticket)
                Button(ticket.key) { model.open(ticket.url) }
                    .buttonStyle(.link)
                    .scaled(.callout.monospaced())
                    .frame(width: 84 * scale, alignment: .leading)
                Text(ticket.summary).lineLimit(1)
                Spacer()
                if let drift = model.state.drift(forKey: ticket.key) {
                    DriftButton(drift: drift, model: model)
                }
                PlanButton(ticket: ticket, model: model) { repo in
                    planNote = ""
                    planning = PlanRequest(ticket: ticket, repo: repo)
                }
                if let priority = ticket.priority {
                    Text(priority).scaled(.caption).foregroundStyle(.tertiary)
                }
            }
            if expanded.contains(ticket.key) {
                MarkdownText(text: ticket.description)
                    .padding(.leading, 20 * scale)
                    .padding(.bottom, 4)
            }
        }
        .padding(.leading, 18)
    }

    /// The accordion. Absent rather than disabled on a ticket with nothing to show, but still taking its
    /// width, so every key in the list stays in one column.
    @ViewBuilder private func disclosure(_ ticket: Ticket) -> some View {
        let isOpen = expanded.contains(ticket.key)
        Group {
            if ticket.description.isEmpty {
                Color.clear
            } else {
                Button {
                    if isOpen { expanded.remove(ticket.key) } else { expanded.insert(ticket.key) }
                } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Hide the description" : "Read the description")
            }
        }
        .scaled(.caption)
        .frame(width: 10 * scale)
    }

    private func color(_ category: TicketStatusCategory) -> Color {
        switch category {
        case .todo: return .secondary
        case .inProgress: return .blue
        case .done: return .green
        case .unknown: return .orange
        }
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
