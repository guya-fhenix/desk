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

        var icon: String {
            switch self {
            case .upNext: return "tray"
            case .pullRequests: return "arrow.triangle.pull"
            case .reviews: return "bubble.left.and.text.bubble.right"
            case .tickets: return SidebarIcon.jira
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = Tab(rawValue: ProcessInfo.processInfo.environment["FHENIX_DESK_OPEN_WINDOW"] ?? "") ?? .upNext

    var body: some View {
        Group {
            if model.showingSettings {
                SettingsView()
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Rectangle().fill(Theme.line).frame(width: 1).ignoresSafeArea()
                    screen
                }
            }
        }
        .overlay(alignment: .top) {
            // Only the strip takes clicks; the spacer under it is not hit-testable, so the rest passes through.
            VStack(spacing: 0) {
                TitleBarArea().frame(height: 40)
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
        }
        // Dimmed, not blurred: a blur filter on the window — even at radius 0 — draws it through an offscreen
        // image, and its text comes out soft.
        .overlay { if model.showingFinder { FinderView() } }
        .appFont()
        .preferredColorScheme(.dark)
        .background(Theme.background.ignoresSafeArea())
        // A regular app while the window shows, so ⌘-Tab and the Dock can bring it back.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        // The menu bar and the nudges ask for a tab by setting this; clearing it keeps it a one-shot.
        .onChange(of: model.pendingTab) { _, requested in
            guard let requested else { return }
            tab = requested
            model.showingSettings = false
            model.pendingTab = nil
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private var sidebar: some View {
        SidebarColumn {
            SidebarHeading(title: "Workspace")
            SidebarItem(title: "Search", icon: "magnifyingglass", action: { model.showingFinder = true }) {
                HStack(spacing: 3) {
                    KeyCap(key: "⌘")
                    KeyCap(key: "K")
                }
            }
            ForEach(Tab.allCases) { item in
                SidebarItem(title: item.title, icon: item.icon, selected: tab == item, action: { tab = item }) {
                    let count = badge(for: item)
                    if count > 0 {
                        Text("\(count)")
                            .scaled(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            SidebarItem(title: "Settings", icon: "gearshape", action: { model.showingSettings = true }) {
                HStack(spacing: 3) {
                    KeyCap(key: "⌘")
                    KeyCap(key: ",")
                }
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

    /// The badge is what waits for you on that screen, so the sidebar is the whole to-do list. Up Next counts
    /// only what is urgent — the same number the menu bar icon shows — or it would repeat the other three.
    private func badge(for tab: Tab) -> Int {
        switch tab {
        case .upNext: return model.urgentCount
        case .tickets: return model.state.openTickets.count
        case .pullRequests: return model.state.waiting(on: .pullRequests)
        case .reviews: return model.state.waiting(on: .reviews)
        }
    }
}

/// The strip along the top of the window where its title bar would be. With the title bar hidden, SwiftUI takes the
/// clicks there, so the window neither zoomed on a double-click nor dragged; this hands both back to the window. A
/// double-click does what System Settings → Desktop & Dock says it should. The window buttons sit above it and keep
/// their own clicks.
private struct TitleBarArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { StripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class StripView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else {
                window.performDrag(with: event)
                return
            }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        }
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
                    Text(source.title).scaled(.caption).foregroundStyle(.secondary)
                }
                .help(model.state.errors[source] ?? "Updated \(Format.age(model.state.lastRefresh[source])) ago")
            }
        }
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
            .inspector(isPresented: $shown) {
                VStack(alignment: .leading, spacing: 0) { inspector() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.background.ignoresSafeArea())
                    .inspectorColumnWidth(min: 260, ideal: width, max: 560)
            }
    }
}
