import DeskCore
import SwiftUI

/// The landing screen: every nudge and every ticket the app could not move, grouped by what you do about
/// it, each with the press that deals with it. The other screens hold the detail; this one says what next.
struct UpNextTab: View {
    @Environment(AppModel.self) private var model
    /// A nudge's id or a drift's ticket key, so the arrow keys can walk the list and Return can open one.
    @State private var selection: String?
    private var reviewDays = ReviewDays()

    /// In the order they are worth your attention.
    enum Group: CaseIterable, Identifiable {
        case waiting, fix, review, merge, sync, quiet

        var id: Self { self }

        var title: String {
            switch self {
            case .waiting: return "Waiting on you"
            case .fix: return "Fix"
            case .review: return "Review"
            case .merge: return "Merge"
            case .sync: return "Jira out of sync"
            case .quiet: return "Quiet"
            }
        }

        /// Nudges in the order Up Next lists them, group by group, keeping the engine's order inside a group. The menu
        /// panel shows the head of this same list.
        static func ordered(_ nudges: [Nudge]) -> [Nudge] {
            let rank = Dictionary(uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })
            return nudges.enumerated()
                .sorted { (rank[of($0.element.kind)] ?? 0, $0.offset) < (rank[of($1.element.kind)] ?? 0, $1.offset) }
                .map(\.element)
        }

