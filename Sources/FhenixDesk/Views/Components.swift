import DeskCore
import SwiftUI

struct Chip: View {
    var text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct StatusDot: View {
    var color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

struct ChecksBadge: View {
    var pr: PullRequest

    var body: some View {
        switch pr.checks {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Checks passed")
        case .failure, .error: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Checks failed")
        case .pending, .expected: Image(systemName: "clock.fill").foregroundStyle(.orange).help("Checks running")
        case .none: Image(systemName: "minus.circle").foregroundStyle(.secondary).help("No checks")
        }
    }
}

struct ReviewBadge: View {
    var pr: PullRequest

    var body: some View {
        if pr.isDraft {
            Chip(text: "Draft", color: .secondary)
        } else {
            switch pr.reviewDecision {
            case .approved: Chip(text: "Approved", color: .green)
            case .changesRequested: Chip(text: "Changes", color: .red)
            case .reviewRequired: Chip(text: "Review", color: .orange)
            case .none: Chip(text: "No review", color: .secondary)
            }
        }
    }
}

struct MergeBadge: View {
    var pr: PullRequest

    var body: some View {
        switch pr.mergeState {
        case .clean: Chip(text: "Clean", color: .green)
        case .dirty: Chip(text: "Conflicts", color: .red)
        case .behind: Chip(text: "Behind", color: .orange)
        case .blocked: Chip(text: "Blocked", color: .secondary)
        case .unstable: Chip(text: "Unstable", color: .orange)
        case .draft, .hasHooks, .unknown: EmptyView()
        }
    }
}

struct TicketBadge: View {
    var ticket: Ticket

    var body: some View {
        switch ticket.category {
        case .inProgress: Chip(text: ticket.status, color: .blue)
        case .todo: Chip(text: ticket.status, color: .secondary)
        case .done: Chip(text: ticket.status, color: .green)
        case .unknown: Chip(text: ticket.status)
        }
    }
}

struct SeverityDot: View {
    var severity: NudgeSeverity

    var body: some View {
        switch severity {
        case .urgent: StatusDot(color: .red)
        case .warning: StatusDot(color: .orange)
        case .info: StatusDot(color: .blue)
        }
    }
}

struct LiveStatusDot: View {
    var session: LiveSession

    var body: some View {
        switch (session.isAlive, session.status) {
        case (false, _): StatusDot(color: .gray)
        case (_, .busy): StatusDot(color: .green)
        case (_, .shell): StatusDot(color: .teal)
        case (_, .idle): StatusDot(color: .orange)
        case (_, .unknown): StatusDot(color: .secondary)
        }
    }
}

/// The refresh button doubles as the refresh indicator: a spinner replaces the arrow while any
/// source loads, and an orange dot marks a failed source. The fixed frame keeps the toolbar capsule
/// the same size in every state; the tooltip carries the error text.
struct RefreshControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.refreshAll() } label: {
            ZStack {
                if model.refreshing.isEmpty {
                    Image(systemName: "arrow.clockwise")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 18, height: 18)
            .overlay(alignment: .topTrailing) {
                if !model.state.errors.isEmpty {
                    Circle().fill(.orange).frame(width: 7, height: 7).offset(x: 2, y: -2)
                }
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        let errors = Source.allCases.compactMap { source in model.state.errors[source].map { "\(source.title): \($0)" } }
        if !errors.isEmpty { return errors.joined(separator: "\n") }
        return model.refreshing.isEmpty ? "Refresh all" : "Refreshing…"
    }
}

/// GitHub's diff stat: the size bucket, then additions in green and deletions in red.
struct DiffStat: View {
    var pr: PullRequest

    var body: some View {
        HStack(spacing: 4) {
            Text(Format.sizeBucket(pr.size))
            Text("+\(pr.additions)").foregroundStyle(.green)
            Text("−\(pr.deletions)").foregroundStyle(.red)
        }
        .font(.caption)
        .monospacedDigit()
    }
}

struct SectionTitle: View {
    var title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct EmptyText: View {
    var text: String

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PullRequestLine: View {
    @Environment(AppModel.self) private var model
    var pr: PullRequest
    var showRepo = true

    var body: some View {
        Button {
            model.open(pr.url)
        } label: {
            HStack(spacing: 8) {
                ChecksBadge(pr: pr)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title).lineLimit(1).font(.callout)
                    HStack(spacing: 6) {
                        Text(showRepo ? "\(pr.repoName)#\(pr.number)" : "#\(pr.number)").font(.caption).foregroundStyle(.secondary)
                        if let parent = model.state.stackParent(of: pr) {
                            Text("↑ #\(parent.number)").font(.caption).foregroundStyle(.secondary).help("Stacked on #\(parent.number)")
                        }
                        if let reason = model.state.rebaseReason(pr) {
                            Chip(text: "rebase: \(reason.text)", color: .orange)
                        }
                    }
                }
                Spacer(minLength: 4)
                ReviewBadge(pr: pr)
                Text(Format.age(pr.updatedAt)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
