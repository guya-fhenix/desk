import AppKit
import DeskCore
import SwiftUI

/// The secondary-click panel: how much is waiting, the few things that most need you, and the ways out.
/// Anything longer than the top of Up Next belongs in the window.
struct MenuPanelView: View {
    @Environment(AppModel.self) private var model
    private var reviewDays = ReviewDays()
    @Environment(\.textScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 0) {
                counter("PRs need you", model.state.waiting(on: .pullRequests), .pullRequests)
                Divider().frame(height: 34 * scale)
                counter("In the review queue", model.state.reviewQueue(.all, days: reviewDays.window).count, .reviews)
                Divider().frame(height: 34 * scale)
                counter("Open Jira tickets", model.state.openTickets.count, .tickets)
            }
            if !model.state.nudges.isEmpty { topNudges }
            footer
        }
        .padding(12)
        // Widened with the text, or a larger setting would wrap the three counters into each other.
        .frame(width: 320 * scale)
        .appFont()
    }

    private var header: some View {
        HStack {
            Text("Fhenix Desk").scaled(.title3.weight(.semibold))
            Spacer()
            RefreshControl().buttonStyle(.borderless)
            Button("Open Desk") { AppDelegate.openDesk?() }.controlSize(.small)
        }
    }

    /// A count that opens its screen in the window, like the Up Next tiles it mirrors.
    private func counter(_ title: String, _ value: Int, _ tab: DeskWindow.Tab) -> some View {
        Button {
            model.pendingTab = tab
            AppDelegate.openDesk?()
        } label: {
            VStack(spacing: 2) {
                Text("\(value)")
                    .scaled(.title)
                    .monospacedDigit()
                    .foregroundStyle(value > 0 ? .primary : .secondary)
                Text(title).scaled(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .hoverFill(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(tab.title)")
    }

    /// The head of Up Next, in Up Next's own order, so what waits on your press comes first here too. Each opens on
    /// GitHub, as its notification does — a finished review straight at its draft.
    private var topNudges: some View {
        let nudges = UpNextTab.Group.ordered(model.state.nudges)
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
                    .hoverFill(cornerRadius: 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if nudges.count > 4 {
                Button("All \(model.upNextCount) in Up Next…") {
                    model.pendingTab = .upNext
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
            // A 24 pt target around the small word.
            Button { NSApp.terminate(nil) } label: {
                Text("Quit").frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).scaled(.caption).foregroundStyle(.secondary)
        }
    }
}
