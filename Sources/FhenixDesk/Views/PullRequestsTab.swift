import DeskCore
import SwiftUI

struct PullRequestsTab: View {
    /// Your open PRs, or the ones merged in the last month.
    enum Scope { case open, merged }

    @Environment(AppModel.self) private var model
    @State private var scope = Scope.open
    @State private var sortOrder: [KeyPathComparator<StackedPullRequest>] = []
    @AppStorage("sort.pullRequests") private var storedSort = ""
    @State private var selection: String?
    /// The pages open over the list; empty shows the list.
    @State private var path: [Route] = []
    @FocusState private var listFocused: Bool
    @State private var search = ""
    /// Open PRs grouped under their tasks, or today's flat list of PRs.
    @AppStorage("pullRequests.byTask") private var byTask = true
    /// With Reduce Motion on, the list jumps to the selected row instead of sliding there.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sort = TableSort<StackedPullRequest>(
        [
            ("repo", KeyPathComparator(\.pullRequest.repoName)),
            ("number", KeyPathComparator(\.pullRequest.number)),
            ("threads", KeyPathComparator(\.pullRequest.unresolvedThreads)),
            ("size", KeyPathComparator(\.pullRequest.size)),
            ("age", KeyPathComparator(\.pullRequest.createdAt)),
            ("updated", KeyPathComparator(\.pullRequest.updatedAt)),
        ],
        fallback: [
            KeyPathComparator(\StackedPullRequest.pullRequest.repoName),
            KeyPathComparator(\StackedPullRequest.pullRequest.updatedAt, order: .reverse),
        ]
    )

    var body: some View {
        let rows = byTask ? taskSections.flatMap(\.rows) : self.rows
        let merged = self.merged
        let shown = scope == .open ? rows.map(\.pullRequest.url) : merged.map(\.url)
        RouteStack(path: $path, back: "Tasks") {
            list(rows: rows, merged: merged, shown: shown)
        }
        .focusedSceneValue(\.routePath, $path)
        .remembersSort(Self.sort, order: $sortOrder, stored: $storedSort)
        .selectsFirstRow(shown.first, selection: $selection)
        // A tab opens on its first row, unless the selection is already in it: search may have switched the tab to
        // show its PR.
        .onChange(of: scope) {
            if !shown.contains(where: { $0 == selection }) { selection = shown.first }
        }
        // Search, Up Next and a notification land here with a PR to show: its page, with its row selected behind it.
        // Only yours: one on its way to Reviews passes through while this screen is still on show, and is Reviews' to
        // take.
        .onChange(of: model.selectPullRequest, initial: true) { _, url in
            guard let url, model.yourPullRequest(url) != nil else { return }
            scope = model.state.recentlyMerged().contains { $0.url == url } ? .merged : .open
            selection = url
            path = [.pr(url)]
            model.selectPullRequest = nil
        }
    }

    @ViewBuilder private func list(rows: [StackedPullRequest], merged: [PullRequest], shown: [String]) -> some View {
        Screen {
            PageHeader(title: "Tasks") {}
            FilterBar {
                // Counted over what the search leaves, like the Reviews and Jira tabs; the key cap marks the tab
                // that ⌃Tab goes to.
                PillTabs(
                    options: [
                        .init(value: .open, title: "Open", count: rows.count, hint: scope == .open ? nil : "⌃⇥"),
                        .init(value: .merged, title: "Recently merged", count: merged.count, hint: scope == .merged ? nil : "⌃⇥"),
                    ],
                    selection: $scope
                )
            } trailing: {
                SearchBox(prompt: "Task, repo, number or title", text: $search)
                if scope == .open {
                    Picker("Show", selection: $byTask) {
                        Text("Tasks").tag(true)
                        Text("PRs").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Your PRs under their tasks, or all of them in one list")
                    // Merged PRs read newest first; the columns this sorts by are about open ones. Tasks keep their own order.
                    if !byTask { SortMenu(sort: Self.sort, order: $sortOrder) }
                }
            }
        } content: {
            Hairline()
            if scope == .open ? model.state.mine.isEmpty && (!byTask || model.state.tasks.isEmpty) : model.state.recentlyMerged().isEmpty {
                if let error = model.state.errors[.github] {
                    EmptyState(
                        icon: "exclamationmark.triangle", text: "Couldn't load your pull requests from GitHub.", detail: error,
                        actionTitle: "Retry", action: { Task { await model.refresh(.github) } }
                    )
                    .padding(.vertical, 20)
                } else {
                    EmptyState(icon: "checkmark.circle", text: scope == .open ? "No open PRs of yours." : "None of your PRs merged recently.")
                        .padding(.vertical, 20)
                }
            } else {
                StaleBanner(source: .github)
                if shown.isEmpty, !(scope == .open && byTask && !taskSections.isEmpty) {
                    EmptyState(
                        icon: "magnifyingglass", text: "No PR matches “\(search)”.",
                        actionTitle: "Clear search", action: { search = "" }
                    )
                    .padding(.vertical, 20)
                }
            }
            ScrollViewReader { proxy in
                // Arrow keys move the selection; a click, Return or → opens the PR's page.
                List(selection: $selection) {
                    switch scope {
                    case .open where byTask:
                        ForEach(taskSections) { section in
                            Section {
                                ForEach(section.rows, id: \.pullRequest.url) { row in
                                    PullRequestRow(row: row, model: model, selected: selection == row.pullRequest.url) { open(row.pullRequest.url) }
                                }
                            } header: {
                                TaskHeader(task: section.task, model: model)
                            }
                        }
                    case .open:
                        ForEach(rows, id: \.pullRequest.url) { row in
                            PullRequestRow(row: row, model: model, selected: selection == row.pullRequest.url) { open(row.pullRequest.url) }
                        }
                    case .merged:
                        ForEach(merged, id: \.url) { pr in
                            MergedRow(pr: pr, model: model, selected: selection == pr.url) { open(pr.url) }
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
                .contextMenu(forSelectionType: String.self) { urls in
                    if let pr = urls.first.flatMap(pullRequest) { PullRequestMenu(pr: pr, model: model) }
                } primaryAction: { urls in
                    if let url = urls.first { open(url) }
                }
                // Search lands here with the row selected; it may be far down the list.
                .onChange(of: selection, initial: true) { _, url in
                    if let url { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(url, anchor: .center) } }
                }
            }
        }
        // ⌃Tab and ⌃⇧Tab flip between the two tabs, from the list or the search box, as they flip a browser's tabs;
        // Tab is left to move focus. With Shift, AppKit reports Tab as backtab.
        .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: .down) { press in
            guard press.modifiers.contains(.control) else { return .ignored }
            scope = scope == .open ? .merged : .open
            return .handled
        }
    }

    /// The stacked rows, filtered by the search field. A child that matches keeps its indent even when its
    /// root does not: the arrow still says it is stacked, and the PR's page names the parent.
    private var rows: [StackedPullRequest] {
        let all = model.state.stackedMine(order: sortOrder)
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { $0.pullRequest.matches(search: search) }
    }

    /// Your tasks, each with its PRs stacked base first. A search keeps a task whose name or title matches whole, and
    /// otherwise the PRs in it that match.
    private var taskSections: [TaskSection] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let byNumber = [KeyPathComparator(\StackedPullRequest.pullRequest.number)]
        return model.state.tasks.compactMap { task in
            let all = Linker.stacked(task.pullRequests, parents: model.state.stackParents, order: byNumber)
            if query.isEmpty || "\(task.id) \(task.title)".localizedCaseInsensitiveContains(query) {
                return TaskSection(task: task, rows: all)
            }
            let rows = all.filter { $0.pullRequest.matches(search: query) }
            return rows.isEmpty ? nil : TaskSection(task: task, rows: rows)
        }
    }

    /// This month's merged PRs, newest first, filtered by the search field.
    private var merged: [PullRequest] {
        model.state.recentlyMerged().filter { $0.matches(search: search) }
    }

    /// Its page, with its row selected behind it for the way back.
    private func open(_ url: String) {
        selection = url
        path.append(.pr(url))
    }

    private func pullRequest(_ url: String) -> PullRequest? { model.yourPullRequest(url) }
}

