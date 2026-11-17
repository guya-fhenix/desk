import DeskCore
import SwiftUI

/// The PRs waiting on your review, a ticket's PRs and a stack's together under who wrote them, each with its tick for
/// Review together; beside them, the selected row's group in full and the press that starts its review session. You
/// read and review each one yourself — its description, the /pre-pr evidence, CodeRabbit's walkthrough, the diff — and
/// submit on GitHub; this screen finds them and says where your review stands.
struct ReviewsTab: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder: [KeyPathComparator<PullRequest>] = []
    @AppStorage("sort.reviewQueue") private var storedSort = ""
    // The filters are remembered, not view state: the screen is rebuilt every time you come back to it,
    // and a filter that quietly resets shows a different queue than the one you left.
    @AppStorage("reviews.scope") private var scope: ReviewScope = .needsYou
    private var filters = ReviewFilters()
    @State private var selection: String?
    /// The PRs ticked to review together, by url: any rows, from any repos and authors.
    @State private var picked: Set<String> = []
    /// Review together's sheet, while it asks for notes.
    @State private var request: ReviewRequest?
    /// The pages open over the list; empty shows the list.
    @State private var path: [Route] = []
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
        let groups = Self.groups(rows, model: model)
        RouteStack(path: $path, back: "Reviews") {
            list(rows: rows, groups: groups)
        }
        .focusedSceneValue(\.routePath, $path)
        .remembersSort(Self.sort, order: $sortOrder, stored: $storedSort)
        // The first row on screen: a group's base comes before the row the sort put first.
        .selectsFirstRow(groups.first?.pullRequests.first?.url, selection: $selection)
        .reviewTogetherSheet($request, model: model)
        // Search, Up Next and a notification land here with a PR to show: its page, with its row selected behind it.
        // One the filters hide is shown by widening them to the whole queue: a find that opens a screen without its
        // PR on it would be no find at all. Yours are left to Pull Requests, the way it leaves these to this screen.
        .onChange(of: model.selectPullRequest, initial: true) { _, url in
            guard let url, model.yourPullRequest(url) == nil else { return }
            if !self.rows.contains(where: { $0.url == url }) {
                scope = .all
                filters.needsApproval = false
                filters.limited = false
                if let author = model.state.github?.allOpen.first(where: { $0.url == url })?.author {
                    filters.hidden = filters.hidden.subtracting([author])
                }
            }
            selection = url
            path = [.pr(url)]
            model.selectPullRequest = nil
        }
        #if DEBUG
        .task(id: rows.count) { snapshotPick(groups) }
        #endif
    }

    private func list(rows: [PullRequest], groups: [QueueGroup]) -> some View {
        let onMe = self.onMe
        let chosen = rows.filter { picked.contains($0.url) }
        let picking = model.state.reviewSkills.values.contains { $0.groupReview }
        let current = groups.first { $0.pullRequests.contains { $0.url == selection } }
        return HStack(spacing: 0) {
            Screen {
                header(rows: rows)
            } content: {
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
                    // Arrows or J and K move the selection, which the details column shows; a double-click, Return or →
                    // opens the PR's page.
                    List(selection: $selection) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            let on = group.id == current?.id
                            // A PR alone by the same author in the same repo as the one alone before it goes under that
                            // one's line, so an author's PRs read as theirs.
                            let headed = index == 0 || !Self.sameLine(group, groups[index - 1])
                            if headed {
                                ReviewGroupHeader(group: group, picked: $picked, picking: picking, on: on)
                                    .padding(.top, index == 0 ? 0 : 14)
                                    .plainListRow(background: Theme.ground)
                                    .selectionDisabled()
                            }
                            let depths = Linker.depths(group.pullRequests, parents: model.state.stackParents)
                            ForEach(group.pullRequests, id: \.url) { pr in
                                ReviewQueueRow(
                                    pr: pr, depth: depths[pr.url] ?? 0, model: model, onMe: onMe.contains(pr.url), picked: $picked,
                                    picking: picking, on: on,
                                    // Inside a group, the row the keys are on; one PR alone is its group's tint.
                                    current: on && group.pullRequests.count > 1 && selection == pr.url,
                                    part: !headed ? .whole : pr.url == group.pullRequests.last?.url ? .bottom : .middle
                                )
                                .tag(pr.url)
                            }
                        }
                    }
                    .deskList()
                    // Focused on arrival and on the way back from a page, so the keys work without a click first.
                    .focused($listFocused)
                    .task(id: path.isEmpty) { if path.isEmpty { listFocused = true } }
                    .onKeyPress(.rightArrow) {
                        guard let selection else { return .ignored }
                        open(selection)
                        return .handled
                    }
                    // J and K move, X picks the selected row, R reviews: the picks together, or else the selected row's group.
                    .onKeyPress(characters: CharacterSet(charactersIn: "jkxr")) { press in
                        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
                        switch press.characters {
                        case "j", "k": move(press.characters == "j" ? 1 : -1, in: groups)
                        case "x":
                            guard picking, let selection else { return .ignored }
                            picked.formSymmetricDifference([selection])
                        default: review(chosen, current)
                        }
                        return .handled
                    }
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
                VStack(alignment: .leading, spacing: 12) {
                    if !chosen.isEmpty { pickedBar(chosen) }
                    KeyHints(hints: [(["J", "K"], "move")] + (picking ? [(["X"], "pick")] : []) + [
                        (["↩"], "open"), (["R"], chosen.isEmpty ? "start review" : "review together"),
                    ])
                }
                .padding(.top, 12)
            }
            ReviewQueueDetails(group: current, selection: selection, model: model, onMe: onMe, anyPicked: !chosen.isEmpty) { url in
                selection = url
            } start: { startReview($0, at: $1) }
        }
    }

    /// Two PRs alone, one after the other, by the same author in the same repo: the second shares the first's line.
    private static func sameLine(_ group: QueueGroup, _ before: QueueGroup) -> Bool {
        group.pullRequests.count == 1 && before.pullRequests.count == 1 && group.authors == before.authors && group.repos == before.repos
    }

    /// Its page, with its row selected behind it for the way back.
    private func open(_ url: String) {
        selection = url
        path.append(.pr(url))
    }

    /// J and K: the selection a row on, through the groups in the order they show.
    private func move(_ step: Int, in groups: [QueueGroup]) {
        let urls = groups.flatMap(\.pullRequests).map(\.url)
        guard !urls.isEmpty else { return }
        let at = selection.flatMap(urls.firstIndex(of:)) ?? (step > 0 ? -1 : urls.count)
        selection = urls[min(max(at + step, 0), urls.count - 1)]
    }

    /// R: Review together on the picks, or with none, Start review on the selected row's group.
    private func review(_ chosen: [PullRequest], _ group: QueueGroup?) {
        if !chosen.isEmpty {
            request = ReviewRequest(pullRequests: chosen)
            picked = []
        } else if let group, let pr = group.pullRequests.first(where: { $0.url == selection }) {
            startReview(group, at: pr)
        }
    }

    /// Start review from the details column: its session's pane when it runs; where reviews take a group, the sheet
    /// that asks for notes, with the group's PRs; else a review of this PR alone, with its diff.
    private func startReview(_ group: QueueGroup, at pr: PullRequest) {
        if model.reviewRunning(pr) {
            model.showReview(pr)
        } else if model.canReviewTogether(pr) {
            request = ReviewRequest(pullRequests: group.pullRequests)
        } else {
            model.startReview(pr)
            open(pr.url)
        }
    }

    /// What is picked, and the press that reviews it together: pinned under the list.
    private func pickedBar(_ chosen: [PullRequest]) -> some View {
        let repos = Set(chosen.map(\.repo)).count
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.square").foregroundStyle(Theme.accentInk).accessibilityHidden(true)
                Text("\(chosen.count) picked").fontWeight(.semibold)
                Text("· from \(repos) repo\(repos == 1 ? "" : "s")").foregroundStyle(Theme.quiet)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Clear") { picked = [] }.buttonStyle(.desk)
            Button {
                request = ReviewRequest(pullRequests: chosen)
                picked = []
            } label: {
                HStack(spacing: 8) { Text("Review together"); ButtonKey(key: "R") }
            }
            .buttonStyle(.deskPrimary)
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 12))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.ruleStrong))
    }

    /// The queue in its sort, with a ticket's PRs and a stack's together, under the first of them the sort reaches.
    static func groups(_ rows: [PullRequest], model: AppModel) -> [QueueGroup] {
        let matcher = TicketKeyMatcher(projectKeys: model.config.jiraProjectKeys)
        let keys = Dictionary(rows.map { ($0.url, TicketSync.keys(for: $0, matcher: matcher)) }, uniquingKeysWith: { first, _ in first })
        let tasks = Linker.tasks(
            mine: rows, allOpen: model.state.github?.allOpen ?? rows, merged: [], ticketKeys: keys, tickets: model.state.tickets, sessions: []
        )
        let place = Dictionary(rows.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { first, _ in first })
        return tasks
            .map { QueueGroup(task: $0) }
            .sorted { ($0.pullRequests.compactMap { place[$0.url] }.min() ?? 0) < ($1.pullRequests.compactMap { place[$0.url] }.min() ?? 0) }
    }

    private var emptyText: String {
        guard let window else {
            switch scope {
            case .onMe, .needsYou: return "Nothing waits on your review."
            case .reviewed: return "No open PRs you reviewed wait on their authors."
            case .all: return "No open PRs by others in the tracked repos."
            }
        }
        let span = window == 1 ? "the last day" : "the last \(window) days"
        switch scope {
        case .onMe, .needsYou: return "Nothing from \(span) waits on you."
        case .reviewed: return "None you reviewed was opened in \(span)."
        case .all: return "Nothing opened in \(span)."
        }
    }

    /// The title with the scopes beside it, each with its count; under them how many of the rows still wait on your
    /// review, the filters in force as tokens, and the one Filters menu and the sort. Counted over the rows on screen,
    /// like the scope counts: a number that outlived the filters would point at rows the list is not showing.
    private func header(rows: [PullRequest]) -> some View {
        let ready = rows.count { model.state.reviewNeed(for: $0) != nil }
        let active = activeFilters
        return VStack(alignment: .leading, spacing: 12) {
            ScreenTitle(title: "Reviews", subtitle: "Teammates' pull requests on GitHub") {
                Segmented(
                    options: ReviewScope.offered.map { .init(value: $0, title: $0.title, count: queue($0).count) },
                    selection: $scope
                )
            }
            HStack(spacing: Theme.Space.s) {
                // Only when it says something the row count beside the scopes does not.
                if ready > 0, ready != rows.count {
                    Chip(text: "\(ready) need review", color: .orange)
                        .help("Of the rows shown: the ones you have not reviewed, or were asked to review again.")
                }
                ForEach(active, id: \.title) { FilterToken(title: $0.title, remove: $0.remove) }
                if !active.isEmpty {
                    Text("\(rows.count) of \(model.state.reviewQueue(scope).count) shown").scaled(.secondary).foregroundStyle(Theme.quiet)
                }
                Spacer(minLength: Theme.Space.m)
                FiltersMenu(
                    queue: model.state.reviewQueue(.all, days: window, needingApproval: filters.needsApproval), filters: filters,
                    active: active.count
                )
                SortMenu(sort: Self.sort, order: $sortOrder)
            }
        }
        .padding(.bottom, 14)
    }

    /// The filters in force, each with the press that lifts it: the approval filter, the day limit, and the hidden authors
    /// as one.
    private var activeFilters: [(title: String, remove: () -> Void)] {
        var active: [(title: String, remove: () -> Void)] = []
        if filters.needsApproval { active.append(("Needs an approval", { filters.needsApproval = false })) }
        if let window { active.append((window == 1 ? "Opened in the last day" : "Opened in the last \(window) days", { filters.limited = false })) }
        let hidden = filters.hidden.sorted()
        if let first = hidden.first {
            active.append((hidden.count == 1 ? "Hiding \(first)" : "Hiding \(hidden.count) authors", { filters.hidden = [] }))
        }
        return active
    }

    #if DEBUG
    /// `FHENIX_DESK_REVIEWS_SNAPSHOT=pick|sheet`, for `--snapshot window reviews`: the first group of more than one PR —
    /// or the first two rows — picked and selected, and with `sheet`, Review together's sheet open on them.
    private func snapshotPick(_ groups: [QueueGroup]) {
        guard let mode = ProcessInfo.processInfo.environment["FHENIX_DESK_REVIEWS_SNAPSHOT"], picked.isEmpty, request == nil else { return }
        let prs = groups.first { $0.pullRequests.count > 1 }?.pullRequests ?? Array(groups.flatMap(\.pullRequests).prefix(2))
        guard let first = prs.first else { return }
        selection = first.url
        if mode == "sheet" { request = ReviewRequest(pullRequests: prs) } else { picked = Set(prs.map(\.url)) }
    }
    #endif
}

