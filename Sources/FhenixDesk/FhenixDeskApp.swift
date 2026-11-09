import AppKit
import DeskCore
import SwiftUI

struct FhenixDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        // Text typed here goes to Claude, and macOS would turn a typed `--repo` into `—repo` and JSON's
        // quotes into curly ones. A value in the app's own domain outranks the system-wide setting.
        UserDefaults.standard.set(false, forKey: "NSAutomaticQuoteSubstitutionEnabled")
        UserDefaults.standard.set(false, forKey: "NSAutomaticDashSubstitutionEnabled")
    }

    var body: some Scene {
        Window("Fhenix Desk", id: DeskWindow.id) {
            // Narrower than this, the sidebar, a list and the details panel stop fitting side by side, and Search's
            // 640 pt box with them.
            DeskRoot(model: model, delegate: delegate)
                .frame(minWidth: 960, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 720)
        // Shown at every launch, even one that restores no window: the window's task is what builds the menu bar item
        // and `openDesk`, and without them this Dock-less app has no way back in.
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentMinSize)
        .commands {
            // View → Show/Hide Sidebar, ⌃⌘S.
            SidebarCommands()
            // Settings live in the Desk window now, so ⌘, opens them there.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.showingSettings = true
                    AppDelegate.openDesk?()
                }
                .keyboardShortcut(",", modifiers: .command)
                Button("Setup…") {
                    model.showingSetup = true
                    AppDelegate.openDesk?()
                }
            }
            CommandMenu("Go") {
                Button("Search…") {
                    model.showingFinder.toggle()
                    AppDelegate.openDesk?()
                }
                .keyboardShortcut("k", modifiers: .command)
                BackCommand()
            }
            // In the system View menu, so every screen and the presses that work on it have a key, listed in one place.
            CommandGroup(before: .toolbar) {
                ForEach(Array(DeskWindow.Tab.allCases.enumerated()), id: \.element) { index, tab in
                    Button(tab.title) {
                        model.pendingTab = tab
                        AppDelegate.openDesk?()
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Divider()
                Button("Sync Now") { model.refreshAll() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Find") {
                    if model.visibleSearchBoxes > 0 { model.searchFocusRequest += 1 } else { model.showingFinder = true }
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Show/Hide Details") { model.inspectorToggleRequest += 1 }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Show/Hide Terminal") { model.terminals.visible.toggle() }
                    .keyboardShortcut("`", modifiers: .control)
                    .disabled(model.terminals.tabs.isEmpty)
                Divider()
            }
        }
    }
}

/// Go → Back, ⌘[: the tab on show from its page back to its list, as the page's back link and ← do.
private struct BackCommand: View {
    @FocusedBinding(\.routePath) private var path

    var body: some View {
        Button("Back") { path?.removeLast() }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(path?.isEmpty != false)
    }
}

/// The Desk window's content, plus the one place that can hand AppKit a way to open this window:
/// `openWindow` only exists inside a scene, and the menu bar item lives outside every scene.
private struct DeskRoot: View {
    @Environment(\.openWindow) private var openWindow
    var model: AppModel
    var delegate: AppDelegate

    var body: some View {
        DeskWindow()
            .environment(model)
            .task {
                AppDelegate.openDesk = {
                    openWindow(id: DeskWindow.id)
                    AppDelegate.raiseDeskWindow()
                    // A status item click does not make the app active, and the polite `activate()` is
                    // refused while another app holds focus — the Desk would rise over its own windows
                    // but stay behind the editor you were in.
                    NSApp.activate(ignoringOtherApps: true)
                }
                delegate.installMenuBarItem(model: model)
            }
    }
}

