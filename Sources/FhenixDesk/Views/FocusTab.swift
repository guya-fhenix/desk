import DeskCore
import SwiftUI

/// The landing screen: everything of yours on one page, and how large an item is drawn is all the page says about how
/// much it matters. On the left what to act on now, as large cards, and what comes next, as medium ones; on the right
/// what can wait and, quietest, what only runs in the background. The master's ranking (`focus.json`) sets the sizes and
/// the order; without one, each item's own state does, and what GitHub changes after the master ranked Desk lifts
/// itself, marked New until the master ranks again. Nothing is forced to the top when nothing is urgent.
///
/// What the master asked you and what the sessions are doing are not here: you follow those in the master's pane and in
/// `claude agents`. Each item carries its own press; a click, or Return on the one J and K walked to, opens a PR's page
/// here (its back link, or ←, returns) or a ticket in Jira. The reviews follow the Reviews screen's filters.
struct FocusTab: View {
    @Environment(AppModel.self) private var model
    /// The item the keys are on: a PR's url or a ticket's key.
    @State private var selection: String?
    /// The pages open over the page; empty shows it.
    @State private var path: [Route] = []
    @FocusState private var focused: Bool
    /// With Reduce Motion on, the page jumps to the selected item instead of sliding there.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var filters = ReviewFilters()

    var body: some View {
        let items = model.focus(filters)
        RouteStack(path: $path, back: "Focus") { page(items) }
            .focusedSceneValue(\.routePath, $path)
    }

    @ViewBuilder private func page(_ items: [FocusItem]) -> some View {
        // The sources that have neither answered nor failed yet: until GitHub has, an empty page means nothing.
        let pending = Source.allCases.filter { model.state.lastRefresh[$0] == nil && model.state.errors[$0] == nil }
        let urgent = items.filter { $0.level == .now }.count
        Screen {
            ScreenTitle(title: "Focus", subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                if !items.isEmpty {
                    Text("\(urgent == 0 ? "Nothing urgent" : "\(urgent) to act on now") · \(items.count) in all")
                        .scaled(.secondary).foregroundStyle(Theme.quiet)
                }
            }
            .padding(.bottom, 18)
        } content: {
            if pending.contains(.github) || (items.isEmpty && !pending.isEmpty) { syncing(pending) }
            ForEach(Source.allCases, id: \.self) { source in
                if source == .github, model.state.github == nil, let error = model.state.errors[.github] {
                    // Nothing from GitHub has ever loaded, so this is no stale page: say what is missing.
                    EmptyState(
                        icon: "exclamationmark.triangle", text: "GitHub didn't answer, so Focus can't say which PRs wait on you.",
                        detail: error, actionTitle: "Retry", action: { Task { await model.refresh(.github) } }
                    )
                    .padding(Theme.Space.m)
                    .background(Theme.warn.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.vertical, Theme.Space.m)
                } else {
                    StaleBanner(source: source)
                }
            }
            if pending.contains(.github) {
                placeholders
            } else if items.isEmpty, pending.isEmpty, model.state.errors.isEmpty {
                // Says how fresh "nothing" is, and where to go next, rather than one grey line.
                EmptyState(
                    icon: "checkmark.circle",
                    text: "All clear. \(Source.names(Source.allCases)) all synced \(Format.ago(model.state.lastRefresh.values.min())).",
                    actionTitle: "Browse the review queue", action: { model.pendingTab = .reviews }
                )
                .padding(.vertical, 20)
            }
            if !items.isEmpty, !pending.contains(.github) { columns(items) }
            Spacer(minLength: 0)
            KeyHints(hints: [(["J", "K"], "move"), (["↩"], "open"), (["M"], "master"), (["⌘R"], "sync")])
        }
    }