/// A group's line over its PRs: who wrote them, the repos and what holds them together — a stack, a ticket — and for
/// more than one PR, a tick that picks them all and how long the oldest has waited.
private struct ReviewGroupHeader: View {
    var group: QueueGroup
    @Binding var picked: Set<String>
    var picking: Bool
    /// The selected row's group: tinted, with an outline round it and its rows.
    var on: Bool

    var body: some View {
        let prs = group.pullRequests
        let urls = Set(prs.map(\.url))
        HStack(spacing: 8) {
            if picking, prs.count > 1 {
                Toggle("Pick all of \(group.label)", isOn: Binding(
                    get: { urls.isSubset(of: picked) }, set: { if $0 { picked.formUnion(urls) } else { picked.subtract(urls) } }
                ))
                .toggleStyle(.checkbox).labelsHidden()
                .frame(width: 20)
                .help("Pick them all to review together")
            }
            Text(group.authors).scaled(.rowTitle.weight(.semibold)).lineLimit(1)
            Text(group.what).scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1)
            Spacer(minLength: 8)
            if prs.count > 1 { AgeText(date: prs.map(\.createdAt).min()) }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .reviewBox(.top, fill: on ? Theme.tint : .clear, line: on ? Theme.tintLine : .clear)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One PR in the queue, as the board lays it out: its tick, `repo #n` in DM Mono, the title with where its review
/// stands on the right of it, the size, and how long it has waited. Carries the model, as every cell here does: a row
/// can be laid out after it has left the table and taken the environment with it.
private struct ReviewQueueRow: View {
    var pr: PullRequest
    /// Under the PRs of its group it is built on.
    var depth = 0
    var model: AppModel
    var onMe: Bool
    @Binding var picked: Set<String>
    var picking: Bool
    /// In the selected row's group.
    var on: Bool
    /// The row the selection is on, inside a group of several.
    var current: Bool
    /// Where it sits in its group's box: the last row closes it, and a row under another group's line is a box alone.
    var part: ReviewBoxPart

    var body: some View {
        HStack(spacing: 10) {
            if picking {
                Toggle("Pick \(pr.repoName) #\(pr.number)", isOn: Binding(
                    get: { picked.contains(pr.url) }, set: { if $0 { picked.insert(pr.url) } else { picked.remove(pr.url) } }
                ))
                .toggleStyle(.checkbox).labelsHidden()
                .frame(width: 20)
                .help("Pick it to review with others (X)")
            }
            StackRef(pr: pr, depth: depth, name: "\(pr.repoName) #\(pr.number)").scaled(.code).truncationMode(.head)
                .scaledFrame(width: 150, alignment: .leading)
            HStack(spacing: 6) {
                // Plain text, so a click on it selects the row; Return or a double-click opens its page.
                Text(pr.title).lineLimit(1)
                Spacer(minLength: 8)
                if onMe { Chip(text: "On you", color: .orange) }
                if pr.needsHuman { Chip(text: "Needs a person", color: .purple) }
                RiskChip(pr: pr)
                QueueReviewCell(pr: pr, model: model).fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(Format.sizeBucket(pr.size)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 5)
                    .background(on ? Theme.chipOn : Theme.chip, in: RoundedRectangle(cornerRadius: 4))
                Text("+\(pr.additions) −\(pr.deletions)")
            }
            .scaled(.code).foregroundStyle(Theme.quiet).lineLimit(1)
            .scaledFrame(width: 112, alignment: .leading)
            AgeText(date: pr.createdAt).help("Waiting since it was opened, \(Format.date(pr.createdAt))")
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(current ? Theme.chipOn : .clear, in: RoundedRectangle(cornerRadius: 6))
        .hoverFill(Theme.inset.opacity(0.7), cornerRadius: 6, enabled: !on)
        .padding(.horizontal, 4)
        .padding(.vertical, part == .whole ? 2 : 0)
        .padding(.bottom, part == .bottom ? 2 : 0)
        .contentShape(Rectangle())
        .reviewBox(part, fill: on ? Theme.tint : .clear, line: on ? Theme.tintLine : .clear)
        // One element per row for VoiceOver, its tick still reachable.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current || (on && part != .middle) ? [.isButton, .isSelected] : .isButton)
        .plainListRow(background: Theme.ground)
    }
}

/// The details column: the selected row's group — a stack, a ticket's PRs — or its one PR, what reviews it, and the
/// press that starts its review session, or shows it in iTerm once it runs.
private struct ReviewQueueDetails: View {
    var group: QueueGroup?
    var selection: String?
    var model: AppModel
    var onMe: Set<String>
    /// Something is picked: R reviews the picks then, not this.
    var anyPicked: Bool
    var select: (String) -> Void
    var start: (QueueGroup, PullRequest) -> Void

    var body: some View {
        DetailColumn(width: 360) {
            if let group, let pr = group.pullRequests.first(where: { $0.url == selection }) {
                content(group, pr)
            } else {
                Text("Select a pull request to see it here.").foregroundStyle(Theme.quiet)
            }
        }
    }

    @ViewBuilder private func content(_ group: QueueGroup, _ pr: PullRequest) -> some View {
        let prs = group.pullRequests
        let many = prs.count > 1
        DetailHeader(
            kicker: many ? [group.kind, group.authors, group.repos].joined(separator: " · ") : "\(pr.author) · \(pr.repoName) #\(pr.number)",
            title: many ? group.task.title : pr.title, summary: summary(group)
        )
        if many {
            let repos = Set(prs.map(\.repo)).count
            RuledList(title: "Pull requests", count: prs.count) {
                ForEach(Array(prs.enumerated()), id: \.element.url) { index, part in
                    Button { select(part.url) } label: {
                        RuledRow(minHeight: 32) {
                            Text("\(index + 1)").foregroundStyle(Theme.quiet).frame(width: 18, alignment: .leading)
                            Text(verbatim: repos > 1 ? "\(part.repoName) #\(part.number)" : "#\(part.number)")
                                .fontWeight(part.url == pr.url ? .semibold : .regular).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(Format.sizeBucket(part.size)) +\(part.additions) −\(part.deletions)").foregroundStyle(Theme.quiet)
                            Text(Self.checks(part)).foregroundStyle(part.checks.isRed ? Theme.danger : Theme.ink)
                                .scaledFrame(width: 72, alignment: .trailing)
                        }
                        .scaled(.code)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(part.title)
                }
            }
        } else {
            let status = model.state.reviewStatus(for: pr)
            FieldRows(labelWidth: 72) {
                FieldRow("Branch", "\(pr.baseRef) ← \(pr.headRef)", mono: true)
                FieldRow("Size", "\(Format.sizeBucket(pr.size)) +\(pr.additions) −\(pr.deletions)", mono: true)
                FieldRow(label: "Checks") {
                    HStack(spacing: 6) { ChecksBadge(pr: pr); Text(Self.checks(pr)) }
                }
                if status.draft != nil || status.headMoved || status.reRequested {
                    FieldRow(label: "Your review") { ReviewStatusChip(status: status) }
                }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Review skill")
            Text(model.state.reviewSkill(for: pr)?.text ?? "No clone of \(pr.repo) here: a review session starts in its checkout")
                .scaled(.code).fixedSize(horizontal: false, vertical: true)
        }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "info.circle").accessibilityHidden(true)
            Text(many
                ? "A review session reads them in order and drafts one pending review per PR; nothing posts until you submit."
                : "A review session reads it and drafts a pending review; nothing posts until you submit.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .scaled(.secondary).foregroundStyle(Theme.quiet)
        if let error = model.sessionErrors[pr.url] {
            Text(error).scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        HStack(spacing: 8) {
            Button("Review on GitHub") { model.openDraft(pr) }
                .buttonStyle(.desk)
                .help(pr.pendingReview != nil
                    ? "Your draft review, in the PR's Files tab: edit or drop comments, then pick the verdict and submit"
                    : "The PR's Files tab on GitHub")
            Spacer(minLength: 0)
            if model.reviewRunning(pr) {
                Button("Show in iTerm") { model.showReview(pr) }
                    .buttonStyle(.deskPrimary)
                    .help("The review session's pane in iTerm")
            } else {
                Button { start(group, pr) } label: {
                    HStack(spacing: 8) {
                        Text("Start review")
                        if !anyPicked { ButtonKey(key: "R") }
                    }
                }
                .buttonStyle(.deskPrimary)
                .help("A review session in a pane of its own in iTerm, and the diff here")
            }
        }
    }

    /// "4 pull requests, each on the one before. Opened 4d ago; your review is requested."
    private func summary(_ group: QueueGroup) -> String {
        let prs = group.pullRequests
        let opened = "Opened \(Format.age(prs.map(\.createdAt).min())) ago"
        let asked = prs.contains { onMe.contains($0.url) } ? "\(opened); your review is requested." : "\(opened)."
        guard prs.count > 1 else { return asked }
        return "\(prs.count) pull requests\(group.task.origin == .pullRequest ? ", each on the one before" : ""). \(asked)"
    }

    static func checks(_ pr: PullRequest) -> String {
        switch pr.checks {
        case .success: return "passing"
        case .failure, .error: return "failing"
        case .pending, .expected: return "running"
        case .none: return "no checks"
        }
    }
}

extension QueueGroup {
    /// Who wrote its PRs, each named once.
    var authors: String { Self.once(pullRequests.map(\.author)).joined(separator: ", ") }
    /// The repos its PRs are in, each named once.
    var repos: String { Self.once(pullRequests.map(\.repoName)).joined(separator: ", ") }
    /// The ticket's key, the stack's root `repo#n`, or the session's name.
    var label: String { task.origin == .pullRequest ? String(task.id.split(separator: "/").last ?? Substring(task.id)) : task.id }
    /// What holds it together, for the details column's first line: "Stack", or the ticket's key.
    var kind: String { task.origin == .pullRequest ? "Stack" : task.id }
    /// Its line under the authors: "cofhe-contracts · stack of 3", or a ticket's key and how many PRs.
    var what: String {
        let count = pullRequests.count
        guard count > 1 else { return repos }
        return "\(repos) · " + (task.origin == .pullRequest ? "stack of \(count)" : "\(task.id) · \(count) PRs")
    }

    private static func once(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}


/// One filter in force, under the Reviews bar, with the ✕ that lifts it.
private struct FilterToken: View {
    var title: String
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
            Button(action: remove) {
                Image(systemName: "xmark").scaled(.caption).foregroundStyle(Theme.quiet)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove the filter \(title)")
        }
        .scaled(.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(Theme.tint, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.tintLine))
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

/// The queue's filters in one menu, drawn like the sort menu beside it, its badge counting the ones in force: only the
/// PRs that still need an approval, how far back the queue reaches, and whose PRs it leaves out. The common spans are
/// one pick; Other… takes any number of days. Every author in the queue is listed, ticked while shown; unticking one
/// filters their PRs out here and on Up Next, and one already hidden stays listed, so it can be brought back while it has
/// nothing open.
private struct FiltersMenu: View {
    var queue: [PullRequest]
    var filters: ReviewFilters
    var active: Int
    @State private var choosing = false

    private static let spans = [1, 3, 7, 14, 30]

    var body: some View {
        let hidden = filters.hidden
        let counts = Dictionary(grouping: queue, by: \.author).mapValues(\.count)
        let authors = Set(counts.keys).union(hidden).sorted { $0.lowercased() < $1.lowercased() }
        Menu {
            Section("Show") {
                // By the review gate's status on the head commit; a repo without the gate always needs an approval.
                Toggle("Only PRs that need an approval", isOn: filters.$needsApproval)
            }
            Section("Opened") {
                Toggle("Any time", isOn: Binding(get: { !filters.limited }, set: { if $0 { filters.limited = false } }))
                ForEach(Self.spans, id: \.self) { span in
                    Toggle(
                        span == 1 ? "Last day" : "Last \(span) days",
                        isOn: Binding(get: { filters.limited && filters.days == span }, set: { if $0 { filters.days = span; filters.limited = true } })
                    )
                }
                Toggle("Other…", isOn: Binding(get: { filters.limited && !Self.spans.contains(filters.days) }, set: { _ in choosing = true }))
            }
            Divider()
            Menu(hidden.isEmpty ? "Authors: everyone" : "Authors: \(hidden.count) hidden") {
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
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").scaled(.caption).foregroundStyle(Theme.quiet)
                Text("Filters")
                if active > 0 {
                    Text("\(active)").scaled(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Theme.accent, in: Capsule())
                }
            }
            .menuBox()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Keep to the PRs that need an approval, opened lately, or by the authors you review")
        .accessibilityLabel(active == 0 ? "Filters" : "Filters, \(active) on")
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                Text("Last")
                TextField("Days", value: filters.$days, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .scaledFrame(width: 52)
                Stepper("Days", value: filters.$days, in: 1...365).labelsHidden()
                Text(filters.days == 1 ? "day" : "days").foregroundStyle(Theme.quiet)
            }
            .padding(12)
            .onAppear { filters.limited = true }
        }
    }
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
                        Text("\(Format.sizeBucket(pr.size)) \(Text("+\(pr.additions)").foregroundStyle(.green)) \(Text("−\(pr.deletions)").foregroundStyle(.red))"),
                    ])
                    ChecksBadge(pr: pr)
                }
            }
            Spacer(minLength: 8)
            QueueActions(pr: pr, model: model)
            // Against an age of fixed width, so the state's right edge is the same on every row.
            QueueReviewCell(pr: pr, model: model).fixedSize()
            Text(Format.age(pr.createdAt)).monospacedDigit().foregroundStyle(.secondary)
                .scaledFrame(width: 40, alignment: .trailing)
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

/// A ticket's PRs, a stack, or one PR, in the review queue.
struct QueueGroup: Identifiable {
    var task: WorkTask
    var id: String { task.id }
    var pullRequests: [PullRequest] { task.pullRequests }
}

/// The PRs a review is about to start on, while the sheet asks for notes.
struct ReviewRequest: Identifiable {
    let id = UUID()
    var pullRequests: [PullRequest]
}

/// Review together, over the dimmed screen: the PRs picked, in the order the session reads them, each to take out; a box
/// for what to focus on, check, or already know; and what the session runs as. The notes go to the review session with
/// the links; empty is fine.
struct ReviewTogetherSheet: View {
    var request: ReviewRequest
    var model: AppModel
    var dismiss: () -> Void
    /// The ones taken out.
    @State private var removed: Set<String> = []
    @State private var notes = ""
    @FocusState private var writing: Bool

    var body: some View {
        let prs = ReviewGroup.ordered(request.pullRequests.filter { !removed.contains($0.url) }, parents: model.state.stackParents)
        ZStack(alignment: .top) {
            Theme.scrim.ignoresSafeArea().onTapGesture(perform: dismiss).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Review together").scaled(.heading).accessibilityAddTraits(.isHeader)
                        Text("One review session reads them in order and drafts a pending review per pull request.")
                            .foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    closeButton("Close", action: dismiss)
                }
                .padding(EdgeInsets(top: 18, leading: 22, bottom: 16, trailing: 22))
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
                VStack(alignment: .leading, spacing: 20) {
                    RuledList(title: "Pull requests · \(prs.count) · in review order") {
                        ForEach(Array(prs.enumerated()), id: \.element.url) { index, pr in
                            RuledRow(minHeight: 48) {
                                Text("\(index + 1)").scaled(.code).foregroundStyle(Theme.quiet).frame(width: 18, alignment: .leading)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(verbatim: "\(pr.repoName) #\(pr.number)").scaled(.code)
                                    Text(pr.title).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(Format.sizeBucket(pr.size)) +\(pr.additions) −\(pr.deletions)").scaled(.code).foregroundStyle(Theme.quiet)
                                closeButton("Remove \(pr.repoName) #\(pr.number)") { removed.insert(pr.url) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your notes for the review").fontWeight(.medium)
                        TextEditor(text: $notes)
                            .focused($writing)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .frame(height: 76)
                            .background(Theme.ground, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.control))
                            .accessibilityLabel("Your notes for the review")
                        Text("What to focus on, what to check, what you already know; optional. The session reads them before the code.")
                            .scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                    }
                    if let first = prs.first {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Runs as")
                            FieldRows(labelWidth: 96) {
                                FieldRow("Skill", model.state.reviewSkill(for: first)?.text ?? "fhenix-workflow · \(ClaudePlugins.reviewTeammateTask)", mono: true)
                                FieldRow("Folders", folders(prs), mono: true)
                                FieldRow("Mode", "default: it asks before acting, except to move the diff")
                            }
                        }
                    }
                }
                .padding(EdgeInsets(top: 18, leading: 22, bottom: 20, trailing: 22))
                HStack(spacing: 12) {
                    Text("It opens in a pane in iTerm, beside the master. Nothing posts until you submit.")
                        .scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Cancel", action: dismiss)
                        .buttonStyle(.desk(.secondary, .large))
                        .keyboardShortcut(.cancelAction)
                    Button {
                        model.startReview(prs, notes: notes)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) { Text("Start review session"); ButtonKey(key: "⌘↩") }
                    }
                    .buttonStyle(.desk(.primary, .large))
                    .disabled(prs.isEmpty)
                    // Return belongs to the editor, so the press that starts it is ⌘-Return.
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 14, leading: 22, bottom: 14, trailing: 22))
                .overlay(alignment: .top) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
            }
            .scaledFrame(width: 560)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.rule))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 12)
            .padding(.top, 96)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { writing = true }
    }

