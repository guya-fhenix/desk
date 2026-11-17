import DeskCore
import SwiftUI

/// The master and its workers, as they run in iTerm: the sessions down a column, the `desk` layout drawn with a Show per
/// pane, the questions the master asked you with Answer in iTerm, and the events Desk told it today; beside them where
/// the master runs and how its terminal is set up. Desk sends nothing to a session from here: every press puts a pane
/// in front, and you type there.
struct MasterScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            SessionsColumn()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let error = model.terminalError ?? model.masterError {
                        Text(error).scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled)
                    }
                    LayoutSketch()
                    questions
                    events
                }
                .padding(EdgeInsets(top: 18, leading: 24, bottom: 20, trailing: 24))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 380)
            MasterDetails()
        }
        .background(Theme.ground)
    }

    private var header: some View {
        let master = model.state.master
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kicker).scaled(.secondary).foregroundStyle(Theme.quiet)
                Text("Master and its workers").scaled(.title.weight(.semibold))
            }
            Spacer(minLength: 8)
            if master != nil {
                Button("Stop master") { model.stopMaster() }.buttonStyle(.desk)
                    .help("claude stop: the master ends; its workers run on")
            }
            Button { model.openMaster() } label: {
                HStack(spacing: 8) { Text(master == nil ? "Start master" : "Open in iTerm"); ButtonKey(key: "↩") }
            }
            .buttonStyle(.deskPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(model.startingMaster)
        }
    }

    private var kicker: String {
        let started = model.state.master?.createdAt.map { " · started \($0.clock)" } ?? ""
        let app = model.config.terminalApp == .iTerm ? "iTerm2" : "Terminal"
        return model.state.master == nil ? "No master running" : "tmux session \(TmuxLayout.session) · shown in \(app)\(started)"
    }

    @ViewBuilder private var questions: some View {
        let asks = model.state.asks
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("The master asked you", count: asks.count).padding(.bottom, 6)
            if asks.isEmpty {
                Text("Nothing open. When the master asks you something, it shows here and on Up Next.")
                    .foregroundStyle(Theme.quiet).padding(.vertical, 8)
            }
            ForEach(asks) { ask in
                RuledRow(minHeight: 44) {
                    HStack(spacing: 8) {
                        StageChip2(text: ask.task).font(AppTextStyle.code.font(scale: model.textScale))
                        Text(Format.age(ask.askedAt)).scaled(.code).foregroundStyle(Theme.quiet)
                    }
                    .scaledFrame(width: 140, alignment: .leading)
                    Text(ask.text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Answer in iTerm") { model.openMaster() }.buttonStyle(.desk(.secondary, .small))
                }
            }
            if !asks.isEmpty { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
            Text("You answer in the master's pane. Desk shows the questions; it sends nothing to a session.")
                .scaled(.secondary).foregroundStyle(Theme.quiet).padding(.top, 8)
        }
    }

    @ViewBuilder private var events: some View {
        let today = model.masterFolder.events(limit: 12).filter { Calendar.current.isDateInToday($0.at) }
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("What Desk told the master · today")
            if today.isEmpty {
                Text(model.config.sendEvents ? "Nothing yet today." : "Events to the master are off in Settings → Master.")
                    .foregroundStyle(Theme.quiet)
            }
            ForEach(Array(today.enumerated()), id: \.offset) { _, event in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(event.at.clock).foregroundStyle(Theme.quiet).scaledFrame(width: 44, alignment: .leading)
                    Text(event.title).fixedSize(horizontal: false, vertical: true)
                }
                .scaled(.code)
            }
        }
    }
}