/// Owns the menu bar item. It is built by hand rather than with `MenuBarExtra` because that one
/// answers every click the same way, and the two buttons have to mean different things here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openDesk: (() -> Void)?
    private var statusItem: NSStatusItem?
    private var model: AppModel?

    /// This is a menu bar app first: closing the Desk window leaves it running behind the status item.
    /// Without this a lone `Window` scene takes the app down with it — `MenuBarExtra` used to be what
    /// kept a scene alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A review session's `fhenixdesk://show/…`: the Desk comes forward on that PR's diff, at that line. Only for a PR
    /// it knows: any web page can open the link, and must not pull focus with it.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            // Every link is read, not only up to the first that matches.
            if urls.map({ model?.open($0) == true }).contains(true) { Self.openDesk?() }
        }
    }

    /// Reopening the app (Dock, Spotlight, `open -a`) shows the Desk window. This is the way in when
    /// the menu bar is full and macOS hides the status item behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Self.openDesk?() }
        return false
    }

    /// `openWindow` re-shows a window that was closed, but does nothing for one that is merely buried
    /// behind another app's, and activating the app alone does not reorder it. Raising it by hand is what
    /// makes a primary click mean "show me the Desk" in every state it can be in.
    @MainActor static func raiseDeskWindow() {
        NSApp.windows.first { $0.identifier?.rawValue == DeskWindow.id }?.makeKeyAndOrderFront(nil)
    }

    @MainActor func installMenuBarItem(model: AppModel) {
        guard statusItem == nil else { return }
        self.model = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "hexagon", accessibilityDescription: "Fhenix Desk")
        item.button?.target = self
        item.button?.action = #selector(clicked)
        // Without this a button only reports the primary button, and the secondary one opens nothing.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // The two clicks mean different things, which nothing else on the button says.
        item.button?.toolTip = "Click: open Desk · Right-click: menu"
        statusItem = item
    }

    /// macOS swaps the two buttons itself when someone sets the right one as primary, so a primary
    /// click always arrives as `.leftMouseUp` whichever hand it came from — reading the event type is
    /// what follows their setting, and second-guessing it here is what would break them.
    /// Control-click is the system's other way of saying "secondary".
    @MainActor @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            Self.openDesk?()
        }
    }

    /// A plain macOS menu, built afresh on each click: open the Desk, quit, then your open PRs and the review queue
    /// inside the Reviews screen's filters, each opening the Desk on that PR's page. Set on the item only while it
    /// shows, so a primary click goes on opening the Desk rather than the menu.
    @MainActor private func showMenu() {
        guard let item = statusItem, let model else { return }
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Fhenix Desk \(Bundle.main.versionText)"))
        menu.addItem(MenuAction("Open Fhenix Desk") { Self.openDesk?() })
        menu.addItem(MenuAction("Quit App", key: "q") { NSApp.terminate(nil) })
        let mine = model.state.mine.sorted { $0.updatedAt > $1.updatedAt }
        if !mine.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Pull Requests"))
            for pr in mine { menu.addItem(Self.item(for: pr, model: model, tab: .pullRequests)) }
        }
        let reviews = model.state.reviewQueue(
            .needsYou, days: ReviewFilters.currentWindow, hiding: ReviewFilters.currentHidden, needingApproval: ReviewFilters.currentNeedsApproval
        )
        if !reviews.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Reviews"))
            for pr in reviews { menu.addItem(Self.item(for: pr, model: model, tab: .reviews)) }
        }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// One PR in the menu: its checks as a coloured mark, repo#number and title, and a press that opens its page.
    @MainActor private static func item(for pr: PullRequest, model: AppModel, tab: DeskWindow.Tab) -> NSMenuItem {
        let title = "\(pr.repoName)#\(pr.number)  \(pr.title)"
        let entry = MenuAction(title.count > 72 ? title.prefix(71) + "…" : title) {
            model.selectPullRequest = pr.url
            model.pendingTab = tab
            Self.openDesk?()
        }
        let (symbol, color): (String, NSColor) = switch pr.checks {
        case .success: ("checkmark.circle.fill", .systemGreen)
        case .failure, .error: ("xmark.circle.fill", .systemRed)
        case .pending, .expected: ("clock.fill", .systemOrange)
        case .none: ("minus.circle", .secondaryLabelColor)
        }
        entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: pr.checks.rawValue)?
            .withSymbolConfiguration(.init(paletteColors: [color]))
        entry.toolTip = pr.title
        return entry
    }
}

/// A menu item that runs a closure, which AppKit's target and selector make awkward for a menu built on the spot.
private final class MenuAction: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, key: String = "", run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("built in code only") }

    @objc private func fire() { run() }
}

extension Bundle {
    /// "1.0.0 (118)": the version, and the build number `scripts/bundle.sh` stamps from the commit count. `swift run`
    /// has no Info.plist, hence "dev".
    var versionText: String {
        guard let version = infoDictionary?["CFBundleShortVersionString"] as? String else { return "dev" }
        return "\(version) (\(infoDictionary?["CFBundleVersion"] as? String ?? "?"))"
    }
}
