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
    /// The PR whose page is showing in place of the list; nil shows the list.
    @State private var opened: String?
    @FocusState private var listFocused: Bool
    @State private var search = ""
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
        let rows = self.rows
        let merged = self.merged
        let shown = scope == .open ? rows.map(\.pullRequest.url) : merged.map(\.url)
        Group {
            if let pr = opened.flatMap(pullRequest) {
                PullRequestPage(pr: pr, model: model) { opened = nil }
            } else {
                list(rows: rows, merged: merged, shown: shown)
            }
        }
        .remembersSort(Self.sort, order: $sortOrder, stored: $storedSort)
        .selectsFirstRow(shown.first, selection: $selection)
        // A tab opens on its first row, unless the selection is already in it: search may have switched the tab to
        // show its PR.
        .onChange(of: scope) {
            if !shown.contains(where: { $0 == selection }) { selection = shown.first }
        }
        // Search, Up Next and a notification land here with a PR to show: its page, with its row selected behind it.
        .onChange(of: model.selectPullRequest, initial: true) { _, url in
            guard let url else { return }
            scope = model.state.recentlyMerged().contains { $0.url == url } ? .merged : .open
            selection = url
            opened = url
            model.selectPullRequest = nil
        }
    }

    @ViewBuilder private func list(rows: [StackedPullRequest], merged: [PullRequest], shown: [String]) -> some View {
        Screen {
            PageHeader(title: "Pull Requests") {}
            FilterBar {
                // Counted over what the search leaves, like the Reviews and Jira tabs; the key cap marks the tab
                // that Tab in the list goes to.
                PillTabs(
                    options: [
                        .init(value: .open, title: "Open", count: rows.count, hint: scope == .open ? nil : "tab"),
                        .init(value: .merged, title: "Recently merged", count: merged.count, hint: scope == .merged ? nil : "tab"),
                    ],
                    selection: $scope
                )
            } trailing: {
                SearchBox(prompt: "Repo, number or title", text: $search)
                // Merged PRs read newest first; the columns this sorts by are about open ones.
                if scope == .open { SortMenu(sort: Self.sort, order: $sortOrder) }
            }
        } content: {
            Hairline()
            if (scope == .open ? model.state.mine : model.state.recentlyMerged()).isEmpty {
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
                if shown.isEmpty {
                    EmptyState(
                        icon: "magnifyingglass", text: "No PR matches “\(search)”.",
                        actionTitle: "Clear search", action: { search = "" }
                    )
                    .padding(.vertical, 20)
                }
            }
            ScrollViewReader { proxy in
                // Arrow keys move the selection; Return, → or a double-click opens the PR's page.
                List(selection: $selection) {
                    switch scope {
                    case .open:
                        ForEach(rows, id: \.pullRequest.url) { row in
                            PullRequestRow(row: row, model: model, selected: selection == row.pullRequest.url)
                        }
                    case .merged:
                        ForEach(merged, id: \.url) { pr in
                            MergedRow(pr: pr, model: model, selected: selection == pr.url)
                        }
                    }
                }
                .deskList()
                // Focused on arrival and on the way back from a page, so the keys work without a click first.
                .focused($listFocused)
                .onAppear { listFocused = true }
                .onKeyPress(.rightArrow) {
                    guard let selection else { return .ignored }
                    opened = selection
                    return .handled
                }
                // Tab flips between the two tabs; Shift-Tab still moves focus out of the list, so it is no trap.
                .onKeyPress(.tab, phases: .down) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    scope = scope == .open ? .merged : .open
                    return .handled
                }
                .contextMenu(forSelectionType: String.self) { urls in
                    if let pr = urls.first.flatMap(pullRequest) { PullRequestMenu(pr: pr, model: model) }
                } primaryAction: { urls in
                    if let url = urls.first { opened = url }
                }
                // Search lands here with the row selected; it may be far down the list.
                .onChange(of: selection, initial: true) { _, url in
                    if let url { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(url, anchor: .center) } }
                }
            }
        }
    }

    /// The stacked rows, filtered by the search field. A child that matches keeps its indent even when its
    /// root does not: the arrow still says it is stacked, and the PR's page names the parent.
    private var rows: [StackedPullRequest] {
        let all = model.state.stackedMine(order: sortOrder)
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { $0.pullRequest.matches(search: search) }
    }

    /// This month's merged PRs, newest first, filtered by the search field.
    private var merged: [PullRequest] {
        model.state.recentlyMerged().filter { $0.matches(search: search) }
    }

    private func pullRequest(_ url: String) -> PullRequest? {
        (model.state.mine + model.state.recentlyMerged()).first { $0.url == url }
    }
}

