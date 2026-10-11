import DeskCore
import SwiftUI

/// The PRs waiting on your review, and the press that has Claude review one. What it finds goes into your
/// draft review on GitHub; this screen follows that draft and opens it, and nothing more.
struct ReviewsTab: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder: [KeyPathComparator<PullRequest>] = []
    @AppStorage("sort.reviewQueue") private var storedSort = ""
    // The filters are remembered, not view state: the screen is rebuilt every time you come back to it,
    // and a filter that quietly resets shows a different queue than the one you left.
    @AppStorage("reviews.scope") private var scope: ReviewScope = .all
    /// Off by default, so the whole queue shows; on, only the PRs opened in the last `days` days.
    @AppStorage("reviews.limited") private var limited = false
    @AppStorage("reviews.days") private var days = 14
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

    /// The day limit in force, or nil for all time. A typed 0 or less reads as one day.
    private var window: Int? { limited ? max(days, 1) : nil }
    private func queue(_ scope: ReviewScope) -> [PullRequest] { model.state.reviewQueue(scope, days: window) }
    private var rows: [PullRequest] { queue(scope).sorted(using: sortOrder) }
    /// The ones GitHub actually put on you, so a row in the mixed list says which it is.
    private var onMe: Set<String> { Set(model.state.reviewRequests.map(\.url)) }

    var body: some View {
        let rows = self.rows
        let onMe = self.onMe
        Screen {
            PageHeader(title: "Reviews") { HeaderControls() }
            header
        } content: {
            GroupHeader(title: "Review queue", count: rows.count)
            if rows.isEmpty {
                EmptyText(text: model.state.errors[.github] ?? emptyText).padding(.vertical, 20)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { pr in
                            // A double-click opens the review on GitHub, in the Files tab where a draft is finished.
                            ListRow(selected: selection == pr.url, select: { selection = pr.url }, open: { model.openDraft(pr) }) {
                                QueueRow(pr: pr, model: model, onMe: onMe.contains(pr.url))
                            }
                        }
                    }
                }
                .onChange(of: selection, initial: true) { _, url in
                    if let url { withAnimation { proxy.scrollTo(url, anchor: .center) } }
                }
            }
        }
        .remembersSort(Self.sort, order: $sortOrder, stored: $storedSort)
        // Search lands here with a PR to select. One the filters hide is shown by widening them to the whole
        // queue: a find that opens a screen without its PR on it would be no find at all.
        .onChange(of: model.selectPullRequest, initial: true) { _, url in
            guard let url else { return }
            if !self.rows.contains(where: { $0.url == url }) {
                scope = .all
                limited = false
            }
            selection = url
            model.selectPullRequest = nil
        }
    }

    private var emptyText: String {
        guard let window else {
            switch scope {
            case .onMe: return "Nothing waits on your review."
            case .open: return "No open PRs left unreviewed in the tracked repos."
            case .all: return "Nothing to review."
            }
        }
        let span = window == 1 ? "the last day" : "the last \(window) days"
        switch scope {
        case .onMe: return "Nothing from \(span) waits on you."
        case .open: return "No unreviewed PRs opened in \(span)."
        case .all: return "Nothing opened in \(span)."
        }
    }

    /// The answer to "what should I press Review on?", which is the only thing that starts a review.
    /// Counted over the rows on screen, like the scope counts beside it: a number that outlived the
    /// filters would point at rows the table is not showing.
    private var header: some View {
        let ready = rows.count { model.state.reviewNeed(for: $0) != nil }
        return FilterBar {
            PillTabs(
                options: ReviewScope.allCases.map { .init(value: $0, title: $0.title, count: queue($0).count) },
                selection: $scope
            )
            if ready > 0 {
                Chip(text: "\(ready) ready to run", color: .orange)
                    .help("Of the rows shown. Press Review on one to run it; nothing runs on its own.")
            }
        } trailing: {
            if !model.canStartReview {
                Text("\(model.busyReviews.count) running").scaled(.caption).foregroundStyle(.secondary)
            }
            DaysFilter(limited: $limited, days: $days)
            SortMenu(sort: Self.sort, order: $sortOrder)
        }
    }
}

/// How far back the queue reaches, drawn like the sort menu beside it: every PR, or only the ones opened in the
/// last few days. The common spans are one pick; Other… takes any number of days.
private struct DaysFilter: View {
    @Binding var limited: Bool
    @Binding var days: Int
    @State private var choosing = false

    private static let spans = [1, 3, 7, 14, 30]

