import DeskCore
import SwiftUI

/// Tasks: your open tasks grouped by who they wait on, each a row with what its worker is doing, and its PRs under it,
/// their facts in the columns of one header; beside them the selected task or PR in full. A task that is a PR is that
/// PR's row. Or your PRs merged this month. Return opens a PR's page; a task has only its details column.
struct PullRequestsTab: View {
    /// Your open work, or the PRs merged in the last month.
    enum Scope { case open, merged }

    @Environment(AppModel.self) private var model
    @State private var scope = Scope.open
    /// A task's id, or the url of a PR under one or in Merged.
    @State private var selection: String?
    /// The pages open over the list; empty shows the list.
    @State private var path: [Route] = []
    @FocusState private var listFocused: Bool
    @State private var search = ""
    /// With Reduce Motion on, the list jumps to the selected row instead of sliding there.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let groups = taskGroups
        let merged = self.merged
        // Down the list as it reads: each task, then the PRs under it.
        let shown = scope == .merged ? merged.map(\.url)
            : groups.flatMap { $0.tasks.flatMap { [Self.root(of: $0)?.url ?? $0.id] + nested($0).map(\.pullRequest.url) } }
        RouteStack(path: $path, back: "Tasks") {
            HStack(spacing: 0) {
                list(groups: groups, merged: merged, shown: shown)
                details
            }
            .background(Theme.ground)
        }
        .focusedSceneValue(\.routePath, $path)
        .selectsFirstRow(shown.first, selection: $selection)
        // A view opens on its first row, unless the selection is already in it: search may have switched it to show its PR.
        .onChange(of: scope) { reselect(shown) }
        // Search, Up Next and a notification land here with a PR to show: its page, with its row selected behind it. Only
        // yours: one on its way to Reviews passes through while this screen is still on show, and is Reviews' to take. A
        // task's id selects its row, or opens its PR's page when the task is a PR.
        .onChange(of: model.selectPullRequest, initial: true) { _, target in
            guard let target else { return }
            if model.yourPullRequest(target) != nil {
                scope = model.state.recentlyMerged().contains { $0.url == target } ? .merged : .open
                selection = target
                path = [.pr(target)]
            } else if let task = model.state.tasks.first(where: { $0.id == target }) {
                scope = .open
                if let root = Self.root(of: task) {
                    selection = root.url
                    path = [.pr(root.url)]
                } else {
                    selection = target
                    path = []
                }
            } else {
                return
            }
            model.selectPullRequest = nil
        }
    }

    private func reselect(_ shown: [String]) {
        if !shown.contains(where: { $0 == selection }) { selection = shown.first }
    }

    @ViewBuilder private func list(groups: [TaskGroup], merged: [PullRequest], shown: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(open: groups.reduce(0) { $0 + $1.tasks.count }, merged: merged.count)
                .padding(.bottom, 8)
            if scope == .open ? model.state.mine.isEmpty && model.state.tasks.isEmpty : model.state.recentlyMerged().isEmpty {
                if let error = model.state.errors[.github] {
                    EmptyState(
                        icon: "exclamationmark.triangle", text: "Couldn't load your pull requests from GitHub.", detail: error,
                        actionTitle: "Retry", action: { Task { await model.refresh(.github) } }
                    )
                    .padding(.vertical, 20)
                } else {
                    EmptyState(icon: "checkmark.circle", text: scope == .open ? "Nothing open: no task and no PR of yours." : "None of your PRs merged recently.")
                        .padding(.vertical, 20)
                }
            } else {
                StaleBanner(source: .github)
                if shown.isEmpty {
                    EmptyState(
                        icon: "magnifyingglass", text: "Nothing matches “\(search)”.",
                        actionTitle: "Clear search", action: { search = "" }
                    )
                    .padding(.vertical, 20)
                }
            }
            ScrollViewReader { proxy in
                // Arrow keys, J and K move the selection; a double-click, Return or → opens the task's page, or the PR's.
                List(selection: $selection) {
                    switch scope {
                    case .open:
                        PullRequestFacets.Header().plainListRow().selectionDisabled()
                        ForEach(groups) { group in
                            GroupHeader(title: group.title, count: group.tasks.count)
                                .padding(.top, group.id == groups.first?.id ? 2 : 0)
                                .plainListRow().selectionDisabled()
                            ForEach(group.tasks) { task in
                                // A task that is a PR is that PR's row: it selects and opens as any PR does. Tagged with
                                // the PR, or the arrow keys and clicks select the task, which ForEach tags it with.
                                if let root = Self.root(of: task) {
                                    PullRequestRow(row: StackedPullRequest(pullRequest: root), model: model, selected: selection == root.url)
                                        .tag(root.url).id(root.url)
                                } else {
                                    TaskRow(task: task, model: model, selected: selection == task.id)
                                }
                                ForEach(nested(task), id: \.pullRequest.url) { row in
                                    PullRequestRow(row: row, model: model, selected: selection == row.pullRequest.url, nested: true)
                                }
                            }
                        }
                    case .merged:
                        ForEach(merged, id: \.url) { pr in
                            MergedRow(pr: pr, model: model, selected: selection == pr.url)
                        }
                    }
                }
                .deskList()
                // The grouped list's first label brings its own gap.
                .padding(.top, scope == .open ? 0 : 10)
                // Focused on arrival and on the way back from a page, so the keys work without a click first.
                .focused($listFocused)
                .task(id: path.isEmpty) { if path.isEmpty { listFocused = true } }
                .onKeyPress(.rightArrow) {
                    guard let selection else { return .ignored }
                    open(selection)
                    return .handled
                }
                .onKeyPress(keys: ["j", "k", "m"]) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    if press.key == "m" {
                        model.openMaster()
                    } else {
                        let index = selection.flatMap(shown.firstIndex(of:)) ?? -1
                        let next = min(max(index + (press.key == "j" ? 1 : -1), 0), shown.count - 1)
                        if shown.indices.contains(next) { selection = shown[next] }
                    }
                    return .handled
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first { menu(id) }
                } primaryAction: { ids in
                    if let id = ids.first { open(id) }
                }
                // Search lands here with the row selected; it may be far down the list.
                .onChange(of: selection, initial: true) { _, id in
                    if let id { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            KeyHints(hints: [(["J", "K"], "move"), (["↩"], "open"), (["⌃⇥"], scope == .open ? "merged" : "open"), (["M"], "master")])
        }
        .padding(EdgeInsets(top: 18, leading: 28, bottom: 16, trailing: 28))
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // ⌃Tab and ⌃⇧Tab flip between Open and Merged, from the list or the search box, as they flip a browser's tabs;
        // Tab is left to move focus. With Shift, AppKit reports Tab as backtab.
        .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: .down) { press in
            guard press.modifiers.contains(.control) else { return .ignored }
            scope = scope == .open ? .merged : .open
            return .handled
        }
    }

    /// "Tasks  6 open · 7 pull requests", and on the right the search, and Open and Merged.
    /// On one line where it fits; else the presses go under the title, on the right.
    private func header(open: Int, merged: Int) -> some View {
        let title = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Tasks").scaled(.title).tracking(-0.3)
            Text("\(model.state.tasks.count) open · \(model.state.mine.count) pull request\(model.state.mine.count == 1 ? "" : "s")")
                .scaled(.code).foregroundStyle(Theme.quiet)
        }
        .fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                title
                Spacer(minLength: 8)
                controls(open: open, merged: merged)
            }
            VStack(alignment: .trailing, spacing: 10) {
                HStack { title; Spacer(minLength: 0) }
                HStack(spacing: 10) { controls(open: open, merged: merged) }
            }
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder private func controls(open: Int, merged: Int) -> some View {
        SearchBox(prompt: "Task, repo, number or title", text: $search)
        // Counted over what the search leaves, like the Reviews and Jira screens.
        Segmented(options: [.init(value: .open, title: "Open", count: open), .init(value: .merged, title: "Merged", count: merged)], selection: $scope)
            .help("Your open work, or your PRs merged this month (⌃⇥)")
    }

    @ViewBuilder private var details: some View {
        if scope == .open, let task = model.state.tasks.first(where: { $0.id == selection }) {
            TaskDetails(task: task, model: model) { open($0) }
        } else if let pr = selection.flatMap(model.yourPullRequest) {
            TaskPullRequestDetails(pr: pr, model: model) { open(pr.url) }
        } else {
            DetailColumn { Text(scope == .open ? "Nothing selected." : "No pull request selected.").foregroundStyle(Theme.quiet) }
        }
    }

    @ViewBuilder private func menu(_ id: String) -> some View {
        if let pr = model.yourPullRequest(id) {
            PullRequestMenu(pr: pr, model: model)
        } else if let task = model.state.tasks.first(where: { $0.id == id }) {
            if let worker = task.worker { Button("Show \(worker.name) in iTerm") { model.show(jobId: worker.id) } }
            if task.origin == .ticket, let ticket = model.state.ticket(task.id) { Button("Open in Jira") { model.open(ticket.url) } }
        }
    }

    /// The PR a task started from, where it is one: a stack's root, whose facts its task's own row carries.
    static func root(of task: WorkTask) -> PullRequest? {
        guard task.origin == .pullRequest else { return nil }
        return task.pullRequests.first { "\($0.repo)#\($0.number)".lowercased() == task.id.lowercased() } ?? task.pullRequests.first
    }

    /// The PRs under a task's row, base first, each a step in for every PR of the task it's built on: all of them, but a
    /// task that is a PR, whose row is its root's.
    private func nested(_ task: WorkTask) -> [StackedPullRequest] {
        let root = Self.root(of: task)
        let depths = Linker.depths(task.pullRequests, parents: model.state.stackParents)
        return task.pullRequests.filter { $0.url != root?.url }.map { StackedPullRequest(pullRequest: $0, depth: depths[$0.url] ?? 0) }
    }


    /// Your tasks by who they wait on, filtered by the search field: a task stays when its key or title matches, or one
    /// of its PRs does.
    private var taskGroups: [TaskGroup] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let asked = model.state.askedTasks
        let tasks = model.state.tasks.filter { task in
            query.isEmpty || "\(task.id) \(TaskHeader.label(task)) \(task.title)".localizedCaseInsensitiveContains(query)
                || task.pullRequests.contains { $0.matches(search: query) }
        }
        let grouped = Dictionary(grouping: tasks) { TaskGroup.Kind.of($0, asked: asked) }
        return TaskGroup.Kind.allCases.compactMap { kind in grouped[kind].map { TaskGroup(kind: kind, tasks: $0) } }
    }

    /// This month's merged PRs, newest first, filtered by the search field.
    private var merged: [PullRequest] {
        model.state.recentlyMerged().filter { $0.matches(search: search) }
    }

    /// A PR's page, with its row selected behind it for the way back. A task has no page: its details column is it.
    private func open(_ id: String) {
        selection = id
        if model.yourPullRequest(id) != nil { path.append(.pr(id)) }
    }
}

