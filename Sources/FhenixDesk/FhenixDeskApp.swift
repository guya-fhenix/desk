import AppKit
import DeskCore
import SwiftUI

struct FhenixDeskApp: App {
    static let environmentOpensWindow = ProcessInfo.processInfo.environment["FHENIX_DESK_OPEN_WINDOW"] != nil

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environment(model)
        } label: {
            MenuBarLabel(count: model.urgentCount)
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Fhenix Desk", id: DeskWindow.id) {
            DeskWindow()
                .environment(model)
        }
        .defaultSize(width: 1080, height: 700)
    }
}

/// Reopening the app (Dock, Spotlight, `open -a`) shows the Desk window. This is the way in when
/// the menu bar is full and macOS hides the status item behind the notch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openDesk: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Self.openDesk?() }
        return false
    }
}

private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var count: Int

    var body: some View {
        Group {
            if count > 0 {
                Label("\(count)", systemImage: "hexagon.fill")
            } else {
                Image(systemName: "hexagon")
            }
        }
        .task {
            AppDelegate.openDesk = { openDesk() }
            if FhenixDeskApp.environmentOpensWindow || model.config.openWindowOnLaunch { openDesk() }
        }
    }

    private func openDesk() {
        openWindow(id: DeskWindow.id)
        NSApp.activate()
    }
}
