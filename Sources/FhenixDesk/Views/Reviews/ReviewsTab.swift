import CryptoKit
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
    private var filters = ReviewFilters()
    @State private var selection: String?
    /// The PR whose page is showing in place of the list; nil shows the list.
    @State private var opened: String?
    @FocusState private var listFocused: Bool
    /// With Reduce Motion on, the list jumps to the selected row instead of sliding there.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    private var window: Int? { filters.window }
    private func queue(_ scope: ReviewScope) -> [PullRequest] { model.state.reviewQueue(scope, days: window, hiding: filters.hidden) }
    private var rows: [PullRequest] { queue(scope).sorted(using: sortOrder) }
    /// The ones GitHub actually put on you, so a row in the mixed list says which it is.
    private var onMe: Set<String> { Set(model.state.reviewRequests.map(\.url)) }

    var body: some View {
        let rows = self.rows
        let onMe = self.onMe
        Group {
            // Looked up in the whole queue, not the rows: a PR you just reviewed may leave the filtered list.
            if let url = opened, let pr = (rows + (model.state.github?.allOpen ?? [])).first(where: { $0.url == url }) {
                ReviewPage(pr: pr, model: model, onMe: onMe.contains(pr.url)) { opened = nil }
            } else {
                list(rows: rows, onMe: onMe)
            }
        }
        .remembersSort(Self.sort, order: $sortOrder, stored: $storedSort)
        .selectsFirstRow(rows.first?.url, selection: $selection)
        // Search, Up Next and a notification land here with a PR to show: its page, with its row selected behind it.
        // One the filters hide is shown by widening them to the whole queue: a find that opens a screen without its
        // PR on it would be no find at all.
        .onChange(of: model.selectPullRequest, initial: true) { _, url in
            guard let url else { return }
            if !self.rows.contains(where: { $0.url == url }) {
                scope = .all
                filters.limited = false
                if let author = model.state.github?.allOpen.first(where: { $0.url == url })?.author {
                    filters.hidden = filters.hidden.subtracting([author])
                }
            }
            selection = url
            opened = url
            model.selectPullRequest = nil
        }
    }

    @ViewBuilder private func list(rows: [PullRequest], onMe: Set<String>) -> some View {
        Screen {
            PageHeader(title: "Reviews") {}
            header
        } content: {
            GroupHeader(title: "Review queue", count: rows.count)
            if rows.isEmpty, let error = model.state.errors[.github] {
                EmptyState(
                    icon: "exclamationmark.triangle", text: "Couldn't load the review queue from GitHub.", detail: error,
                    actionTitle: "Retry", action: { Task { await model.refresh(.github) } }
                )
                .padding(.vertical, 20)
            } else if rows.isEmpty {
                // The day and author filters are what can hide what is there; each empty list offers to lift one.
                EmptyState(
                    icon: "checkmark.circle", text: emptyText,
                    actionTitle: filters.limited ? "Show all time" : filters.hidden.isEmpty ? nil : "Show everyone",
                    action: { if filters.limited { filters.limited = false } else { filters.hidden = [] } }
                )
                .padding(.vertical, 20)
            } else {
                StaleBanner(source: .github)
            }
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(rows, id: \.url) { pr in
                        ListRow(selected: selection == pr.url, open: { open(pr.url) }) {
                            QueueRow(pr: pr, model: model, onMe: onMe.contains(pr.url))
                        }
                    }
                }
                .deskList()
                // Focused on arrival and on the way back from a page, so the keys work without a click first.
                .focused($listFocused)
                .onAppear { listFocused = true }
                .onKeyPress(.rightArrow) {
                    guard let selection else { return .ignored }
                    open(selection)
                    return .handled
                }
                // A click, Return or → opens the PR's page; GitHub is a press on the page or in this menu.
                .contextMenu(forSelectionType: String.self) { urls in
                    if let pr = rows.first(where: { urls.contains($0.url) }) {
                        PullRequestMenu(pr: pr, model: model)
                        Divider()
                        Button(model.state.reviewStatus(for: pr).draft == nil ? "Review" : "Review Again") { model.review(pr) }
                            .disabled(!model.canReview(pr))
                        Button("Reveal Worktree") {
                            model.reveal(ReviewPlanner.worktreePath(reviewRoot: model.config.expandedReviewRoot, pr: pr))
                        }
                    }
                } primaryAction: { urls in
                    if let url = urls.first { open(url) }
                }
                .onChange(of: selection, initial: true) { _, url in
                    if let url { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(url, anchor: .center) } }
                }
            }
        }
    }

    /// Its page, with its row selected behind it for the way back.
    private func open(_ url: String) {
        selection = url
        opened = url
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
            // Only when it says something the row count beside the scopes does not.
            if ready > 0, ready != rows.count {
                Chip(text: "\(ready) need review", color: .orange)
                    .help("Of the rows shown. Press Review on one to run it; nothing runs on its own.")
            }
        } trailing: {
            if !model.canStartReview {
                Text("\(model.busyReviews.count) running").scaled(.caption).foregroundStyle(.secondary)
            }
            AuthorsFilter(queue: model.state.reviewQueue(.all, days: window), filters: filters)
            DaysFilter(limited: filters.$limited, days: filters.$days)
            SortMenu(sort: Self.sort, order: $sortOrder)
        }
    }
}

