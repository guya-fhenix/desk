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
        NavigationStack(path: $path) {
            list(rows: rows, merged: merged, shown: shown)
                .navigationDestination(for: Route.self) { RoutePage(route: $0, back: "Pull Requests", path: $path) }
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
            PageHeader(title: "Pull Requests") {}
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
                // Arrow keys move the selection; a click, Return or → opens the PR's page.
                List(selection: $selection) {
                    switch scope {
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
        } else if pr.baseRef != pr.defaultBranch {
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
                Image(systemName: "arrow.right.circle.fill").scaled(.caption2).foregroundStyle(.orange)
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
    var back = "Pull Requests"
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
            HStack(spacing: 8) {
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
                // The page's action on the right, where a status line's presses go.
                Spacer(minLength: 8)
                if pr.state == .open { SessionStatus(pr: pr, model: model) }
                MoreMenu(pr: pr, model: model)
            }
            if let error = model.sessionErrors[pr.url] {
                Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        } main: {
            description
            ConversationSection(pr: pr, model: model)
        } side: {
            // An ended PR has nothing left to act on or check: its facts. How it ended is on the status line.
            if pr.state == .open {
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
                // Not while a merge or a flow press is under way on it.
                Button("Close Pull Request…", role: .destructive) { confirmingClose = true }
                    .disabled(closing || model.busyFlows.contains(pr.url))
            }
        } label: {
            if closing { ProgressView().controlSize(.small) } else { Image(systemName: "ellipsis") }
        }
        .menuStyle(.button).handCursor()
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
            Text(verbatim: "#\(pr.number) is still open"),
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
