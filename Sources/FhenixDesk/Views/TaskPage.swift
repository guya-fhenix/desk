import AppKit
import DeskCore
import SwiftUI

extension AppTextStyle {
    /// A page's title under its breadcrumb: a task's, a PR's.
    static let taskPageTitle = AppTextStyle(size: 18, weight: .semibold)
}

/// A page over the Tasks list, a task's or a PR's: a header bar with the breadcrumb, the title and the page's presses; the
/// main column scrolling under it; the details column on the right. ← goes back and M shows the master, once the page has
/// the focus, which it takes as it opens.
struct TaskPageFrame<Crumb: View, Title: View, Actions: View, Main: View, Details: View>: View {
    var model: AppModel
    /// The screen it opened over, the breadcrumb's first word.
    var back: String
    var onBack: () -> Void
    /// After "Tasks /": what the page is.
    @ViewBuilder var crumb: Crumb
    @ViewBuilder var title: Title
    @ViewBuilder var actions: Actions
    @ViewBuilder var main: Main
    @ViewBuilder var details: Details
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 0) {
                            Button(action: onBack) { Text(back) }.buttonStyle(.plain).handCursor().help("Back to \(back) (←)")
                            Text(" / ")
                            crumb
                        }
                        .scaled(.secondary)
                        .foregroundStyle(Theme.quiet)
                        .lineLimit(1)
                        title
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 8) { actions }.fixedSize()
                }
                .padding(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24))
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) { main }
                        .padding(EdgeInsets(top: 18, leading: 24, bottom: 20, trailing: 24))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .deskScrollBar()
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) { details }
                    .padding(EdgeInsets(top: 18, leading: 22, bottom: 16, trailing: 22))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 360)
            .frame(maxHeight: .infinity)
            .background(Theme.surface)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.rule).frame(width: 1) }
        }
        .background(Theme.ground)
        .environment(\.focusPage, { [focus = $focused] in focus.wrappedValue = true })
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // A turn of the run loop later: asked for while the page is still being put on screen, in place of the list that
        // had focus, the focus is dropped, and ← does nothing until a click.
        .task {
            await Task.yield()
            focused = true
        }
        // Not while a field is being typed in, such as the title being renamed: there the keys are the field's.
        .onKeyPress(.leftArrow) { typing ? .ignored : run(onBack) }
        .onKeyPress("m") { typing ? .ignored : run(model.openMaster) }
    }

    private var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }

    private func run(_ action: () -> Void) -> KeyPress.Result {
        action()
        return .handled
    }
}

/// A task's own page: its ticket's first line and the stages its PRs have reached; its PRs, each opening its page, and
/// what they depend on; the sessions behind it. Beside them its ticket, the master's questions about it, and what
/// happened to it lately. Desk sends nothing to a session: the presses show the master's pane, or a worker's, in iTerm.
struct TaskPage: View {
    var task: WorkTask
    var model: AppModel
    var back = "Tasks"
    var onBack: () -> Void
    /// Opens a page on top of this one: a PR's.
    var open: (Route) -> Void

