import DeskCore
import SwiftUI

/// The PRs waiting on your review. You read and review each one yourself on GitHub — its description, the /pre-pr
/// evidence, CodeRabbit's walkthrough, the diff; this screen finds them and says where your review stands.
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
    private func queue(_ scope: ReviewScope, needingApproval: Bool? = nil) -> [PullRequest] {
        model.state.reviewQueue(scope, days: window, hiding: filters.hidden, needingApproval: needingApproval ?? filters.needsApproval)
    }
    /// Your column sort, inside "needs a person" first: those are the reviews nobody else can do.
    private var rows: [PullRequest] { queue(scope).sorted(using: sortOrder).needsHumanFirst }
    /// The ones GitHub actually put on you, so a row in the mixed list says which it is.
    private var onMe: Set<String> { Set(model.state.reviewRequests.map(\.url)) }

    var body: some View {
        let rows = self.rows
        let onMe = self.onMe
        Group {
            // Looked up in the whole queue, not the rows: a PR you just reviewed may leave the filtered list.
            if let url = opened, let pr = (rows + (model.state.github?.allOpen ?? [])).first(where: { $0.url == url }) {
                // Start review swaps the page for the diff; back from the diff is the page again.
                if model.reviewing == url {
                    ReviewDiffScreen(pr: pr, model: model) { model.reviewing = nil }
                } else {
                    ReviewPage(pr: pr, model: model, onMe: onMe.contains(pr.url)) { opened = nil }
                }
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
                filters.needsApproval = false
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
                // The approval, day and author filters are what can hide what is there; each empty list offers to lift one.
                let approvalHides = filters.needsApproval && !queue(scope, needingApproval: false).isEmpty
                EmptyState(
                    icon: "checkmark.circle", text: approvalHides ? "Nothing here still needs an approval." : emptyText,
                    actionTitle: approvalHides ? "Show all" : filters.limited ? "Show all time" : filters.hidden.isEmpty ? nil : "Show everyone",
                    action: {
                        if approvalHides { filters.needsApproval = false } else if filters.limited { filters.limited = false } else { filters.hidden = [] }
                    }
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
            case .onMe, .needsYou: return "Nothing waits on your review."
            case .open: return "No open PRs left unreviewed in the tracked repos."
            case .reviewed: return "No open PRs you reviewed wait on their authors."
            case .all: return "No open PRs by others in the tracked repos."
            }
        }
        let span = window == 1 ? "the last day" : "the last \(window) days"
        switch scope {
        case .onMe, .needsYou: return "Nothing from \(span) waits on you."
        case .open: return "No unreviewed PRs opened in \(span)."
        case .reviewed: return "None you reviewed was opened in \(span)."
        case .all: return "Nothing opened in \(span)."
        }
    }

    /// The scopes, the approval filter and how many of the rows still wait on your review. Counted over the rows on
    /// screen, like the scope counts beside it: a number that outlived the filters would point at rows the table is not
    /// showing.
    private var header: some View {
        let ready = rows.count { model.state.reviewNeed(for: $0) != nil }
        return FilterBar {
            PillTabs(
                options: ReviewScope.offered.map { .init(value: $0, title: $0.title, count: queue($0).count) },
                selection: $scope
            )
            Divider().frame(height: 18)
            // By the review gate's status on the head commit; a repo without the gate always needs an approval.
            PillTabs(
                options: [
                    .init(value: true, title: "Needs approval", count: queue(scope, needingApproval: true).count),
                    .init(value: false, title: "All", count: queue(scope, needingApproval: false).count),
                ],
                selection: filters.$needsApproval
            )
            // Only when it says something the row count beside the scopes does not.
            if ready > 0, ready != rows.count {
                Chip(text: "\(ready) need review", color: .orange)
                    .help("Of the rows shown: the ones you have not reviewed, or were asked to review again.")
            }
        } trailing: {
            AuthorsFilter(queue: model.state.reviewQueue(.all, days: window, needingApproval: filters.needsApproval), filters: filters)
            DaysFilter(limited: filters.$limited, days: filters.$days)
            SortMenu(sort: Self.sort, order: $sortOrder)
        }
    }
}

/// The Reviews screen's filters: whether it keeps to the PRs that still need an approval, how far back the queue reaches,
/// and whose PRs it leaves out. The sidebar badge, Up Next and the menu bar's menu read them too, so what they count is
/// what the screen lists.
struct ReviewFilters: DynamicProperty {
    /// On by default: only the PRs the review gate says still need an approval, or has not decided on, and every PR of a
    /// repo without the gate. Off, the whole queue.
    @AppStorage("reviews.needsApproval") var needsApproval = true
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