/// The tasks waiting on one party, under its label.
private struct TaskGroup: Identifiable {
    enum Kind: CaseIterable {
        case you, worker, review, noPullRequest

        /// Who it waits on; a task waiting on nobody has no PR yet, since an open PR waits on you or its reviewers.
        static func of(_ task: WorkTask, asked: Set<String>) -> Kind {
            switch task.waitingOn(asked: asked) {
            case .you: return .you
            case .worker: return .worker
            case .reviewers: return .review
            case .nobody: return .noPullRequest
            }
        }
    }

    var kind: Kind
    var tasks: [WorkTask]
    var id: Kind { kind }

    var title: String {
        switch kind {
        case .you: return "Waits on you"
        case .worker: return "Worker at it"
        case .review: return "In review"
        case .noPullRequest: return "No pull request yet"
        }
    }
}

extension PullRequest {
    /// "cofhe #1159": how a task, a breadcrumb and a row name it.
    var taskRef: String { "\(repoName) #\(number)" }

    /// Who requested the changes GitHub still holds against it, whether or not they have been asked for a re-review since.
    var changesRequestedBy: [String] {
        guard reviewDecision == .changesRequested else { return [] }
        var last: [String: ReviewState] = [:]
        for review in reviews.sorted(by: { $0.submittedAt < $1.submittedAt }) where review.author != author && review.state != .commented {
            last[review.author] = review.state
        }
        return last.filter { $0.value == .changesRequested }.keys.sorted()
    }
}

