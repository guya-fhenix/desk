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
            DeskRoot(model: model, delegate: delegate)
        }
        .defaultSize(width: 1180, height: 720)
        // The window's buttons sit on the sidebar and its title bar is gone; the background drags the window.
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            // Settings live in the Desk window now, so ⌘, opens them there.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.showingSettings = true
                    AppDelegate.openDesk?()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
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
    /// The event monitors below run outside the delegate's own isolation and cannot capture it.
    @MainActor fileprivate static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var model: AppModel?
    private var dismissMonitors: [Any] = []

    /// This is a menu bar app first: closing the Desk window leaves it running behind the status item.
    /// Without this a lone `Window` scene takes the app down with it — `MenuBarExtra` used to be what
    /// kept a scene alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
        Self.shared = self
        self.model = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        // Without this a button only reports the primary button, and the secondary one opens nothing.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        draw(count: model.urgentCount)
        model.onUrgentCountChange = { [weak self] count in self?.draw(count: count) }
    }

    /// macOS swaps the two buttons itself when someone sets the right one as primary, so a primary
    /// click always arrives as `.leftMouseUp` whichever hand it came from — reading the event type is
    /// what follows their setting, and second-guessing it here is what would break them.
    /// Control-click is the system's other way of saying "secondary".
    @MainActor @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            togglePanel()
        } else {
            closePanel()
            Self.openDesk?()
        }
    }

    @MainActor private func togglePanel() {
        guard let button = statusItem?.button, let model else { return }
        if popover?.isShown == true {
            closePanel()
            return
        }
        let panel = popover ?? makePopover(model: model)
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        watchForDismiss()
    }

    @MainActor private func makePopover(model: AppModel) -> NSPopover {
        let panel = NSPopover()
        // Not `.transient`: that dismisses the panel by eating the click on its way to the button, so a
        // primary click with the panel open would close the panel and never open the window. Dismissing
        // it by hand leaves the button's clicks to the button.
        panel.behavior = .applicationDefined
        // Dark like the Desk window, whatever the system is set to.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentViewController = NSHostingController(rootView: MenuPanelView().environment(model))
        popover = panel
        return panel
    }

    /// What `.transient` used to do: close on anything that is neither the panel nor the menu bar button,
    /// and on Escape.
    @MainActor private func watchForDismiss() {
        let elsewhere = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { AppDelegate.shared?.closePanel() }
        }
        let inApp = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            let isEscape = event.type == .keyDown && event.keyCode == 53
            MainActor.assumeIsolated {
                guard let delegate = AppDelegate.shared else { return }
                if event.type == .keyDown {
                    if isEscape { delegate.closePanel() }
                    return
                }
                let ours = [delegate.popover?.contentViewController?.view.window, delegate.statusItem?.button?.window]
                if !ours.contains(where: { $0 === event.window }) { delegate.closePanel() }
            }
            // The event still goes where it was headed; the panel only steps out of its way.
            return event
        }
        dismissMonitors = [elsewhere, inApp].compactMap { $0 }
    }

    @MainActor private func closePanel() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors = []
        popover?.performClose(nil)
    }

    @MainActor private func draw(count: Int) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: count > 0 ? "hexagon.fill" : "hexagon", accessibilityDescription: "Fhenix Desk"
        )
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
        button.title = count > 0 ? " \(count)" : ""
    }
}