    /// Now and Next on the left, Can wait and Background on the right, scrolling together.
    private func columns(_ items: [FocusItem]) -> some View {
        let rows = items.map(\.id)
        return ScrollViewReader { proxy in
            ScrollView {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !items.contains(where: { $0.level == .now }) {
                            Text("Nothing is urgent right now.").foregroundStyle(Theme.quiet).padding(.bottom, 4)
                        }
                        group(.now, items)
                        group(.next, items)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 8) {
                        group(.canWait, items)
                        group(.background, items)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                // Room for the selected item's ring, which the scroll view would clip.
                .padding(3)
            }
            .deskScrollBar()
            // Focused on arrival and on the way back from a page, so the keys work without a click first.
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .task(id: path.isEmpty) { if path.isEmpty { focused = true } }
            .onKeyPress(.return) {
                guard let item = items.first(where: { $0.id == selection }) else { return .ignored }
                open(item)
                return .handled
            }
            // J and K walk the items, largest first; M shows the master.
            .onKeyPress(keys: ["j", "k", "m"]) { press in
                guard press.modifiers.isEmpty else { return .ignored }
                if press.key == "m" {
                    model.openMaster()
                } else {
                    selection = Self.step(rows, from: selection, by: press.key == "j" ? 1 : -1)
                }
                return .handled
            }
            .onChange(of: selection) { _, id in
                if let id { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    /// One level's items under its label; nothing for a level with none.
    @ViewBuilder private func group(_ level: FocusLevel, _ items: [FocusItem]) -> some View {
        let shown = items.filter { $0.level == level }
        if !shown.isEmpty {
            SectionLabel(level.title).padding(.top, level == .now || level == .canWait ? 0 : 6)
            ForEach(shown) { item in
                FocusCard(item: item, model: model, selected: selection == item.id) { open(item) }
                    .id(item.id)
                    .contextMenu { menu(item) }
            }
        }
    }

    @ViewBuilder private func menu(_ item: FocusItem) -> some View {
        switch item.subject {
        case .pullRequest(let pr): PullRequestMenu(pr: pr, model: model)
        case .move(let drift): ticketMenu(drift.ticket)
        case .ticket(let ticket): ticketMenu(ticket)
        }
    }

    @ViewBuilder private func ticketMenu(_ ticket: Ticket) -> some View {
        Button("Open in Jira") { model.open(ticket.url) }
        Button("Copy Key") { Clipboard.copy(ticket.key) }
    }

    /// "Reading GitHub and Jira… Git answered.": which sources Focus still waits on, over the bars that stand in for
    /// theirs.
    private func syncing(_ pending: [Source]) -> some View {
        let answered = Source.allCases.filter { model.state.lastRefresh[$0] != nil }
        return HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.mini)
            Text("Reading \(Source.names(pending))…" + (answered.isEmpty ? "" : " \(Source.names(answered)) answered."))
        }
        .scaled(.secondary)
        .foregroundStyle(Theme.quiet)
        .padding(.vertical, Theme.Space.m)
    }

    /// Grey bars where the first items will be, so the screen reads as loading rather than empty.
    private var placeholders: some View {
        VStack(spacing: 0) {
            ForEach([CGFloat(360), 280, 320], id: \.self) { width in
                HStack(spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().frame(width: width, height: 10)
                        Capsule().frame(width: width - 90, height: 8).opacity(0.7)
                    }
                    Spacer()
                    Capsule().frame(width: 90, height: 10)
                }
                .foregroundStyle(Theme.inset)
                .padding(Theme.Space.m)
            }
        }
        .accessibilityHidden(true)
    }

    /// The row `by` steps from `id`, held at the ends; the first row when nothing is selected. The Jira and Tasks
    /// screens' J and K walk their rows with it too.
    static func step(_ rows: [String], from id: String?, by offset: Int) -> String? {
        guard let id, let index = rows.firstIndex(of: id) else { return rows.first }
        return rows[min(max(index + offset, 0), rows.count - 1)]
    }

    /// The checks in a word: "passing", "failing", "running". Search says it the same way.
    static func checks(_ pr: PullRequest) -> String {
        switch pr.checks {
        case .success: return "passing"
        case .failure, .error: return "failing"
        case .pending, .expected: return "running"
        case .none: return "no checks"
        }
    }

    /// A PR's page, with the item selected behind it for the way back; a ticket in Jira, which has no page here; a PR
    /// merged longer ago than Desk keeps pages for, on GitHub.
    private func open(_ item: FocusItem) {
        selection = item.id
        switch item.subject {
        case .move(let drift): model.open(drift.ticket.url)
        case .ticket(let ticket): model.open(ticket.url)
        case .pullRequest(let pr):
            let known = model.yourPullRequest(pr.url) != nil || model.state.github?.allOpen.contains { $0.url == pr.url } == true
            if known { path.append(.pr(pr.url)) } else { model.open(pr.url) }
        }
    }
}

/// One Focus item, drawn at its level's size: a large card with its facts and its press, a medium one with its press
/// beside its line of detail, a small one with its title over its line of detail, and the same without a frame, quiet,
/// in the background. Every size says what it is, names it, and says how long it has waited when it waits on something.
private struct FocusCard: View {
    var item: FocusItem
    var model: AppModel
    /// The keys are on it.
    var selected: Bool
    var open: () -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(item.level == .background ? Color.clear : Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Theme.accentInk : edge, lineWidth: selected || item.level == .now ? 1.5 : 1)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .handCursor()
            // One element per item for VoiceOver, its buttons still reachable as actions.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var content: some View {
        switch item.level {
        case .now:
            VStack(alignment: .leading, spacing: 9) {
                head
                Text(title).scaled(.heading).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(detail).scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1)
                if !facts.isEmpty { factStrip }
                action(.regular, primary: true).padding(.top, 2)
            }
            .padding(14)
        case .next:
            VStack(alignment: .leading, spacing: 5) {
                head
                Text(title).scaled(.body.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(detail).scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1)
                    Spacer(minLength: 4)
                    action(.small, primary: false)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        case .canWait, .background:
            let quiet = item.level == .background
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    marks
                    Text(name).scaled(.code).foregroundStyle(Theme.quiet).lineLimit(1).fixedSize()
                    Text(title).scaled(quiet ? .secondary : .rowTitle).foregroundStyle(quiet ? Theme.quiet : Theme.ink).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.lifted { newChip }
                    if let since = item.since {
                        Text(Format.age(since)).scaled(.caption).foregroundStyle(Theme.quiet).fixedSize()
                            .help("Waiting since \(Format.date(since))").accessibilityLabel("waiting \(Format.age(since))")
                    }
                }
                HStack(spacing: 6) {
                    if quiet {
                        Text("\(item.kind.title) · \(detail)").scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1)
                    } else {
                        chip
                        Text(detail).scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    // A suggested move keeps its two presses at any size: opening the ticket in Jira does not make it.
                    if case .move(let drift) = item.subject { MoveButtons(drift: drift, model: model) }
                }
            }
            .padding(EdgeInsets(top: quiet ? 3 : 7, leading: 10, bottom: quiet ? 3 : 7, trailing: 10))
        }
    }

    /// A large or medium card's first line: its marks, its name, what it is, and how long it has waited.
    private var head: some View {
        HStack(spacing: 6) {
            marks
            Text(name).scaled(.code).foregroundStyle(Theme.quiet).lineLimit(1).fixedSize()
            chip
            if item.lifted { newChip }
            Spacer(minLength: 4)
            if let since = item.since {
                Text("waiting \(Format.age(since))").scaled(.caption).foregroundStyle(Theme.quiet).fixedSize()
                    .help("Since \(Format.date(since))")
            }
        }
    }

    private var chip: some View { StageChip2(text: item.kind.title, color: tone) }

    /// Only on what Desk lifted because GitHub changed after the master ranked.
    private var newChip: some View {
        StageChip2(text: "New", color: Theme.warn).help("Changed on GitHub since the master last ranked")
    }

    /// The chip's colour, and a large card's edge: red for yours to fix, green to merge, orange to answer, the accent for
    /// a review asked of you, Jira's blue for a ticket in motion; none for what only waits.
    private var tone: Color? {
        switch item.kind {
        case .ciFailed, .conflicts, .changesRequested: return Theme.danger
        case .readyToMerge: return Theme.ok
        case .needsRebase, .openThreads, .reviewDraft: return Theme.warn
        case .reviewAsked: return Theme.accentInk
        case .jiraMove, .inProgress: return Theme.jira
        case .draftReviewed, .draft, .waitingOnReview, .reviewOpen, .toStart, .merged: return nil
        }
    }

    private var edge: Color {
        switch item.level {
        case .now: return tone ?? Theme.ruleStrong
        case .background: return .clear
        case .next, .canWait: return Theme.rule
        }
    }

    /// What kind of thing it is, before its name: a PR's own mark and its checks, an eye on a review, Jira's diamond.
    @ViewBuilder private var marks: some View {
        switch item.subject {
        case .move, .ticket:
            Image(systemName: "diamond.fill").font(.system(size: 10)).foregroundStyle(Theme.jira).accessibilityLabel("Jira ticket")
        case .pullRequest(let pr):
            switch item.kind {
            case .merged:
                Image(systemName: "arrow.triangle.merge").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.merged)
                    .accessibilityLabel("Merged pull request")
            case .reviewAsked, .reviewOpen, .reviewDraft:
                Image(systemName: "eye").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accentInk)
                    .accessibilityLabel("Review")
            default:
                PRMark(pr: pr)
                ChecksBadge(pr: pr).font(.system(size: 11))
            }
        }
    }

    /// "cofhe#1186", or the ticket's key.
    private var name: String {
        if case .pullRequest(let pr) = item.subject { return "\(pr.repoName)#\(pr.number)" }
        return item.id
    }

    private var title: String {
        switch item.subject {
        case .pullRequest(let pr): return pr.title
        case .move(let drift): return "\(drift.ticket.summary) → \(drift.target)"
        case .ticket(let ticket): return ticket.summary
        }
    }

    /// The line of detail every size carries: a PR's ticket, approvals and CI; a review's author, size and risk; a
    /// ticket's status, sprint or backlog, and priority.
    private var detail: String {
        let parts: [String?]
        switch item.subject {
        case .move(let drift):
            parts = ["\(drift.ticket.status) now", model.ticketMoveErrors[drift.ticket.key].map { "Jira refused: \($0)" } ?? drift.because]
        case .ticket(let ticket):
            parts = [ticket.status, ticket.placement == .unknown ? nil : ticket.placement.rawValue, ticket.priority]
        case .pullRequest(let pr):
            switch item.kind {
            case .merged:
                parts = [model.state.ticketKeys[pr.url]?.first, pr.mergedAt.map { "merged \($0.clock)" }]
            case .reviewDraft:
                let count = pr.pendingReview?.comments ?? 0
                parts = [pr.author, "your draft, \(count) \(count == 1 ? "comment" : "comments"), not sent"]
            case .reviewAsked, .reviewOpen:
                parts = [pr.author, "+\(pr.additions) −\(pr.deletions)", pr.risk.map { "\($0) risk" }, "CI \(FocusTab.checks(pr))"]
            default:
                let facts = PullRequestFacets(pr: pr, rebase: model.state.rebaseReason(pr)).facts
                parts = [
                    model.state.ticketKeys[pr.url]?.first, model.state.stackParent(of: pr).map { "on #\($0.number)" },
                    item.kind == .draft ? "not self-reviewed" : nil, pr.isDraft ? nil : facts[3].words.lowercased(),
                    "CI \(FocusTab.checks(pr))",
                ]
            }
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// A large card's facts, label over value: your PR's as the PR list's columns name them, a review's size, risk and
    /// checks. A ticket's line of detail already says all Desk knows of it.
    private var facts: [(label: String, value: String, color: Color)] {
        guard case .pullRequest(let pr) = item.subject, item.kind != .merged else { return [] }
        switch item.kind {
        case .reviewAsked, .reviewOpen, .reviewDraft:
            return [
                ("Size", "+\(pr.additions) −\(pr.deletions)", Theme.ink), ("Risk", pr.risk ?? "–", Theme.ink),
                ("CI", FocusTab.checks(pr), pr.checks.isRed ? Theme.danger : pr.checks == .success ? Theme.ok : Theme.ink),
            ]
        default:
            let facets = PullRequestFacets(pr: pr, rebase: model.state.rebaseReason(pr)).facts
            return facets.enumerated().dropFirst().map { index, fact in
                (PullRequestFacets.labels[index], fact.words, fact.tone == .neutral ? Theme.ink : PullRequestFacets.color(fact.tone))
            }
        }
    }

    private var factStrip: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                VStack(alignment: .leading, spacing: 1) {
                    Text(fact.label).textCase(.uppercase).scaled(.caption).tracking(0.4).foregroundStyle(Theme.quiet).lineLimit(1)
                    Text(fact.value).scaled(.secondary.weight(.medium)).foregroundStyle(fact.color).lineLimit(2)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .leading) { if index > 0 { Rectangle().fill(Theme.rule).frame(width: 1) } }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rule))
    }

    /// The item's press: a review starts, or shows while it runs; a move moves or is dismissed; a ticket opens in Jira;
    /// your own PR opens its page, where its merge and its other presses are.
    @ViewBuilder private func action(_ size: DeskButtonStyle.Size, primary: Bool) -> some View {
        let kind: DeskButtonStyle.Kind = primary ? .primary : .secondary
        switch item.subject {
        case .move(let drift): MoveButtons(drift: drift, model: model, prominent: primary)
        case .ticket(let ticket): Button("Open in Jira") { model.open(ticket.url) }.buttonStyle(.desk(kind, size))
        case .pullRequest(let pr):
            switch item.kind {
            case .merged: EmptyView()
            case .reviewAsked, .reviewOpen:
                Button(model.reviewRunning(pr) ? "Show review" : "Start review") {
                    if model.reviewRunning(pr) {
                        model.showReview(pr)
                    } else {
                        model.startReview(pr)
                        open()
                    }
                }
                .buttonStyle(.desk(kind, size))
                .help(model.reviewRunning(pr) ? "The review session's window in iTerm" : "The diff here and a review session in a window of its own in iTerm")
            case .reviewDraft:
                Button("Open review") { model.openDraft(pr) }.buttonStyle(.desk(kind, size)).help("Your draft review on GitHub")
            default:
                Button(item.kind == .readyToMerge ? "Open to merge" : "Open PR", action: open).buttonStyle(.desk(kind, size))
                    .help("The PR's page")
            }
        }
    }
}
