import DeskCore
import SwiftUI

struct WorkTab: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            if model.state.workItems.isEmpty {
                EmptyText(text: "No work items yet. Tickets, PRs, and worktrees show up here.")
            }
            ForEach(model.state.workItems) { item in
                DisclosureGroup(isExpanded: binding(item.id)) {
                    details(item)
                } label: {
                    header(item)
                }
            }
        }
        .navigationTitle("Work")
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { value in if value { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func header(_ item: WorkItem) -> some View {
        HStack(spacing: 8) {
            if !item.liveSessions.isEmpty { StatusDot(color: item.liveSessions.contains { $0.status == .busy } ? .green : .orange) }
            if let key = item.ticketKey {
                Button(key) { model.open(item.ticket?.url ?? "https://\(model.config.jiraSite)/browse/\(key)") }.buttonStyle(.link).font(.callout.weight(.semibold))
            }
            Text(item.ticket?.summary ?? item.pullRequests.first?.title ?? item.worktrees.first?.branch ?? item.id).lineLimit(1)
            Spacer()
            if let ticket = item.ticket { TicketBadge(ticket: ticket) }
            HStack(spacing: 4) {
                if !item.pullRequests.isEmpty { Chip(text: "\(item.pullRequests.count) PR", color: .blue) }
                if !item.worktrees.isEmpty { Chip(text: "\(item.worktrees.count) wt", color: .purple) }
                if !item.sessions.isEmpty { Chip(text: "\(item.sessions.count) sessions", color: .teal) }
                if item.claudeCostUSD > 0 { Chip(text: Format.usd(item.claudeCostUSD), color: .secondary) }
            }
            Text(Format.age(item.lastActivityAt)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }

    private func details(_ item: WorkItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(item.pullRequests) { pr in PullRequestLine(pr: pr) }
            ForEach(item.worktrees) { worktree in
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.purple)
                    Text("\(worktree.repoName)/\(worktree.name)").font(.callout)
                    Text(worktree.branch ?? "detached").font(.caption).foregroundStyle(.secondary)
                    if worktree.dirtyFiles > 0 { Chip(text: "\(worktree.dirtyFiles) dirty", color: .orange) }
                    if worktree.ahead > 0 { Chip(text: "↑\(worktree.ahead)", color: .blue) }
                    if worktree.behindDefault > 0 { Chip(text: "\(worktree.behindDefault) behind \(worktree.defaultBranch)", color: .secondary) }
                    Spacer()
                    Button("Terminal") { model.openTerminal(worktree.path) }.controlSize(.mini)
                }
            }
            ForEach(item.sessions.prefix(8)) { session in
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(.teal)
                    Text(session.displayName).font(.callout).lineLimit(1)
                    Text(session.branches.last ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text("\(session.humanPrompts) prompts").font(.caption).foregroundStyle(.secondary)
                    if let cost = session.costUSD { Text(Format.usd(cost)).font(.caption).foregroundStyle(.secondary) }
                    if let ms = session.totalDurationMs { Text(Format.duration(Double(ms) / 1000)).font(.caption).foregroundStyle(.secondary) }
                    Text(Format.age(session.lastActivityAt)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
            if item.sessions.count > 8 {
                Text("+\(item.sessions.count - 8) older sessions").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
    }
}