/// What every view of a task says about it the same way: its key, its origin's icon, the chip for where it stands, and
/// the line under its title.
enum TaskHeader {
    /// The ticket key, the worker's name, or the stack's root as `cofhe #1154`, without its owner.
    static func label(_ task: WorkTask) -> String {
        guard task.origin == .pullRequest else { return task.id }
        return (task.id.split(separator: "/").last.map(String.init) ?? task.id).replacingOccurrences(of: "#", with: " #")
    }

    static func icon(_ task: WorkTask) -> String {
        switch task.origin {
        case .ticket: return "ticket"
        case .session: return "terminal"
        case .pullRequest: return "arrow.triangle.pull"
        }
    }

    /// Where it stands in a word: Working while its worker is at it; with no PR, Investigating for a session and Planning
    /// for a ticket; else its least advanced PR's stage, an in-review one yours to fix as Your move.
    static func chip(_ task: WorkTask, asked: Set<String>) -> String {
        if task.waitingOn(asked: asked) == .worker { return "Working" }
        if task.pullRequests.isEmpty { return task.origin == .session ? "Investigating" : "Planning" }
        switch task.stage {
        case .inReview: return task.pullRequests.contains { RowState.of($0).move == .yoursToFix } ? "Your move" : "In review"
        default: return task.stage.title
        }
    }

    /// "Changes requested by haimbj1 · powershot #116 · #117 · worker done: doc written · the master asks you".
    @MainActor static func line(_ task: WorkTask, model: AppModel) -> Text {
        var parts: [Text] = []
        let changes = Array(Set(task.pullRequests.flatMap(\.changesRequestedBy))).sorted()
        if !changes.isEmpty {
            parts.append(Text("Changes requested by \(ListFormatter.localizedString(byJoining: changes))").fontWeight(.semibold).foregroundStyle(Theme.danger))
        }
        if task.pullRequests.isEmpty {
            parts.append(Text(task.origin == .session ? "A session, no ticket" : "No pull request yet"))
        } else {
            parts.append(Text(verbatim: pullRequests(task.pullRequests)))
            if task.pullRequests.count == 1, let pr = task.pullRequests.first {
                parts.append(Text(verbatim: "\(Format.sizeBucket(pr.size)) +\(pr.additions) −\(pr.deletions)"))
            }
        }
        if let worker = task.worker {
            let who = task.origin == .session && task.pullRequests.isEmpty ? "investigation" : "worker"
            let state = worker.isAsking ? "asks you" : worker.isRunning ? "at work" : worker.state
            parts.append(Text(verbatim: "\(who) \(state)" + (worker.detail.map { ": \($0)" } ?? "")))
        }
        if model.state.askedTasks.contains(task.id) { parts.append(Text("the master asks you")) }
        return parts.dropFirst().reduce(parts[0]) { Text("\($0) · \($1)") }
    }

    /// "powershot #116 · #117", a repo named once before its numbers.
    static func pullRequests(_ prs: [PullRequest]) -> String {
        var repos: [String] = []
        let byRepo = Dictionary(grouping: prs) { pr in
            if !repos.contains(pr.repoName) { repos.append(pr.repoName) }
            return pr.repoName
        }
        return repos.map { repo in "\(repo) " + byRepo[repo]!.map { "#\($0.number)" }.joined(separator: " · ") }.joined(separator: " · ")
    }

    /// A dependency without its owner: `powershot@ohad/back_to_super_majority`, or `cofhe #1154`.
    static func dependency(_ dependency: String) -> String {
        (dependency.split(separator: "/", maxSplits: 1).last.map(String.init) ?? dependency).replacingOccurrences(of: "#", with: " #")
    }
}

/// One task: where it came from, its key, its title over its PRs and what its worker is doing, and a chip for where it
/// stands with its age.
private struct TaskRow: View {
    var task: WorkTask
    var model: AppModel
    var selected: Bool

    var body: some View {
        ListRow(selected: selected) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: TaskHeader.icon(task)).font(.system(size: 12)).foregroundStyle(Theme.quiet)
                    .frame(width: 18, height: 20)
                Text(TaskHeader.label(task)).scaled(.code).foregroundStyle(Theme.quiet).lineLimit(1)
                    .scaledFrame(width: 160, height: 20, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).scaled(.rowTitle.weight(selected ? .semibold : .medium)).lineLimit(1)
                    TaskHeader.line(task, model: model).foregroundStyle(Theme.quiet).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    StageChip2(text: TaskHeader.chip(task, asked: model.state.askedTasks), onTint: selected)
                    // The PR rows' session marks' place, so the ages line up down the list.
                    Color.clear.frame(width: 14, height: 14)
                    AgeText(date: task.updatedAt)
                }
                .frame(height: 20)
            }
        }
    }
}

