import AppKit
import DeskCore
import SwiftUI

struct FhenixDeskApp: App {
    static let openWindowOnLaunch = ProcessInfo.processInfo.environment["FHENIX_DESK_OPEN_WINDOW"] != nil

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
        }
        .menuBarExtraStyle(.window)

        Window("Fhenix Desk", id: DeskWindow.id) {
            DeskWindow()
                .environment(model)
        }
        .defaultSize(width: 1080, height: 700)
    }
}

private struct MenuBarLabel: View {
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
            if FhenixDeskApp.openWindowOnLaunch {
                openWindow(id: DeskWindow.id)
                NSApp.activate()
            }
        }
    }
}
