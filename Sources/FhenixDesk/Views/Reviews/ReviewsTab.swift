import DeskCore
import SwiftUI

/// Two screens in one tab: the queue of PRs waiting on you, and the workspace for one of them. The
/// selection lives on the model rather than here so it survives a tab switch and so a nudge can open it.
struct ReviewsTab: View {
    @Environment(AppModel.self) private var model
    // Hoisted out of ReviewQueue: an if/else swap destroys the queue's own state, and losing the sort
    // every time you come back from a review would be maddening.
    @State private var sortOrder: [KeyPathComparator<PullRequest>] = []
    @AppStorage("sort.reviewQueue") private var storedSort = ""

    private static let sort = TableSort<PullRequest>(
        [
            ("repo", KeyPathComparator(\.repoName)),
            ("number", KeyPathComparator(\.number)),
            ("author", KeyPathComparator(\.author)),
            ("size", KeyPathComparator(\.size)),
            ("waiting", KeyPathComparator(\.createdAt)),
        ],
        fallback: [KeyPathComparator(\PullRequest.createdAt)]
    )
    // Hoisted for the same reason as the sort: coming back from a workspace should not reset the scope.
    @State private var scope: ReviewScope = .all
    // Most of the queue is old and settled; the recent window is what you actually act on.
    @State private var recentOnly = true

    var body: some View {
        Group {
            if let url = model.openReviewURL, let record = model.state.reviews[url] {
                ReviewWorkspace(record: record, pr: model.state.pullRequest(for: record), model: model)
                    .equatable()
                    // A different PR gets a fresh workspace: scroll position, folds and drafts all reset.
                    .id(url)
            } else {
                ReviewQueue(sortOrder: $sortOrder, scope: $scope, recentOnly: $recentOnly, model: model)
            }
        }
        .remembersSort(Self.sort, order: $sortOrder, stored: $storedSort)
        .navigationTitle("Reviews")
    }
}

private struct ReviewQueue: View {
    @Binding var sortOrder: [KeyPathComparator<PullRequest>]
    @Binding var scope: ReviewScope
    @Binding var recentOnly: Bool
    var model: AppModel

