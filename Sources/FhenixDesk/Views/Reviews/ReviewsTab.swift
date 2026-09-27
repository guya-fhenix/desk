import DeskCore
import SwiftUI

/// The PRs waiting on your review, and the press that has Claude review one. What it finds goes into your
/// draft review on GitHub; this screen follows that draft and opens it, and nothing more.
struct ReviewsTab: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder: [KeyPathComparator<PullRequest>] = []
    @AppStorage("sort.reviewQueue") private var storedSort = ""
    @State private var scope: ReviewScope = .all
    // Most of the queue is old and settled; the recent window is what you actually act on.
    @State private var recentOnly = true
    @State private var selection: String?

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

    private func queue(_ scope: ReviewScope) -> [PullRequest] { model.state.reviewQueue(scope, recentOnly: recentOnly) }
    private var rows: [PullRequest] { queue(scope).sorted(using: sortOrder) }
    /// The ones GitHub actually put on you, so a row in the mixed list says which it is.
    private var onMe: Set<String> { Set(model.state.reviewRequests.map(\.url)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
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
                TableColumn("") { pr in QueueActions(pr: pr, model: model) }.width(170)
            }
            // Double-click opens the draft on GitHub, when there is one to open.
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { urls in
                if let url = urls.first, let record = model.state.reviews[url], record.draft != nil { model.openDraft(record) }
            }
            .overlay {
                if rows.isEmpty {
                    EmptyText(text: model.state.errors[.github] ?? emptyText).padding()
                }
            }
        }
        .remembersSort(Self.sort, order: $sortOrder, stored: $storedSort)
        .navigationTitle("Reviews")
    }

    private var emptyText: String {
        switch scope {
        case .onMe: return recentOnly ? "Nothing from the last two weeks waits on you." : "Nothing waits on your review."
        case .open: return recentOnly ? "No unreviewed PRs opened in the last two weeks." : "No open PRs left unreviewed in the tracked repos."
        case .all: return recentOnly ? "Nothing opened in the last two weeks." : "Nothing to review."
        }
    }

    /// The answer to "what should I press Review on?", which is the only thing that starts a review.
    /// Counted over the rows on screen, like the scope counts beside it: a number that outlived the
    /// filters would point at rows the table is not showing.
    private var header: some View {
        let ready = rows.count { model.state.reviewNeed(for: $0) != nil }
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
                    .help("Of the rows shown. Press Review on one to run it; nothing runs on its own.")
            }
            Spacer()
            if !model.canStartReview {
                Text("\(model.busyReviews.count) running").scaled(.caption).foregroundStyle(.secondary)
            }
            if model.reviewSpendToday > 0 {
                Text("\(Format.usd(model.reviewSpendToday)) today").scaled(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Cells are hosted in their own AppKit views, which can lay one out after its row has left the table
/// and taken the environment with it. Every cell here therefore carries the model, as `StackedTitle` does.
private struct QueueTitle: View {
    var pr: PullRequest
    var model: AppModel
    /// True when GitHub has this PR down as waiting on you, as opposed to you having gone looking for it.
    var onMe: Bool

    var body: some View {
        HStack(spacing: 6) {
            if onMe { Chip(text: "on you", color: .orange) }
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
                Text("starting").scaled(.caption2).foregroundStyle(.secondary)
            } else if model.state.localRepo(for: pr) == nil {
                Chip(text: "no local clone", color: .secondary)
                    .help("Clone \(pr.repo) under a repo root to review it here")
            } else {
                if let need {
                    Chip(text: need.title, color: need == .failed ? .red : .orange)
                        .help(model.state.review(for: pr)?.error ?? need.detail)
                }
                if let record = model.state.review(for: pr), need != .failed {
                    ReviewStatusChip(record: record, status: model.state.reviewStatus(for: record, pr: pr))
                    if record.costUSD > 0 {
                        Text(Format.usd(record.costUSD)).scaled(.caption2).monospacedDigit().foregroundStyle(.tertiary)
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
                    .disabled(!model.canReview(pr))
                    .help(startHelp)
            } else if let record, record.draft != nil {
                Button("Open on GitHub") { model.openDraft(record) }
                    .controlSize(.small)
                    .help("Your draft review, in the PR's Files tab: edit or drop comments, then pick the verdict and submit")
            }
            if let record {
                Menu {
                    if record.draft != nil { Button("Open draft on GitHub") { model.openDraft(record) } }
                    Button("Review again") { model.review(pr) }.disabled(!model.canReview(pr))
                    Button("Reveal worktree") { model.reveal(record.worktreePath) }
                    Button("Remove review", role: .destructive) { model.removeReview(record) }.disabled(record.phase.isBusy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Review again adds only what the draft does not already have. Remove forgets the review here and deletes its worktree; the draft on GitHub stays.")
            }
        }
    }

    private var startHelp: String {
        if model.state.localRepo(for: pr) == nil { return "No local clone of \(pr.repo) to review in" }
        if !model.canStartReview { return "Already running \(model.busyReviews.count) reviews; wait for one to finish" }
        return "Run Claude on this PR and put its comments in your draft review on GitHub"
    }
}