    /// An ✕ in a 28 pt square, quiet.
    private func closeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.quiet)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The clones the session works in: the first PR's, where it starts, then the others'.
    private func folders(_ prs: [PullRequest]) -> String {
        var seen = Set<String>()
        return prs.map { model.state.localRepo(for: $0).map { ($0.root as NSString).lastPathComponent } ?? $0.repoName }
            .filter { seen.insert($0).inserted }
            .joined(separator: ", ")
    }
}

extension View {
    /// Review together's sheet over this view, dimmed, while `request` is set.
    func reviewTogetherSheet(_ request: Binding<ReviewRequest?>, model: AppModel) -> some View {
        overlay {
            if let item = request.wrappedValue {
                ReviewTogetherSheet(request: item, model: model) { request.wrappedValue = nil }.id(item.id)
            }
        }
    }
}

/// A PR in the queue on its own page, laid out as a PR page is: what it is and its status line — checks, whether it is
/// on you, the risk, where your review stands — with Review on GitHub and the session on the right; the description in
/// the wide column; its checks in a line and its facts beside it. The review itself is yours: read the description, the /pre-pr
/// evidence and CodeRabbit's walkthrough, then the diff, and write it on GitHub. Under the description, the PR's
/// conversation, to reply in, resolve and comment on.
struct ReviewPage: View {
    var pr: PullRequest
    var model: AppModel
    var onMe: Bool
    /// The screen it was opened from, which its back link names and returns to.
    var back = "Reviews"
    var onBack: () -> Void
    /// Start review, asking for notes first where the review can take them.
    @State private var request: ReviewRequest?

