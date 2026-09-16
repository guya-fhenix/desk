import AppKit
import DeskCore
import SwiftUI

struct DeskWindow: View {
    static let id = "desk"

    enum Tab: String, CaseIterable, Identifiable {
        case tickets, pullRequests, reviews, metrics, settings

        /// The row tag must be the same type as the selection binding, or clicks never select.
        var id: Tab { self }

        var title: String {
            switch self {
            case .tickets: return "Tickets"
            case .pullRequests: return "Pull Requests"
            case .reviews: return "Reviews"
            case .metrics: return "Metrics"
            case .settings: return "Settings"
            }
        }

        var icon: String {
            switch self {
            case .tickets: return "checklist"
            case .pullRequests: return "arrow.triangle.pull"
            case .reviews: return "eye"
            case .metrics: return "chart.bar"
            case .settings: return "gearshape"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab? = Tab(rawValue: ProcessInfo.processInfo.environment["FHENIX_DESK_OPEN_WINDOW"] ?? "") ?? .tickets

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
            List(Tab.allCases, selection: $tab) { tab in
                Label(tab.title, systemImage: tab.icon).badge(badge(for: tab))
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch tab ?? .tickets {
            case .tickets: TicketsTab()
            case .pullRequests: PullRequestsTab()
            case .reviews: ReviewsTab()
            case .metrics: MetricsTab()
            case .settings: SettingsTab()
            }
        }
    }

    /// The badge is what waits for you on that screen, so the sidebar is the whole to-do list.
    private func badge(for tab: Tab) -> Int {
        switch tab {
        case .tickets: return model.state.openTickets.count
        case .pullRequests: return model.state.waiting(on: .pullRequests)
        case .reviews: return model.state.waiting(on: .reviews)
        default: return 0
        }
    }
}