    /// The same, read where no view is, as the menu bar's menu is.
    static var currentWindow: Int? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "reviews.limited") else { return nil }
        return max(defaults.object(forKey: "reviews.days") as? Int ?? 14, 1)
    }

    static var currentHidden: Set<String> { authors(UserDefaults.standard.string(forKey: "reviews.hiddenAuthors") ?? "") }

    static var currentNeedsApproval: Bool { UserDefaults.standard.object(forKey: "reviews.needsApproval") as? Bool ?? true }

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
            if pr.needsHuman { Chip(text: "Needs a person", color: .purple) }
            RiskChip(pr: pr)
            // Plain text, so a click on it selects the row; Return or a double-click opens the review on GitHub.
            Text(pr.title).scaled(.rowTitle).lineLimit(1)
        }
    }
}

/// The PR's risk tier: the review gate's, which its approvals follow, or else CodeRabbit's `risk:*` label.
private struct RiskChip: View {
    var pr: PullRequest

    var body: some View {
        if let risk = pr.approvalGate?.tier ?? pr.risk {
            Chip(text: "Risk: \(risk)", color: ["high", "critical"].contains(risk) ? .red : risk == "medium" ? .orange : .secondary)
                .fixedSize()
                .help(pr.approvalStatus ?? "CodeRabbit's risk label")
        }
    }
}

private struct QueueReviewCell: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        let need = model.state.reviewNeed(for: pr)
        HStack(spacing: 6) {
            // A chip only for "Review again": the plain "needs review" rows are the queue itself.
            if need == .reRequested {
                Chip(text: ReviewNeed.reRequested.title, color: .orange).help(ReviewNeed.reRequested.detail)
            }
            // Without its own "Re-requested" chip when "Review again" already says so.
            let status = model.state.reviewStatus(for: pr)
            ReviewStatusChip(status: need == .reRequested ? { var s = status; s.reRequested = false; return s }() : status)
        }
    }
}

/// The one press on a row: your review on GitHub, once you have started one. The background session is on the PR's
/// page, with the rest of what acts on the PR.
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
/// on you, the risk, where your review stands — with Review on GitHub and the session on the right; the description in
/// the wide column; the details and the checks beside it. The review itself is yours: read the description, the /pre-pr
/// evidence and CodeRabbit's walkthrough, then the diff, and write it on GitHub. Under the description, the PR's
/// conversation, to reply in, resolve and comment on.
struct ReviewPage: View {
    var pr: PullRequest
    var model: AppModel
    var onMe: Bool
    /// The screen it was opened from, which its back link names and returns to.
    var back = "Reviews"
    var onBack: () -> Void

    var body: some View {
        DetailPage(back: back, onBack: onBack) {
            // Someone else's PR: its title is theirs to change.
            PageHeadline(pr: pr, model: model, gitHub: pr.url, editable: false)
            HStack(spacing: 8) {
                ChecksPill(pr: pr)
                // Each only when it says something: GitHub asked you, and your review's state, which is blank without one.
                if onMe { Chip(text: "On you", color: .orange) }
                RiskChip(pr: pr)
                if pr.needsHuman { Chip(text: "Needs a person", color: .purple) }
                ReviewStatusChip(status: model.state.reviewStatus(for: pr))
                Spacer(minLength: 8)
                Button(model.reviewRunning(pr) ? "Open review" : "Start review") { model.startReview(pr) }
                    .buttonStyle(.borderedProminent).handCursor()
                    .help("The diff here and a Claude review session beside it: it summarizes the PR, gives its take on each question, and posts the comments and the verdict you decide on")
                Button("Review on GitHub") { model.openDraft(pr) }
                    .handCursor()
                    .help("The PR's Files tab, where you comment, pick the verdict and submit")
                ClaudeSessionButton(pr: pr, model: model).fixedSize()
            }
            if let error = model.sessionErrors[pr.url] {
                Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        } main: {
            PanelSection("Description") { PullRequestDescription(pr: pr) }
            ConversationSection(pr: pr, model: model)
        } side: {
            LabelsCard(pr: pr)
            DetailsCard(pr: pr)
            WorkflowsSection(pr: pr, model: model)
        }
    }
}