/// One open PR of yours, title first: its title over a monospaced line of checks, number, repo, branches, size, open
/// threads and ticket; on the right one pill for what it waits on, its session's marks, and when it last moved. Sessions
/// are started and attached to from the PR's page. A stack reads top-down: each PR stacked on another sits indented
/// beneath it, and a root notes a parent that is not in the list, or a base branch that has no open PR at all.
struct PullRequestRow: View {
    var row: StackedPullRequest
    var model: AppModel
    var selected: Bool
    var open: () -> Void

    var body: some View {
        let pr = row.pullRequest
        ListRow(selected: selected, open: open) {
            // No avatar and no tick: every PR here is yours, and a mark that is gone on the next launch is no mark.
            HStack(alignment: .center, spacing: 12) {
                if row.depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.secondary)
                        .padding(.leading, CGFloat(row.depth - 1) * 16)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        // Plain text, so a click on it opens the PR's page like a click anywhere else on the row.
                        Text(pr.title).scaled(.rowTitle).lineLimit(1)
                        if row.depth == 0 { stackNote(pr) }
                    }
                    HStack(spacing: 8) {
                        ChecksBadge(pr: pr).scaled(.secondary)
                        MetaLine(parts: Self.meta(pr))
                        TicketMark(pr: pr, model: model)
                    }
                }
                Spacer(minLength: 8)
                StatePill(state: RowState.of(pr))
                // The marks and the age keep their width on every row, so the pills line up down the list.
                Color.clear.frame(width: 16, height: 16).overlay { SessionMarks(pr: pr, model: model) }
                Text(Format.age(pr.updatedAt)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
                    .help("Updated \(Format.date(pr.updatedAt)) · opened \(Format.date(pr.createdAt))")
            }
        }
    }

    static func meta(_ pr: PullRequest) -> [Text] {
        var parts = [
            Text(verbatim: "#\(pr.number)"),
            Text(pr.repoName),
            Text("\(pr.baseRef) ← \(pr.headRef)"),
            Text("\(Format.sizeBucket(pr.size)) \(Text("+\(pr.additions)").foregroundStyle(.green)) \(Text("−\(pr.deletions)").foregroundStyle(.red))"),
        ]
        if pr.unresolvedThreads > 0 {
            parts.append(Text("\(pr.unresolvedThreads) unresolved").foregroundStyle(.orange))
        }
        return parts
    }

    @ViewBuilder private func stackNote(_ pr: PullRequest) -> some View {
        if row.stackSize > 1 {
            Chip(text: "Stack of \(row.stackSize)").fixedSize()
        }
        if let parent = model.state.stackParent(of: pr) {
            Text(verbatim: "on #\(parent.number)").scaled(.caption).foregroundStyle(.secondary).fixedSize()
                .help("Stacked on #\(parent.number) by \(parent.author)" as String)
        } else if pr.baseRef != pr.defaultBranch {
            // Something the task depends on rather than something wrong: a merged base asks for a rebase elsewhere.
            Text("on \(pr.baseRef)").scaled(.caption).foregroundStyle(.secondary).fixedSize()
                .help("Sits on a branch no open PR opens: its task depends on it")
        }
    }
}