/// One open PR of yours: its status chips in aligned columns, then its title, and a monospaced line with
/// number, repo, branches, size, open threads and ticket; its stage and ages on the right. Sessions are started and
/// attached to from the PR's page. A stack reads top-down: each PR stacked on another sits indented beneath it, and a root notes a parent that is not
/// in the list, or a base branch that has no open PR at all.
private struct PullRequestRow: View {
    var row: StackedPullRequest
    var model: AppModel
    var selected: Bool

    var body: some View {
        let pr = row.pullRequest
        ListRow(selected: selected) {
            // No avatar and no tick: every PR here is yours, and a mark that is gone on the next launch is no mark.
            HStack(alignment: .center, spacing: 12) {
                // The status leads, in fixed columns, so checks, review and merge state read straight down the list.
                PullRequestStatus(pr: pr).fixedSize()
                if row.depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.secondary)
                        .padding(.leading, CGFloat(row.depth - 1) * 16)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        // Plain text, so a click on it selects the row like a click anywhere else; Return, → and a
                        // double-click open the PR's page.
                        Text(pr.title).scaled(.rowTitle).lineLimit(1)
                        if row.depth == 0 { stackNote(pr) }
                    }
                    HStack(spacing: 8) {
                        MetaLine(parts: Self.meta(pr))
                        TicketMark(pr: pr, model: model)
                    }
                }
                Spacer(minLength: 8)
                FlowStageCell(pr: pr, model: model)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Format.age(pr.updatedAt)).monospacedDigit().foregroundStyle(.secondary)
                        .help("Updated \(Format.date(pr.updatedAt))")
                    Text("opened \(Format.age(pr.createdAt))").scaled(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .help("Opened \(Format.date(pr.createdAt))")
                }
            }
        }
    }

    static func meta(_ pr: PullRequest) -> [Text] {
        var parts = [
            Text(verbatim: "#\(pr.number)"),
            Text(pr.repoName),
            Text("\(pr.baseRef) ← \(pr.headRef)"),
            Text("\(Format.sizeBucket(pr.size)) ") + Text("+\(pr.additions)").foregroundStyle(.green) + Text(" −\(pr.deletions)").foregroundStyle(.red),
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
        } else if pr.baseRef != model.state.defaultBranches[pr.repoName] ?? "main" {
            Text("on \(pr.baseRef)").scaled(.caption).foregroundStyle(.orange).fixedSize()
                .help("Base branch has no open PR")
        }
    }
}

/// One PR of yours merged this month: its title, the same monospaced line an open one has, and when it merged.
private struct MergedRow: View {
    var pr: PullRequest
    var model: AppModel
    var selected: Bool

    var body: some View {
        ListRow(selected: selected) {
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
                .buttonStyle(.link)
                .disabled(ticket == nil)
            if let drift {
                Image(systemName: "arrow.right.circle.fill").scaled(.caption2).foregroundStyle(.orange)
                    .help("Jira says “\(drift.ticket.status)”; this PR says “\(drift.target)”, so Desk moves it")
            }
        }
        .fixedSize()
        .help(ticket.map { "\(key) — \($0.status)" } ?? "\(key) — not among your tickets")
    }
}

/// A pull request's own page, opened from its row: what it is and every press on it at the top, the description and
/// the workflows in the wide column, the status, stack, flow, ticket and sessions beside them.
private struct PullRequestPage: View {
    var pr: PullRequest
    var model: AppModel
    var onBack: () -> Void

