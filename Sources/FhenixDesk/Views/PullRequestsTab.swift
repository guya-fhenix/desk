import DeskCore
import SwiftUI

struct PullRequestsTab: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder: [KeyPathComparator<StackedPullRequest>] = []
    @AppStorage("sort.pullRequests") private var storedSort = ""
    @State private var selection: String?
    @State private var search = ""

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
        Screen {
            PageHeader(title: "Pull Requests") { HeaderControls(inspector: "pullRequests") }
            FilterBar {
                Text("\(model.state.mine.count) open").scaled(.callout).foregroundStyle(.secondary)
            } trailing: {
                SearchBox(prompt: "Repo, number or title", text: $search)
                SortMenu(sort: Self.sort, order: $sortOrder)
            }
        } content: {
            Hairline()
            if model.state.mine.isEmpty {
                EmptyText(text: model.state.errors[.github] ?? "No open PRs.").padding(.vertical, 20)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.pullRequest.url) { row in
                            PullRequestRow(row: row, model: model, selected: selection == row.pullRequest.url) {
                                selection = row.pullRequest.url
                            }
                        }
                    }
                }
                // Search lands here with the row selected; it may be far down the list.
                .onChange(of: selection, initial: true) { _, url in
                    if let url { withAnimation { proxy.scrollTo(url, anchor: .center) } }
                }
            }
        }
        .remembersSort(Self.sort, order: $sortOrder, stored: $storedSort)
        .onChange(of: model.selectPullRequest, initial: true) { _, url in
            guard let url else { return }
            selection = url
            model.selectPullRequest = nil
        }
        .deskInspector("pullRequests") {
            if let pr = model.state.mine.first(where: { $0.url == selection }) {
                PullRequestInspector(pr: pr, model: model)
            } else {
                EmptyText(text: "Select a pull request.").padding()
                Spacer()
            }
        }
    }

    /// The stacked rows, filtered by the search field. A child that matches keeps its indent even when its
    /// root does not: the arrow still says it is stacked, and the inspector names the parent.
    private var rows: [StackedPullRequest] {
        let all = model.state.stackedMine(order: sortOrder)
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { row in
            let pr = row.pullRequest
            return pr.matches(search: search)
        }
    }
}

/// One open PR of yours: your own tick, its picture, its status chips and title, and a monospaced line with
/// number, repo, branches, size, open threads and ticket; its stage, session and ages on the right. A stack
/// reads top-down: each PR stacked on another sits indented beneath it, and a root notes a parent that is not
/// in the list, or a base branch that has no open PR at all.
private struct PullRequestRow: View {
    var row: StackedPullRequest
    var model: AppModel
    var selected: Bool
    var select: () -> Void

    var body: some View {
        let pr = row.pullRequest
        ListRow(selected: selected, select: select) {
            HStack(alignment: .center, spacing: 12) {
                CheckMark(url: pr.url, model: model)
                if row.depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(row.depth - 1) * 16)
                }
                Avatar(login: pr.author)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        PullRequestStatus(pr: pr)
                        Button { model.open(pr.url) } label: { Text(pr.title).lineLimit(1) }
                            .buttonStyle(.plain)
                            .help("Open #\(pr.number) on GitHub" as String)
                        if row.depth == 0 { stackNote(pr) }
                    }
                    HStack(spacing: 8) {
                        MetaLine(parts: meta(pr))
                        TicketMark(pr: pr, model: model)
                    }
                }
                Spacer(minLength: 8)
                FlowStageCell(pr: pr, model: model)
                ClaudeSessionButton(pr: pr, model: model)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Format.age(pr.updatedAt)).monospacedDigit().foregroundStyle(.secondary).help("Updated")
                    Text("opened \(Format.age(pr.createdAt))").scaled(.caption).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func meta(_ pr: PullRequest) -> [Text] {
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
            Chip(text: "stack of \(row.stackSize)").fixedSize()
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

/// Your own tick on a row. GitHub never sees it, and it does not survive the app quitting.
private struct CheckMark: View {
    var url: String
    var model: AppModel

    var body: some View {
        Toggle("Checked", isOn: Binding(
            get: { model.checkedPullRequests.contains(url) },
            set: { checked in
                if checked { model.checkedPullRequests.insert(url) } else { model.checkedPullRequests.remove(url) }
            }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .help("Your own mark; cleared when the PR leaves this list")
    }
}

/// The Jira ticket a pull request is about, and whether the two still agree. Read-only on purpose: the
/// press that moves a ticket lives on the Tickets screen, where the ticket does.
private struct TicketMark: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        if let key = model.state.ticketKeys[pr.url]?.first {
            link(key)
        } else {
            Text("–").foregroundStyle(.secondary).help("No Jira key in the branch name or title")
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

/// Everything about the selected pull request that the row has no room for, and every press that acts on it.
private struct PullRequestInspector: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        Panel {
            PanelSection {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "#\(pr.number) \(pr.title)").scaled(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text("\(pr.repoName) · \(pr.headRef) → \(pr.baseRef)")
                        .scaled(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button("Open on GitHub") { model.open(pr.url) }
                    Button("Copy branch") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pr.headRef, forType: .string)
                    }
                }
                .controlSize(.small)
            }
            PanelSection("Status") {
                LabeledContent("Checks") { HStack(spacing: 4) { ChecksBadge(pr: pr); Text(checksText) } }
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
    }

    private var checksText: String {
        switch pr.checks {
        case .success: return "Passed"
        case .failure, .error: return "Failed"
        case .pending, .expected: return "Running"
        case .none: return "No checks"
        }
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
            HStack {
                Button("Start on \(pr.headRef)") { model.startSession(for: pr) }
                    .disabled(model.state.localRepo(for: pr) == nil || model.startingSessions.contains(pr.url))
                if model.startingSessions.contains(pr.url) { ProgressView().controlSize(.mini) }
            }
            .controlSize(.small)
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