/// The sessions Desk knows of: the master first, the open tasks' workers at work and done, and the review sessions. A
/// press shows that session's pane in iTerm.
private struct SessionsColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        var seen = Set<String>()
        let workers = model.state.tasks.compactMap(\.worker).filter { seen.insert($0.id).inserted }
        let working = workers.filter(\.isBusy)
        let done = workers.filter { !$0.isBusy }
        let reviews = model.state.claudeJobs.filter { $0.role == .review }
        VStack(alignment: .leading, spacing: 2) {
            Text("Sessions").scaled(.title).padding(.horizontal, 8).frame(minHeight: 32).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    masterRow
                    if !workers.isEmpty {
                        SectionLabel("Workers", count: workers.count).padding(EdgeInsets(top: 18, leading: 8, bottom: 4, trailing: 8))
                        if !working.isEmpty { group("Working", working) }
                        if !done.isEmpty { group("Done", done) }
                    }
                    if !reviews.isEmpty {
                        SectionLabel("Reviews", count: reviews.count).padding(EdgeInsets(top: 18, leading: 8, bottom: 4, trailing: 8))
                        ForEach(reviews) { SessionRow2(job: $0) }
                    }
                }
            }
            Text("The master starts one worker per task. A session that runs or waits has a pane in iTerm; a finished one gives its pane back.")
                .scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 12, leading: 8, bottom: 0, trailing: 8))
                .overlay(alignment: .top) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
        }
        .padding(EdgeInsets(top: 18, leading: 10, bottom: 16, trailing: 10))
        .scaledFrame(width: 264)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.rule).frame(width: 1) }
    }

    @ViewBuilder private var masterRow: some View {
        Button { model.openMaster() } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Circle().fill(model.state.master == nil ? Theme.control : Theme.warn).frame(width: 8, height: 8)
                    Text("Master").fontWeight(.semibold)
                }
                Text(model.masterStatus).scaled(.secondary).foregroundStyle(Theme.quiet).padding(.leading, 16)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.tint, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.tintLine))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the master's pane in iTerm")
    }

    private func group(_ title: String, _ jobs: [ClaudeJob]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) · \(jobs.count)").scaled(.secondary).foregroundStyle(Theme.quiet).padding(.horizontal, 8).padding(.vertical, 2)
            ForEach(jobs) { SessionRow2(job: $0) }
        }
    }
}

/// A session in the column: its state's mark, its name in DM Mono and its age, and under them what it is doing.
private struct SessionRow2: View {
    @Environment(AppModel.self) private var model
    var job: ClaudeJob

