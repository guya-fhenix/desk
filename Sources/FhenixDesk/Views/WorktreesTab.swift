import DeskCore
import SwiftUI

struct WorktreesTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Table(model.state.worktrees) {
            TableColumn("Repo") { worktree in Text(worktree.repoName) }.width(min: 90, ideal: 110)
            TableColumn("Worktree") { worktree in
                Text(worktree.isMain ? "(main)" : worktree.name).foregroundStyle(worktree.isMain ? .secondary : .primary)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Branch") { worktree in Text(worktree.branch ?? "detached").lineLimit(1) }.width(min: 140, ideal: 190)
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
            TableColumn("Behind default") { worktree in
                Text(worktree.behindDefault > 0 ? "\(worktree.behindDefault) behind \(worktree.defaultBranch)" : "–").font(.caption).monospacedDigit()
            }
            .width(100)
            TableColumn("Last commit") { worktree in Text(Format.age(worktree.lastCommitAt)).monospacedDigit() }.width(80)
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
    private static let recentLimit = 60

    var body: some View {
        VStack(spacing: 0) {
            Table(model.state.liveSessions) {
                TableColumn("") { session in LiveStatusDot(session: session) }.width(16)
                TableColumn("Session") { session in Text(session.name).lineLimit(1) }.width(min: 160, ideal: 260)
                TableColumn("Kind") { session in Text(session.kind.rawValue) }.width(80)
                TableColumn("Status") { session in
                    Text(session.isAlive ? session.status.rawValue : "dead").foregroundStyle(session.waitsForInput ? .orange : .primary)
                }
                .width(70)
                TableColumn("Since") { session in Text(Format.age(session.statusUpdatedAt)).monospacedDigit() }.width(60)
                TableColumn("Where") { session in Text(relative(session.cwd)).lineLimit(1) }.width(min: 160, ideal: 300)
                TableColumn("Started") { session in Text(Format.age(session.startedAt)).monospacedDigit() }.width(70)
                TableColumn("") { session in
                    Button { model.openTerminal(session.cwd) } label: { Image(systemName: "terminal") }.buttonStyle(.borderless)
                }
                .width(30)
            }
            .frame(minHeight: 120, idealHeight: 200, maxHeight: 260)
            Divider()
            Table(Array(model.state.sessions.prefix(Self.recentLimit))) {
                TableColumn("Session") { session in
                    HStack(spacing: 6) {
                        if let live = model.state.liveSessions.first(where: { $0.sessionId == session.sessionId }), live.isAlive { LiveStatusDot(session: live) }
                        Text(session.displayName).lineLimit(1)
                    }
                }
                .width(min: 200, ideal: 320)
                TableColumn("Where") { session in Text(session.cwd.map(relative) ?? "–").lineLimit(1) }.width(min: 140, ideal: 220)
                TableColumn("Branch") { session in Text(session.branches.last ?? "–").lineLimit(1) }.width(min: 140, ideal: 220)
                TableColumn("Prompts") { session in Text("\(session.humanPrompts)").monospacedDigit() }.width(60)
                TableColumn("PRs") { session in
                    HStack(spacing: 4) {
                        ForEach(session.prLinks.prefix(3), id: \.url) { link in
                            Button("#\(link.number)") { model.open(link.url) }.buttonStyle(.link).font(.caption)
                        }
                    }
                }
                .width(110)
                TableColumn("Cost") { session in Text(Format.usd(session.costUSD)).monospacedDigit() }.width(60)
                TableColumn("Time") { session in Text(Format.duration(session.totalDurationMs.map { Double($0) / 1000 })).monospacedDigit() }.width(60)
                TableColumn("Active") { session in Text(Format.age(session.lastActivityAt)).monospacedDigit() }.width(60)
            }
        }
        .navigationTitle("Claude")
    }

    private func relative(_ path: String) -> String {
        for root in model.config.expandedRepoRoots where path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
