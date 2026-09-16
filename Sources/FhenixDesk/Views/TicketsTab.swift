import DeskCore
import SwiftUI

/// Your Jira tickets by status, split by whether they are in the running sprint or waiting in the
/// backlog. Done is left out: the screen is about what is still open.
struct TicketsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale: Double

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
        HStack(spacing: 8) {
            Button(ticket.key) { model.open(ticket.url) }
                .buttonStyle(.link)
                .scaled(.callout.monospaced())
                .frame(width: 84 * scale, alignment: .leading)
            Text(ticket.summary).lineLimit(1)
            Spacer()
            if let drift = model.state.drift(forKey: ticket.key) {
                DriftButton(drift: drift, model: model)
            }
            if let priority = ticket.priority {
                Text(priority).scaled(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 18)
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