/// One open PR of yours, as a task row reads: its key, its title over its branches, size, open threads and ticket, and
/// on the right the one pill for what it waits on, its session's marks, and when it last moved. A stack reads top-down:
/// each PR stacked on another sits under it a step in, with a turn, and a root notes a parent that is not in the list.
struct PullRequestRow: View {
    var row: StackedPullRequest
    var model: AppModel
    var selected: Bool
    var indent: CGFloat = 0
    /// Under its task's row: a line down the icon's column joins it to the task.
    var nested = false
    /// Opens its page on a click; nil where a click selects it and Return opens it.
    var open: (() -> Void)? = nil

    var body: some View {
        let pr = row.pullRequest
        ListRow(selected: selected, open: open, indent: indent) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 12)).foregroundStyle(Theme.quiet)
                    .frame(width: 18, height: 20)
                    .opacity(row.depth > 0 || nested ? 0 : 1)
                StackRef(pr: pr, depth: row.depth, name: pr.taskRef).scaled(.code).foregroundStyle(Theme.quiet)
                    .scaledFrame(width: 160, height: 20, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title).scaled(.rowTitle.weight(selected ? .semibold : .medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(line(pr)).foregroundStyle(Theme.quiet).lineLimit(1)
                        TicketMark(pr: pr, model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    PullRequestFacets(pr: pr, rebase: model.state.rebaseReason(pr))
                    // The marks keep their width on every row, so the pills line up down the list.
                    Color.clear.frame(width: 14, height: 14).overlay { SessionMarks(pr: pr, model: model) }
                    AgeText(date: pr.updatedAt)
                        .help("Updated \(Format.date(pr.updatedAt)) · opened \(Format.date(pr.createdAt))")
                }
                .frame(height: 20)
            }
            .background(alignment: .leading) {
                if nested {
                    // Through the row's padding too, so the line runs on from the task's row to the next.
                    Rectangle().fill(Theme.ruleStrong).frame(width: 1).padding(.leading, 8.5).padding(.vertical, -9)
                }
            }
        }
    }

    /// "stack of 2 · master ← chore/x · M +244 −0 · 2 unresolved".
    private func line(_ pr: PullRequest) -> String {
        var parts: [String] = []
        if row.depth == 0, row.stackSize > 1 { parts.append("stack of \(row.stackSize)") }
        if row.depth == 0, let parent = model.state.stackParent(of: pr) { parts.append("on #\(parent.number)") }
        parts.append("\(pr.baseRef) ← \(pr.headRef)")
        parts.append("\(Format.sizeBucket(pr.size)) +\(pr.additions) −\(pr.deletions)")
        return parts.joined(separator: " · ")
    }
}

/// A PR of yours fact by fact, each in a narrow column of its own under the list's header, so a column reads down the
/// list: whether it's a draft, its self-review, its CI, its review, its open threads, and its branch against its base.
/// A mark, and a word or a count where a mark can't say it; the words on hover, and in the details column. Nothing is
/// summed into one word: ready to merge is every column green.
struct PullRequestFacets: View {
    var pr: PullRequest
    var rebase: RebaseReason?

