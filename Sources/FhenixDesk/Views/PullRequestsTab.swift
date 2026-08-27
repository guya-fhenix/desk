import DeskCore
import SwiftUI

struct PullRequestsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Table(model.state.mine.sorted { ($0.repoName, $1.updatedAt) < ($1.repoName, $0.updatedAt) }) {
            TableColumn("Repo") { pr in Text(pr.repoName) }.width(min: 90, ideal: 120)
            TableColumn("Pull request") { pr in
                Button { model.open(pr.url) } label: {
                    Text("#\(pr.number) \(pr.title)").lineLimit(1)
                }
                .buttonStyle(.link)
            }
            .width(min: 200, ideal: 330)
            TableColumn("Checks") { pr in ChecksBadge(pr: pr) }.width(50)
            TableColumn("Review") { pr in ReviewBadge(pr: pr) }.width(90)
            TableColumn("Merge") { pr in MergeBadge(pr: pr) }.width(80)
            TableColumn("Size") { pr in Text("\(Format.sizeBucket(pr.size)) +\(pr.additions) −\(pr.deletions)").font(.caption).monospacedDigit() }.width(120)
            TableColumn("Stack") { pr in
                if let parent = model.state.stackParent(of: pr) {
                    Text("on #\(parent.number)").font(.caption)
                } else if pr.baseRef != model.state.defaultBranches[pr.repoName] ?? "main" {
                    Text("on \(pr.baseRef)").font(.caption).foregroundStyle(.orange).help("Base branch has no open PR")
                } else {
                    Text("–").foregroundStyle(.secondary)
                }
            }
            .width(110)
            TableColumn("Age") { pr in Text(Format.age(pr.createdAt)).monospacedDigit() }.width(50)
            TableColumn("Updated") { pr in Text(Format.age(pr.updatedAt)).monospacedDigit() }.width(60)
        }
        .navigationTitle("Pull Requests")
        .overlay {
            if model.state.mine.isEmpty { EmptyText(text: model.state.errors[.github] ?? "No open PRs.").padding() }
        }
    }
}

struct ReviewsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(model.state.humanReviewRequests.sorted { $0.createdAt < $1.createdAt }) {
                TableColumn("Repo") { pr in Text(pr.repoName) }.width(min: 90, ideal: 120)
                TableColumn("Pull request") { pr in
                    Button { model.open(pr.url) } label: { Text("#\(pr.number) \(pr.title)").lineLimit(1) }.buttonStyle(.link)
                }
                .width(min: 200, ideal: 360)
                TableColumn("Author") { pr in Text(pr.author) }.width(110)
                TableColumn("Size") { pr in Text("\(Format.sizeBucket(pr.size)) · \(pr.size)").monospacedDigit() }.width(90)
                TableColumn("Checks") { pr in ChecksBadge(pr: pr) }.width(50)
                TableColumn("Waiting") { pr in Text(Format.age(pr.createdAt)).monospacedDigit() }.width(70)
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