/// The Reviews screen's filters: how far back the queue reaches, and whose PRs it leaves out. The sidebar badge, Up
/// Next and the menu bar's menu read them too, so what they count is what the screen lists.
struct ReviewFilters: DynamicProperty {
    /// Off by default, so the whole queue shows; on, only the PRs opened in the last `days` days.
    @AppStorage("reviews.limited") var limited = false
    @AppStorage("reviews.days") var days = 14
    /// The authors filtered out, one login per line.
    @AppStorage("reviews.hiddenAuthors") var hiddenText = ""

    /// The day limit in force, or nil for all time. A typed 0 or less reads as one day.
    var window: Int? { limited ? max(days, 1) : nil }

    var hidden: Set<String> {
        get { Self.authors(hiddenText) }
        nonmutating set { hiddenText = newValue.sorted().joined(separator: "\n") }
    }

    /// The same two, read where no view is, as the menu bar's menu is.
    static var currentWindow: Int? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "reviews.limited") else { return nil }
        return max(defaults.object(forKey: "reviews.days") as? Int ?? 14, 1)
    }

    static var currentHidden: Set<String> { authors(UserDefaults.standard.string(forKey: "reviews.hiddenAuthors") ?? "") }

    private static func authors(_ text: String) -> Set<String> { Set(text.split(separator: "\n").map(String.init)) }
}

/// Whose PRs the queue shows: every author in it, ticked while shown; unticking one filters their PRs out here and on
/// Up Next. One already hidden stays listed, so it can be brought back while it has nothing open.
private struct AuthorsFilter: View {
    var queue: [PullRequest]
    var filters: ReviewFilters

    var body: some View {
        let hidden = filters.hidden
        let counts = Dictionary(grouping: queue, by: \.author).mapValues(\.count)
        let authors = Set(counts.keys).union(hidden).sorted { $0.lowercased() < $1.lowercased() }
        Menu {
            if !hidden.isEmpty {
                Button("Show everyone") { filters.hidden = [] }
                Divider()
            }
            ForEach(authors, id: \.self) { author in
                Toggle(
                    counts[author].map { "\(author)  \($0)" } ?? author,
                    isOn: Binding(
                        get: { !hidden.contains(author) },
                        set: { shown in filters.hidden = shown ? hidden.subtracting([author]) : hidden.union([author]) }
                    )
                )
            }
        } label: {
            MenuBox(title: "Authors", value: hidden.isEmpty ? "Everyone" : "\(hidden.count) hidden")
        }
        .menuStyle(.button).handCursor()
        .buttonStyle(.plain).handCursor()
        .menuIndicator(.hidden)
        .fixedSize()
        .help(hidden.isEmpty ? "Filter out the PRs of authors you do not review" : "Hiding: " + hidden.sorted().joined(separator: ", "))
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
        .menuStyle(.button).handCursor()
        .buttonStyle(.plain).handCursor()
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
struct QueueRow: View {
    var pr: PullRequest
    var model: AppModel
    var onMe: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Avatar(login: pr.author)
            // Two lines: what it is, then the facts. Where its review stands is on the right, where it lines up row to
            // row and a glance down the list reads it.
            VStack(alignment: .leading, spacing: 5) {
                QueueTitle(pr: pr, model: model, onMe: onMe)
                HStack(spacing: 8) {
                    MetaLine(parts: [
                        Text(verbatim: "#\(pr.number)"), Text(pr.repoName), Text(pr.author), Text("\(pr.baseRef) ← \(pr.headRef)"),
                        Text("\(Format.sizeBucket(pr.size)) ") + Text("+\(pr.additions)").foregroundStyle(.green)
                            + Text(" −\(pr.deletions)").foregroundStyle(.red),
                    ])
                    ChecksBadge(pr: pr)
                }
            }
            Spacer(minLength: 8)
            QueueActions(pr: pr, model: model)
            // Against an age of fixed width, so the state's right edge is the same on every row.
            QueueReviewCell(pr: pr, model: model).fixedSize()
            Text(Format.age(pr.createdAt)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
                .help("Waiting since it was opened, \(Format.date(pr.createdAt))")
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
            if onMe { Chip(text: "On you", color: .orange) }
            // Plain text, so a click on it selects the row; Return or a double-click opens the review on GitHub.
            Text(pr.title).scaled(.rowTitle).lineLimit(1)
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
                Chip(text: "Starting", color: .teal, spinning: true)
            } else if model.state.localRepo(for: pr) == nil {
                Chip(text: "No local clone", color: .secondary)
                    .help("Clone \(pr.repo) under a repo root to review it here")
            } else {
                // A readiness chip only for the exceptions, "Review again" and "Run failed": the Review button
                // already marks the plain "needs review" rows.
                if need == .failed {
                    Chip(text: ReviewNeed.failed.title, color: .red)
                        .help(model.state.reviewRun(for: pr)?.error ?? ReviewNeed.failed.detail)
                } else {
                    if need == .reRequested {
                        Chip(text: ReviewNeed.reRequested.title, color: .orange).help(ReviewNeed.reRequested.detail)
                    }
                    // Without its own "Re-requested" chip when "Review again" already says so.
                    let status = model.state.reviewStatus(for: pr)
                    ReviewStatusChip(status: need == .reRequested ? { var s = status; s.reRequested = false; return s }() : status)
                }
            }
        }
    }
}

