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
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { row in CheckMark(url: row.pullRequest.url, model: model) }.width(20)
            TableColumn("Repo", value: \.pullRequest.repoName) { row in Text(row.pullRequest.repoName) }.width(min: 90, ideal: 120)
            TableColumn("Pull request", value: \.pullRequest.number) { row in StackedTitle(row: row, model: model) }.width(min: 200, ideal: 340)
            TableColumn("Ticket") { row in TicketMark(pr: row.pullRequest, model: model) }.width(min: 70, ideal: 90)
            // Grouped only because a group has one sort type, so no sortable column can sit among these.
            Group {
                TableColumn("Agent") { (row: StackedPullRequest) in ClaudeSessionButton(pr: row.pullRequest, model: model) }.width(44)
                TableColumn("Stage") { (row: StackedPullRequest) in FlowStageCell(pr: row.pullRequest, model: model) }.width(min: 80, ideal: 100)
                TableColumn("Status") { (row: StackedPullRequest) in PullRequestStatus(pr: row.pullRequest) }.width(min: 150, ideal: 170)
            }
            TableColumn("Threads", value: \.pullRequest.unresolvedThreads) { row in UnresolvedThreads(count: row.pullRequest.unresolvedThreads) }.width(70)
            TableColumn("Size", value: \.pullRequest.size) { row in DiffStat(pr: row.pullRequest) }.width(110)
            TableColumn("Age", value: \.pullRequest.createdAt) { row in Text(Format.age(row.pullRequest.createdAt)).monospacedDigit() }.width(44)
            TableColumn("Updated", value: \.pullRequest.updatedAt) { row in Text(Format.age(row.pullRequest.updatedAt)).monospacedDigit() }.width(56)
        }
        .remembersSort(Self.sort, order: $sortOrder, stored: $storedSort)
        .searchable(text: $search, placement: .toolbar, prompt: "Repo, number or title")
        .navigationTitle("Pull Requests")
        .overlay {
            if model.state.mine.isEmpty { EmptyText(text: model.state.errors[.github] ?? "No open PRs.").padding() }
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
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { row in
            let pr = row.pullRequest
            return "\(pr.repoName)#\(pr.number) \(pr.title) \(pr.headRef)".lowercased().contains(needle)
        }
    }
}

/// A stack reads top-down: the root carries its size, and each PR stacked on it sits indented beneath.
/// A root also notes a parent that is not in the table, or a base branch that has no open PR at all.
///
/// Table cells are hosted in their own AppKit views, and AppKit can lay one out after its row left the
/// table and the environment with it. Cells therefore take the model from the table view instead of
/// reading it from the environment, which would trap with "No Observable object of type AppModel found".
private struct StackedTitle: View {
    var row: StackedPullRequest
    var model: AppModel

    var body: some View {
        let pr = row.pullRequest
        HStack(spacing: 6) {
            if row.depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(row.depth - 1) * 16)
            }
            Button { model.open(pr.url) } label: { Text("#\(pr.number) \(pr.title)").lineLimit(1) }.buttonStyle(.link)
            if row.depth == 0 {
                if row.stackSize > 1 {
                    Chip(text: "stack of \(row.stackSize)").fixedSize()
                }
                if let parent = model.state.stackParent(of: pr) {
                    Text("on #\(parent.number)").scaled(.caption).foregroundStyle(.secondary).fixedSize()
                        .help("Stacked on #\(parent.number) by \(parent.author)")
                } else if pr.baseRef != model.state.defaultBranches[pr.repoName] ?? "main" {
                    Text("on \(pr.baseRef)").scaled(.caption).foregroundStyle(.orange).fixedSize()
                        .help("Base branch has no open PR")
                }
            }
        }
    }
}

/// The PR's stage in the app's flow, or a dash for a PR no flow carries.
private struct FlowStageCell: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        if let flow = model.state.flow(for: pr) {
            StageChip(stage: flow.stage).fixedSize()
        } else {
            Text("–").foregroundStyle(.secondary).help("Not started from a ticket")
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

/// Review conversations still open on a PR. Zero reads as a dash so the column stays quiet on clean PRs.
private struct UnresolvedThreads: View {
    var count: Int

    var body: some View {
        if count > 0 {
            Chip(text: "\(count) open", color: .orange).help("\(count) unresolved review \(count == 1 ? "thread" : "threads")")
        } else {
            Text("–").foregroundStyle(.secondary)
        }
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
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("#\(pr.number) \(pr.title)").scaled(.headline).fixedSize(horizontal: false, vertical: true)
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
            Section("Status") {
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
                Section("Stack") {
                    if let parent { stackLine("On", parent) }
                    ForEach(children) { stackLine("Under it", $0) }
                }
            }
            if let flow = model.state.flow(for: pr) {
                Section("Flow") {
                    LabeledContent("Stage") { StageChip(stage: flow.stage) }
                    if let key = flow.ticketKey { LabeledContent("Started from", value: key) }
                }
            }
            Section("Jira") { jira }
            Section("Background session") { sessions }
        }
        .formStyle(.grouped)
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
            Button { model.open(other.url) } label: { Text("#\(other.number) \(other.title)").lineLimit(1) }
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
                Button("Attach") { model.attach(job, for: pr) }.controlSize(.small)
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
