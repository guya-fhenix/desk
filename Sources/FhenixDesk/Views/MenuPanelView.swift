import AppKit
import DeskCore
import SwiftUI

struct MenuPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private static let maxNudges = 6
    private static let maxReviews = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nudges
                    myPullRequests
                    reviewQueue
                    claude
                }
                .padding(.trailing, 4)
            }
            footer
        }
        .padding(12)
        .frame(width: 420)
        .frame(maxHeight: 660)
    }

    private var header: some View {
        HStack {
            Text("Fhenix Desk").font(.title3.weight(.semibold))
            Spacer()
            if !model.refreshing.isEmpty { ProgressView().controlSize(.small) }
            Button { model.refreshAll() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh all")
            Button("Open Desk") {
                openWindow(id: DeskWindow.id)
                NSApp.activate()
            }
            .controlSize(.small)
        }
    }

    private var nudges: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Waits for you", count: model.state.nudges.count)
            if model.state.nudges.isEmpty {
                EmptyText(text: "Nothing waits. Good.")
            }
            ForEach(model.state.nudges.prefix(Self.maxNudges)) { nudge in
                Button { model.act(on: nudge) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SeverityDot(severity: nudge.severity).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(nudge.title).font(.callout).lineLimit(1)
                            Text(nudge.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if model.state.nudges.count > Self.maxNudges {
                Text("+\(model.state.nudges.count - Self.maxNudges) more in Desk").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var myPullRequests: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "My PRs", count: model.state.mine.count)
            if model.state.mine.isEmpty { EmptyText(text: model.state.github == nil ? "Loading GitHub…" : "No open PRs.") }
            ForEach(groupedByRepo(model.state.mine), id: \.repo) { group in
                Text(group.repo).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(group.prs) { pr in PullRequestLine(pr: pr, showRepo: false) }
            }
        }
    }

    private var reviewQueue: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "Review queue", count: model.state.humanReviewRequests.count)
                if !model.state.botReviewRequests.isEmpty {
                    Chip(text: "+\(model.state.botReviewRequests.count) bots", color: .secondary)
                }
            }
            if model.state.humanReviewRequests.isEmpty { EmptyText(text: "No reviews wait on you.") }
            ForEach(model.state.humanReviewRequests.sorted { $0.createdAt < $1.createdAt }.prefix(Self.maxReviews)) { pr in
                PullRequestLine(pr: pr)
            }
        }
    }

    private var claude: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Claude", count: model.state.aliveSessions.count)
            if model.state.aliveSessions.isEmpty { EmptyText(text: "No live sessions.") }
            ForEach(model.state.aliveSessions) { session in
                Button { model.openTerminal(session.cwd) } label: {
                    HStack(spacing: 8) {
                        LiveStatusDot(session: session)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.name).font(.callout).lineLimit(1)
                            Text(relativePath(session.cwd)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(session.status == .idle ? "idle \(Format.age(session.statusUpdatedAt))" : session.status.rawValue)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ForEach(Source.allCases, id: \.self) { source in
                HStack(spacing: 3) {
                    StatusDot(color: model.state.errors[source] == nil ? (model.state.lastRefresh[source] == nil ? .gray : .green) : .red)
                    Text(source.title).font(.caption2).foregroundStyle(.secondary)
                }
                .help(model.state.errors[source] ?? "Updated \(Format.age(model.state.lastRefresh[source])) ago")
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func groupedByRepo(_ prs: [PullRequest]) -> [(repo: String, prs: [PullRequest])] {
        Dictionary(grouping: prs, by: \.repoName)
            .map { (repo: $0.key, prs: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { $0.repo < $1.repo }
    }

    private func relativePath(_ path: String) -> String {
        let roots = model.config.expandedRepoRoots
        for root in roots where path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