    /// The columns' names and widths, the header's and the rows' alike.
    static let columns: [(title: String, width: CGFloat)] = [
        ("State", 44), ("Self", 34), ("CI", 30), ("Review", 56), ("Threads", 56), ("Branch", 50),
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                Self.cell(fact).scaledFrame(width: Self.columns[index].width, alignment: .leading)
            }
        }
    }

    enum Tone { case ok, bad, warn, neutral }

    /// A fact as a mark, a word or a count beside it for the row, the words for it for the details column and the
    /// hover, and how it reads: fine, to fix, under way or to look at, neutral.
    struct Fact {
        var symbol: String?
        var text: String?
        var words: String
        var tone: Tone
    }

    var facts: [Fact] { [state, selfReview, ci, review, threads, branch] }

    /// The facts' names in a details column, where there's room to spell them.
    static let labels = ["State", "Self-review", "CI", "Review", "Threads", "Branch"]

    private var state: Fact {
        pr.isDraft ? Fact(text: "Draft", words: "Draft, not asked of reviewers", tone: .neutral)
            : Fact(text: "Open", words: "Open for review", tone: .neutral)
    }

    /// Done or not, draft or open alike: the local-reviewed label the self-review sets when it passes.
    private var selfReview: Fact {
        pr.isLocallyReviewed
            ? Fact(symbol: "checkmark.seal.fill", words: "Self-reviewed", tone: .ok)
            : Fact(symbol: "circle.dashed", words: "Not self-reviewed", tone: .warn)
    }

    private var ci: Fact {
        switch pr.checks {
        case .success: return Fact(symbol: "checkmark.circle.fill", words: "Passing", tone: .ok)
        case .failure, .error: return Fact(symbol: "xmark.circle.fill", words: "Failed", tone: .bad)
        case .pending, .expected: return Fact(symbol: "clock.fill", words: "Running", tone: .warn)
        case .none: return Fact(text: "—", words: "No checks", tone: .neutral)
        }
    }

    private var review: Fact {
        if pr.reviewDecision == .changesRequested {
            return Fact(symbol: "arrow.uturn.backward.circle.fill", words: "Changes requested", tone: .bad)
        }
        if pr.isDraft { return Fact(text: "—", words: "Not asked yet: a draft", tone: .neutral) }
        switch pr.approvalGate?.state {
        case .counted(let have, let needed):
            return Fact(symbol: "person.fill.checkmark", text: "\(have)/\(needed)", words: "\(have) of \(needed) approvals",
                        tone: have >= needed ? .ok : .neutral)
        case .waitingForCodeRabbit:
            return Fact(symbol: "hourglass", words: "Waiting for CodeRabbit", tone: .neutral)
        default:
            return pr.reviewDecision == .approved
                ? Fact(symbol: "checkmark.circle.fill", words: "Approved", tone: .ok)
                : Fact(symbol: "hourglass", words: "Waiting on reviewers", tone: .neutral)
        }
    }

    private var threads: Fact {
        let count = pr.unresolvedThreads
        return count == 0 ? Fact(text: "—", words: "None open", tone: .neutral)
            : Fact(symbol: "bubble.left.fill", text: "\(count)", words: "\(count) unresolved", tone: .warn)
    }

    private var branch: Fact {
        switch rebase {
        case .conflicts: return Fact(symbol: "exclamationmark.triangle.fill", words: "Conflicts with \(pr.baseRef)", tone: .bad)
        case .behindBase: return Fact(symbol: "arrow.down.circle.fill", words: "Behind \(pr.baseRef)", tone: .warn)
        case .baseMerged: return Fact(symbol: "arrow.triangle.branch", words: "\(pr.baseRef) was merged: rebase onto \(pr.defaultBranch)", tone: .warn)
        case nil: return Fact(text: "—", words: "Up to date", tone: .neutral)
        }
    }

    /// The facts as label and value rows, in words, for a details column's `FieldRows`.
    struct Rows: View {
        var pr: PullRequest
        var rebase: RebaseReason?

        var body: some View {
            let facts = PullRequestFacets(pr: pr, rebase: rebase).facts
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                FieldRow(label: PullRequestFacets.labels[index]) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let symbol = fact.symbol {
                            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(PullRequestFacets.color(fact.tone))
                        }
                        Text(fact.words).foregroundStyle(fact.tone == .bad ? Theme.danger : Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private static func cell(_ fact: Fact) -> some View {
        HStack(spacing: 3) {
            if let symbol = fact.symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color(fact.tone)) }
            if let text = fact.text {
                Text(text).lineLimit(1).foregroundStyle(fact.tone == .neutral ? Theme.quiet : color(fact.tone))
            }
        }
        .scaled(.secondary)
        .help(fact.words)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fact.words)
    }

    static func color(_ tone: Tone) -> Color {
        switch tone {
        case .ok: Theme.ok
        case .bad: Theme.danger
        case .warn: Theme.warn
        case .neutral: Theme.quiet
        }
    }

    /// The column names over the rows, in the rows' places: the PR, its title, the facts, when it moved.
    struct Header: View {
        var body: some View {
            HStack(spacing: 10) {
                Color.clear.frame(width: 18, height: 1)
                Text("Task · PR").scaledFrame(width: 160, alignment: .leading)
                Text("Title").frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    ForEach(PullRequestFacets.columns, id: \.title) { column in
                        Text(column.title).scaledFrame(width: column.width, alignment: .leading)
                    }
                }
                Color.clear.frame(width: 14, height: 1)
                Text("Moved").lineLimit(1).fixedSize().scaledFrame(width: 34, alignment: .trailing)
            }
            .scaled(.caption.weight(.medium))
            .foregroundStyle(Theme.quiet)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
        }
    }
}

/// One PR of yours merged this month: its key, its title over its branches and size, and when it merged.
private struct MergedRow: View {
    var pr: PullRequest
    var model: AppModel
    var selected: Bool

    var body: some View {
        ListRow(selected: selected) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 12)).foregroundStyle(Theme.quiet)
                    .frame(width: 18, height: 20)
                Text(pr.taskRef).scaled(.code).foregroundStyle(Theme.quiet).lineLimit(1)
                    .scaledFrame(width: 160, height: 20, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title).scaled(.rowTitle.weight(selected ? .semibold : .medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(verbatim: "\(pr.baseRef) ← \(pr.headRef) · \(Format.sizeBucket(pr.size)) +\(pr.additions) −\(pr.deletions) · opened \(Format.age(pr.createdAt)) ago")
                            .foregroundStyle(Theme.quiet).lineLimit(1)
                        TicketMark(pr: pr, model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    StageChip2(text: "Merged", onTint: selected)
                    AgeText(date: pr.mergedAt)
                }
                .frame(height: 20)
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
        return HStack(spacing: 3) {
            Button { model.open(ticket?.url) } label: { Text(key).scaled(.caption.monospaced()) }
                .buttonStyle(.link).handCursor()
                .disabled(ticket == nil)
            if let drift {
                Image(systemName: "arrow.right.circle.fill").scaled(.caption.weight(.medium)).foregroundStyle(Theme.warn)
                    .help("Jira says “\(drift.ticket.status)”; this PR says “\(drift.target)”. A suggested move: press Move on the ticket")
            }
        }
        .fixedSize()
        .help(ticket.map { "\(key) — \($0.status)" } ?? "\(key) — not among your tickets")
    }
}

/// The selected task in full: what it is and its ticket's first line, its PRs and where each stands, what it depends on,
/// its worker and what that worker did, and the master's questions about it; at the foot, the master and its ticket.
/// A task's only view: it has no page.
private struct TaskDetails: View {
    var task: WorkTask
    var model: AppModel
    /// Opens a PR's page, by url.
    var open: (String) -> Void

