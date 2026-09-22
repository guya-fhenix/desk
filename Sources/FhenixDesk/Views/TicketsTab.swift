import DeskCore
import SwiftUI

/// Your Jira tickets by status, split by whether they are in the running sprint or waiting in the
/// backlog. Done is left out: the screen is about what is still open.
struct TicketsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale: Double
    /// Which descriptions are open. By key, so a poll that replaces every ticket leaves them open.
    @State private var expanded: Set<String> = []

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
                PlanButton(ticket: ticket, model: model)
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

/// Where a ticket's pull requests say it should be, and the press that moves it. The only thing in this
/// app that writes to Jira — so it names the pull requests it is arguing from, and it is never automatic.
private struct DriftButton: View {
    var drift: TicketDrift
    var model: AppModel

    var body: some View {
        if model.movingTickets.contains(drift.ticket.key) {
            ProgressView().controlSize(.mini)
        } else {
            Button { model.moveTicket(drift) } label: {
                Chip(text: "→ \(drift.target)", color: drift.stage == .done ? .green : .blue)
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }

    private var help: String {
        let prs = drift.pullRequests.map { "\($0.repoName)#\($0.number)" }.joined(separator: ", ")
        let because = drift.stage == .done ? "\(prs) merged" : "\(prs) open for review"
        return "\(because) — move \(drift.ticket.key) to “\(drift.target)”"
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

    var body: some View {
        let repos = (model.state.gitScan?.repos ?? []).sorted { $0.name < $1.name }
        if model.planningTickets.contains(ticket.key) {
            ProgressView().controlSize(.mini).help("Starting a session to plan \(ticket.key)")
        } else if !repos.isEmpty {
            Menu {
                ForEach(repos, id: \.root) { repo in
                    Button(repo.name) { model.planTicket(ticket, in: repo) }
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