/// The task a PR of yours belongs to, read-only: its other PRs and where each stands, what it depends on, its worker and
/// what that worker is doing, and the master's questions about it. The presses are the master's to make, on your word.
private struct TaskCard: View {
    var task: WorkTask
    var pr: PullRequest
    var model: AppModel

    /// Shown when the task is more than this PR alone.
    static func hasMore(_ task: WorkTask, than pr: PullRequest, asks: [MasterAsk]) -> Bool {
        task.pullRequests.count > 1 || task.worker != nil || !task.dependsOn.isEmpty || asks.contains { $0.task == task.id }
    }

    var body: some View {
        SideCard(title: "Task") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(task.pullRequests.filter { $0.url != pr.url }, id: \.url) { other in
                    LabeledContent {
                        Text(FlowStage.of(other).title).foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: "\(other.repoName)#\(other.number)").scaled(.secondary.monospaced())
                    }
                }
                ForEach(task.dependsOn, id: \.self) { dependency in
                    // The branch alone, or `repo#n` for a PR: the owner and repo are this PR's own, and the card is narrow.
                    let short = dependency.contains("@")
                        ? String(dependency.split(separator: "@", maxSplits: 1).last ?? "")
                        : String(dependency.split(separator: "/", maxSplits: 1).last ?? "")
                    LabeledContent("Depends on") {
                        Text(short).scaled(.caption.monospaced()).lineLimit(2).multilineTextAlignment(.trailing).help(dependency)
                    }
                }
                if let worker = task.worker {
                    LabeledContent("Worker") {
                        Button("\(worker.name) · \(worker.status)") { model.attach(jobId: worker.id, errorKey: pr.url) }
                            .buttonStyle(.link).handCursor()
                    }
                    if let detail = worker.detail, !detail.isEmpty {
                        Text(detail).scaled(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(model.state.asks.filter { $0.task == task.id }) { ask in
                    HStack(alignment: .firstTextBaseline) {
                        Text("Waiting on you: \(ask.text)").scaled(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Button("Open Master") { model.openMaster() }.controlSize(.small)
                    }
                }
            }
        } trailing: {
            Text(TaskHeader.label(task)).scaled(.secondary.monospaced()).foregroundStyle(.secondary)
        }
    }
}

/// One task and the rows of its PRs that show.
private struct TaskSection: Identifiable {
    var task: WorkTask
    var rows: [StackedPullRequest]
    var id: String { task.id }
}

/// A task's line above its PRs: what it is (the ticket key, the worker's name, or the stack's root), its title, Jira's
/// status for a ticket, who it waits on, and its worker with a press that attaches it; under it, what the worker is doing
/// and what the task depends on. A task with no PR yet, an investigation say, is this line alone.
struct TaskHeader: View {
    var task: WorkTask
    var model: AppModel

