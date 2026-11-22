import AppKit
import DeskCore
import SwiftUI

struct DeskWindow: View {
    static let id = "desk"

    enum Tab: String, CaseIterable, Identifiable {
        case focus, pullRequests, reviews, tickets

        var id: Tab { self }

        var title: String {
            switch self {
            case .focus: return "Focus"
            case .pullRequests: return "Tasks"
            case .reviews: return "Reviews"
            case .tickets: return "Jira"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = Tab(rawValue: ProcessInfo.processInfo.environment["FHENIX_DESK_OPEN_WINDOW"] ?? "") ?? .focus
    /// Whether the sidebar shows, as its toggle and ⌃⌘S leave it; setup hides it without changing this.
    @State private var columns = NavigationSplitViewVisibility.all
    /// How many review diffs are on screen — two for a moment, as one replaces another — and the sidebar as it was before
    /// the first folded it away, put back when the last goes.
    @State private var reviewDiffs = 0
    @State private var columnsBeforeReview = NavigationSplitViewVisibility.all
    private var filters = ReviewFilters()
    private var tickets = TicketFilters()

    /// Snapshots set this: the sidebar beside the screen in a plain row, since the split view's sidebar column draws
    /// nothing off screen.
    nonisolated(unsafe) static var flat = false
    /// Snapshots set this: the text scale is theirs to give (`scale=`), not the screen's the off-screen window is near.
    nonisolated(unsafe) static var followsScreen = true

    var body: some View {
        // The sidebar stays while Settings or the Master screen is open, so you never lose your place. Setup takes the
        // sidebar's place, its toggle gone with it.
        Group {
            if Self.flat {
                HStack(spacing: 0) {
                    if !model.showingSetup {
                        sidebar.frame(width: Theme.sidebarWidth * model.textScale)
                        Rectangle().fill(Theme.rule).frame(width: 1)
                    }
                    detail
                }
            } else {
                NavigationSplitView(columnVisibility: model.showingSetup ? .constant(.detailOnly) : $columns) {
                    sidebar
                } detail: {
                    detail
                }
            }
        }
        .environment(\.reviewRoom, reviewRoom)
        // Each screen's header says where you are.
        .toolbar(removing: .title)
        // Dimmed, not blurred: a blur filter on the window — even at radius 0 — draws it through an offscreen
        // image, and its text comes out soft.
        .overlay { if model.showingFinder { FinderView() } }
        .appFont()
        // A wider screen, larger text: the scale follows the screen the window is on.
        .environment(\.textScale, model.textScale)
        .background(ScreenReader { screen in
            guard Self.followsScreen else { return }
            let scale = CGFloat(ScreenTextScale.scale(forWidth: Double(screen.frame.width)))
            if model.textScale != scale { model.textScale = scale }
        })
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        // The accent is read as a colour draws: a new one rebuilds the window.
        .id(model.config.accent)
        // A regular app while the window shows, so ⌘-Tab and the Dock can bring it back.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        // The menu bar and the nudges ask for a tab by setting this; clearing it keeps it a one-shot.
        .onChange(of: model.pendingTab, initial: true) { _, requested in
            guard let requested else { return }
            choose(requested)
            model.pendingTab = nil
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private var detail: some View {
        Group {
            if model.showingSetup { SetupView() }
            else if model.showingSettings { SettingsView() }
            else if model.showingMaster { MasterScreen() }
            else { screen }
        }
        // No minimum height: the split view sizes itself to its columns' minimum, worked out at their narrowest, where a
        // page's title squeezed by its buttons wraps a word to a line. That came out taller than the window, and the page
        // drifted up under its top edge. Each screen fills the height it gets and scrolls within it.
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Theme.ground.ignoresSafeArea())
    }

    /// Instrument's sidebar: the app's mark, Search, the four screens with their counts, and pinned under them the
    /// master, the sync status and your accounts, which open Settings.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                AppMark()
                Text("Fhenix Desk").scaled(.body.weight(.semibold))
            }
            .frame(height: 32)
            .padding(.horizontal, 8)
            Button { model.showingFinder = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                    Text("Search")
                    Spacer(minLength: 4)
                    Text("⌘K").scaled(.caption.monospaced())
                }
                .foregroundStyle(Theme.quiet)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.ruleStrong))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search, ⌘K")
            VStack(spacing: 1) {
                ForEach(Tab.allCases) { item in navItem(item) }
            }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                UpdateNotice()
                MasterStatus()
                SidebarStatus()
                AccountFooter(selected: model.showingSettings) {
                    model.showingMaster = false
                    model.showingSettings = true
                }
            }
        }
        .padding(EdgeInsets(top: 18, leading: 10, bottom: 14, trailing: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel.ignoresSafeArea())
        .toolbar(removing: model.showingSetup ? .sidebarToggle : nil)
        // Outermost, or the split view does not see it.
        .navigationSplitViewColumnWidth(min: 212 * model.textScale, ideal: Theme.sidebarWidth * model.textScale, max: 300 * model.textScale)
    }

    private func navItem(_ item: Tab) -> some View {
        let selected = !model.showingSettings && !model.showingMaster && tab == item
        return NavItem(title: item.title, count: badge(for: item), selected: selected) { choose(item) }
    }

    private func choose(_ item: Tab) {
        tab = item
        model.showingSettings = false
        model.showingMaster = false
    }

    /// A review diff wants the window's width for its code: the first on screen folds the sidebar away, the last to go
    /// puts it back as it was. ⌃⌘S still shows it in between.
    private func reviewRoom(_ taking: Bool) {
        if taking {
            if reviewDiffs == 0 {
                columnsBeforeReview = columns
                columns = .detailOnly
            }
            reviewDiffs += 1
        } else {
            reviewDiffs -= 1
            if reviewDiffs == 0 { columns = columnsBeforeReview }
        }
    }

    @ViewBuilder private var screen: some View {
        switch tab {
        case .focus: FocusTab()
        case .pullRequests: PullRequestsTab()
        case .reviews: ReviewsTab()
        case .tickets: TicketsTab()
        }
    }

    /// The count beside each screen: Focus its items at Now and Next, Tasks the open tasks, Reviews its Needs you scope inside
    /// its filters, and Jira the tickets in its placement and assignee filter.
    private func badge(for tab: Tab) -> Int {
        switch tab {
        case .focus: return model.focusCount(filters)
        case .tickets: return model.state.ticketGroups(tickets.placement, assignees: tickets.assignees).reduce(0) { $0 + $1.tickets.count }
        case .pullRequests: return model.state.tasks.count
        case .reviews: return model.state.reviewQueue(.needsYou, days: filters.window, hiding: filters.hidden, needingApproval: filters.needsApproval).count
        }
    }
}

