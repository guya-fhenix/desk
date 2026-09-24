import AppKit
import DeskCore
import SwiftUI

struct DeskWindow: View {
    static let id = "desk"

    enum Tab: String, CaseIterable, Identifiable {
        case today, pullRequests, reviews, tickets, metrics

        /// The row tag must be the same type as the selection binding, or clicks never select.
        var id: Tab { self }

        var title: String {
            switch self {
            case .today: return "Today"
            case .pullRequests: return "Pull Requests"
            case .reviews: return "Reviews"
            case .tickets: return "Tickets"
            case .metrics: return "Metrics"
            }
        }

        var icon: String {
            switch self {
            case .today: return "tray"
            case .pullRequests: return "arrow.triangle.pull"
            case .reviews: return "eye"
            case .tickets: return "checklist"
            case .metrics: return "chart.bar"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab? = Tab(rawValue: ProcessInfo.processInfo.environment["FHENIX_DESK_OPEN_WINDOW"] ?? "") ?? .today

    var body: some View {
        splitView
            .textScale(model.textScale)
        // A regular app while the window shows, so ⌘-Tab and the Dock can bring it back.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        // The menu bar and the nudges ask for a tab by setting this; clearing it keeps it a one-shot.
        .onChange(of: model.pendingTab) { _, requested in
            guard let requested else { return }
            tab = requested
            model.pendingTab = nil
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        // Toolbar items live in their own hosting view, which AppKit keeps updating after the window
        // closes while the window's environment is gone. The item carries the model itself so a late
        // update cannot hit "No Observable object of type AppModel found".
        .toolbar {
            ToolbarItem(placement: .primaryAction) { TextSizeControl().environment(model) }
            ToolbarItem(placement: .primaryAction) { RefreshControl().environment(model) }
        }
    }

    /// The window's whole content, apart from the toolbar: the toolbar keeps the system size at every
    /// setting, so the control that changes the text never moves under the pointer.
    private var splitView: some View {
        NavigationSplitView {
            List(selection: $tab) {
                row(.today)
                Section("Work") {
                    row(.pullRequests)
                    row(.reviews)
                    row(.tickets)
                }
                Section("Insights") { row(.metrics) }
            }
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch tab ?? .today {
            case .today: TodayTab()
            case .pullRequests: PullRequestsTab()
            case .reviews: ReviewsTab()
            case .tickets: TicketsTab()
            case .metrics: MetricsTab()
            }
        }
    }

    private func row(_ tab: Tab) -> some View {
        Label(tab.title, systemImage: tab.icon).badge(badge(for: tab)).tag(tab)
    }

    /// The badge is what waits for you on that screen, so the sidebar is the whole to-do list. Today counts
    /// only what is urgent — the same number the menu bar icon shows — or it would repeat the other three.
    private func badge(for tab: Tab) -> Int {
        switch tab {
        case .today: return model.urgentCount
        case .tickets: return model.state.openTickets.count
        case .pullRequests: return model.state.waiting(on: .pullRequests)
        case .reviews: return model.state.waiting(on: .reviews)
        case .metrics: return 0
        }
    }
}

/// Pinned under the sidebar: the way into Settings, drawn as one more sidebar row, then a quiet status
/// strip — what is running and whether each source answered.
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsLink {
                HStack(spacing: 7) {
                    Image(systemName: "gearshape").foregroundStyle(.tint).frame(width: 18)
                    Text("Settings")
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                if let running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(running).scaled(.caption).foregroundStyle(.secondary)
                    }
                }
                SourceDots()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
    }

    private var running: String? {
        let reviews = model.busyReviews.count
        let sessions = model.state.claudeJobs.count { $0.isRunning }
        var parts: [String] = []
        if reviews > 0 { parts.append("\(reviews) \(reviews == 1 ? "review" : "reviews")") }
        if sessions > 0 { parts.append("\(sessions) \(sessions == 1 ? "session" : "sessions")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ") + " running"
    }
}

/// One dot per source: green once it answered, red with the error as its tooltip, grey before the first poll.
struct SourceDots: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Source.allCases, id: \.self) { source in
                HStack(spacing: 3) {
                    StatusDot(color: model.state.errors[source] == nil ? (model.state.lastRefresh[source] == nil ? .gray : .green) : .red)
                    Text(source.title).scaled(.caption2).foregroundStyle(.secondary)
                }
                .help(model.state.errors[source] ?? "Updated \(Format.age(model.state.lastRefresh[source])) ago")
            }
        }
    }
}

/// The trailing inspector the table screens share, and the toolbar button that shows and hides it. The
/// flag is remembered per screen, so closing it on one does not close it everywhere.
extension View {
    /// `width` is where the column starts; the user can drag it anywhere from 260 to 560.
    func deskInspector<Inspector: View>(
        _ key: String, width: CGFloat = 300, @ViewBuilder content: @escaping () -> Inspector
    ) -> some View {
        modifier(DeskInspector(key: key, width: width, inspector: content))
    }
}

private struct DeskInspector<Inspector: View>: ViewModifier {
    @AppStorage private var shown: Bool
    let width: CGFloat
    let inspector: () -> Inspector

    init(key: String, width: CGFloat, inspector: @escaping () -> Inspector) {
        self.width = width
        _shown = AppStorage(wrappedValue: true, "inspector.\(key)")
        self.inspector = inspector
    }

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: $shown) {
                inspector()
                    // A grouped form in a column this narrow runs its cards under the scroller; this lane
                    // keeps them clear of it, and the scroller stays at the edge.
                    .contentMargins(.trailing, 14, for: .scrollContent)
                    .inspectorColumnWidth(min: 260, ideal: width, max: 560)
            }
            // On the content, not inside the inspector: there it would leave with the column it reopens.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { shown.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                        .help(shown ? "Hide the inspector" : "Show the inspector")
                }
            }
    }
}
