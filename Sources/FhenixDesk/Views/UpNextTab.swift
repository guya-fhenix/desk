import DeskCore
import SwiftUI

/// The landing screen: what waits on you, under the section that says what to do — the master's questions and your PRs
/// whose move is yours, ready to merge, drafts to submit, the reviews waiting on you (a few, the rest on Reviews), the
/// workers at it, the Jira moves the app suggests, the sprint's tickets nothing has started, and your PRs that wait on
/// someone else. The selected row's details sit in the column on the right with its presses. Return, → or a double-click
/// opens the PR's or the ticket's page here, and its back link, or ←, returns here; on a question it shows the master in
/// iTerm, on a worker its pane. The reviews follow the Reviews screen's filters.
struct UpNextTab: View {
    @Environment(AppModel.self) private var model
    /// A row's id: a PR's url, a ticket's key, `ask:` a question, `job:` a worker.
    @State private var selection: String?
    /// The pages open over the list; empty shows the list.
    @State private var path: [Route] = []
    @FocusState private var listFocused: Bool
    /// With Reduce Motion on, the list jumps to the selected row instead of sliding there.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var filters = ReviewFilters()

    var body: some View {
        let sections = self.sections
        let rows = sections.flatMap(\.items).map(\.id)
        RouteStack(path: $path, back: "Up Next") {
            HStack(spacing: 0) {
                list(sections, rows: rows)
                if let item = sections.flatMap(\.items).first(where: { $0.id == selection }) {
                    UpNextDetails(item: item, model: model, open: open)
                        .id(item.id)
                }
            }
            .background(Theme.ground)
        }
        .focusedSceneValue(\.routePath, $path)
        .selectsFirstRow(rows.first, selection: $selection)
    }

    /// The sections in the order the screen shows them, empty ones left out. Only the first few reviews show: the rest
    /// are a press away on Reviews.
    private var sections: [UpNextSectionRows] {
        let plan = model.state.upNext(reviewDays: filters.window, hiding: filters.hidden, needingApproval: filters.needsApproval)
        func prs(_ section: UpNextSection) -> [UpNextItem] {
            (plan.first { $0.section == section }?.pullRequests ?? []).map { .pullRequest($0, section) }
        }
        var seen = Set<String>()
        let workers = model.state.tasks.compactMap { task in task.worker.map { (job: $0, task: task) } }
            .filter { $0.job.isBusy && seen.insert($0.job.id).inserted }
        let reviews = prs(.toReview)
        return [
            UpNextSectionRows(title: "Needs you", items: model.state.asks.map(UpNextItem.ask) + prs(.yourMove)),
            UpNextSectionRows(title: UpNextSection.readyToMerge.title, items: prs(.readyToMerge)),
            UpNextSectionRows(title: UpNextSection.draftsToSubmit.title, items: prs(.draftsToSubmit)),
            UpNextSectionRows(title: UpNextSection.toReview.title, items: Array(reviews.prefix(Self.reviewsShown)), total: reviews.count),
            UpNextSectionRows(title: "Workers at it", items: workers.map { .worker($0.job, $0.task) }),
            UpNextSectionRows(title: "Jira moves", items: model.state.ticketDrifts.map(UpNextItem.move)),
            UpNextSectionRows(title: "Ready to start", items: model.state.ticketsToStart.map(UpNextItem.ticket)),
            UpNextSectionRows(title: UpNextSection.waiting.title, items: prs(.waiting)),
        ]
        .filter { !$0.items.isEmpty }
    }

    private static let reviewsShown = 3

