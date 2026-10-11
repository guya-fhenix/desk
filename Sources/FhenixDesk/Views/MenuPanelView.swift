import AppKit
import DeskCore
import SwiftUI

/// The secondary-click panel: how much is waiting, the few things that most need you, and the ways out.
/// Anything longer than the top of Today belongs in the window.
struct MenuPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 0) {
                counter("Pull requests", model.state.waiting(on: .pullRequests))
                Divider().frame(height: 34 * model.textScale)
                counter("Reviews", model.state.waiting(on: .reviews))
                Divider().frame(height: 34 * model.textScale)
                counter("Tickets", model.state.openTickets.count)
            }
            if !model.state.nudges.isEmpty { topNudges }
            footer
        }
        .padding(12)
        // Widened with the text, or a larger setting would wrap the three counters into each other.
        .frame(width: 320 * model.textScale)
        .textScale(model.textScale)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("Fhenix Desk").scaled(.title3.weight(.semibold))
            Spacer()
            RefreshControl().buttonStyle(.borderless)
            Button("Open Desk") { AppDelegate.openDesk?() }.controlSize(.small)
        }
    }

    private func counter(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .scaled(.size(24).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? .primary : .secondary)
            Text(title).scaled(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// The head of Today, already sorted most urgent first. Each opens on GitHub, as its notification does —
    /// a finished review straight at its draft.
    private var topNudges: some View {
        let nudges = model.state.nudges
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(nudges.prefix(4)) { nudge in
                Button { model.open(nudge.url) } label: {
                    HStack(spacing: 8) {
                        if nudge.kind == .readyToMerge { StatusDot(color: .green) } else { SeverityDot(severity: nudge.severity) }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(nudge.title).scaled(.callout).lineLimit(1)
                            Text(nudge.detail).scaled(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if nudges.count > 4 {
                Button("All \(nudges.count) in Today…") {
                    model.pendingTab = .today
                    AppDelegate.openDesk?()
                }
                .buttonStyle(.link)
                .scaled(.caption)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            SourceDots()
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).scaled(.caption).foregroundStyle(.secondary)
        }
    }
}
