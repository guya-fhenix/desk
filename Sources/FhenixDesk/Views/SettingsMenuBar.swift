import DeskCore
import SwiftUI

/// What a primary click on the menu bar item shows: who you are, the master, what needs you — the rows Focus counts,
/// each a press away — and Open Desk. While GitHub's last refresh failed it says so on top, with Retry and Settings, and
/// greys the list it kept, marked with when it was read.
struct SettingsMenuBarPopover: View {
    @Environment(AppModel.self) private var model
    /// Closes the popover, after a press that goes somewhere.
    var close: () -> Void = {}
    private var filters = ReviewFilters()

    init(close: @escaping () -> Void = {}) { self.close = close }

    var body: some View {
        let stale = model.state.errors[.github] != nil
        let asOf = stale ? model.state.lastRefresh[.github].map { " · as of \($0.clock)" } ?? "" : ""
        let needs = needsYou
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AppMark(size: 18)
                Text("Fhenix Desk").fontWeight(.semibold)
                Spacer(minLength: 8)
                Text(model.state.login).scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1)
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 8, trailing: 14))
            if stale { banner }
            master
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Needs you · \(model.focusCount(filters))\(asOf)").padding(EdgeInsets(top: 6, leading: 8, bottom: 4, trailing: 8))
                if needs.isEmpty {
                    Text("Nothing waits on you.").scaled(.secondary).foregroundStyle(Theme.quiet).padding(.horizontal, 8).padding(.vertical, 6)
                }
                ForEach(needs.prefix(5)) { item in
                    row(dot: item.dot, title: item.title, line: item.line, age: item.date) { go(item.open) }
                }
                .opacity(stale ? 0.55 : 1)
                if needs.count > 5 {
                    Button("\(needs.count - 5) more in Focus") { go { model.pendingTab = .focus; AppDelegate.openDesk?() } }
                        .buttonStyle(.plain).scaled(.secondary).foregroundStyle(Theme.accentInk)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 6)
            foot.padding(.top, 6)
        }
        .frame(width: 380)
        .background(Theme.surface)
        .appFont()
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
    }

    // MARK: Parts

    /// GitHub's error, and the two presses that help.
    private var banner: some View {
        // "for 6m" once there is a minute to say; "for 0m" would read as a glitch.
        let down = model.state.lastRefresh[.github].map { Date().timeIntervalSince($0) } ?? 0
        let since = down >= 60 ? " for \(TimeText.duration(down))" : ""
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(Theme.danger).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub didn't answer\(since).").fontWeight(.semibold).foregroundStyle(Theme.danger)
                    Text(model.state.errors[.github] ?? "").scaled(.secondary).lineLimit(3).help(model.state.errors[.github] ?? "")
                    Text("Desk keeps the last list and retries.").scaled(.secondary).foregroundStyle(Theme.quiet)
                }
                HStack(spacing: 6) {
                    Button("Retry") { Task { await model.refresh(.github) } }.disabled(model.refreshing.contains(.github))
                    Button("Settings") { go { model.openSettings(.github); AppDelegate.openDesk?() } }
                }
                .buttonStyle(.desk(.secondary, .small))
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(Theme.del, in: RoundedRectangle(cornerRadius: 8))
        .padding(EdgeInsets(top: 2, leading: 12, bottom: 6, trailing: 12))
        .accessibilityElement(children: .contain)
    }

    /// The master, as the sidebar shows it: whether one runs, and Open to see it in iTerm.
    private var master: some View {
        let running = model.state.master
        let failed = model.masterError != nil
        let status = failed ? (running == nil ? "Couldn't start" : "Couldn't open") : model.masterStatus
        return Button { go(model.openMaster) } label: {
            HStack(spacing: 8) {
                MasterIcon().frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Master").fontWeight(.semibold)
                    HStack(spacing: 5) {
                        Circle().fill(model.masterDot).frame(width: 6, height: 6)
                        Text(status).lineLimit(1)
                    }
                    .scaled(.secondary)
                    .foregroundStyle(failed ? Theme.danger : Theme.quiet)
                }
                Spacer(minLength: 4)
                Text(running == nil ? "Start" : "Open")
                    .scaled(.secondary.weight(.medium))
                    .foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.tint, in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.ruleStrong))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(model.startingMaster)
        .help(model.masterError ?? "Show the master's pane in iTerm")
        .accessibilityLabel("Master session: \(status). \(running == nil ? "Start" : "Open")")
        .padding(EdgeInsets(top: 2, leading: 12, bottom: 6, trailing: 12))
    }

    /// The sync line and Open Desk, on the ground colour under a hairline.
    private var foot: some View {
        HStack(spacing: 8) {
            // Ticks, so "Retrying in 40s" counts down while the popover is open.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Circle().fill(sync(context.date).color).frame(width: 6, height: 6)
                    Text(sync(context.date).text).lineLimit(1)
                }
                .scaled(.secondary)
                .foregroundStyle(Theme.quiet)
            }
            Spacer(minLength: 8)
            Button("Open Desk") { go { AppDelegate.openDesk?() } }.buttonStyle(.desk(.primary, .small))
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .background(Theme.ground)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
    }

    private func sync(_ now: Date) -> (text: String, color: Color) {
        if model.state.errors[.github] != nil {
            if model.refreshing.contains(.github) { return ("Retrying…", Theme.danger) }
            let next = model.nextPoll[.github].map { $0.timeIntervalSince(now) } ?? 0
            let wait = next >= 60 ? TimeText.duration(next) : "\(Int(next.rounded(.up)))s"
            return (next > 0 ? "Retrying in \(wait)" : "Retrying…", Theme.danger)
        }
        if !model.refreshing.isEmpty { return ("Syncing…", Theme.quiet) }
        guard let oldest = model.state.lastRefresh.values.min() else { return ("Not synced yet", Theme.control) }
        return ("Synced \(Format.ago(oldest, now: now))", Theme.ok)
    }

    /// A row of Needs you: its dot, two lines, and its age in DM Mono.
    private func row(dot: Color, title: String, line: String, age: Date?, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 10, height: 10).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.semibold).lineLimit(1)
                    Text(line).scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(Format.age(age)).scaled(.code).foregroundStyle(Theme.quiet)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(minHeight: 46)
            .hoverFill(Theme.inset, cornerRadius: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func go(_ action: () -> Void) {
        action()
        close()
    }

    // MARK: Data

    private struct Item: Identifiable {
        var id: String
        var dot: Color
        var title: String
        var line: String
        var date: Date?
        var open: () -> Void
    }

    /// What Focus counts, in its order: its items at Now and Next. Each opens the Desk on it.
    private var needsYou: [Item] {
        let model = model
        // The review learning pass first, while it waits on you: it opens Desk on Focus, where its presses are.
        let learning = model.reviewLearning.flatMap { $0.needsYou ? $0 : nil }.map { status in
            Item(id: "review-learning", dot: Theme.warn, title: status.title, line: status.words, date: status.dueSince) {
                model.pendingTab = .focus
                AppDelegate.openDesk?()
            }
        }
        return (learning.map { [$0] } ?? []) + model.focus(filters).filter { $0.level >= .next }.map { item in
            let dot = item.kind.tone ?? Theme.quiet
            switch item.subject {
            case .pullRequest(let pr):
                return Item(id: item.id, dot: dot, title: pr.title, line: "\(item.kind.title) · \(pr.repoName) #\(pr.number)", date: item.since) {
                    model.show(pr.url)
                }
            case .move(let drift):
                return Item(id: item.id, dot: dot, title: "Move \(drift.ticket.key) to \(drift.target)", line: drift.ticket.summary, date: item.since) {
                    Self.show(drift.ticket, model)
                }
            case .ticket(let ticket):
                return Item(id: item.id, dot: dot, title: ticket.summary, line: "\(item.kind.title) · \(ticket.key)", date: nil) {
                    Self.show(ticket, model)
                }
            }
        }
    }

    /// The Jira screen, on this ticket.
    private static func show(_ ticket: Ticket, _ model: AppModel) {
        model.selectTicket = ticket.key
        model.pendingTab = .tickets
        AppDelegate.openDesk?()
    }
}