    var body: some View {
        let ticket = task.origin == .ticket ? model.state.ticket(task.id) : nil
        TaskPageFrame(model: model, back: back, onBack: onBack) {
            TaskKicker(task: task, ticket: ticket)
        } title: {
            Text(task.title).scaled(.taskPageTitle).tracking(-0.2).lineLimit(2).textSelection(.enabled)
        } actions: {
            if let ticket { Button("Open in Jira") { model.open(ticket.url) }.buttonStyle(.desk) }
            Button("Master in iTerm") { model.openMaster() }.buttonStyle(.deskPrimary).help("Show the master's pane in iTerm (M)")
        } main: {
            VStack(alignment: .leading, spacing: 14) {
                if let first = ticket.flatMap(TaskText.firstLine) {
                    Text("\(Text(first.label.map { "\($0) " } ?? "").fontWeight(.semibold))\(first.text)")
                        .frame(maxWidth: 640, alignment: .leading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                TaskStages(stages: TaskText.stages(task, merged: merged))
            }
            pullRequests
            sessions
        } details: {
            if let ticket { ticketFields(ticket) } else { taskFields }
            ForEach(model.state.asks.filter { $0.task == task.id }) { TaskAskCallout(ask: $0, model: model, tinted: true) }
            activity
        }
    }

    /// Your PRs on this ticket merged this month: the last stage's count.
    private var merged: Int {
        guard task.origin == .ticket else { return 0 }
        return (model.state.github?.mergedRecent ?? []).filter { model.state.ticketKeys[$0.url]?.contains(task.id) == true }.count
    }

    /// Every session behind it, the master aside: its worker first, then any other that touched its PRs or started on its
    /// ticket.
    private var sessionsBehind: [ClaudeJob] {
        var seen = Set<String>()
        let ticketSessions = task.origin == .ticket ? model.state.sessions(forTicket: task.id) : []
        return (task.sessions + task.pullRequests.flatMap(model.state.claudeJobs(for:)) + ticketSessions)
            .filter { $0.role != .master && seen.insert($0.id).inserted }
    }

    @ViewBuilder private var pullRequests: some View {
        let repos = Set(task.pullRequests.map(\.repo)).count
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(repos > 0 ? "Pull requests · \(repos) \(repos == 1 ? "repo" : "repos")" : "Pull requests").padding(.bottom, 6)
            if task.pullRequests.isEmpty {
                Text("No pull request yet.").foregroundStyle(Theme.quiet)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(task.pullRequests.enumerated()), id: \.element.url) { index, pr in
                        TaskPullRequestRow(pr: pr, model: model) { open(.pr(pr.url)) }
                            .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Theme.ruleSoft).frame(height: 1) } }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rule))
            }
            ForEach(task.dependsOn, id: \.self) { dependency in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warn)
                    Text("Depends on \(Text(TaskHeader.dependency(dependency)).font(AppTextStyle.code.font(scale: 1))): \(dependency.contains("@") ? "no open pull request opens that branch yet." : "an open pull request that isn't yours.")")
                        .fixedSize(horizontal: false, vertical: true)
                        .help(dependency)
                }
                .scaled(.secondary)
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 10)
            }
        }
    }

    @ViewBuilder private var sessions: some View {
        let sessions = sessionsBehind
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Sessions behind it", count: sessions.count).padding(.bottom, 6)
            if sessions.isEmpty {
                Text("No session yet. The master starts a worker when you hand it the task.").foregroundStyle(Theme.quiet).padding(.vertical, 8)
            }
            ForEach(sessions) { job in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    SessionMark(job: job).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Text(role(job)).fontWeight(.medium)) \(Text(job.name).font(AppTextStyle.code.font(scale: 1)))").lineLimit(1)
                        Text("\(job.status) · \(TaskText.when(job.updatedAt))").scaled(.code).foregroundStyle(Theme.quiet).lineLimit(1)
                    }
                    .frame(width: 172, alignment: .leading)
                    Text(job.detail ?? "").frame(maxWidth: 560, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Show in iTerm") { model.show(jobId: job.id) }.buttonStyle(.desk(.secondary, .small))
                        .help("Show \(job.name)'s pane in iTerm")
                }
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
            }
            if !sessions.isEmpty { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
            Text("Full transcripts stay in Claude Code on this Mac.").scaled(.secondary).foregroundStyle(Theme.quiet).padding(.top, 8)
        }
    }

    private func role(_ job: ClaudeJob) -> String {
        switch job.role {
        case .worker: return task.origin == .session && task.pullRequests.isEmpty && job == task.worker ? "Investigation" : "Worker"
        case .review: return "Review"
        case .master, .other: return "Session"
        }
    }

    private func ticketFields(_ ticket: Ticket) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Ticket · from Jira").frame(minHeight: 32, alignment: .bottomLeading).padding(.bottom, 8)
            FieldRows(labelWidth: 84) {
                FieldRow("Key", ticket.key, mono: true)
                FieldRow("Status", ticket.status)
                if let priority = ticket.priority { FieldRow(label: "Priority") { PriorityMark.text(priority) } }
                FieldRow("Assignee", ticket.assignedToMe ? "You" : ticket.assignee ?? "Unassigned")
                if let reporter = ticket.reporter { FieldRow("Opened by", reporter) }
            }
            Button("Open in Jira") { model.open(ticket.url) }
                .buttonStyle(.plain).underline().scaled(.secondary).foregroundStyle(Theme.quiet).handCursor()
                .padding(.top, 10)
        }
    }

    private var taskFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Task").frame(minHeight: 32, alignment: .bottomLeading).padding(.bottom, 8)
            FieldRows(labelWidth: 84) {
                FieldRow("Key", TaskHeader.label(task), mono: true)
                FieldRow("From", task.origin == .session ? "A session, no ticket" : "A pull request, no ticket")
                FieldRow("Waits on", TaskText.waits(task.waitingOn(asked: model.state.askedTasks)))
                FieldRow("Moved", "\(Format.age(task.updatedAt)) ago")
            }
        }
    }

    @ViewBuilder private var activity: some View {
        let items = TaskText.activity(task, sessions: sessionsBehind, asks: model.state.asks.filter { $0.task == task.id })
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Activity")
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(TaskText.stamp(item.at)).scaled(.code).foregroundStyle(Theme.quiet).frame(width: 52, alignment: .leading)
                            .help(Format.date(item.at))
                        Text(item.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// One PR in a task page's table: its key, title, size, checks and age; under them its branch and what it waits on. A
/// press opens its page.
private struct TaskPullRequestRow: View {
    var pr: PullRequest
    var model: AppModel
    var open: () -> Void

    var body: some View {
        let state = RowState.of(pr)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Text(pr.taskRef).scaled(.code).lineLimit(1).frame(width: 124, alignment: .leading)
                    Text(pr.title).scaled(.rowTitle).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: "+\(pr.additions) −\(pr.deletions)").scaled(.code).foregroundStyle(Theme.quiet)
                        .frame(width: 84, alignment: .leading)
                    HStack(spacing: 5) {
                        Circle().fill(TaskText.checksColor(pr)).frame(width: 6, height: 6)
                        Text(TaskText.checks(pr))
                    }
                    .scaled(.secondary)
                    .frame(width: 72, alignment: .leading)
                    Text(Format.age(pr.updatedAt)).scaled(.code).foregroundStyle(Theme.quiet).frame(width: 36, alignment: .trailing)
                }
                HStack(spacing: 12) {
                    Text(pr.headRef).font(AppTextStyle.code.font(scale: 1)).lineLimit(1).truncationMode(.tail)
                        .frame(width: 124, alignment: .leading)
                        .help("\(pr.baseRef) ← \(pr.headRef)")
                    Text("\(Text(state.title).foregroundStyle(Theme.ink).fontWeight(.medium))\(note(state))").lineLimit(1)
                }
                .scaled(.secondary)
                .foregroundStyle(Theme.quiet)
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(Theme.inset.opacity(0.5), cornerRadius: 0)
        .help("Open \(pr.taskRef)")
    }

    /// " · sits on ohad/back_to_super_majority", and for a draft no one has self-reviewed, who runs it.
    private func note(_ state: RowState) -> String {
        var parts: [String] = []
        if state == .draft(.notRun) { parts.append("the worker runs it when you say") }
        if let session = model.state.session(for: pr), session.isRunning, let detail = session.detail { parts.append("worker: \(detail)") }
        if pr.baseRef != pr.defaultBranch { parts.append("sits on \(pr.baseRef)") }
        return parts.map { " · \($0)" }.joined()
    }
}

