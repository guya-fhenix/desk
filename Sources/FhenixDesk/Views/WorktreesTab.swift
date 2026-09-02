import DeskCore
import SwiftUI

struct WorktreesTab: View {
    @Environment(AppModel.self) private var model
    /// Empty until a header is clicked: the scan already orders by repo with the main worktree first.
    @State private var sortOrder: [KeyPathComparator<Worktree>] = []

    private var worktrees: [Worktree] {
        sortOrder.isEmpty ? model.state.worktrees : model.state.worktrees.sorted(using: sortOrder)
    }

    var body: some View {
        Table(worktrees, sortOrder: $sortOrder) {
            TableColumn("Repo", value: \.repoName) { worktree in Text(worktree.repoName) }.width(min: 90, ideal: 110)
            TableColumn("Worktree", value: \.name) { worktree in
                Text(worktree.isMain ? "(main)" : worktree.name).foregroundStyle(worktree.isMain ? .secondary : .primary)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Branch", value: \.branch, comparator: OptionalComparator()) { worktree in
                Text(worktree.branch ?? "detached").lineLimit(1)
            }
            .width(min: 140, ideal: 190)
            TableColumn("State") { worktree in
                HStack(spacing: 4) {
                    if worktree.isPrunable { Chip(text: "prunable", color: .red) }
                    if worktree.dirtyFiles > 0 { Chip(text: "\(worktree.dirtyFiles) dirty", color: .orange) }
                    if worktree.ahead > 0 { Chip(text: "↑\(worktree.ahead)", color: .blue) }
                    if worktree.behind > 0 { Chip(text: "↓\(worktree.behind)", color: .secondary) }
                    if !worktree.hasUpstream && !worktree.isOnDefaultBranch { Chip(text: "no upstream", color: .orange) }
                }
            }
            .width(min: 100, ideal: 120)
            TableColumn("Behind default", value: \.behindDefault) { worktree in
                Text(worktree.behindDefault > 0 ? "\(worktree.behindDefault) behind \(worktree.defaultBranch)" : "–").font(.caption).monospacedDigit()
            }
            .width(100)
            TableColumn("Last commit", value: \.lastCommitAt, comparator: OptionalComparator()) { worktree in
                Text(Format.age(worktree.lastCommitAt)).monospacedDigit()
            }
            .width(80)
            TableColumn("Claude") { worktree in
                if let live = model.state.liveSession(for: worktree) {
                    HStack(spacing: 4) { LiveStatusDot(session: live); Text(live.status.rawValue).font(.caption) }
                }
            }
            .width(70)
            TableColumn("") { worktree in
                HStack(spacing: 4) {
                    Button { model.reveal(worktree.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Reveal in Finder")
                    Button { model.openTerminal(worktree.path) } label: { Image(systemName: "terminal") }.buttonStyle(.borderless).help("Open in Terminal")
                }
            }
            .width(60)
        }
        .navigationTitle("Worktrees")
        .overlay {
            if model.state.worktrees.isEmpty { EmptyText(text: model.state.errors[.git] ?? "Scanning repos…").padding() }
        }
    }
}

struct ClaudeTab: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\LiveSession.startedAt, order: .reverse)]

    var body: some View {
        Table(model.state.aliveSessions.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("") { session in LiveStatusDot(session: session) }.width(16)
            TableColumn("Session", value: \.name) { session in Text(session.name).lineLimit(1) }.width(min: 160, ideal: 280)
            TableColumn("Kind", value: \.kind.rawValue) { session in Text(session.kind.rawValue) }.width(80)
            TableColumn("Status", value: \.status.rawValue) { session in
                Text(session.status.rawValue).foregroundStyle(session.waitsForInput ? .orange : .primary)
            }
            .width(70)
            TableColumn("Since", value: \.statusUpdatedAt, comparator: OptionalComparator()) { session in
                Text(Format.age(session.statusUpdatedAt)).monospacedDigit()
            }
            .width(60)
            TableColumn("Where", value: \.cwd) { session in Text(relative(session.cwd)).lineLimit(1) }.width(min: 160, ideal: 300)
            TableColumn("Started", value: \.startedAt) { session in Text(Format.age(session.startedAt)).monospacedDigit() }.width(70)
            TableColumn("") { session in
                Button { model.openTerminal(session.cwd) } label: { Image(systemName: "terminal") }.buttonStyle(.borderless)
            }
            .width(30)
        }
        .navigationTitle("Claude")
        .overlay {
            if model.state.aliveSessions.isEmpty { EmptyText(text: "No open Claude sessions.").padding() }
        }
    }

    private func relative(_ path: String) -> String {
        for root in model.config.expandedRepoRoots where path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
