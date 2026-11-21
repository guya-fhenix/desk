import DeskCore
import SwiftUI

/// The master and its workers, as they run in iTerm: the sessions down a column, each with its task, the `desk` layout
/// drawn with a Show per pane, and the events Desk told the master today; beside them where the master runs and how its
/// terminal is set up. What a session is doing, and what the master asked you, are not here: the first is in `claude
/// agents`, the second in the master's pane. Every press puts a pane in front, and you type there; Restart alone types
/// for you, one line asking the master for its handoff.
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
                    restartPanel
                    LayoutSketch()
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

    /// The title with the master's presses beside it, or under it where the column is too narrow for both on a line.
    private var header: some View {
        let title = VStack(alignment: .leading, spacing: 2) {
            Text(kicker).scaled(.secondary).foregroundStyle(Theme.quiet)
            Text("Master and its workers").scaled(.title.weight(.semibold))
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                title.fixedSize()
                Spacer(minLength: 4)
                presses
            }
            VStack(alignment: .leading, spacing: 10) {
                title
                HStack(spacing: 8) { presses }
            }
        }
    }

    @ViewBuilder private var presses: some View {
        let master = model.state.master
        if master != nil {
            Button("Stop master") { model.stopMaster() }.buttonStyle(.desk)
                .disabled(model.masterRestart != nil)
                .help("The master ends and leaves Claude Code's list; its workers run on")
            Button("Restart master") { model.confirmingMasterRestart = true }.buttonStyle(.desk)
                .disabled(model.confirmingMasterRestart || model.masterRestart != nil)
                .help("A new master in place of this one, after it writes its handoff; its workers run on")
        }
        Button { model.openMaster() } label: {
            HStack(spacing: 8) { Text(master == nil ? "Start master" : "Open in iTerm"); ButtonKey(key: "↩") }
        }
        .buttonStyle(.deskPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(model.startingMaster || model.masterRestart == .restarting)
    }

    private var kicker: String {
        let started = model.state.master?.createdAt.map { " · started \($0.clock)" } ?? ""
        let app = model.config.terminalApp == .iTerm ? "iTerm2" : "Terminal"
        if model.masterRestart == .restarting { return "Stopping the master and starting a new one…" }
        return model.state.master == nil ? "No master running" : "tmux session \(TmuxLayout.session) · shown in \(app)\(started)"
    }

    /// Restart's two steps, each a tinted panel under the header: your yes, then the wait for the master's handoff, with
    /// the way to restart without it when the master doesn't answer.
    @ViewBuilder private var restartPanel: some View {
        if model.masterRestart == .waitingForHandoff {
            panel(
                "Waiting for the master's handoff…", working: true,
                "Desk asked the master to write handoff.md, and restarts it as soon as the file is there. If the master doesn't answer, restart without it: the new master then starts from the task list and its open questions only."
            ) {
                Button("Restart without the handoff") { model.restartMaster(handoff: false) }.buttonStyle(.desk)
                Button("Cancel") { model.cancelRestart() }.buttonStyle(.desk)
            }
        } else if model.confirmingMasterRestart, model.masterRestart == nil, model.state.master != nil {
            panel(
                "Restart the master?", working: false,
                "Desk asks the master to write its handoff and waits for it. Then it stops the master and starts a new one, with a new conversation, which reads the handoff. Your workers run on."
            ) {
                Button("Restart") { model.restartMaster(handoff: true) }.buttonStyle(.deskPrimary)
                Button("Cancel") { model.confirmingMasterRestart = false }.buttonStyle(.desk)
            }
        }
    }

    private func panel(_ title: String, working: Bool, _ text: String, @ViewBuilder presses: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.mini) }
                Text(title).fontWeight(.semibold)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { presses() }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tint, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.tintLine))
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

/// The sessions Desk knows of: the master first, each open task's worker under its task's title, and the review
/// sessions. A press shows that session's pane in iTerm.
private struct SessionsColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        var seen = Set<String>()
        let workers = model.state.tasks.compactMap { task in task.worker.map { (job: $0, task: task) } }
            .filter { seen.insert($0.job.id).inserted }
        let reviews = model.state.claudeJobs.filter { $0.role == .review }
        VStack(alignment: .leading, spacing: 2) {
            Text("Sessions").scaled(.title).padding(.horizontal, 8).frame(minHeight: 32).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    masterRow
                    if !workers.isEmpty {
                        SectionLabel("Workers", count: workers.count).padding(EdgeInsets(top: 18, leading: 8, bottom: 4, trailing: 8))
                        ForEach(workers, id: \.job.id) { SessionRow2(job: $0.job, line: $0.task.title) }
                    }
                    if !reviews.isEmpty {
                        SectionLabel("Reviews", count: reviews.count).padding(EdgeInsets(top: 18, leading: 8, bottom: 4, trailing: 8))
                        ForEach(reviews) { SessionRow2(job: $0, line: nil) }
                    }
                }
            }
            Text("The master starts one worker per task. What each is doing is in claude agents, on the right in iTerm.")
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
                    Circle().fill(model.masterDot).frame(width: 8, height: 8)
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
}

/// A session in the column: the session mark, its name in DM Mono, and under them what it is on, a worker's task.
private struct SessionRow2: View {
    @Environment(AppModel.self) private var model
    var job: ClaudeJob
    var line: String?

    var body: some View {
        Button { model.show(jobId: job.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    SessionMark().frame(width: 12)
                    Text(job.name).scaled(.code).lineLimit(1)
                }
                if let line {
                    Text(line).scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(2).padding(.leading, 20)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(job.name) in iTerm")
    }
}

/// A background session's mark, the same for every one: Desk says which session, never what it is doing.
struct SessionMark: View {
    var body: some View {
        Image(systemName: "terminal").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.quiet).accessibilityHidden(true)
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
        let showing = model.agentsShowing.flatMap { id in model.state.claudeJobs.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 8) {
            paneHeader(name: showing?.name ?? "claude agents", state: showing.map { _ in "in claude agents' place" } ?? "") { model.openMaster() }
            Text(showing.map { "claude attach \($0.name)" } ?? "claude agents").foregroundStyle(Theme.quiet)
            if showing == nil {
                Text("Every background session and what it is doing: who works, who is done, who waits for you.")
                    .scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
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
            Circle().fill(Theme.accentInk).frame(width: 7, height: 7)
            Text(job?.name ?? (key.hasPrefix("review:") ? "review" : key)).scaled(.code.weight(.medium)).lineLimit(1)
            Spacer(minLength: 4)
            Button("Show") { if key.hasPrefix("review:") { model.showPane(key) } else { model.show(jobId: key) } }
                .buttonStyle(.desk(.secondary, .small))
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    private func masterPane(_ spec: PaneSpec?) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            paneHeader(name: "master", state: model.state.master == nil ? "not running" : "") { model.openMaster() }
            Text(spec == nil ? "claude --bg -n master" : "claude attach master").foregroundStyle(Theme.quiet)
            Spacer(minLength: 0)
            Text("> _").foregroundStyle(Theme.quiet)
        }
        .scaled(.code)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.tintLine))
    }

    private func paneHeader(name: String, state: String, show: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.accentInk).frame(width: 7, height: 7)
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