/// The five stages a task goes through, as a row of bars: done ones with a tick, the current one in the accent, the rest
/// ahead in grey, each with a line on where it stands.
private struct TaskStages: View {
    var stages: [TaskText.Stage]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(stages) { stage in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(stage.state == .done ? Theme.quiet : stage.state == .current ? Theme.accentInk : Theme.control)
                        .frame(height: 3)
                    HStack(spacing: 6) {
                        if stage.state == .done { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.quiet) }
                        Text(stage.title)
                            .fontWeight(stage.state == .current ? .semibold : stage.state == .done ? .medium : .regular)
                            .foregroundStyle(stage.state == .ahead && stage.id == stages.last?.id ? Theme.quiet : Theme.ink)
                    }
                    Text(stage.note).scaled(.secondary).foregroundStyle(stage.state == .current ? Theme.ink : Theme.quiet).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityValue(stage.state == .done ? "done" : stage.state == .current ? "current" : "ahead")
            }
        }
    }
}

/// What the task screens say about a task in words, worked out from its PRs and sessions: nothing of it is stored.
enum TaskText {
    struct Stage: Identifiable {
        enum State { case done, current, ahead }
        var title: String
        var note: String
        var state: State
        var id: String { title }
    }

    /// Plan, Build, Self-review, In review, Merged, read off the task's open PRs: planned once a worker or a PR exists,
    /// built once a PR does, self-reviewed once no draft lacks the self-review's label, through review once every PR is
    /// ready to merge. `merged` counts its PRs merged this month. The first stage not done is the current one.
    static func stages(_ task: WorkTask, merged: Int) -> [Stage] {
        let prs = task.pullRequests
        let drafts = prs.filter { $0.isDraft && !$0.isLocallyReviewed }
        let inReview = prs.filter { !$0.isDraft }
        let workerStarted = task.sessions.compactMap(\.createdAt).min()
        let built = prs.map(\.createdAt).min()
        let worker = task.worker
        let done = [
            !prs.isEmpty || worker != nil,
            !prs.isEmpty,
            !prs.isEmpty && drafts.isEmpty,
            !prs.isEmpty && prs.allSatisfy { FlowStage.of($0) == .approved },
            !prs.isEmpty && prs.allSatisfy { $0.state == .merged },
        ]
        let notes = [
            workerStarted.map(day) ?? (worker == nil ? "No worker yet" : "Worker started"),
            built.map(day) ?? (worker?.isRunning == true ? "Worker at it" : "No pull request yet"),
            drafts.isEmpty ? (prs.isEmpty ? "After a pull request" : "Done") : "Waits on " + drafts.map { "#\($0.number)" }.joined(separator: ", "),
            inReview.isEmpty ? "None in review" : inReview.map { "#\($0.number) \(RowState.of($0).title.lowercased())" }.joined(separator: ", "),
            "\(merged) of \(prs.count + merged)",
        ]
        let current = done.firstIndex(of: false)
        return ["Plan", "Build", "Self-review", "In review", "Merged"].enumerated().map { index, title in
            Stage(title: title, note: notes[index], state: done[index] ? .done : index == current ? .current : .ahead)
        }
    }