    @ViewBuilder private func list(_ sections: [UpNextSectionRows], rows: [String]) -> some View {
        // The sources that have neither answered nor failed yet: until GitHub has, an empty list means nothing.
        let pending = Source.allCases.filter { model.state.lastRefresh[$0] == nil && model.state.errors[$0] == nil }
        Screen {
            ScreenTitle(title: "Up Next", subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .padding(.bottom, 18)
        } content: {
            if pending.contains(.github) || (sections.isEmpty && !pending.isEmpty) { syncing(pending) }
            ForEach(Source.allCases, id: \.self) { source in
                if source == .github, model.state.github == nil, let error = model.state.errors[.github] {
                    // Nothing from GitHub has ever loaded, so this is no stale list: say what is missing.
                    EmptyState(
                        icon: "exclamationmark.triangle", text: "GitHub didn't answer, so Up Next can't say which PRs wait on you.",
                        detail: error, actionTitle: "Retry", action: { Task { await model.refresh(.github) } }
                    )
                    .padding(Theme.Space.m)
                    .background(Theme.warn.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.vertical, Theme.Space.m)
                } else {
                    StaleBanner(source: source)
                }
            }
            if pending.contains(.github) {
                placeholders
            } else if sections.isEmpty, pending.isEmpty, model.state.errors.isEmpty {
                // Says how fresh "nothing" is, and where to go next, rather than one grey line.
                EmptyState(
                    icon: "checkmark.circle",
                    text: "All clear. \(Source.names(Source.allCases)) all synced \(Format.ago(model.state.lastRefresh.values.min())).",
                    actionTitle: "Browse the review queue", action: { model.pendingTab = .reviews }
                )
                .padding(.vertical, 20)
            }
            ScrollViewReader { proxy in
                // A click or the arrow keys select a row; Return, → or a double-click opens it.
                List(selection: $selection) {
                    ForEach(sections) { section in
                        SectionLabel(section.title, count: section.total, tone: section.title == "Needs you" ? Theme.danger : Theme.quiet)
                            .padding(EdgeInsets(top: section.id == sections.first?.id ? 0 : 24, leading: 10, bottom: 6, trailing: 10))
                            .plainListRow().selectionDisabled()
                        ForEach(section.items) { item in
                            ListRow(selected: selection == item.id) { UpNextRow(item: item, model: model, selected: selection == item.id) }
                        }
                        if section.total > section.items.count {
                            Button { model.pendingTab = .reviews } label: {
                                Text("\(section.total - section.items.count) more in Reviews").underline(color: Theme.control)
                            }
                                .buttonStyle(.plain).handCursor()
                                .scaled(.secondary).foregroundStyle(Theme.quiet)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .plainListRow().selectionDisabled()
                        }
                    }
                }
                .deskList()
                // Focused on arrival and on the way back from a page, so the keys work without a click first.
                .focused($listFocused)
                .task(id: path.isEmpty) { if path.isEmpty { listFocused = true } }
                .onKeyPress(.rightArrow) {
                    guard let selection else { return .ignored }
                    open(selection)
                    return .handled
                }
                // J and K walk the rows as the arrows do; M shows the master.
                .onKeyPress(keys: ["j", "k", "m"]) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    if press.key == "m" {
                        model.openMaster()
                    } else {
                        selection = Self.step(rows, from: selection, by: press.key == "j" ? 1 : -1)
                    }
                    return .handled
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first { menu(id) }
                } primaryAction: { ids in
                    if let id = ids.first { open(id) }
                }
                .onChange(of: selection, initial: true) { _, id in
                    if let id { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            KeyHints(hints: [(["J", "K"], "move"), (["↩"], "open"), (["M"], "master"), (["⌘R"], "sync")])
        }
    }

    @ViewBuilder private func menu(_ id: String) -> some View {
        if id.hasPrefix("ask:") {
            Button("Answer in iTerm") { model.openMaster() }
        } else if id.hasPrefix("job:") {
            Button("Show in iTerm") { model.show(jobId: String(id.dropFirst(4))) }
        } else if let ticket = model.state.ticket(id) {
            Button("Open in Jira") { model.open(ticket.url) }
            Button("Copy Key") { Clipboard.copy(ticket.key) }
        } else if let pr = model.state.github?.allOpen.first(where: { $0.url == id }) {
            PullRequestMenu(pr: pr, model: model)
        }
    }

    /// "Reading GitHub and Jira… Git answered.": which sources Up Next still waits on, over the rows that stand in for
    /// theirs.
    private func syncing(_ pending: [Source]) -> some View {
        let answered = Source.allCases.filter { model.state.lastRefresh[$0] != nil }
        return HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.mini)
            Text("Reading \(Source.names(pending))…" + (answered.isEmpty ? "" : " \(Source.names(answered)) answered."))
        }
        .scaled(.secondary)
        .foregroundStyle(Theme.quiet)
        .padding(.vertical, Theme.Space.m)
    }

    /// Grey bars where the first rows will be, so the screen reads as loading rather than empty.
    private var placeholders: some View {
        VStack(spacing: 0) {
            ForEach([CGFloat(360), 280, 320], id: \.self) { width in
                HStack(spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().frame(width: width, height: 10)
                        Capsule().frame(width: width - 90, height: 8).opacity(0.7)
                    }
                    Spacer()
                    Capsule().frame(width: 90, height: 10)
                }
                .foregroundStyle(Theme.inset)
                .padding(Theme.Space.m)
            }
        }
        .accessibilityHidden(true)
    }

