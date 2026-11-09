import AppKit
import DeskCore
import SwiftUI

struct DeskWindow: View {
    static let id = "desk"

    enum Tab: String, CaseIterable, Identifiable {
        case upNext, pullRequests, reviews, tickets

        /// The row tag must be the same type as the selection binding, or clicks never select.
        var id: Tab { self }

        var title: String {
            switch self {
            case .upNext: return "Up Next"
            case .pullRequests: return "Pull Requests"
            case .reviews: return "Reviews"
            case .tickets: return "Jira"
            }
        }

        /// The key its details panel remembers its flag under, on the screens that have one.
        var inspectorKey: String? {
            switch self {
            case .tickets: return "tickets"
            // Pull requests and reviews open a page of their own instead.
            case .pullRequests, .reviews, .upNext: return nil
            }
        }

        var icon: String {
            switch self {
            case .upNext: return "tray"
            case .pullRequests: return "arrow.triangle.pull"
            case .reviews: return "bubble.left.and.text.bubble.right"
            case .tickets: return SidebarIcon.jira
            }
        }
    }

    /// What the sidebar has chosen: a tab, or Settings beside the sidebar.
    private enum Choice: Hashable {
        case tab(Tab)
        case settings
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = Tab(rawValue: ProcessInfo.processInfo.environment["FHENIX_DESK_OPEN_WINDOW"] ?? "") ?? .upNext
    /// Whether the sidebar shows, as its toggle and ⌃⌘S leave it; setup hides it without changing this.
    @State private var columns = NavigationSplitViewVisibility.all
    private var filters = ReviewFilters()

    var body: some View {
        // The sidebar stays while Settings is open, with Settings chosen in it, so you never lose your place.
        // Setup takes the sidebar's place, its toggle gone with it, but keeps the terminal panel, where its installs and
        // sign-ins run.
        NavigationSplitView(columnVisibility: model.showingSetup ? .constant(.detailOnly) : $columns) {
            sidebar
        } detail: {
            // The terminal panel on the right, when it has a tab and is not hidden; the divider between drags.
            HSplitView {
                Group { if model.showingSetup { SetupView() } else if model.showingSettings { SettingsView() } else { screen } }
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                if model.terminals.visible, !model.terminals.tabs.isEmpty {
                    TerminalPanelView(panel: model.terminals)
                        .frame(minWidth: 360, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.background.ignoresSafeArea())
        }
        // Each screen's header says where you are.
        .toolbar(removing: .title)
        // Dimmed, not blurred: a blur filter on the window — even at radius 0 — draws it through an offscreen
        // image, and its text comes out soft.
        .overlay { if model.showingFinder { FinderView() } }
        .appFont()
        // A regular app while the window shows, so ⌘-Tab and the Dock can bring it back.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        // The menu bar and the nudges ask for a tab by setting this; clearing it keeps it a one-shot.
        .onChange(of: model.pendingTab, initial: true) { _, requested in
            guard let requested else { return }
            tab = requested
            model.showingSettings = false
            model.pendingTab = nil
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        // View → Show/Hide Details flips the remembered flag of the screen on show; its panel follows the flag.
        .onChange(of: model.inspectorToggleRequest) {
            guard !model.showingSettings, let key = tab.inspectorKey else { return }
            let flag = "inspector.\(key)"
            UserDefaults.standard.set(!(UserDefaults.standard.object(forKey: flag) as? Bool ?? true), forKey: flag)
        }
    }

    /// Search, which opens over the window rather than being chosen, the tabs with their counts, and Settings; the sync
    /// status pinned under them.
    private var sidebar: some View {
        List(selection: choice) {
            Button { model.showingFinder = true } label: {
                HStack(spacing: Theme.Space.s) {
                    Label("Search", systemImage: "magnifyingglass")
                    Spacer(minLength: Theme.Space.xs)
                    HStack(spacing: 3) {
                        KeyCap(key: "⌘")
                        KeyCap(key: "K")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(Tab.allCases) { item in
                Label { Text(item.title) } icon: { SidebarIcon(name: item.icon) }
                    .badge(badge(for: item))
                    .tag(Choice.tab(item))
            }
            Label("Settings", systemImage: "gearshape").tag(Choice.settings)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarStatus().padding(.horizontal, Theme.Space.s).padding(.bottom, Theme.Space.m)
        }
        .toolbar(removing: model.showingSetup ? .sidebarToggle : nil)
        // Outermost, or the split view does not see it.
        .navigationSplitViewColumnWidth(min: 200, ideal: Theme.sidebarWidth, max: 320)
    }

    private var choice: Binding<Choice?> {
        Binding {
            model.showingSettings ? .settings : .tab(tab)
        } set: { choice in
            switch choice {
            case .tab(let item):
                tab = item
                model.showingSettings = false
            case .settings: model.showingSettings = true
            case nil: break
            }
        }
    }

    @ViewBuilder private var screen: some View {
        switch tab {
        case .upNext: UpNextTab()
        case .pullRequests: PullRequestsTab()
        case .reviews: ReviewsTab()
        case .tickets: TicketsTab()
        }
    }

    /// The badge counts the rows the screen opens on: Up Next the rows it lists, Pull Requests every open PR of yours,
    /// drafts too, as its Open tab lists them, Reviews what waits on you inside its filters — not the PRs you reviewed
    /// that wait on their authors.
    private func badge(for tab: Tab) -> Int {
        switch tab {
        case .upNext: return model.upNextCount(filters)
        case .tickets: return model.state.openTickets.count
        case .pullRequests: return model.state.mine.count
        case .reviews: return model.state.reviewQueue(.needsYou, days: filters.window, hiding: filters.hidden, needingApproval: filters.needsApproval).count
        }
    }
}

/// A page a tab opens over its list: a PR's, by url, or a ticket's, by key. Each tab keeps a path of these, so Back,
/// ⌘[ and ← return to the list with its row still selected.
enum Route: Hashable {
    case pr(String)
    case ticket(String)
}

extension FocusedValues {
    /// The path of the tab on show, for Go → Back.
    @Entry var routePath: Binding<[Route]>?
}

/// The page a route opens: your PR's own page, someone else's PR as the review queue shows it — its diff while you
/// review it — or a ticket's. The PR is looked up among every open one, not only the screen's rows: one you just
/// reviewed may leave a filtered list. Keyed by the route, so nothing typed on one page carries over to the next.
struct RoutePage: View {
    var route: Route
    /// The tab it opened on, which the back link names.
    var back: String
    @Binding var path: [Route]
    /// Start in… on a ticket's page, which asks the tab for the plan's note.
    var plan: (Ticket, RepoRef) -> Void = { _, _ in }
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch route {
            case .ticket(let key):
                if let ticket = model.state.ticket(key) {
                    TicketPage(ticket: ticket, model: model, back: back, plan: plan, onBack: pop)
                } else {
                    gone
                }
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

/// The details panel the list screens share, on the right. Its switch sits in the screen's header; the flag is
/// remembered per screen, so closing it on one does not close it everywhere.
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
            // A screen wider than the room beside the panel spills into its own margins rather than pushing the panel
            // past the window's edge.
            .frame(minWidth: 0)
            .inspector(isPresented: $shown) {
                VStack(alignment: .leading, spacing: 0) { inspector() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.background.ignoresSafeArea())
                    .inspectorColumnWidth(min: 260, ideal: width, max: 560)
            }
    }
}