    /// The ticket's TL;DR, or its first line of text: "Pick how the nodes jointly sign…", with "TL;DR" as its label.
    static func firstLine(_ ticket: Ticket) -> (label: String?, text: String)? {
        let lines = ticket.description.split(whereSeparator: \.isNewline)
            .map { $0.replacing(/[*_`]+/, with: "").replacing(/^#+\s*/, with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let index = lines.firstIndex(where: { $0.lowercased().hasPrefix("tl;dr") }) {
            let rest = lines[index].dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
            if !rest.isEmpty { return ("TL;DR", rest) }
            if index + 1 < lines.count { return ("TL;DR", lines[index + 1]) }
        }
        return lines.first.map { (nil, $0) }
    }

    /// "Mon 9 Nov".
    static func day(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }

    /// "today 17:28", "Sun 15:02", or "9 Nov" further back.
    static func when(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDateInToday(date) { return "today \(date.clock)" }
        if now.timeIntervalSince(date) < 6 * 86_400 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(date.clock)" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// An activity line's time: "17:28" today, "Sun" this week, "9 Nov" before.
    static func stamp(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDateInToday(date) { return date.clock }
        if now.timeIntervalSince(date) < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// What happened to the task lately, newest first, from what Desk can see: when its sessions started and finished,
    /// when the master asked about it, when its PRs opened and last moved.
    static func activity(_ task: WorkTask, sessions: [ClaudeJob], asks: [MasterAsk], limit: Int = 8) -> [(at: Date, text: String)] {
        var items: [(at: Date, text: String)] = []
        for job in sessions {
            let who = job.role == .worker ? "Worker \(job.name)" : "Session \(job.name)"
            if let started = job.createdAt { items.append((started, "\(who) started")) }
            if job.isIdle { items.append((job.updatedAt, "\(who) finished")) }
        }
        for ask in asks { if let at = ask.askedAt { items.append((at, "Master asked you")) } }
        for pr in task.pullRequests {
            items.append((pr.createdAt, "Opened \(pr.taskRef)"))
            if pr.updatedAt.timeIntervalSince(pr.createdAt) > 60 { items.append((pr.updatedAt, "\(pr.taskRef) moved on GitHub")) }
        }
        return Array(items.sorted { $0.at > $1.at }.prefix(limit))
    }

    /// The checks in a word: "passing", "failing", "running", "none".
    static func checks(_ pr: PullRequest) -> String {
        switch pr.checks {
        case .success: return "passing"
        case .failure, .error: return "failing"
        case .pending, .expected: return "running"
        case .none: return "none"
        }
    }

    static func checksColor(_ pr: PullRequest) -> Color {
        switch pr.checks {
        case .success: return Theme.ok
        case .failure, .error: return Theme.danger
        case .pending, .expected: return Theme.warn
        case .none: return Theme.control
        }
    }

    static func waits(_ wait: TaskWait) -> String {
        switch wait {
        case .you: return "You"
        case .worker: return "Its worker"
        case .reviewers: return "Reviewers"
        case .nobody: return "Nobody"
        }
    }
}
