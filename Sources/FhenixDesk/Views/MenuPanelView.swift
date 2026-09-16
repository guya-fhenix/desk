import AppKit
import DeskCore
import SwiftUI

/// The secondary-click panel: how much is waiting, and the two ways out. Anything that needs reading
/// rather than counting belongs in the window.
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
            footer
        }
        .padding(12)
        // Widened with the text, or a larger setting would wrap the three counters into each other.
        .frame(width: 320 * model.textScale)
        .textScale(model.textScale)
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

    private var footer: some View {
        HStack(spacing: 10) {
            ForEach(Source.allCases, id: \.self) { source in
                HStack(spacing: 3) {
                    StatusDot(color: model.state.errors[source] == nil ? (model.state.lastRefresh[source] == nil ? .gray : .green) : .red)
                    Text(source.title).scaled(.caption2).foregroundStyle(.secondary)
                }
                .help(model.state.errors[source] ?? "Updated \(Format.age(model.state.lastRefresh[source])) ago")
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).scaled(.caption).foregroundStyle(.secondary)
        }
    }
}