        static func of(_ kind: NudgeKind) -> Group {
            switch kind {
            case .flowWaiting: return .waiting
            case .ciFailed, .changesRequested, .needsRebase, .sessionNeedsYou: return .fix
            case .reviewRequested, .reviewReady: return .review
            case .readyToMerge: return .merge
            case .stalePullRequest: return .quiet
            }
        }
    }

    var body: some View {
        let byGroup = Dictionary(grouping: model.state.nudges) { Group.of($0.kind) }
        // Only the moves that failed: the rest the app makes on its own, and they need nothing from you.
        let drifts = model.failedDrifts
        // One filled button on the screen, on the row that comes first; the rest are plain bordered ones.
        let firstNudge = Group.allCases.lazy.compactMap { byGroup[$0]?.first?.id }.first
        Screen {
            PageHeader(title: "Up Next") {
                HeaderControls()
            }
        } content: {
            // Arrow keys walk the nudges; Return or a double-click opens the selected one where it lives.
            List(selection: $selection) {
                tiles.padding(.vertical, 14).plainListRow().selectionDisabled()
                ForEach(Group.allCases) { group in
                    let nudges = byGroup[group] ?? []
                    let count = group == .sync ? drifts.count : nudges.count
                    if count > 0 {
                        GroupHeader(title: group.title, count: count).plainListRow().selectionDisabled()
                        if group == .sync {
                            ForEach(drifts) { drift in
                                ListRow(selected: selection == drift.id) { DriftRow(drift: drift, model: model) }
                            }
                        } else {
                            ForEach(nudges) { nudge in
                                ListRow(selected: selection == nudge.id) {
                                    NudgeRow(nudge: nudge, model: model, prominent: nudge.id == firstNudge)
                                }
                            }
                        }
                    }
                }
                if model.state.nudges.isEmpty && drifts.isEmpty {
                    // Says how fresh "nothing" is, and where to go next, rather than one grey line.
                    EmptyState(
                        icon: "checkmark.circle", text: "All clear · synced \(Format.age(model.state.lastRefresh.values.max())) ago",
                        actionTitle: "Browse the review queue", action: { model.pendingTab = .reviews }
                    )
                    .padding(.vertical, 20)
                    .plainListRow()
                    .selectionDisabled()
                }
            }
            .deskList()
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let nudge = model.state.nudges.first(where: { $0.id == id }), let url = nudge.url {
                    Button("Open on GitHub") { model.open(url) }
                    Button("Copy Link") { Clipboard.copy(url) }
                } else if let id = ids.first, let drift = drifts.first(where: { $0.id == id }) {
                    Button("Open in Jira") { model.open(drift.ticket.url) }
                    Button("Copy Key") { Clipboard.copy(drift.ticket.key) }
                }
            } primaryAction: { ids in
                guard let id = ids.first else { return }
                if let nudge = model.state.nudges.first(where: { $0.id == id }) {
                    model.open(nudge.url)
                } else if let drift = drifts.first(where: { $0.id == id }) {
                    model.open(drift.ticket.url)
                }
            }
        }
    }

    /// The three numbers that say how full the other screens are, the same ones their sidebar badges show; each one
    /// opens its screen. Where a second number helps, it is spelled out beside the label.
    private var tiles: some View {
        let state = model.state
        return HStack(spacing: 10) {
            tile("\(state.waiting(on: .pullRequests))", "PRs need you · \(state.mine.count) open", .pullRequests)
            tile("\(state.reviewQueue(.all, days: reviewDays.window).count)", "In the review queue · \(state.reviewRequests.count) on you", .reviews)
            tile("\(state.openTickets.count)", "Open Jira tickets", .tickets)
        }
        .padding(.vertical, 4)
    }

    private func tile(_ value: String, _ label: String, _ tab: DeskWindow.Tab) -> some View {
        Button { model.pendingTab = tab } label: {
            // The chevron says it goes somewhere, as the hover fill does once the pointer is on it.
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(value).scaled(.title).monospacedDigit()
                    Text(label).scaled(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .hoverFill(Theme.selected, cornerRadius: 8)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One nudge and the buttons that act on it. The pull request is looked up by url, so a nudge whose PR has
/// just left the snapshot still reads, and only loses its buttons.
private struct NudgeRow: View {
    var nudge: Nudge
    var model: AppModel
    /// The one row whose press is drawn filled.
    var prominent = false

    private var pr: PullRequest? {
        let state = model.state
        return (state.mine + state.reviewRequests + state.openForReview).first { $0.url == nudge.url }
    }

    var body: some View {
        HStack(spacing: 10) {
            dot
            // The PR's own title leads, as on every other screen; what happened, the repo, the author and the age
            // go on the line under it. A nudge with no PR keeps its own two lines.
            VStack(alignment: .leading, spacing: 1) {
                if let pr {
                    Text(pr.title).lineLimit(1)
                    MetaLine(parts: [Text(nudge.title), Text(pr.author), Text("opened \(Format.age(pr.createdAt))")])
                } else {
                    Text(nudge.title).lineLimit(1)
                    Text(nudge.detail).scaled(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            actions
            // Labelled: the detail line may carry an age of its own, the time the PR has waited.
            Text(pr.map { "updated \(Format.age($0.updatedAt))" } ?? "")
                .scaled(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)
                .help(pr.map { "Updated \(Format.date($0.updatedAt))" } ?? "")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var dot: some View {
        if nudge.kind == .readyToMerge { StatusDot(color: .green) } else { SeverityDot(severity: nudge.severity) }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if let pr {
                switch nudge.kind {
                case .reviewRequested, .reviewReady:
                    if model.state.reviewNeed(for: pr) != nil {
                        let blocker = model.reviewBlocker(pr)
                        DisabledReason(text: blocker)
                        Button("Review") { model.review(pr) }
                            .primaryStyle(prominent)
                            .disabled(blocker != nil)
                            .help(blocker ?? "Run Claude on this PR and put its comments in your draft review")
                    }
                    if pr.pendingReview != nil {
                        Button("Open draft") { model.openDraft(pr) }
                    }
                case .flowWaiting:
                    flowActions(pr)
                case .sessionNeedsYou:
                    EmptyView()
                default:
                    ClaudeSessionButton(pr: pr, model: model)
                }
            }
            if nudge.kind == .sessionNeedsYou, let jobId = nudge.jobId {
                Button("Attach") { model.attach(jobId: jobId, errorKey: nudge.url ?? jobId) }
            }
            Button("Open PR") { model.open(nudge.url) }.disabled(nudge.url == nil)
        }
        .controlSize(.small)
    }
}

extension NudgeRow {
    /// Approve and Merge right here; the stages that want reading first open the PR's details panel.
    @ViewBuilder fileprivate func flowActions(_ pr: PullRequest) -> some View {
        if let flow = model.state.flow(for: pr) {
            switch flow.stage {
            case .draft:
                let blocker = model.approveBlocker(flow, pr)
                DisabledReason(text: blocker)
                Button("Approve") { model.approveDraft(flow) }
                    .primaryStyle(prominent)
                    .disabled(blocker != nil)
                    .help(model.state.reviewSkill(for: pr)?.text ?? "Start the self-review")
            case .approved:
                let blocker = model.mergeBlocker(flow, pr)
                DisabledReason(text: blocker)
                Button("Merge") { model.merge(flow) }
                    .primaryStyle(prominent)
                    .disabled(blocker != nil)
                    .help(blocker ?? "Squash-merges the PR into \(pr.baseRef)")
            default:
                Button("Show") {
                    model.selectPullRequest = pr.url
                    model.pendingTab = .pullRequests
                }
            }
        }
    }
}

/// A ticket whose Jira status has fallen behind its pull requests and that the app could not move, and why.
private struct DriftRow: View {
    var drift: TicketDrift
    var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: .blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(drift.ticket.key) should be “\(drift.target)”").lineLimit(1)
                Text("Jira says “\(drift.ticket.status)” · \(reason)").scaled(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(model.ticketMoveErrors[drift.ticket.key] ?? "").scaled(.caption).foregroundStyle(.red).lineLimit(1)
                    .help(model.ticketMoveErrors[drift.ticket.key] ?? "")
            }
            Spacer(minLength: 8)
            Button("Open in Jira") { model.open(drift.ticket.url) }.controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var reason: String {
        let prs = drift.pullRequests.map { "\($0.repoName)#\($0.number)" }.joined(separator: ", ")
        return drift.stage == .done ? "\(prs) merged" : "\(prs) open for review"
    }
}