    var body: some View {
        DetailPage(back: "Pull Requests", onBack: onBack) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "#\(pr.number) \(pr.title)").scaled(.title).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("\(pr.repoName) · \(pr.author) · \(pr.baseRef) ← \(pr.headRef)")
                    .scaled(.secondary.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                // Side by side, not in the list's columns: there is only the one PR to line up.
                if pr.state != .merged { ChecksBadge(pr: pr); ReviewBadge(pr: pr); MergeBadge(pr: pr) }
                Button("Open on GitHub") { model.open(pr.url) }
                CopyButton(title: "Copy branch", text: pr.headRef)
                // A merged PR has no branch left to work on.
                if pr.state != .merged { ClaudeSessionButton(pr: pr, model: model).fixedSize() }
            }
            .controlSize(.small)
        } main: {
            // Workflows first: folded they are a few lines, and a description can run for screens.
            if pr.state != .merged { WorkflowsSection(pr: pr, model: model) }
            PanelSection("Description") { PullRequestDescription(pr: pr) }
        } side: {
            // A merged PR has nothing left to check, stack or start a session on: when it landed, and its ticket.
            if pr.state == .merged {
                PanelSection("Merged") {
                    LabeledContent("Merged", value: "\(Format.age(pr.mergedAt)) ago into \(pr.baseRef)")
                    LabeledContent("Size") { DiffStat(pr: pr) }
                    LabeledContent("Opened", value: "\(Format.age(pr.createdAt)) ago")
                }
                PanelSection("Jira") { jira }
            } else {
                openSections
            }
        }
    }

    @ViewBuilder private var openSections: some View {
        PanelSection("Status") {
            LabeledContent("Checks") { HStack(spacing: 4) { ChecksBadge(pr: pr); Text(pr.checksText) } }
            LabeledContent("Review") { ReviewBadge(pr: pr) }
            LabeledContent("Merge") { MergeBadge(pr: pr) }
            if let reason = model.state.rebaseReason(pr) {
                LabeledContent("Rebase") { Text(reason.text).foregroundStyle(.orange) }
            }
            LabeledContent("Threads", value: pr.unresolvedThreads == 0 ? "None open" : "\(pr.unresolvedThreads) unresolved")
            LabeledContent("Size") { DiffStat(pr: pr) }
            LabeledContent("Opened", value: "\(Format.age(pr.createdAt)) ago, updated \(Format.age(pr.updatedAt)) ago")
        }
        if parent != nil || !children.isEmpty {
            PanelSection("Stack") {
                if let parent { stackLine("On", parent) }
                ForEach(children) { stackLine("Under it", $0) }
            }
        }
        if let flow = model.state.flow(for: pr) { FlowSection(flow: flow, pr: pr, model: model) }
        PanelSection("Jira") { jira }
        PanelSection("Background session") { sessions }
    }

    private var parent: PullRequest? { model.state.stackParent(of: pr) }

    private var children: [PullRequest] {
        (model.state.github?.allOpen ?? []).filter { model.state.stackParents[$0.url] == pr.url }
    }

    private func stackLine(_ label: String, _ other: PullRequest) -> some View {
        LabeledContent(label) {
            Button { model.open(other.url) } label: { Text(verbatim: "#\(other.number) \(other.title)").lineLimit(1) }
                .buttonStyle(.link)
        }
    }

    @ViewBuilder private var jira: some View {
        let keys = model.state.ticketKeys[pr.url] ?? []
        if keys.isEmpty {
            Text("No Jira key in the branch name or title.").foregroundStyle(.secondary)
        }
        ForEach(keys, id: \.self) { key in
            let ticket = model.state.ticket(key)
            LabeledContent {
                Text(ticket?.status ?? "Not among your tickets").foregroundStyle(.secondary)
            } label: {
                Button(key) { model.open(ticket?.url) }.buttonStyle(.link).disabled(ticket == nil)
            }
            if let drift = model.state.drift(forKey: key) {
                HStack {
                    Text("Jira says “\(drift.ticket.status)”; this PR says “\(drift.target)”.").scaled(.caption)
                    Spacer()
                    DriftBadge(drift: drift, model: model)
                }
            }
        }
    }

    @ViewBuilder private var sessions: some View {
        let jobs = model.state.claudeJobs(for: pr)
        if let skill = model.state.reviewSkill(for: pr) {
            LabeledContent("Review skill") { ReviewSkillMark(skill: skill, showsText: true) }
        }
        if jobs.isEmpty {
            Text("No background session mentions this PR.").foregroundStyle(.secondary)
        }
        ForEach(jobs) { job in
            LabeledContent {
                HStack(spacing: 6) {
                    if model.state.flow(for: pr) == nil {
                        Button("Use for flow") { model.joinFlow(job, pr) }
                            .help("Carry this PR through the flow from its current stage, with this session")
                    }
                    Button("Attach") { model.attach(job, for: pr) }
                }
                .controlSize(.small)
            } label: {
                HStack(spacing: 6) {
                    StatusDot(color: job.isRunning ? .green : .secondary)
                    Text(job.name).lineLimit(1)
                    Text(job.state).scaled(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let error = model.sessionErrors[pr.url] {
            Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
