import DeskCore
import SwiftUI

struct PullRequestsTab: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder: [KeyPathComparator<StackedPullRequest>] = []
    @AppStorage("sort.pullRequests") private var storedSort = ""

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
        Table(model.state.stackedMine(order: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Repo", value: \.pullRequest.repoName) { row in Text(row.pullRequest.repoName) }.width(min: 90, ideal: 120)
            TableColumn("Pull request", value: \.pullRequest.number) { row in StackedTitle(row: row, model: model) }.width(min: 200, ideal: 360)
            TableColumn("Agent") { row in ClaudeSessionButton(pr: row.pullRequest, model: model) }.width(50)
            TableColumn("Checks") { row in ChecksBadge(pr: row.pullRequest) }.width(50)
            TableColumn("Review") { row in ReviewBadge(pr: row.pullRequest) }.width(90)
            TableColumn("Merge") { row in MergeBadge(pr: row.pullRequest) }.width(80)
            TableColumn("Threads", value: \.pullRequest.unresolvedThreads) { row in UnresolvedThreads(count: row.pullRequest.unresolvedThreads) }.width(80)
            TableColumn("Size", value: \.pullRequest.size) { row in DiffStat(pr: row.pullRequest) }.width(120)
            TableColumn("Age", value: \.pullRequest.createdAt) { row in Text(Format.age(row.pullRequest.createdAt)).monospacedDigit() }.width(50)
            TableColumn("Updated", value: \.pullRequest.updatedAt) { row in Text(Format.age(row.pullRequest.updatedAt)).monospacedDigit() }.width(60)
        }
        .remembersSort(Self.sort, order: $sortOrder, stored: $storedSort)
        .navigationTitle("Pull Requests")
        .overlay {
            if model.state.mine.isEmpty { EmptyText(text: model.state.errors[.github] ?? "No open PRs.").padding() }
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
            if let key = model.state.ticketKeys[pr.url]?.first {
                TicketMark(key: key, model: model)
            }
            if row.depth == 0 {
                if row.stackSize > 1 {
                    Chip(text: "stack of \(row.stackSize)").fixedSize()
                }
                if let parent = model.state.stackParent(of: pr) {
                    Text("on #\(parent.number)").font(.caption).foregroundStyle(.secondary).fixedSize()
                        .help("Stacked on #\(parent.number) by \(parent.author)")
                } else if pr.baseRef != model.state.defaultBranches[pr.repoName] ?? "main" {
                    Text("on \(pr.baseRef)").font(.caption).foregroundStyle(.orange).fixedSize()
                        .help("Base branch has no open PR")
                }
            }
        }
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
    var key: String
    var model: AppModel

    var body: some View {
        let ticket = model.state.ticket(key)
        let drift = model.state.drift(forKey: key)
        HStack(spacing: 3) {
            Button { model.open(ticket?.url) } label: { Text(key).font(.caption.monospaced()) }
                .buttonStyle(.link)
                .disabled(ticket == nil)
            if let drift {
                Image(systemName: "arrow.right.circle.fill").font(.caption2).foregroundStyle(.orange)
                    .help("Jira says “\(drift.ticket.status)”; this PR says “\(drift.target)” — move it on the Tickets screen")
            }
        }
        .fixedSize()
        .help(ticket.map { "\(key) — \($0.status)" } ?? "\(key) — not among your tickets")
    }
}
