import DeskCore
import SwiftUI

struct PullRequestsTab: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [
        KeyPathComparator(\StackedPullRequest.pullRequest.repoName),
        KeyPathComparator(\StackedPullRequest.pullRequest.updatedAt, order: .reverse),
    ]

    var body: some View {
        Table(model.state.stackedMine(order: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Repo", value: \.pullRequest.repoName) { row in Text(row.pullRequest.repoName) }.width(min: 90, ideal: 120)
            TableColumn("Pull request", value: \.pullRequest.number) { row in StackedTitle(row: row) }.width(min: 200, ideal: 360)
            TableColumn("Checks") { row in ChecksBadge(pr: row.pullRequest) }.width(50)
            TableColumn("Review") { row in ReviewBadge(pr: row.pullRequest) }.width(90)
            TableColumn("Merge") { row in MergeBadge(pr: row.pullRequest) }.width(80)
            TableColumn("Size", value: \.pullRequest.size) { row in DiffStat(pr: row.pullRequest) }.width(120)
            TableColumn("Age", value: \.pullRequest.createdAt) { row in Text(Format.age(row.pullRequest.createdAt)).monospacedDigit() }.width(50)
            TableColumn("Updated", value: \.pullRequest.updatedAt) { row in Text(Format.age(row.pullRequest.updatedAt)).monospacedDigit() }.width(60)
        }
        .navigationTitle("Pull Requests")
        .overlay {
            if model.state.mine.isEmpty { EmptyText(text: model.state.errors[.github] ?? "No open PRs.").padding() }
        }
    }
}

/// A stack reads top-down: the root carries its size, and each PR stacked on it sits indented beneath.
/// A root also notes a parent that is not in the table, or a base branch that has no open PR at all.
private struct StackedTitle: View {
    @Environment(AppModel.self) private var model
    var row: StackedPullRequest

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

struct ReviewsTab: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\PullRequest.createdAt)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(model.state.humanReviewRequests.sorted(using: sortOrder), sortOrder: $sortOrder) {
                TableColumn("Repo", value: \.repoName) { pr in Text(pr.repoName) }.width(min: 90, ideal: 120)
                TableColumn("Pull request", value: \.number) { pr in
                    Button { model.open(pr.url) } label: { Text("#\(pr.number) \(pr.title)").lineLimit(1) }.buttonStyle(.link)
                }
                .width(min: 200, ideal: 360)
                TableColumn("Author", value: \.author) { pr in Text(pr.author) }.width(110)
                TableColumn("Size", value: \.size) { pr in DiffStat(pr: pr) }.width(120)
                TableColumn("Checks") { pr in ChecksBadge(pr: pr) }.width(50)
                TableColumn("Waiting", value: \.createdAt) { pr in Text(Format.age(pr.createdAt)).monospacedDigit() }.width(70)
            }
            Divider()
            bots
        }
        .navigationTitle("Reviews")
    }

    private var bots: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(title: "Bot PRs", count: model.state.botReviewRequests.count)
                Spacer()
                if model.state.botReviewRequests.count > 1 {
                    Button("Approve all bot PRs") { model.state.botReviewRequests.forEach(model.approve) }.controlSize(.small)
                }
            }
            if model.state.botReviewRequests.isEmpty { EmptyText(text: "No bot PRs wait.") }
            ForEach(model.state.botReviewRequests) { pr in
                HStack(spacing: 10) {
                    ChecksBadge(pr: pr)
                    Button { model.open(pr.url) } label: { Text("\(pr.repoName)#\(pr.number) \(pr.title)").lineLimit(1) }.buttonStyle(.link)
                    Spacer()
                    Text(Format.age(pr.createdAt)).font(.caption).foregroundStyle(.secondary)
                    Button("Approve") { model.approve(pr) }.controlSize(.small).disabled(pr.checks.isRed)
                }
            }
        }
        .padding(12)
        .frame(maxHeight: 220)
    }
}