    var body: some View {
        DetailPage(back: back, onBack: onBack) {
            // Someone else's PR: its title is theirs to change.
            PageHeadline(pr: pr, model: model, gitHub: pr.url, editable: false)
            StatusLine {
                ChecksPill(pr: pr)
                // Each only when it says something: GitHub asked you, and your review's state, which is blank without one.
                if onMe { Chip(text: "On you", color: .orange) }
                RiskChip(pr: pr)
                if pr.needsHuman { Chip(text: "Needs a person", color: .purple) }
                ReviewStatusChip(status: model.state.reviewStatus(for: pr))
            } actions: {
                Button(model.reviewRunning(pr) ? "Open review" : "Start review") {
                    if !model.reviewRunning(pr), model.canReviewTogether(pr) { request = ReviewRequest(pullRequests: [pr]) } else { model.startReview(pr) }
                }
                    .buttonStyle(.deskPrimary)
                    .help("The diff here and a Claude review session in a pane of its own in iTerm: it summarizes the PR, gives its take on each question, and drafts the comments you decide on")
                Button("Review on GitHub") { model.openDraft(pr) }
                    .buttonStyle(.desk)
                    .help("The PR's Files tab, where you comment, pick the verdict and submit")
                ClaudeSessionButton(pr: pr, model: model).fixedSize()
            }
            if let error = model.sessionErrors[pr.url] {
                Text(error).scaled(.caption).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
        } main: {
            PanelSection("Description") { PullRequestDescription(pr: pr) }
            ConversationSection(pr: pr, model: model)
        } side: {
            WorkflowsSection(pr: pr, model: model)
            AboutCard(pr: pr, model: model)
        }
        .reviewTogetherSheet($request, model: model)
    }
}