    /// The row `by` steps from `id`, held at the ends; the first row when nothing is selected. The Jira screen's J and K
    /// walk its rows with it too.
    static func step(_ rows: [String], from id: String?, by offset: Int) -> String? {
        guard let id, let index = rows.firstIndex(of: id) else { return rows.first }
        return rows[min(max(index + offset, 0), rows.count - 1)]
    }

    /// The checks in a word: "passing", "failing", "running". Search says it the same way.
    static func checks(_ pr: PullRequest) -> String {
        switch pr.checks {
        case .success: return "passing"
        case .failure, .error: return "failing"
        case .pending, .expected: return "running"
        case .none: return "no checks"
        }
    }

    /// A PR's page, with its row selected behind it for the way back, or a ticket in Jira, which has no page here. A
    /// question of the master's shows the master in iTerm, where it is answered, and a worker its own pane.
    private func open(_ id: String) {
        selection = id
        if id.hasPrefix("ask:") {
            model.openMaster()
        } else if id.hasPrefix("job:") {
            model.show(jobId: String(id.dropFirst(4)))
        } else {
            if let ticket = model.state.ticket(id) { model.open(ticket.url) } else { path.append(.pr(id)) }
        }
    }
}

/// One of Up Next's sections: its title, its rows, and how many it has in all when only the first few show.
struct UpNextSectionRows: Identifiable {
    var title: String
    var items: [UpNextItem]
    var total: Int

    init(title: String, items: [UpNextItem], total: Int? = nil) {
        self.title = title
        self.items = items
        self.total = total ?? items.count
    }

    var id: String { title }
}

/// A row of Up Next: a question of the master's, a PR under its section, a worker at work on its task, a suggested Jira
/// move, or a ticket to start.
enum UpNextItem: Identifiable {
    case ask(MasterAsk)
    case pullRequest(PullRequest, UpNextSection)
    case worker(ClaudeJob, WorkTask)
    case move(TicketDrift)
    case ticket(Ticket)

    /// What the list selects it by; never a PR's url or a ticket's key for a question or a worker.
    var id: String {
        switch self {
        case .ask(let ask): return "ask:\(ask.id)"
        case .pullRequest(let pr, _): return pr.url
        case .worker(let job, _): return "job:\(job.id)"
        case .move(let drift): return drift.id
        case .ticket(let ticket): return ticket.key
        }
    }
}

/// A row as the board draws it: the state's mark, then either two lines — a title over a quiet line — or one, a DM Mono
/// name before the title and a quiet tail after it; a chip and a DM Mono age on the right.
private struct UpNextRow: View {
    var item: UpNextItem
    var model: AppModel
    var selected: Bool

    var body: some View {
        switch item {
        case .ask(let ask):
            row(.dot(Theme.warn), title: "Master asks about \(ask.task)", line: ask.text, chip: "Master", tone: Theme.warn, date: ask.askedAt)
        case .pullRequest(let pr, let section):
            pullRequest(pr, section)
        case .worker(let job, let task):
            row(.job(job), name: task.pullRequests.first.map(Self.name) ?? job.name, title: task.title, line: job.detail,
                chip: job.isAsking ? "Asks you" : "Working", tone: job.isAsking ? Theme.warn : Theme.accentInk, date: job.updatedAt)
        case .move(let drift):
            HStack(spacing: 10) {
                UpNextMark(mark: .dot(drift.stage == .done ? Theme.ok : Theme.accentInk))
                MoveRow(drift: drift, model: model, keyWidth: 150)
            }
        case .ticket(let ticket):
            row(.ring, name: ticket.key, title: ticket.summary, line: ticket.priority, chip: ticket.status, date: nil)
        }
    }

    @ViewBuilder private func pullRequest(_ pr: PullRequest, _ section: UpNextSection) -> some View {
        switch section {
        case .toReview, .draftsToSubmit:
            let need = model.state.reviewNeed(for: pr)
            let onMe = model.state.reviewRequests.contains { $0.url == pr.url }
            let chip = section == .draftsToSubmit ? "Your draft" : need == .reRequested ? ReviewNeed.reRequested.title : onMe ? "On you" : "Open"
            // As the Reviews screen colours them: what is on you in orange, your draft in the accent.
            let tone: Color? = section == .draftsToSubmit ? Theme.accentInk : need == .reRequested || onMe ? Theme.warn : nil
            row(need == .reRequested ? .approved : .ring, name: Self.name(pr), title: pr.title, line: pr.author, chip: chip, tone: tone, date: pr.createdAt)
        default:
            let state = RowState.of(pr)
            let mark: UpNextMark.Kind = switch section {
            case .readyToMerge: .dot(Theme.ok)
            case .waiting: state.move == .draft ? .dot(Theme.accentInk) : .ring
            default: state.move == .draft ? .dot(Theme.accentInk) : .dot(Theme.danger)
            }
            let on = model.state.stackParent(of: pr).map { " · on #\($0.number)" } ?? ""
            row(mark, title: pr.title, line: "\(Self.name(pr))\(on)", chip: nil, date: pr.updatedAt) {
                PullRequestFacets(pr: pr, rebase: model.state.rebaseReason(pr))
            }
        }
    }