    var body: some View {
        Button { model.show(jobId: job.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    SessionMark(job: job).frame(width: 12)
                    Text(job.name).scaled(.code.weight(job.isBusy ? .medium : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    if job.isBusy { Text(Format.age(job.updatedAt)).scaled(.caption.monospaced()).foregroundStyle(Theme.quiet) }
                }
                Text(line).scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(2).padding(.leading, 20)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(job.name) in iTerm")
    }

    private var line: String {
        let state = job.isAsking ? "Waiting for you" : job.isRunning ? "Working" : "Done"
        return job.detail.map { "\(state) · \($0)" } ?? state
    }
}

/// A session's state as a small mark: an arc while it works, a filled dot while it waits for you, a tick when done.
struct SessionMark: View {
    var job: ClaudeJob

    var body: some View {
        Group {
            if job.isAsking {
                Circle().fill(Theme.warn).frame(width: 9, height: 9)
            } else if job.isRunning {
                ZStack {
                    Circle().stroke(Theme.quiet, lineWidth: 1.5)
                    Circle().trim(from: 0, to: 0.25).stroke(Theme.accentInk, lineWidth: 1.5).rotationEffect(.degrees(-90))
                }
                .frame(width: 10, height: 10)
            } else {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.quiet)
            }
        }
        .accessibilityLabel(job.isAsking ? "Waiting for you" : job.isRunning ? "Working" : "Done")
    }
}

/// The `desk` window as iTerm shows it: the master in the left half, `claude agents` in the right, each with Show; under
/// it, the sessions open in windows of their own.
private struct LayoutSketch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let master = model.layoutPanes.first { $0.isMaster }
        let windows = model.panes.filter { $0 != PaneSpec.agentsKey && $0 != master?.key && !$0.isEmpty }.sorted()
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(model.panes.isEmpty ? "In iTerm, once opened" : "In iTerm")
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.control).frame(width: 8, height: 8) }
                    Spacer()
                    Text("\(TmuxLayout.session) · master | claude agents").scaled(.caption.monospaced()).foregroundStyle(Theme.quiet)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                HStack(spacing: 6) {
                    masterPane(master)
                    agentsPane
                }
                .padding(6)
                .frame(height: 300)
            }
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.ruleStrong))
            if !windows.isEmpty {
                VStack(spacing: 6) {
                    ForEach(windows.prefix(6), id: \.self) { key in window(key) }
                }
            }
            Text("Desk keeps the master on the left and claude agents, every background session, on the right. A session you show takes claude agents' place until you leave it; a review runs in a window of its own.")
                .scaled(.secondary).foregroundStyle(Theme.quiet)
        }
    }

    private var agentsPane: some View {
        let running = model.state.claudeJobs.filter { $0.role != .master && $0.isBusy }
        let showing = model.agentsShowing.flatMap { id in model.state.claudeJobs.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 8) {
            paneHeader(name: showing?.name ?? "claude agents", state: showing.map { _ in "in claude agents' place" } ?? "\(running.count) at work",
                       dot: Theme.accentInk) { model.openMaster() }
            Text(showing.map { "claude attach \($0.name)" } ?? "claude agents").foregroundStyle(Theme.quiet)
            ForEach(running.prefix(6)) { job in
                HStack(spacing: 6) {
                    Circle().fill(job.isAsking ? Theme.warn : Theme.accentInk).frame(width: 6, height: 6)
                    Text(job.name).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .scaled(.code)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    private func window(_ key: String) -> some View {
        let job = model.state.claudeJobs.first { $0.id == key }
        return HStack(spacing: 8) {
            Circle().fill(job?.isAsking == true ? Theme.warn : Theme.accentInk).frame(width: 7, height: 7)
            Text(job?.name ?? (key.hasPrefix("review:") ? "review" : key)).scaled(.code.weight(.medium)).lineLimit(1)
            Text(job.map { $0.isAsking ? "waiting for you" : $0.isRunning ? "working" : "done" } ?? "review").scaled(.secondary).foregroundStyle(Theme.quiet)
            Spacer(minLength: 4)
            Button("Show") { if key.hasPrefix("review:") { model.showPane(key) } else { model.show(jobId: key) } }
                .buttonStyle(.desk(.secondary, .small))
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    private func masterPane(_ spec: PaneSpec?) -> some View {
        let master = model.state.master
        let ask = model.state.asks.first
        return VStack(alignment: .leading, spacing: 8) {
            paneHeader(name: "master", state: master == nil ? "not running" : master!.isAsking ? "waiting for you" : master!.status,
                       dot: master?.isAsking == true ? Theme.warn : Theme.accentInk) { model.openMaster() }
            Text(spec == nil ? "claude --bg -n master" : "claude attach master").foregroundStyle(Theme.quiet)
            if let ask { Text("\(ask.task): \(ask.text)").fixedSize(horizontal: false, vertical: true) }
            else if let detail = master?.detail { Text(detail).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            Text("> _").foregroundStyle(Theme.quiet)
        }
        .scaled(.code)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.tintLine))
    }

    private func paneHeader(name: String, state: String, dot: Color, show: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(name).scaled(.code.weight(.medium)).lineLimit(1)
            Text(state).scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1)
            Spacer(minLength: 4)
            Button("Show", action: show).buttonStyle(.desk(.secondary, .small))
        }
    }
}

/// Where the master runs, what its workers start with, and the terminal it shows in.
private struct MasterDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        DetailColumn(width: 320) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Where it runs")
                FieldRows(labelWidth: 72) {
                    FieldRow("Folder", (model.masterFolder.path as NSString).abbreviatingWithTildeInPath, mono: true)
                    FieldRow("Also sees", config.masterFolderList.joined(separator: "\n"), mono: true)
                    FieldRow("Mode", DeskService.masterPermissionMode, mono: true)
                    FieldRow("Skill", "fhenix-workflow:coordinate-tasks", mono: true)
                    FieldRow(label: "Plugins") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(config.pluginDir.isEmpty ? "The installed plugins" : (config.pluginDir as NSString).abbreviatingWithTildeInPath)
                                .font(config.pluginDir.isEmpty ? nil : AppTextStyle.code.font(scale: model.textScale))
                            if !config.pluginDir.isEmpty { Text("A plugin folder, for trying skill changes").scaled(.secondary).foregroundStyle(Theme.quiet) }
                        }
                    }
                }
            }
            HStack {
                Text("Events from Desk")
                Spacer()
                Circle().fill(config.sendEvents ? Theme.ok : Theme.control).frame(width: 6, height: 6)
                Text(config.sendEvents ? "On" : "Off").fontWeight(.medium)
            }
            .padding(.top, 16)
            .overlay(alignment: .top) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Workers start with")
                FieldRows(labelWidth: 72) {
                    FieldRow("Plugins", config.pluginDir.isEmpty ? "The installed plugins" : "The same plugin folder")
                    FieldRow("Mode", DeskService.masterPermissionMode, mono: true)
                }
            }
            .padding(.top, 16)
            .overlay(alignment: .top) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Terminal")
                FieldRows(labelWidth: 72) {
                    FieldRow("App", config.terminalApp == .iTerm ? "iTerm2, through tmux" : "Terminal, through tmux")
                    FieldRow("Session", TmuxLayout.session, mono: true)
                    FieldRow("Layout", "Master on the left, a pane per running session on the right")
                    FieldRow("Each pane", "claude attach <id>", mono: true)
                }
            }
            .padding(.top, 16)
            .overlay(alignment: .top) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
            Spacer(minLength: 0)
            Text("Closing iTerm leaves every session running; Open in iTerm brings the layout back.")
                .scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
        }
    }
}