    var body: some View {
        let ticket = task.origin == .ticket ? model.state.ticket(task.id) : nil
        DetailColumn {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        TaskKicker(task: task, ticket: ticket, priority: true).scaled(.secondary).foregroundStyle(Theme.quiet)
                        Text(task.title).scaled(.heading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if let first = ticket.flatMap(TaskText.firstLine) {
                            Text(first.text).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !task.pullRequests.isEmpty {
                        RuledList(title: "Pull requests", count: task.pullRequests.count) {
                            ForEach(task.pullRequests, id: \.url) { pr in
                                RuledRow {
                                    Button { open(pr.url) } label: {
                                        HStack(spacing: 12) {
                                            Text(pr.taskRef).scaled(.code).lineLimit(1)
                                            Spacer(minLength: 8)
                                            StatePill(state: RowState.of(pr))
                                        }
                                        .frame(maxHeight: .infinity)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open \(pr.title)")
                                }
                            }
                        }
                    }
                    if !task.dependsOn.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("Depends on")
                            ForEach(task.dependsOn, id: \.self) { Text(TaskHeader.dependency($0)).scaled(.code).help($0) }
                        }
                    }
                    if let worker = task.worker {
                        RuledList(title: task.origin == .session && task.pullRequests.isEmpty ? "Investigation" : "Worker") {
                            RuledRow { TaskWorkerLine(job: worker, model: model).padding(.vertical, 8) }
                        }
                    }
                    ForEach(model.state.asks.filter { $0.task == task.id }) { TaskAskCallout(ask: $0, model: model) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            HStack(spacing: 8) {
                Button("Master in iTerm") { model.openMaster() }.buttonStyle(.desk(.primary, .large, wide: true))
                if let ticket { Button("Open in Jira") { model.open(ticket.url) }.buttonStyle(.desk(.secondary, .large)) }
            }
        }
    }
}

/// "PRO-650 · Jira · Review Ready · Medium", "cofhe #1159 · Pull request, no ticket", "teecryptor · Session, no ticket",
/// the key in DM Mono.
struct TaskKicker: View {
    var task: WorkTask
    var ticket: Ticket?
    var priority = false
    @Environment(\.textScale) private var scale

    var body: some View {
        let rest: String = switch task.origin {
        case .ticket: ([" · Jira", ticket?.status ?? "not among your tickets"] + (priority ? [ticket?.priority].compactMap { $0 } : [])).joined(separator: " · ")
        case .pullRequest: " · Pull request, no ticket"
        case .session: " · Session, no ticket"
        }
        Text("\(Text(TaskHeader.label(task)).font(AppTextStyle.code.font(scale: scale)))\(rest)").lineLimit(1)
    }
}

/// A worker in a details column: its state's mark, its name, where it stands and since when, and under them what it
/// did, with the press that shows its pane.
struct TaskWorkerLine: View {
    var job: ClaudeJob
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SessionMark(job: job).frame(width: 12)
                Text(job.name).scaled(AppTextStyle(size: 12.5, weight: .medium, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(job.status) · \(TaskText.when(job.updatedAt))").scaled(.code).foregroundStyle(Theme.quiet).fixedSize()
            }
            if let detail = job.detail, !detail.isEmpty {
                Text(detail).fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
            }
            Button("Show in iTerm") { model.show(jobId: job.id) }
                .buttonStyle(.desk(.secondary, .small))
                .padding(.leading, 20).padding(.top, 2)
                .help("Show \(job.name)'s pane in iTerm")
        }
    }
}

/// A question the master has open on a task, as a quiet callout, with the press that shows the master's pane to answer
/// it there.
struct TaskAskCallout: View {
    var ask: MasterAsk
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Master asks").fontWeight(.semibold).foregroundStyle(Theme.ink)
                Spacer(minLength: 4)
                Text(Format.age(ask.askedAt)).scaled(.code).help(Format.date(ask.askedAt))
            }
            .scaled(.secondary)
            .foregroundStyle(Theme.quiet)
            Text(ask.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Answer in iTerm") { model.openMaster() }.buttonStyle(.desk(.secondary, .small))
                Text("in the master's pane").scaled(.secondary).foregroundStyle(Theme.quiet)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A PR selected in the PRs view or Merged: what it is and where it stands, its task, and its page at the foot.
private struct TaskPullRequestDetails: View {
    var pr: PullRequest
    var model: AppModel
    var open: () -> Void

    var body: some View {
        let task = pr.state == .open ? model.state.task(for: pr) : nil
        DetailColumn {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pr.taskRef).scaled(.code).foregroundStyle(Theme.quiet)
                        Text(pr.title).scaled(.heading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if pr.state != .open { TaskStatePill(pr: pr).padding(.top, 2) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Pull request")
                        FieldRows(labelWidth: 84) {
                            if pr.state == .open { PullRequestFacets.Rows(pr: pr, rebase: model.state.rebaseReason(pr)) }
                            FieldRow("Branches", "\(pr.baseRef) ← \(pr.headRef)", mono: true)
                            FieldRow(label: "Size") { DiffStat(pr: pr) }
                            FieldRow("Updated", "\(Format.age(pr.updatedAt)) ago")
                        }
                    }
                    if let task, task.origin != .pullRequest {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Task")
                            TaskKicker(task: task, ticket: model.state.ticket(task.id)).scaled(.secondary).foregroundStyle(Theme.quiet)
                            Text(task.title).fixedSize(horizontal: false, vertical: true)
                            if let worker = task.worker { TaskWorkerLine(job: worker, model: model).padding(.top, 4) }
                        }
                    } else if let worker = task?.worker {
                        // A task that is a PR is this PR or its stack, so only its worker is news here.
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Worker")
                            TaskWorkerLine(job: worker, model: model)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            HStack(spacing: 8) {
                Button(action: open) { HStack(spacing: 8) { Text("Open pull request"); ButtonKey(key: "↩") } }
                    .buttonStyle(.desk(.primary, .large, wide: true))
                Button("Open on GitHub") { model.open(pr.url) }.buttonStyle(.desk(.secondary, .large))
            }
        }
    }
}

/// Where a PR stands, as its page's header says it: what it waits on for an open one, in the colour of whose move it
/// is, or how it ended. The chip every status in the app is.
struct TaskStatePill: View {
    var pr: PullRequest

    var body: some View {
        switch pr.state {
        case .open: StatePill(state: RowState.of(pr))
        case .merged: StageChip2(text: "Merged", color: Theme.merged).help(pr.mergedAt.map { "Merged \(Format.date($0))" } ?? "Merged")
        case .closed: StageChip2(text: "Closed", color: Theme.closed)
        }
    }
}

/// A pull request's own page, opened from its row or its task. Its header says what it is — the breadcrumb back, its
/// title (yours to rename), its branches and size — with where it stands, Open on GitHub, and ⋯ for the presses that
/// change it; under it its conversation or its files. Beside them, the next step it waits on, its checks, its task and
/// its ticket, and its facts.
struct PullRequestPage: View {
    var pr: PullRequest
    var model: AppModel
    /// The screen it was opened from, which its breadcrumb names and returns to.
    var back = "Tasks"
    /// The main column's tab it opens on.
    var tab: PullRequestTab = Self.openingTab
    /// Conversation; snapshots set Files changed with `tab=files`.
    nonisolated(unsafe) static var openingTab = PullRequestTab.conversation
    /// The tab picked since it opened.
    @State private var picked: PullRequestTab?
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
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rule))
    }

    var body: some View {
        // An ended PR has nothing left to act on or check: its ticket and its facts.
        let task = pr.state == .open ? model.state.task(for: pr) : nil
        let shown = picked ?? tab
        TaskPageFrame(model: model, back: back, onBack: onBack, mainScrolls: shown != .files) {
            Text(pr.taskRef).font(AppTextStyle.code.font(scale: model.textScale))
        } title: {
            EditableTitle(prefix: "", title: pr.title, what: "the PR", editable: pr.state == .open, style: .taskPageTitle) {
                await model.retitle(pr, to: $0)
            } trailing: {
                EmptyView()
            }
            Text(verbatim: "\(pr.taskRef) · \(pr.baseRef) ← \(pr.headRef) · \(Format.sizeBucket(pr.size)) +\(pr.additions) −\(pr.deletions)")
                .scaled(.code).foregroundStyle(Theme.quiet).lineLimit(1).textSelection(.enabled)
        } actions: {
            TaskStatePill(pr: pr)
            Button("Open on GitHub") { model.open(pr.url) }.buttonStyle(.desk)
            MoreMenu(pr: pr, model: model)
        } main: {
            if let error = model.sessionErrors[pr.url] {
                Text(error).scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
            PullRequestMain(pr: pr, model: model, tab: Binding { shown } set: { picked = $0 }) {
                description
                ConversationSection(pr: pr, model: model)
            }
        } details: {
            if pr.state == .open {
                NextStepCard(pr: pr, session: model.state.session(for: pr), model: model)
                TaskChecks(pr: pr, model: model)
            }
            if let task { TaskOfPullRequest(task: task, model: model) }
            TaskJiraSection(pr: pr, model: model)
            AboutCard(pr: pr, model: model)
        }
    }
}