    /// "cofhe #1159".
    static func name(_ pr: PullRequest) -> String { "\(pr.repoName) #\(pr.number)" }

    /// Two lines without `name`; one with it. Your PR's facts, in the PR list's columns, where another row has its chip.
    private func row(
        _ mark: UpNextMark.Kind, name: String? = nil, title: String, line: String?, chip: String?, tone: Color? = nil, date: Date?,
        @ViewBuilder facts: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 10) {
            UpNextMark(mark: mark)
            if let name {
                Text(name).scaled(.code).foregroundStyle(Theme.quiet).lineLimit(1).scaledFrame(width: 150, alignment: .leading)
                Text("\(title)\(Text(line.map { " · \($0)" } ?? "").foregroundStyle(Theme.quiet))").lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).scaled(.body.weight(.semibold)).lineLimit(1)
                    if let line { Text(line).foregroundStyle(Theme.quiet).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let chip { StageChip2(text: chip, onTint: selected, color: tone) } else { facts() }
            if let date { AgeText(date: date) } else { Color.clear.scaledFrame(width: 34, height: 1) }
        }
    }
}

/// A row's leading mark: a filled dot in the colour of whose move it is, a ring for one waiting, a ring with a tick for a
/// review to give again, or a session's own mark.
struct UpNextMark: View {
    enum Kind {
        case dot(Color), ring, approved, job(ClaudeJob)
    }

    var mark: Kind

    var body: some View {
        Group {
            switch mark {
            case .dot(let color): Circle().fill(color).frame(width: 10, height: 10)
            case .ring: Circle().strokeBorder(Theme.quiet, lineWidth: 1.5).frame(width: 10, height: 10)
            case .approved:
                Circle().strokeBorder(Theme.quiet, lineWidth: 1.5).frame(width: 10, height: 10)
                    .overlay { Image(systemName: "checkmark").font(.system(size: 6, weight: .bold)).foregroundStyle(Theme.ok) }
            case .job(let job): SessionMark(job: job)
            }
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }
}

/// The selected row in full, with its presses at the foot: a question with its task's PRs and what it depends on; a PR's
/// facts; a worker and its task; a suggested move; a ticket to start.
private struct UpNextDetails: View {
    var item: UpNextItem
    var model: AppModel
    var open: (String) -> Void

    var body: some View {
        DetailColumn(width: 360) {
            switch item {
            case .ask(let ask): askDetails(ask)
            case .pullRequest(let pr, let section): pullRequestDetails(pr, review: section == .toReview || section == .draftsToSubmit)
            case .worker(let job, let task): workerDetails(job, task)
            case .move(let drift): ticketDetails(drift.ticket, kicker: "suggested move") { MoveSuggestion(drift: drift, model: model) }
            case .ticket(let ticket): ticketDetails(ticket, kicker: "ready to start") { EmptyView() }
            }
        }
    }

    @ViewBuilder private func askDetails(_ ask: MasterAsk) -> some View {
        let task = model.state.tasks.first { $0.id == ask.task }
        DetailHeader(kicker: "Master asks · about \(ask.task)" + (ask.askedAt.map { " · \(Format.age($0)) ago" } ?? ""), title: ask.text)
        if let task { taskParts(task) }
        if let error = model.terminalError ?? model.masterError { failure(error) }
        Spacer(minLength: 0)
        Button { model.openMaster() } label: { HStack(spacing: 8) { Text("Answer in iTerm"); ButtonKey(key: "↩") } }
            .buttonStyle(.desk(.primary, .large, wide: true))
            .help("Shows the master's pane in iTerm, where you answer")
    }