    /// A stack's root reads as `desk#28`, without its owner.
    static func label(_ task: WorkTask) -> String {
        task.origin == .pullRequest ? String(task.id.split(separator: "/").last ?? Substring(task.id)) : task.id
    }

    private var waits: (text: String, color: Color)? {
        switch task.waitingOn(asked: model.state.askedTasks) {
        case .you: return ("waits on you", .orange)
        case .worker: return ("worker on it", .secondary)
        case .reviewers: return ("in review", .secondary)
        case .nobody: return nil
        }
    }

    private var notes: String? {
        var parts: [String] = []
        if let detail = task.worker?.detail, !detail.isEmpty { parts.append(detail) }
        if !task.dependsOn.isEmpty {
            parts.append("depends on " + task.dependsOn.map { $0.split(separator: "/", maxSplits: 1).last.map(String.init) ?? $0 }.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(Self.label(task)).scaled(.secondary.monospaced()).fontWeight(.semibold).foregroundStyle(.primary)
                // Not when it would repeat: a session named by its title, or one PR whose row says it right below.
                if task.title != Self.label(task), !(task.origin == .pullRequest && task.pullRequests.count == 1) {
                    Text(task.title).scaled(.secondary).foregroundStyle(.primary).lineLimit(1)
                }
                if task.origin == .ticket, let status = model.state.ticket(task.id)?.status { Chip(text: status).fixedSize() }
                Spacer(minLength: 8)
                if let waits { Text(waits.text).scaled(.caption).foregroundStyle(waits.color) }
                if let worker = task.worker {
                    Button { model.attach(jobId: worker.id, errorKey: task.id) } label: {
                        Label(worker.status, systemImage: "terminal").scaled(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Attach \(worker.name) in the terminal panel")
                }
            }
            if let notes { Text(notes).scaled(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }
}

/// One PR of yours merged this month: its title, the same monospaced line an open one has, and when it merged.
private struct MergedRow: View {
    var pr: PullRequest
    var model: AppModel
    var selected: Bool
    var open: () -> Void

    var body: some View {
        ListRow(selected: selected, open: open) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(pr.title).scaled(.rowTitle).lineLimit(1)
                    HStack(spacing: 8) {
                        MetaLine(parts: PullRequestRow.meta(pr))
                        TicketMark(pr: pr, model: model)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("merged \(Format.age(pr.mergedAt))").monospacedDigit().foregroundStyle(.secondary)
                        .help(pr.mergedAt.map { "Merged \(Format.date($0))" } ?? "")
                    Text("opened \(Format.age(pr.createdAt))").scaled(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .help("Opened \(Format.date(pr.createdAt))")
                }
            }
        }
    }
}

/// The Jira ticket a pull request is about, and whether the two still agree. Read-only on purpose: the
/// press that moves a ticket lives on the Jira screen, where the ticket does.
private struct TicketMark: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        // Nothing at all without a key: an en dash only asks what it stands for.
        if let key = model.state.ticketKeys[pr.url]?.first {
            link(key)
        }
    }

    private func link(_ key: String) -> some View {
        let ticket = model.state.ticket(key)
        let drift = model.state.drift(forKey: key)
        return         HStack(spacing: 3) {
            Button { model.open(ticket?.url) } label: { Text(key).scaled(.caption.monospaced()) }
                .buttonStyle(.link).handCursor()
                .disabled(ticket == nil)
            if let drift {
                Image(systemName: "arrow.right.circle.fill").scaled(.caption.weight(.medium)).foregroundStyle(.orange)
                    .help("Jira says “\(drift.ticket.status)”; this PR says “\(drift.target)”. A suggested move: press Move on the ticket")
            }
        }
        .fixedSize()
        .help(ticket.map { "\(key) — \($0.status)" } ?? "\(key) — not among your tickets")
    }
}

/// A pull request's own page, opened from its row. At the top what it is, its status line — checks, review and merge
/// state, its Jira ticket, its session or the press that starts one, and ⋯ for the rest — and, top right, any warning
/// about its review skill; in the wide column the description and under it the conversation; beside it the next step
/// its stage waits for, its checks in a line, and its facts in one card.
struct PullRequestPage: View {
    var pr: PullRequest
    var model: AppModel
    /// The screen it was opened from, which its back link names and returns to.
    var back = "Tasks"
    /// The main column's tab it opens on.
    var tab: PullRequestTab = .conversation
    var onBack: () -> Void

    /// Yours to rewrite while it is open; a review's description is the author's, so the Reviews page only reads it.
    private var description: some View {
        EditableDescription(
            text: pr.body, editable: pr.state == .open,
            editHelp: "Edit the description; saving writes it to GitHub", lockedHelp: "It has ended: edit it on GitHub"
        ) {
            await model.editDescription(pr, body: $0)
        } rendered: {
            PullRequestDescription(pr: pr)
        }
    }

    var body: some View {
        DetailPage(back: back, onBack: onBack) {
            PageHeadline(pr: pr, model: model, gitHub: pr.url, editable: pr.state == .open)
            StatusLine {
                // How it ended, first and in GitHub's colours: a merge or close from this page shows here the moment it lands.
                EndedPill(pr: pr)
                // An ended PR has no state left to show and no branch left to work on; its ticket is what is left.
                if pr.state == .open {
                    // Side by side, not in the list's columns: there is only the one PR to line up.
                    ChecksPill(pr: pr)
                    ReviewBadge(pr: pr)
                    MergeBadge(pr: pr)
                }
                JiraStatus(pr: pr, model: model)
            } actions: {
                // The page's action on the right, where a status line's presses go.
                if pr.state == .open { SessionStatus(pr: pr, model: model) }
                MoreMenu(pr: pr, model: model)
            }
            if let error = model.sessionErrors[pr.url] {
                Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        } main: {
            PullRequestMain(pr: pr, model: model, tab: tab) {
                description
                ConversationSection(pr: pr, model: model)
            }
        } side: {
            // An ended PR has nothing left to act on or check: its facts. How it ended is on the status line.
            if pr.state == .open {
                if let task = model.state.task(for: pr), TaskCard.hasMore(task, than: pr, asks: model.state.asks) {
                    TaskCard(task: task, pr: pr, model: model)
                }
                // Every open PR of yours, session or not: Mark ready and Merge need none, and Run /pre-pr starts one.
                NextStepCard(pr: pr, session: model.state.session(for: pr), model: model)
                WorkflowsSection(pr: pr, model: model)
            }
            AboutCard(pr: pr, model: model)
        } accessory: {
            if let skill = model.state.reviewSkill(for: pr), !skill.has(skill.selfReview) {
                Label(skill.text, systemImage: "exclamationmark.triangle.fill")
                    .scaled(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(skill.text)
            }
        }
    }

}

/// Your PR's main column, in two tabs: its conversation (the description and what was said), or the code it changed with
/// each review thread under its line. A tab, not a screen of its own like a review's diff: the next step and the facts
/// stay beside it.
enum PullRequestTab: Hashable { case conversation, files }

private struct PullRequestMain<Conversation: View>: View {
    var pr: PullRequest
    var model: AppModel
    @State var tab: PullRequestTab
    @ViewBuilder var conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            PillTabs(
                options: [
                    .init(value: .conversation, title: "Conversation"),
                    .init(value: .files, title: "Files changed", count: model.diffs[pr.url]?.files.count),
                ],
                selection: $tab
            )
            switch tab {
            case .conversation: VStack(alignment: .leading, spacing: Theme.Space.xl) { conversation }
            case .files: PullRequestFiles(pr: pr, model: model)
            }
        }
    }
}

/// The code your PR changed, a box per file that folds, each review thread under the line it ends on, to reply to or
/// resolve there. Fetched when the tab opens, and again once new commits move the PR's head: it is your branch, so the
/// newest code is the one to see, where a review's diff asks first.
private struct PullRequestFiles: View {
    var pr: PullRequest
    var model: AppModel
    /// The files whose fold you changed from how the diff opened: a large file opens folded, the rest unfolded.
    @State private var flipped: Set<String> = []
    @Environment(\.textScale) private var scale

    var body: some View {
        Group {
            if let diff = model.diffs[pr.url] {
                files(diff)
            } else if let error = model.diffErrors[pr.url] {
                EmptyState(icon: "exclamationmark.triangle", text: "Couldn't load the changes.", detail: error,
                           actionTitle: "Retry", action: { model.loadDiff(pr, force: true) })
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            }
        }
        .task(id: "\(pr.url) \(pr.headSha)") { model.loadDiff(pr, force: model.diffs[pr.url].map { $0.sha != pr.headSha } ?? false) }
        .task(id: "\(pr.url) \(pr.updatedAt)") { await model.loadConversation(pr) }
    }

    // ponytail: each file's rows are built in full once its box scrolls in; a large file opens folded, as in a review's diff,
    // so only one unfolded by hand gets that big. Make the rows lazy too if such a file stutters.
    private func files(_ diff: LoadedDiff) -> some View {
        LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
            if diff.files.isEmpty { Text("No changes.").scaled(.secondary).foregroundStyle(.secondary) }
            ForEach(diff.files) { file in
                let large = diff.foldedAtFirst.contains(file.path)
                let folded = large != flipped.contains(file.path)
                VStack(alignment: .leading, spacing: 0) {
                    DiffFileHeader(file: file, folded: folded, large: large) { flipped.formSymmetricDifference([file.path]) }
                    if !folded {
                        if file.isBinary {
                            Text("Binary file").font(DiffType(scale: scale).mono).foregroundStyle(.secondary).padding(8)
                        }
                        let rows = diff.rows[file.path] ?? []
                        ForEach(rows.indices, id: \.self) { index in
                            switch rows[index] {
                            case .hunk(let header):
                                DiffHunkRow(header: header)
                            case .line(let line):
                                DiffLineRow(line: line)
                                DiffThreads(line: line, path: file.path, pr: pr, model: model)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            }
        }
    }
}

/// ⋯ on the page's status line: the presses kept out of the way of its next step — the ways out to GitHub and the
/// clipboard, and Close, asked about first.
private struct MoreMenu: View {
    var pr: PullRequest
    var model: AppModel
    @State private var confirmingClose = false
    @State private var closing = false
    @State private var error: String?

    var body: some View {
        Menu {
            Button("Open on GitHub") { model.open(pr.url) }
            Button("Copy Branch") { Clipboard.copy(pr.headRef) }
            Button("Copy Link") { Clipboard.copy(pr.url) }
            if pr.state == .open {
                Divider()
                if pr.isDraft {
                    Button("Mark Ready for Review") { model.markReady(pr) }
                        .disabled(model.busyFlows.contains(pr.url))
                } else {
                    Button("Convert to Draft") { Task { error = await model.convertToDraft(pr) } }
                        .disabled(model.busyFlows.contains(pr.url))
                }
                // Not while a merge or a flow press is under way on it.
                Button("Close Pull Request…", role: .destructive) { confirmingClose = true }
                    .disabled(closing || model.busyFlows.contains(pr.url))
            }
        } label: {
            if closing { ProgressView().controlSize(.small) } else { Image(systemName: "ellipsis") }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open on GitHub, copy its branch or link, or close it")
        .accessibilityLabel("More")
        .confirmationDialog(
            // Verbatim: a localized title prints the number as "1,082".
            Text(verbatim: "Close #\(pr.number) without merging?"), isPresented: $confirmingClose
        ) {
            Button("Close pull request", role: .destructive) {
                closing = true
                Task {
                    error = await model.close(pr)
                    closing = false
                }
            }
        } message: {
            Text("It closes without merging. It can be reopened on GitHub.")
        }
        .alert(
            // The message says which change failed: a close, or turning it back into a draft.
            Text(verbatim: "#\(pr.number) didn't change"),
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

/// The PR's Jira ticket on its status line: its key, which opens it, and where Jira has it, with the move the app is
/// making when Jira is behind; or that the PR names none.
private struct JiraStatus: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        if let key = model.state.ticketKeys[pr.url]?.first {
            let ticket = model.state.ticket(key)
            HStack(spacing: 6) {
                Button { model.open(ticket?.url) } label: {
                    HStack(spacing: 6) {
                        SidebarIcon(name: SidebarIcon.jira)
                        Text(key).monospaced()
                        Text("·  \(ticket?.status ?? "not found")").foregroundStyle(.secondary)
                    }
                    .pill()
                }
                .buttonStyle(.plain).handCursor()
                .disabled(ticket == nil)
                .help(ticket.map { "\(key): \($0.summary)" } ?? "\(key) is not among the tickets Jira gave the app")
                if let drift = model.state.drift(forKey: key) { DriftBadge(drift: drift, model: model) }
            }
        } else {
            HStack(spacing: 6) {
                SidebarIcon(name: SidebarIcon.jira)
                Text("No Jira ticket")
            }
            .foregroundStyle(.secondary)
            .pill()
            .help("No Jira key in the branch name or title")
        }
    }
}

/// How a PR ended, on its status line: "Merged into master · 2h ago" on GitHub's purple, or "Closed" on its red; nothing
/// while it is open.
private struct EndedPill: View {
    var pr: PullRequest

    var body: some View {
        switch pr.state {
        case .merged:
            pill("arrow.triangle.merge", "Merged", "into \(pr.baseRef) · \(Format.age(pr.mergedAt)) ago", Theme.merged)
                .help(pr.mergedAt.map { "Merged \(Format.date($0))" } ?? "Merged")
        case .closed:
            pill("xmark.circle", "Closed", "without merging", Theme.closed).help("Closed unmerged; it can be reopened on GitHub")
        case .open:
            EmptyView()
        }
    }

    private func pill(_ symbol: String, _ word: String, _ detail: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(word).fontWeight(.medium)
            Text(detail).opacity(0.85)
        }
        .scaled(.secondary)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