/// The one press left on a row: your draft, once there is one. Review and the background session are in the
/// details panel, with the rest of what acts on the PR.
private struct QueueActions: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        if model.state.reviewStatus(for: pr).draft != nil {
            Button("Open on GitHub") { model.openDraft(pr) }
                .controlSize(.small)
                .help(pr.pendingReview != nil
                    ? "Your draft review, in the PR's Files tab: edit or drop comments, then pick the verdict and submit"
                    : "The PR's Files tab on GitHub")
        }
    }
}

/// A PR in the queue on its own page, laid out as a PR page is: what it is and its status line — checks, whether it is
/// on you, where your draft stands — with Review and the session on the right; the description in the wide column;
/// the details and the checks beside it.
struct ReviewPage: View {
    var pr: PullRequest
    var model: AppModel
    var onMe: Bool
    /// The screen it was opened from, which its back link names and returns to.
    var back = "Reviews"
    var onBack: () -> Void

    var body: some View {
        let status = model.state.reviewStatus(for: pr)
        let ran = status.draft != nil || model.state.reviewRun(for: pr) != nil
        let error = model.state.reviewRun(for: pr)?.error
        DetailPage(back: back, onBack: onBack) {
            // Someone else's PR: its title is theirs to change. GitHub opens on the Files tab, where your draft is.
            PageHeadline(pr: pr, model: model, gitHub: "\(pr.url)/files", editable: false)
            HStack(spacing: 8) {
                ChecksPill(pr: pr)
                // Each only when it says something: GitHub asked you, and your draft's state, which is blank without one.
                if onMe { Chip(text: "On you", color: .orange) }
                // The run's progress is on the Review button, so the chip keeps to what GitHub says.
                ReviewStatusChip(status: status, showsRun: false)
                // The page's actions on the right, where a status line's presses go; why Review is dead, beside it.
                Spacer(minLength: 8)
                if let progress = reviewProgress {
                    Button {} label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(progress)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    // At full strength, as a running state, not greyed out as a dead button; a press does nothing.
                    .allowsHitTesting(false)
                } else {
                    DisabledReason(text: model.reviewBlocker(pr))
                    Button(ran ? "Review again" : "Review") { model.review(pr) }
                        .buttonStyle(.borderedProminent).handCursor()
                        .disabled(!model.canReview(pr))
                        .help(
                            (ran ? "Adds only what your draft does not already have" : "Run Claude on this PR and put its comments in your draft review")
                                + ", then hands them to the PR's session to talk through"
                        )
                }
                ClaudeSessionButton(pr: pr, model: model, prominent: true).fixedSize()
            }
            if model.reviewHandoffs[pr.url] != nil {
                if let failed = model.handoffErrors[pr.url] {
                    HStack(spacing: 8) {
                        Text(failed).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
                        Button("Try again") { model.retryHandoff(pr) }.controlSize(.small)
                    }
                } else {
                    Text("The review goes to the session once it is idle.").scaled(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.sessionErrors[pr.url] {
                Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        } main: {
            // What the review found, first: the draft is the page's reason to be open.
            if pr.pendingReview != nil { DraftReviewCard(pr: pr, model: model) }
            PanelSection("Description") { PullRequestDescription(pr: pr) }
        } side: {
            DetailsCard(pr: pr)
            WorkflowsSection(pr: pr, model: model)
            // The review's own leftovers: why the last run failed, and the checkout it ran in.
            if ran || error != nil {
                SideCard(title: "Review worktree") {
                    if let error {
                        Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if ran {
                        HStack {
                            Button("Reveal worktree") { model.reveal(worktreePath) }
                            Button("Remove worktree", role: .destructive) { model.removeReviewWorktree(pr) }
                                .disabled(model.state.reviewRun(for: pr)?.phase.isBusy == true)
                                .help("Deletes the review checkout when it is clean; the review on GitHub stays")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var worktreePath: String {
        ReviewPlanner.worktreePath(reviewRoot: model.config.expandedReviewRoot, pr: pr)
    }

    /// Where a running review is, in the words its button shows while it runs; nil when none is.
    private var reviewProgress: String? {
        let phase = model.state.reviewRun(for: pr)?.phase
        switch phase {
        case .preparing?: return "Starting"
        case .running?: return "Reviewing"
        case .posting?: return "Posting draft"
        default: return model.busyReviews.contains(pr.url) ? (phase == nil ? "Starting" : "Reviewing") : nil
        }
    }
}

/// Your draft review on the page: what the last run said overall, then each comment, most severe first — its severity,
/// the line it sits on, which opens there in GitHub's Files tab, and what it says, three lines of it until opened. Read
/// from GitHub, so it is there after a restart too, and read again whenever the draft changes.
private struct DraftReviewCard: View {
    var pr: PullRequest
    var model: AppModel
    @State private var loaded: (key: String, comments: [DraftReviewComment])?
    @State private var error: String?

    var body: some View {
        // The draft's id and size: a run that adds comments, or an edit on GitHub that drops some, reloads it.
        let key = "\(pr.url) \(pr.pendingReview?.id ?? "") \(pr.pendingReview?.comments ?? 0)"
        let summary = model.state.reviewRun(for: pr)?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Your draft review").scaled(.callout.weight(.medium)).foregroundStyle(.secondary)
                if let loaded, loaded.key == key {
                    Text("\(loaded.comments.count)").scaled(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open on GitHub") { model.openDraft(pr) }
                    .controlSize(.small)
                    .help("Your draft in the PR's Files tab: edit or drop comments, then pick the verdict and submit. Only you can see it.")
            }
            if !summary.isEmpty { MarkdownText(text: summary) }
            if let loaded, loaded.key == key {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(loaded.comments) { comment in
                        row(comment)
                        if comment.id != loaded.comments.last?.id { Hairline() }
                    }
                }
                .padding(.horizontal, Theme.Space.m)
                .background(Theme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else if let error {
                Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: key) {
            error = nil
            do {
                loaded = (key, try await model.draftComments(for: pr))
            } catch {
                if !Task.isCancelled { self.error = "Couldn't load your draft: \(error)" }
            }
        }
    }

    private func row(_ comment: DraftReviewComment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            severityChip(comment).frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Button { model.open(fileLink(comment)) } label: {
                    Text(verbatim: comment.line.map { "\(comment.path):\($0)" } ?? comment.path).scaled(.caption.monospaced())
                }
                .buttonStyle(.link).handCursor()
                .help("Open this line in the PR's Files tab")
                DraftCommentText(text: comment.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Space.s + 2)
    }

    @ViewBuilder private func severityChip(_ comment: DraftReviewComment) -> some View {
        if let severity = comment.severity {
            let color: Color = switch severity {
            case .important: .red
            case .nit: .yellow
            case .preExisting: .secondary
            case .question: .blue
            }
            Chip(text: severity.title, color: color)
        } else {
            Chip(text: comment.isClaude ? "Comment" : "Yours", color: .secondary)
        }
    }

    /// The comment's line in the Files tab: GitHub anchors a file's diff by the SHA-256 of its path, and a line on the
    /// new side by R and its number.
    private func fileLink(_ comment: DraftReviewComment) -> String {
        let hash = SHA256.hash(data: Data(comment.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(pr.url)/files#diff-\(hash)" + (comment.line.map { "R\($0)" } ?? "")
    }
}

/// A draft comment's words: three lines of its first paragraph, and More when there is more — a cut line, or a
/// suggestion block below — which opens the whole of it, markdown and all. Whether the lines are cut is measured, so
/// More shows only where something is hidden.
private struct DraftCommentText: View {
    var text: String
    @State private var open = false
    @State private var clamped: CGFloat = 0
    @State private var full: CGFloat = 0

    var body: some View {
        let first = Markdown.inline(String(text.split(separator: "\n", maxSplits: 1).first ?? ""))
        let more = text.contains("\n") || full > clamped + 1
        VStack(alignment: .leading, spacing: 4) {
            if open {
                MarkdownText(text: text).textSelection(.enabled)
            } else {
                Text(first)
                    .lineLimit(3)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { clamped = $0 }
                    // The same words uncut, unseen, at the same width: taller means the three lines hide some.
                    .background(alignment: .topLeading) {
                        Text(first)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full = $0 }
                    }
            }
            if more || open {
                Button(open ? "Less" : "More") { open.toggle() }
                    .buttonStyle(.link).handCursor().scaled(.caption)
            }
        }
    }
}
