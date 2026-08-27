import DeskCore
import SwiftUI

struct DeskWindow: View {
    static let id = "desk"

    enum Tab: String, CaseIterable, Identifiable {
        case overview, pullRequests, reviews, work, worktrees, claude, metrics, settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .pullRequests: return "Pull Requests"
            case .reviews: return "Reviews"
            case .work: return "Work"
            case .worktrees: return "Worktrees"
            case .claude: return "Claude"
            case .metrics: return "Metrics"
            case .settings: return "Settings"
            }
        }

        var icon: String {
            switch self {
            case .overview: return "bell.badge"
            case .pullRequests: return "arrow.triangle.pull"
            case .reviews: return "eye"
            case .work: return "rectangle.3.group"
            case .worktrees: return "folder.badge.gearshape"
            case .claude: return "sparkles"
            case .metrics: return "chart.bar"
            case .settings: return "gearshape"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab? = Tab(rawValue: ProcessInfo.processInfo.environment["FHENIX_DESK_OPEN_WINDOW"] ?? "") ?? .overview

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { tab in
                Label(tab.title, systemImage: tab.icon).badge(badge(for: tab))
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch tab ?? .overview {
            case .overview: OverviewTab()
            case .pullRequests: PullRequestsTab()
            case .reviews: ReviewsTab()
            case .work: WorkTab()
            case .worktrees: WorktreesTab()
            case .claude: ClaudeTab()
            case .metrics: MetricsTab()
            case .settings: SettingsTab()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if !model.refreshing.isEmpty { ProgressView().controlSize(.small) }
                if !model.state.errors.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help(model.state.errors.map { "\($0.key.title): \($0.value)" }.joined(separator: "\n"))
                }
                Button { model.refreshAll() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh all")
            }
        }
    }

    private func badge(for tab: Tab) -> Int {
        switch tab {
        case .overview: return model.urgentCount
        case .pullRequests: return model.state.mine.count
        case .reviews: return model.state.humanReviewRequests.count
        case .claude: return model.state.aliveSessions.filter(\.waitsForInput).count
        default: return 0
        }
    }
}

struct OverviewTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                HStack(spacing: 24) {
                    counter("Open PRs", model.state.mine.count)
                    counter("Reviews on me", model.state.humanReviewRequests.count)
                    counter("Bot PRs", model.state.botReviewRequests.count)
                    counter("Live Claude", model.state.aliveSessions.count)
                    counter("In progress", model.state.tickets.filter { $0.assignedToMe && $0.category == .inProgress }.count)
                }
                .padding(.vertical, 4)
            }
            ForEach([NudgeSeverity.urgent, .warning, .info], id: \.self) { severity in
                let rows = model.state.nudges.filter { $0.severity == severity }
                if !rows.isEmpty {
                    Section(title(severity)) {
                        ForEach(rows) { nudge in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                SeverityDot(severity: nudge.severity).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(nudge.title)
                                    Text(nudge.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if nudge.url != nil || nudge.path != nil {
                                    Button(nudge.url != nil ? "Open" : "Terminal") { model.act(on: nudge) }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }
            if model.state.nudges.isEmpty {
                Section { EmptyText(text: "Nothing waits for you.") }
            }
            if !model.state.errors.isEmpty {
                Section("Source errors") {
                    ForEach(Array(model.state.errors.keys), id: \.self) { source in
                        Text("\(source.title): \(model.state.errors[source] ?? "")").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Overview")
    }

    private func counter(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func title(_ severity: NudgeSeverity) -> String {
        switch severity {
        case .urgent: return "Urgent"
        case .warning: return "Needs action"
        case .info: return "Good to know"
        }
    }
}
