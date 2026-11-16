import DeskCore
import SwiftUI

/// What a primary click on the menu bar item shows: who you are, the master, what needs you — the rows Up Next counts —
/// and the workers at it, each a press away, and Open Desk. While GitHub's last refresh failed it says so on top, with
/// Retry and Settings, and greys the lists it kept, marked with when they were read.
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
        let workers = busyWorkers
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
                SectionLabel("Needs you · \(model.upNextCount(filters))\(asOf)").padding(EdgeInsets(top: 6, leading: 8, bottom: 4, trailing: 8))
                if needs.isEmpty {
                    Text("Nothing waits on you.").scaled(.secondary).foregroundStyle(Theme.quiet).padding(.horizontal, 8).padding(.vertical, 6)
                }
                ForEach(needs.prefix(5)) { item in
                    row(dot: item.dot, title: item.title, line: item.line, age: item.date) { go(item.open) }
                }
                .opacity(stale ? 0.55 : 1)
                if needs.count > 5 {
                    Button("\(needs.count - 5) more in Up Next") { go { model.pendingTab = .upNext; AppDelegate.openDesk?() } }
                        .buttonStyle(.plain).scaled(.secondary).foregroundStyle(Theme.accentInk)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 6)
            if !workers.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Workers at it · \(workers.count)\(asOf)").padding(EdgeInsets(top: 8, leading: 8, bottom: 4, trailing: 8))
                    ForEach(workers) { job in worker(job) }.opacity(stale ? 0.55 : 1)
                }
                .padding(EdgeInsets(top: 4, leading: 6, bottom: 6, trailing: 6))
                .overlay(alignment: .top) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
                .padding(.top, 4)
            }
            foot.padding(.top, workers.isEmpty ? 6 : 0)
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

    /// The master, as the sidebar shows it: its state and the questions it has for you, and Open to see it in iTerm.
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
                        Circle().fill(failed ? Theme.danger : running == nil ? Theme.control
                                      : running!.isAsking || !model.state.asks.isEmpty ? Theme.warn : Theme.ok)
                            .frame(width: 6, height: 6)
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

    /// A worker at it: its mark, its name in DM Mono, and what it does and since when; a press shows its pane.
    private func worker(_ job: ClaudeJob) -> some View {
        Button { go { model.show(jobId: job.id) } } label: {
            HStack(spacing: 8) {
                SessionMark(job: job).frame(width: 16)
                Text(job.name).scaled(.code).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text([job.detail ?? (job.isAsking ? "waiting for you" : "working"), Format.age(job.updatedAt)].joined(separator: " · "))
                    .scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .hoverFill(Theme.inset, cornerRadius: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(job.name) in iTerm")
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

    /// What Up Next counts, in its order: the master's questions, your PRs that are not waiting on others and the
    /// reviews on you, then the Jira moves it suggests. Each opens the Desk on it.
    private var needsYou: [Item] {
        let model = model
        let asks = model.state.asks.map { ask in
            Item(id: "ask:\(ask.id)", dot: Theme.warn, title: "Master asks about \(ask.task)", line: ask.text, date: ask.askedAt) {
                model.showMasterScreen()
                AppDelegate.openDesk?()
            }
        }
        let plan = model.state.upNext(reviewDays: filters.window, hiding: filters.hidden, needingApproval: filters.needsApproval)
        let prs = plan.filter { $0.section != .waiting }.flatMap { group in
            group.pullRequests.map { pr in
                Item(id: pr.url, dot: Self.dot(group.section), title: pr.title,
                     line: "\(group.section.title) · \(pr.repoName) #\(pr.number)", date: pr.updatedAt) { model.show(pr.url) }
            }
        }
        let moves = model.state.ticketDrifts.map { drift in
            Item(id: drift.id, dot: Theme.accentInk, title: "Move \(drift.ticket.key) to \(drift.target)", line: drift.ticket.summary, date: nil) {
                model.selectTicket = drift.ticket.key
                model.pendingTab = .tickets
                AppDelegate.openDesk?()
            }
        }
        return asks + prs + moves
    }

    private static func dot(_ section: UpNextSection) -> Color {
        switch section {
        case .yourMove: return Theme.danger
        case .readyToMerge: return Theme.ok
        default: return Theme.accentInk
        }
    }

    /// The open tasks' workers at work or waiting on you, each once.
    private var busyWorkers: [ClaudeJob] {
        var seen = Set<String>()
        return model.state.tasks.compactMap(\.worker).filter { $0.isBusy && seen.insert($0.id).inserted }
    }
}