/// The task a PR belongs to, in its page's details column: its key, its worker with what it did, and the way to its page.
private struct TaskOfPullRequest: View {
    var task: WorkTask
    var model: AppModel
    var open: (@MainActor (Route) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Task").padding(.bottom, 8)
            FieldRows(labelWidth: 64) {
                FieldRow("Task", TaskHeader.label(task), mono: true)
                if let worker = task.worker {
                    FieldRow(label: "Worker") {
                        Text("\(Text(worker.name).font(AppTextStyle.code.font(scale: model.textScale))) \(Text("· \(worker.status)").foregroundStyle(Theme.quiet))")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let detail = worker.detail, !detail.isEmpty {
                        FieldRow(label: "Summary") { Text(detail).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                if task.pullRequests.count > 1 {
                    FieldRow("With", TaskHeader.pullRequests(task.pullRequests), mono: true)
                }
            }
            HStack(spacing: 12) {
                if let worker = task.worker {
                    Button("Show in iTerm") { model.show(jobId: worker.id) }.buttonStyle(.desk(.secondary, .small))
                        .help("Show \(worker.name)'s pane in iTerm")
                }
            }
            .padding(.top, 10)
        }
    }
}

/// The PR's Jira ticket: its key and where Jira has it, which opens it, with the move the app suggests when Jira is
/// behind; or that it names none.
private struct TaskJiraSection: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Jira")
            if let key = model.state.ticketKeys[pr.url]?.first {
                let ticket = model.state.ticket(key)
                HStack(spacing: 6) {
                    Text(key).scaled(.code)
                    Text("· \(ticket?.status ?? "not among your tickets")").foregroundStyle(Theme.quiet)
                    if let drift = model.state.drift(forKey: key) { DriftBadge(drift: drift, model: model) }
                }
                .help(ticket.map { "\(key): \($0.summary)" } ?? "\(key) is not among the tickets Jira gave the app")
                if let ticket {
                    Button("Open in Jira") { model.open(ticket.url) }
                        .buttonStyle(.plain).underline().scaled(.secondary).foregroundStyle(Theme.quiet).handCursor()
                }
            } else {
                Text("No ticket: a task of its own").foregroundStyle(Theme.quiet).help("No Jira key in the branch name or title")
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
    @Binding var tab: PullRequestTab
    @ViewBuilder var conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Segmented(
                options: [
                    .init(value: .conversation, title: "Conversation"),
                    .init(value: .files, title: "Files changed", count: model.diffs[pr.url]?.files.count),
                ],
                selection: $tab
            )
            switch tab {
            case .conversation: VStack(alignment: .leading, spacing: 24) { conversation }
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
                // Out to the column's edges, so the scroll bar sits in the margin, clear of the boxes.
                ScrollView {
                    files(diff)
                        .padding(EdgeInsets(top: 0, leading: 24, bottom: 20, trailing: 24))
                }
                .deskScrollBar()
                .padding(.horizontal, -24)
            } else if let error = model.diffErrors[pr.url] {
                EmptyState(icon: "exclamationmark.triangle", text: "Couldn't load the changes.", detail: error,
                           actionTitle: "Retry", action: { model.loadDiff(pr, force: true) })
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: "\(pr.url) \(pr.headSha)") { model.loadDiff(pr, force: model.diffs[pr.url].map { $0.sha != pr.headSha } ?? false) }
        .task(id: "\(pr.url) \(pr.updatedAt)") { await model.loadConversation(pr) }
    }

    /// A box per file drawn a row at a time, every line an item of the lazy stack, as the review's diff draws it. A file's
    /// whole box as one item laid out all its lines at once as it scrolled in: thousands, for a large file unfolded. A hang
    /// while scrolling the tab, the window laying itself out without end, was reported with that shape.
    private func files(_ diff: LoadedDiff) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if diff.files.isEmpty { Text("No changes.").scaled(.secondary).foregroundStyle(Theme.quiet) }
            ForEach(diff.files) { file in
                let large = diff.foldedAtFirst.contains(file.path)
                let folded = large != flipped.contains(file.path)
                DiffFileHeader(file: file, folded: folded, large: large) { flipped.formSymmetricDifference([file.path]) }
                    .reviewBox(folded ? .whole : .top, fill: Theme.surface, line: Theme.rule)
                if !folded {
                    if file.isBinary {
                        Text("Binary file").font(DiffType(scale: scale).mono).foregroundStyle(Theme.quiet).padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .reviewBox(.middle, fill: Theme.surface, line: Theme.rule)
                    }
                    let rows = diff.rows[file.path] ?? []
                    ForEach(rows.indices, id: \.self) { index in
                        switch rows[index] {
                        case .hunk(let header):
                            DiffHunkRow(header: header).reviewBox(.middle, fill: Theme.surface, line: Theme.rule)
                        case .line(let line):
                            // One item with its threads, which are empty on nearly every line.
                            VStack(alignment: .leading, spacing: 0) {
                                DiffLineRow(line: line)
                                DiffThreads(line: line, path: file.path, pr: pr, model: model)
                            }
                            .reviewBox(.middle, fill: Theme.surface, line: Theme.rule)
                        }
                    }
                    Color.clear.frame(height: 6).reviewBox(.bottom, fill: Theme.surface, line: Theme.rule)
                }
                Color.clear.frame(height: Theme.Space.m)
            }
        }
    }
}