    var body: some View {
        Menu {
            Toggle("All time", isOn: Binding(get: { !limited }, set: { if $0 { limited = false } }))
            Divider()
            ForEach(Self.spans, id: \.self) { span in
                Toggle(Self.title(span), isOn: Binding(get: { limited && days == span }, set: { if $0 { days = span; limited = true } }))
            }
            Divider()
            Toggle("Other…", isOn: Binding(get: { limited && !Self.spans.contains(days) }, set: { _ in choosing = true }))
        } label: {
            MenuBox(title: "Opened", value: limited ? Self.title(max(days, 1)) : "All time")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show every pull request, or only the ones opened in the last few days")
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                Text("Last")
                TextField("Days", value: $days, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Stepper("Days", value: $days, in: 1...365).labelsHidden()
                Text(days == 1 ? "day" : "days").foregroundStyle(.secondary)
            }
            .padding(12)
            .onAppear { limited = true }
        }
    }

    private static func title(_ days: Int) -> String { days == 1 ? "Last day" : "Last \(days) days" }
}

/// One PR in the queue: the author's picture, where the review stands and the title, a monospaced line with
/// number, repo, author, branches, size and checks, the presses on the right, and how long it has waited.
private struct QueueRow: View {
    var pr: PullRequest
    var model: AppModel
    var onMe: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Avatar(login: pr.author)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    QueueTitle(pr: pr, model: model, onMe: onMe)
                }
                HStack(spacing: 8) {
                    MetaLine(parts: [
                        Text(verbatim: "#\(pr.number)"), Text(pr.repoName), Text(pr.author), Text("\(pr.baseRef) ← \(pr.headRef)"),
                        Text("\(Format.sizeBucket(pr.size)) ") + Text("+\(pr.additions)").foregroundStyle(.green)
                            + Text(" −\(pr.deletions)").foregroundStyle(.red),
                    ])
                    ChecksBadge(pr: pr)
                }
                QueueReviewCell(pr: pr, model: model)
            }
            Spacer(minLength: 8)
            QueueActions(pr: pr, model: model)
            Text(Format.age(pr.createdAt)).monospacedDigit().foregroundStyle(.secondary).help("Waiting since it was opened")
        }
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
            Button { model.open(pr.url) } label: { Text(pr.title).lineLimit(1) }
                .buttonStyle(.plain)
                .help("Open #\(pr.number) on GitHub" as String)
        }
    }
}

private struct QueueReviewCell: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        let need = model.state.reviewNeed(for: pr)
        HStack(spacing: 6) {
            if model.busyReviews.contains(pr.url), model.state.reviewRun(for: pr) == nil {
                ProgressView().controlSize(.mini)
                Text("starting").scaled(.caption2).foregroundStyle(.secondary)
            } else if model.state.localRepo(for: pr) == nil {
                Chip(text: "no local clone", color: .secondary)
                    .help("Clone \(pr.repo) under a repo root to review it here")
            } else {
                if let need {
                    Chip(text: need.title, color: need == .failed ? .red : .orange)
                        .help(model.state.reviewRun(for: pr)?.error ?? need.detail)
                }
                if need != .failed {
                    ReviewStatusChip(status: model.state.reviewStatus(for: pr))
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
        let need = model.state.reviewNeed(for: pr)
        let reviewed = model.state.reviewStatus(for: pr).draft != nil
        HStack(spacing: 4) {
            ClaudeSessionButton(pr: pr, model: model)
            if need != nil {
                Button("Review") { model.review(pr) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .disabled(!model.canReview(pr))
                    .help(startHelp)
            } else if reviewed {
                Button("Open on GitHub") { model.openDraft(pr) }
                    .controlSize(.small)
                    .help(pr.pendingReview != nil
                        ? "Your draft review, in the PR's Files tab: edit or drop comments, then pick the verdict and submit"
                        : "The PR's Files tab on GitHub")
            }
            if reviewed || model.state.reviewRun(for: pr) != nil {
                Menu {
                    Button("Open on GitHub") { model.openDraft(pr) }
                    Button("Review again") { model.review(pr) }.disabled(!model.canReview(pr))
                    Button("Reveal worktree") { model.reveal(worktreePath) }
                    Button("Remove worktree", role: .destructive) { model.removeReviewWorktree(pr) }
                        .disabled(model.state.reviewRun(for: pr)?.phase.isBusy == true)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Review again adds only what your draft does not already have. Remove worktree deletes the review checkout when it is clean; the review on GitHub stays.")
            }
        }
    }

    private var worktreePath: String {
        ReviewPlanner.worktreePath(reviewRoot: model.config.expandedReviewRoot, pr: pr)
    }

    private var startHelp: String {
        if model.state.localRepo(for: pr) == nil { return "No local clone of \(pr.repo) to review in" }
        if !model.canStartReview { return "Already running \(model.busyReviews.count) reviews; wait for one to finish" }
        return "Run Claude on this PR and put its comments in your draft review on GitHub"
    }
}