    private func queue(_ scope: ReviewScope) -> [PullRequest] { model.state.reviewQueue(scope, recentOnly: recentOnly) }
    private var rows: [PullRequest] { queue(scope).sorted(using: sortOrder) }
    /// The ones GitHub actually put on you, so a row in the mixed list says which it is.
    private var onMe: Set<String> { Set(model.state.reviewRequests.map(\.url)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Repo", value: \.repoName) { pr in Text(pr.repoName) }.width(min: 90, ideal: 110)
                TableColumn("Pull request", value: \.number) { pr in
                    QueueTitle(pr: pr, model: model, onMe: onMe.contains(pr.url))
                }
                .width(min: 220, ideal: 340)
                TableColumn("Author", value: \.author) { pr in Text(pr.author) }.width(100)
                TableColumn("Size", value: \.size) { pr in DiffStat(pr: pr) }.width(110)
                TableColumn("Checks") { pr in ChecksBadge(pr: pr) }.width(50)
                TableColumn("Waiting", value: \.createdAt) { pr in Text(Format.age(pr.createdAt)).monospacedDigit() }.width(64)
                TableColumn("Review") { pr in QueueReviewCell(pr: pr, model: model) }.width(min: 210, ideal: 260)
                TableColumn("") { pr in QueueActions(pr: pr, model: model) }.width(136)
            }
            .overlay {
                if rows.isEmpty {
                    EmptyText(text: model.state.errors[.github] ?? emptyText).padding()
                }
            }
            Divider()
            PastReviews(model: model)
        }
    }

    private var emptyText: String {
        switch scope {
        case .onMe: return recentOnly ? "Nothing from the last two weeks waits on you." : "Nothing waits on your review."
        case .open: return recentOnly ? "No unreviewed PRs opened in the last two weeks." : "No open PRs left unreviewed in the tracked repos."
        case .all: return recentOnly ? "Nothing opened in the last two weeks." : "Nothing to review."
        }
    }

    /// The answer to "what should I press Review on?", which is the only thing that starts a review.
    private var header: some View {
        let ready = model.state.reviewsToRun.count
        return HStack(spacing: 8) {
            Picker("Scope", selection: $scope) {
                ForEach(ReviewScope.allCases) { scope in
                    Text("\(scope.title) \(queue(scope).count)").tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle(isOn: $recentOnly) { Text(recentOnly ? "Last 2 weeks" : "All time") }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show only pull requests opened in the last two weeks")
            if ready > 0 {
                Chip(text: "\(ready) ready to run", color: .orange)
                    .help("Press Review on a row to run it. Nothing runs on its own.")
            }
            Spacer()
            if !model.canStartReview {
                Text("\(model.busyReviews.count) running").font(.caption).foregroundStyle(.secondary)
            }
            if model.reviewSpendToday > 0 {
                Text("\(Format.usd(model.reviewSpendToday)) today").font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Cells are hosted in their own AppKit views, which can lay one out after its row has left the table
/// and taken the environment with it. Every cell here therefore carries the model, as `StackedTitle`
/// does — and it matters more on this table, which is torn down whenever a workspace opens.
private struct QueueTitle: View {
    var pr: PullRequest
    var model: AppModel
    /// True when GitHub has this PR down as waiting on you, as opposed to you having gone looking for it.
    var onMe: Bool

    var body: some View {
        HStack(spacing: 6) {
            if onMe { Chip(text: "on you", color: .orange) }
            // Opens GitHub, the same as the Pull Requests table. The review workspace has its own button
            // and menu entry in the row, so the title never needs to be dead.
            Button { model.open(pr.url) } label: { Text("#\(pr.number) \(pr.title)").lineLimit(1) }
                .buttonStyle(.link)
        }
    }
}

private struct QueueReviewCell: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        let need = model.state.reviewNeed(for: pr)
        HStack(spacing: 6) {
            if model.busyReviews.contains(pr.url), model.state.review(for: pr) == nil {
                ProgressView().controlSize(.mini)
                Text("starting").font(.caption2).foregroundStyle(.secondary)
            } else if model.state.localRepo(for: pr) == nil {
                Chip(text: "no local clone", color: .secondary)
                    .help("Clone \(pr.repo) under a repo root to review it here")
            } else {
                if let need {
                    Chip(text: need.title, color: need == .failed ? .red : .orange).help(need.detail)
                }
                // A failed run has nothing to show, and a first review has nothing yet; anything else
                // still has its comments worth counting.
                if let record = model.state.review(for: pr), need != .failed {
                    ReviewStatusChip(status: model.state.reviewStatus(for: record, pr: pr))
                    if record.costUSD > 0 {
                        Text(Format.usd(record.costUSD)).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct QueueActions: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        let record = model.state.review(for: pr)
        let need = model.state.reviewNeed(for: pr)
        HStack(spacing: 4) {
            ClaudeSessionButton(pr: pr, model: model)
            if need != nil {
                Button("Review") { model.review(pr) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                    .help(startHelp)
            } else if record != nil {
                Button("Open") { model.openWorkspace(pr.url) }.controlSize(.small)
            }
            if let record {
                Menu {
                    Button("Open review") { model.openWorkspace(pr.url) }
                    Button("Review again") { model.review(pr) }.disabled(!canStart)
                    Button("Reveal worktree") { model.reveal(record.worktreePath) }
                    Button("Remove review", role: .destructive) { model.removeReview(record) }.disabled(record.phase.isBusy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    private var canStart: Bool {
        guard model.state.localRepo(for: pr) != nil, !model.busyReviews.contains(pr.url) else { return false }
        guard model.state.review(for: pr)?.phase.isBusy != true else { return false }
        return model.canStartReview
    }

    private var startHelp: String {
        if model.state.localRepo(for: pr) == nil { return "No local clone of \(pr.repo) to review in" }
        if !model.canStartReview { return "Already running \(model.busyReviews.count) reviews; wait for one to finish" }
        return "Run Claude on this PR now"
    }
}

/// Reviews whose PR left the queue: sent and waiting on the author, or gone. Their worktree stays until
/// the PR merges or the user removes it here.
private struct PastReviews: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Past reviews", count: model.state.pastReviews.count)
            if model.state.pastReviews.isEmpty { EmptyText(text: "No reviews outside the queue.") }
            ForEach(model.state.pastReviews) { record in
                HStack(spacing: 10) {
                    Button { model.openWorkspace(record.prUrl) } label: {
                        Text("\(record.label) \(record.title)").lineLimit(1)
                    }
                    .buttonStyle(.link)
                    ReviewStatusChip(status: model.state.reviewStatus(for: record, pr: model.state.pullRequest(for: record)))
                    Spacer()
                    Text(Format.age(record.lastRunAt)).font(.caption).foregroundStyle(.secondary)
                    Button("Remove") { model.removeReview(record) }
                        .controlSize(.small).disabled(record.phase.isBusy)
                        .help("Delete the review and its worktree (kept when the worktree has local changes)")
                }
            }
        }
        .padding(12)
        .frame(maxHeight: 200)
    }
}
