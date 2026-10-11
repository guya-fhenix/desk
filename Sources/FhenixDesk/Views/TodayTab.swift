import DeskCore
import SwiftUI

/// The landing screen: every nudge and every ticket the app could not move, grouped by what you do about
/// it, each with the press that deals with it. The other screens hold the detail; this one says what next.
struct TodayTab: View {
    @Environment(AppModel.self) private var model

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
        let drifts = model.state.ticketDrifts.filter { model.ticketMoveErrors[$0.ticket.key] != nil }
        Screen {
            PageHeader(title: "Today", subtitle: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                HeaderControls()
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    tiles.padding(.vertical, 14)
                    ForEach(Group.allCases) { group in
                        let nudges = byGroup[group] ?? []
                        let count = group == .sync ? drifts.count : nudges.count
                        if count > 0 {
                            GroupHeader(title: group.title, count: count)
                            if group == .sync {
                                ForEach(drifts) { drift in ListRow { DriftRow(drift: drift, model: model) } }
                            } else {
                                ForEach(nudges) { nudge in ListRow { NudgeRow(nudge: nudge, model: model) } }
                            }
                        }
                    }
                    if model.state.nudges.isEmpty && drifts.isEmpty {
                        EmptyText(text: "Nothing needs you right now.").padding(.vertical, 20)
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    /// The three numbers that say how full the other screens are; each one opens its screen.
    private var tiles: some View {
        HStack(spacing: 10) {
            tile("\(model.state.mine.count)", "My open PRs", .pullRequests)
            tile("\(model.state.reviewRequests.count)", "Reviews on you", .reviews)
            tile("\(model.state.openTickets.count)", "Open tickets", .tickets)
        }
        .padding(.vertical, 4)
    }

    private func tile(_ value: String, _ label: String, _ tab: DeskWindow.Tab) -> some View {
        Button { model.pendingTab = tab } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(value).scaled(.size(22).weight(.semibold)).monospacedDigit()
                Text(label).scaled(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
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

    private var pr: PullRequest? {
        let state = model.state
        return (state.mine + state.reviewRequests + state.openForReview).first { $0.url == nudge.url }
    }

    var body: some View {
        HStack(spacing: 10) {
            dot
            VStack(alignment: .leading, spacing: 1) {
                Text(nudge.title).lineLimit(1)
                Text(nudge.detail).scaled(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            actions
            Text(pr.map { Format.age($0.updatedAt) } ?? "")
                .scaled(.caption).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
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
                        Button("Review") { model.review(pr) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canReview(pr))
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
                Button("Approve") { model.approveDraft(flow) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.state.reviewSkill(for: pr)?.isReady != true || flow.paused)
                    .help(model.state.reviewSkill(for: pr)?.text ?? "Start the self-review")
            case .approved:
                Button("Merge") { model.merge(flow) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busyFlows.contains(flow.id) || pr.mergeState == .dirty)
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
