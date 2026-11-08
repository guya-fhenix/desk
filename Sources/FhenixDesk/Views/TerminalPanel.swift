import AppKit
import DeskCore
import SwiftTerm
import SwiftUI

/// One tab of the terminal panel: a process in a SwiftTerm view. The tab owns the view, so switching tabs or
/// screens never stops what runs in it; closing the tab does.
@MainActor
@Observable
final class TerminalTab: Identifiable, LocalProcessTerminalViewDelegate {
    let id: String
    let title: String
    let view = LocalProcessTerminalView(frame: .zero)
    private(set) var running = true

    init(id: String, title: String, executable: String, arguments: [String], directory: String?) {
        self.id = id
        self.title = title
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.processDelegate = self
        var environment = Shell.toolEnvironment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        // Set when Desk itself was started from a Claude session, and then claude refuses to start inside it.
        environment["CLAUDECODE"] = nil
        view.startProcess(
            executable: executable, args: arguments, environment: environment.map { "\($0.key)=\($0.value)" },
            currentDirectory: directory
        )
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        running = false
        view.feed(text: "\r\n[ended — close this tab, or start it again from Desk]\r\n")
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// The terminal panel on the right of the window: a tab per session Desk opened, background sessions attached and
/// review sessions run in it.
@MainActor
@Observable
final class TerminalPanel {
    private(set) var tabs: [TerminalTab] = []
    var selected: String?
    /// View → Show/Hide Terminal. Opening a tab shows the panel again.
    var visible = false

    var current: TerminalTab? { tabs.first { $0.id == selected } ?? tabs.last }

    func tab(_ id: String) -> TerminalTab? { tabs.first { $0.id == id } }

    /// Shows the tab with this id, starting it when there is none or what ran in it has ended.
    func open(id: String, title: String, executable: String, arguments: [String], directory: String? = nil) {
        if tab(id)?.running != true {
            tabs.removeAll { $0.id == id }
            tabs.append(TerminalTab(id: id, title: title, executable: executable, arguments: arguments, directory: directory))
        }
        select(id)
    }

    func select(_ id: String) {
        selected = id
        visible = true
        focus()
    }

    /// Stops what runs in it: an attached session only detaches, a review session ends (`claude --resume` reopens it).
    func close(_ id: String) {
        tab(id)?.view.terminate()
        tabs.removeAll { $0.id == id }
        if selected == id { selected = tabs.last?.id }
        if tabs.isEmpty { visible = false }
    }

    /// Puts `text` in the program's input as a paste, not sent: you finish the question and press Return. False when
    /// nothing runs in that tab.
    func paste(_ text: String, into id: String) -> Bool {
        guard let tab = tab(id), tab.running else { return false }
        tab.view.pasteText(text)
        select(id)
        return true
    }

    /// A turn of the run loop later: a tab opened this moment is not in the window yet.
    private func focus() {
        Task { @MainActor in
            await Task.yield()
            if let view = current?.view { view.window?.makeFirstResponder(view) }
        }
    }
}

struct TerminalPanelView: View {
    var panel: TerminalPanel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(panel.tabs) { tab in
                        TerminalTabButton(tab: tab, selected: tab.id == panel.current?.id, select: { panel.select(tab.id) }, close: { panel.close(tab.id) })
                    }
                }
                .padding(.horizontal, Theme.Space.m)
            }
            // Clear of the window's title-bar strip, which takes the clicks along the top for dragging.
            .padding(.top, 14)
            .padding(.bottom, 6)
            Hairline()
            if let tab = panel.current {
                TerminalHost(view: tab.view)
                    .padding(.leading, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct TerminalTabButton: View {
    var tab: TerminalTab
    var selected: Bool
    var select: () -> Void
    var close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.title).scaled(.caption).lineLimit(1)
                .foregroundStyle(tab.running ? .primary : .secondary)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(tab.running ? "Close the tab and stop what runs in it" : "Close the tab")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(selected ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

/// Holds whichever tab's view is selected. The tabs own their views; this only moves one in and out.
private struct TerminalHost: NSViewRepresentable {
    let view: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard container.subviews.first !== view else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}