/// The app's mark: an F on the accent, the way Nightshift marks a workspace.
struct AppMark: View {
    var size: CGFloat = 20

    var body: some View {
        Text("F").font(.custom(AppFonts.sans, fixedSize: size * 0.55).weight(.semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: size / 4))
            .accessibilityHidden(true)
    }
}

/// One screen in the sidebar: its name, and its count in DM Mono.
private struct NavItem: View {
    var title: String
    var count: Int
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).scaled(selected ? .body.weight(.medium) : .body)
                Spacer(minLength: 4)
                if count > 0 { Text("\(count)").scaled(.caption.monospaced()).foregroundStyle(selected ? Theme.ink : Theme.quiet) }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityValue(count > 0 ? "\(count)" : "")
    }
}

/// Under a hairline at the sidebar's foot: who you are on GitHub and the way to Settings. An account not signed in shows
/// in the sync detail.
private struct AccountFooter: View {
    @Environment(AppModel.self) private var model
    var selected: Bool
    var action: () -> Void

    var body: some View {
        let login = model.state.login
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(login.isEmpty ? "Not signed in to GitHub" : login).foregroundStyle(Theme.ink).fontWeight(.medium)
                Text("Settings ⌘,")
            }
            .scaled(.secondary)
            .foregroundStyle(Theme.quiet)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 10, leading: 8, bottom: selected ? 8 : 0, trailing: 8))
            .background(selected ? Theme.selected : .clear, in: UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6))
            .overlay(alignment: .top) { Rectangle().fill(Theme.ruleStrong).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

}

/// A page a tab opens over its list: a PR's, by url. Each tab keeps a path of these, so Back, ⌘[ and ← return to the
/// list with its row still selected. A task and a ticket have none: their details column is them.
enum Route: Hashable {
    case pr(String)
}

extension FocusedValues {
    /// The path of the tab on show, for Go → Back.
    @Entry var routePath: Binding<[Route]>?
}

extension EnvironmentValues {
    /// Told true as a review diff comes on screen and false as it goes, so the window can make room for it.
    @Entry var reviewRoom: @MainActor (Bool) -> Void = { _ in }
}

/// A tab's list, or the page on top of its path in place of it.
struct RouteStack<Root: View>: View {
    @Binding var path: [Route]
    /// The tab, which a page's back link names.
    var back: String
    @ViewBuilder var root: Root

    var body: some View {
        if let route = path.last {
            RoutePage(route: route, back: back, path: $path)
        } else {
            root
        }
    }
}

/// The page a route opens: your PR's own page, someone else's PR as the review queue shows it — its diff while you
/// review it — or a ticket's. Keyed by the route, so nothing typed on one page carries over to the next.
struct RoutePage: View {
    var route: Route
    /// The tab it opened on, which the back link names.
    var back: String
    @Binding var path: [Route]
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch route {
            case .pr(let url):
                if let pr = model.yourPullRequest(url) {
                    PullRequestPage(pr: pr, model: model, back: back, onBack: pop)
                } else if let pr = model.state.github?.allOpen.first(where: { $0.url == url }) {
                    // Start review swaps the page for the diff; back from the diff is the page again.
                    if model.reviewing == url {
                        ReviewDiffScreen(pr: pr, model: model) { model.reviewing = nil }
                    } else {
                        let onMe = model.state.reviewRequests.contains { $0.url == url }
                        ReviewPage(pr: pr, model: model, onMe: onMe, back: back, onBack: pop)
                    }
                } else {
                    gone
                }
            }
        }
        .id(route)
    }

    /// Gone from every list since it opened, merged or closed by someone else: there is nothing to show, so back to the
    /// list.
    private var gone: some View { Color.clear.onAppear(perform: pop) }

    private func pop() {
        if !path.isEmpty { path.removeLast() }
    }
}