    /// The task's PRs, each with where it stands, and what it sits on that is not its own.
    @ViewBuilder private func taskParts(_ task: WorkTask) -> some View {
        if !task.pullRequests.isEmpty {
            let count = task.pullRequests.count
            RuledList(title: "Task · \(task.id) · \(count) pull \(count == 1 ? "request" : "requests")") {
                ForEach(task.pullRequests, id: \.url) { pr in
                    RuledRow {
                        Text(UpNextRow.name(pr)).scaled(.code).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(RowState.of(pr).title).scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1)
                    }
                }
            }
        }
        if !task.dependsOn.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Depends on")
                ForEach(task.dependsOn, id: \.self) { Text($0).scaled(.code).textSelection(.enabled) }
            }
        }
    }

    @ViewBuilder private func pullRequestDetails(_ pr: PullRequest, review: Bool) -> some View {
        let job = model.state.claudeJobs(for: pr).first
        DetailHeader(
            kicker: review ? "\(UpNextRow.name(pr)) · \(pr.author) · opened \(Format.age(pr.createdAt)) ago"
                : "\(UpNextRow.name(pr)) · yours · updated \(Format.age(pr.updatedAt)) ago",
            title: pr.title
        )
        FieldRows(labelWidth: 84) {
            if review {
                FieldRow("Review", pr.pendingReview != nil ? "Your draft, not submitted" : model.state.reviewNeed(for: pr)?.title ?? "Open to review")
                FieldRow("Asked", model.state.reviewRequests.contains { $0.url == pr.url } ? "Of you" : "Of anyone")
                FieldRow(label: "Checks") {
                    HStack(spacing: 6) { ChecksBadge(pr: pr); Text(UpNextTab.checks(pr)) }
                }
            } else {
                PullRequestFacets.Rows(pr: pr, rebase: model.state.rebaseReason(pr))
            }
            FieldRow("Branches", "\(pr.baseRef) ← \(pr.headRef)", mono: true)
            FieldRow(label: "Size") { DiffStat(pr: pr) }
        }
        if review, pr.pendingReview != nil {
            Button { model.openDraft(pr) } label: { Text("Your draft review on GitHub").underline(color: Theme.control) }
                .buttonStyle(.plain).handCursor().scaled(.secondary).foregroundStyle(Theme.quiet)
        }
        if let error = model.sessionErrors[pr.url] { failure(error) }
        Spacer(minLength: 0)
        HStack(spacing: 8) {
            Button { open(pr.url) } label: { HStack(spacing: 8) { Text("Open"); ButtonKey(key: "↩") } }
                .buttonStyle(.desk(.primary, .large, wide: true))
                .help("The PR's page")
            if review {
                Button(model.reviewRunning(pr) ? "Show review" : "Start review") {
                    if model.reviewRunning(pr) {
                        model.showReview(pr)
                    } else {
                        model.startReview(pr)
                        open(pr.url)
                    }
                }
                .buttonStyle(.desk(.secondary, .large))
                .help(model.reviewRunning(pr) ? "The review session's window in iTerm" : "The diff here and a review session in a window of its own in iTerm")
            } else if let job {
                Button("Show in iTerm") { model.show(jobId: job.id) }.buttonStyle(.desk(.secondary, .large))
                    .help("Show “\(job.name)” (\(job.status)) in its pane in iTerm")
            }
        }
    }

    @ViewBuilder private func workerDetails(_ job: ClaudeJob, _ task: WorkTask) -> some View {
        DetailHeader(
            kicker: "Worker · \(job.name) · \(job.isAsking ? "asks you" : "working") · \(Format.age(job.updatedAt))",
            title: task.title, summary: job.isAsking ? job.asking : job.detail
        )
        taskParts(task)
        if let error = model.terminalError { failure(error) }
        Spacer(minLength: 0)
        Button { model.show(jobId: job.id) } label: { HStack(spacing: 8) { Text("Show in iTerm"); ButtonKey(key: "↩") } }
            .buttonStyle(.desk(.primary, .large, wide: true))
            .help("Show “\(job.name)” in its pane in iTerm")
    }

    @ViewBuilder private func ticketDetails(_ ticket: Ticket, kicker: String, @ViewBuilder extra: () -> some View) -> some View {
        DetailHeader(kicker: "\(ticket.key) · Jira · \(kicker)", title: ticket.summary)
        FieldRows(labelWidth: 72) {
            FieldRow("Status", ticket.status)
            if let priority = ticket.priority { FieldRow(label: "Priority") { PriorityMark.text(priority) } }
            FieldRow("Assignee", ticket.assignedToMe ? "You" : ticket.assignee ?? "Unassigned")
        }
        VStack(alignment: .leading, spacing: 10) { extra() }
        Spacer(minLength: 0)
        HStack(spacing: 8) {
            Button { open(ticket.key) } label: { HStack(spacing: 8) { Text("Open"); ButtonKey(key: "↩") } }
                .buttonStyle(.desk(.primary, .large, wide: true))
                .help("The ticket's page")
            Button("Open in Jira") { model.open(ticket.url) }.buttonStyle(.desk(.secondary, .large))
        }
    }

    private func failure(_ error: String) -> some View {
        Text(error).scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