/// ⋯ in the page's header: the presses that change the PR — ready for review or back to a draft, the squash merge, and
/// Close — each asked about first where it cannot be undone, and the branch and link to copy. A press that does not
/// apply now stays in the menu, greyed, with why.
private struct MoreMenu: View {
    var pr: PullRequest
    var model: AppModel
    @State private var confirmingClose = false
    @State private var confirmingMerge = false
    @State private var closing = false
    @State private var error: String?

    var body: some View {
        let busy = model.busyFlows.contains(pr.url)
        Menu {
            if pr.state == .open {
                Button { model.markReady(pr) } label: {
                    Text("Mark Ready for Review")
                    if !pr.isDraft { Text("It's ready already") }
                }
                .disabled(!pr.isDraft || busy)
                Button { Task { error = await model.convertToDraft(pr) } } label: {
                    Text("Convert to Draft")
                    if pr.isDraft { Text("It's a draft already") }
                }
                .disabled(pr.isDraft || busy)
                Divider()
                Button { confirmingMerge = true } label: {
                    Text("Squash and Merge…")
                    if let blocker = mergeBlocker { Text(blocker) }
                }
                // A merge holds the PR in `busyFlows` until it is done.
                .disabled(mergeBlocker != nil || busy)
                Divider()
            }
            Button("Copy Branch") { Clipboard.copy(pr.headRef) }
            Button("Copy Link") { Clipboard.copy(pr.url) }
            if pr.state == .open {
                Divider()
                // Not while a merge or a flow press is under way on it.
                Button("Close Pull Request…", role: .destructive) { confirmingClose = true }
                    .disabled(closing || busy)
            }
        } label: {
            Group {
                if closing || busy { ProgressView().controlSize(.small) } else { Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)) }
            }
            .foregroundStyle(Theme.ink)
            .frame(width: 32, height: 32)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.control))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ready for review, draft, merge or close; copy its branch or link")
        .accessibilityLabel("More")
        .confirmationDialog(
            // Verbatim: a localized title prints the number as "1,082".
            Text(verbatim: "Squash and merge #\(pr.number) into \(pr.baseRef)?"), isPresented: $confirmingMerge
        ) {
            Button("Squash and merge") { Task { error = await model.squashMerge(pr) } }
        } message: {
            Text(pr.checks.isPending ? "CI is still running, so GitHub may refuse the merge until it passes." : "Its commits become one commit on \(pr.baseRef).")
        }
        .confirmationDialog(Text(verbatim: "Close #\(pr.number) without merging?"), isPresented: $confirmingClose) {
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
            // The message says which change failed: a merge, a close, or turning it back into a draft.
            Text(verbatim: "#\(pr.number) didn't change"),
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// Why Squash and merge is greyed: not ready to merge yet, in the words its row uses, or what GitHub would refuse it for.
    private var mergeBlocker: String? {
        FlowStage.of(pr) == .approved ? pr.mergeBlocker : RowState.of(pr).title
    }
}
