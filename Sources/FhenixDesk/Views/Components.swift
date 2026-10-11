import DeskCore
import SwiftUI

/// A status tag: a small tinted rectangle, the way the reference app marks "ready" or "failing".
struct Chip: View {
    var text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .scaled(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }
}

/// Whether a repo's sessions can run the team review skill: a green seal, or an orange warning that says why
/// not. `showsText` spells it out where there is room for it.
struct ReviewSkillMark: View {
    var skill: ReviewSkill
    var showsText = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: skill.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(skill.isReady ? Color.green : .orange)
            if showsText { Text(skill.text).scaled(.caption).foregroundStyle(.secondary) }
        }
        .help(skill.text)
    }
}

/// A flow's stage. Orange when it waits on your press, so the column reads as a to-do list.
struct StageChip: View {
    var stage: FlowStage

    var body: some View {
        Chip(text: stage.title, color: stage.waitsOnYou ? .orange : stage == .merged ? .purple : .blue)
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
            case .reviewRequired: Chip(text: "Required", color: .orange)
            case .none: Chip(text: "Not required", color: .secondary)
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

/// The sync pill doubles as the refresh button: "Synced" with a green dot, a spinner while any source loads,
/// and an orange dot when one failed, whose error is the tooltip. Pressing it refreshes everything.
struct RefreshControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.refreshAll() } label: {
            HStack(spacing: 6) {
                if model.refreshing.isEmpty {
                    Circle().fill(model.state.errors.isEmpty ? Color.green : .orange).frame(width: 6, height: 6)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(!model.refreshing.isEmpty ? "Syncing" : model.state.errors.isEmpty ? "Synced" : "Sync failed")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.raised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
        .scaled(.caption)
        .monospacedDigit()
    }
}

struct SectionTitle: View {
    var title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).scaled(.headline)
            if let count { Text("\(count)").scaled(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct EmptyText: View {
    var text: String

    var body: some View {
        Text(text).scaled(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// GitHub's +/− pair, shared by the PR tables, the file list and the diff headers.
struct AddDeleteCounts: View {
    var additions: Int
    var deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(.green)
            Text("−\(deletions)").foregroundStyle(.red)
        }
        .scaled(.caption)
        .monospacedDigit()
    }
}

/// Where a review stands, as chips: this session's run while it is going, then what GitHub says — your
/// draft, or the review you sent — and what changed since.
struct ReviewStatusChip: View {
    var status: ReviewStatus

    var body: some View {
        HStack(spacing: 4) {
            switch status.run?.phase {
            case .preparing:
                ProgressView().controlSize(.mini)
                Text("starting").scaled(.caption2).foregroundStyle(.secondary)
            case .running:
                ProgressView().controlSize(.mini)
                Text("reviewing").scaled(.caption2).foregroundStyle(.secondary)
            case .posting:
                ProgressView().controlSize(.mini)
                Text("posting draft").scaled(.caption2).foregroundStyle(.secondary)
            case .failed:
                Chip(text: "failed", color: .red).help(status.run?.error ?? "")
            case .posted, nil:
                github
            }
            if status.headMoved {
                Chip(text: "new commits", color: .orange)
                    .help("The head moved since your draft's comments were written; GitHub marks the ones on changed lines outdated")
            }
            if status.reRequested {
                Chip(text: "re-requested", color: .orange).help("Your review was requested again after you last submitted one")
            }
        }
    }

    @ViewBuilder private var github: some View {
        switch status.draft {
        case .pending(let comments, let claude):
            Chip(text: "draft · \(comments)", color: .blue)
                .help("Your pending review on GitHub: \(comments) \(comments == 1 ? "comment" : "comments"), \(claude) of them Claude's. Only you can see it.")
        case .submitted(let state):
            Chip(text: Self.submittedTitle(state), color: .green).help("Your latest review on GitHub")
        case nil:
            if status.run?.phase == .posted {
                Chip(text: "no comments", color: .green).help(noCommentsHelp)
            }
        }
    }

    private var noCommentsHelp: String {
        let skipped = status.run?.skipped ?? 0
        return skipped == 0 ? "Claude found nothing to comment on" : "Nothing posted; \(skipped) could not be placed on this PR's lines"
    }

    private static func submittedTitle(_ state: String) -> String {
        switch state {
        case "APPROVED": return "approved"
        case "CHANGES_REQUESTED": return "changes requested"
        case "DISMISSED": return "dismissed"
        default: return "commented"
        }
    }
}

/// The background Claude sessions that worked on a PR, and the way in. A filled terminal means there is
/// one — pressing it attaches, which is the only way into a background session from outside the terminal
/// that started it. A hollow one means there is none, and pressing it starts one on the PR's branch.
///
/// Interactive sessions never appear here: nothing outside their own terminal can reach them.
struct ClaudeSessionButton: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        let jobs = model.state.claudeJobs(for: pr)
        if model.startingSessions.contains(pr.url) {
            ProgressView().controlSize(.mini).help("Starting a session on \(pr.headRef)")
        } else if jobs.count > 1, let newest = jobs.first {
            Menu {
                ForEach(jobs) { job in
                    Button("\(job.name) — \(job.state)") { model.attach(job, for: pr) }
                }
            } label: {
                icon("terminal.fill", newest.isRunning ? .green : .accentColor)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(failure ?? "\(jobs.count) background sessions on this PR")
        } else if let job = jobs.first {
            Button { model.attach(job, for: pr) } label: { icon("terminal.fill", job.isRunning ? .green : .accentColor) }
                .buttonStyle(.borderless)
                .help(failure ?? "Attach to “\(job.name)” (\(job.state)) in Terminal")
        } else {
            Button { model.startSession(for: pr) } label: { icon("terminal", .secondary) }
                .buttonStyle(.borderless)
                .disabled(model.state.localRepo(for: pr) == nil)
                .help(failure ?? startHelp)
        }
    }

    /// The last failure on this PR's button, which takes over the tooltip until the next press works.
    private var failure: String? { model.sessionErrors[pr.url] }

    /// Green while a session is running, the accent colour for one that has finished, grey for the button
    /// that would start the first — and red once a press has failed, whichever it was.
    private func icon(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name).foregroundStyle(failure == nil ? tint : .red)
    }

    private var startHelp: String {
        guard model.state.localRepo(for: pr) != nil else { return "No local clone of \(pr.repo) to start a session in" }
        return "Start a background Claude session on \(pr.headRef)"
    }
}

/// Where a ticket's pull requests say it should be. The app moves it there on its own, so this only shows
/// the move in flight, or in red why it did not happen — nothing tries again. It names the pull requests
/// it is arguing from: a move nobody can explain is one nobody should make.
struct DriftBadge: View {
    var drift: TicketDrift
    var model: AppModel

    var body: some View {
        if model.movingTickets.contains(drift.ticket.key) {
            ProgressView().controlSize(.mini).help("Moving \(drift.ticket.key) to “\(drift.target)”")
        } else {
            Chip(text: "→ \(drift.target)", color: failure == nil ? (drift.stage == .done ? .green : .blue) : .red)
                .help(help)
        }
    }

    private var failure: String? { model.ticketMoveErrors[drift.ticket.key] }

    private var help: String {
        if let failure { return "Could not move \(drift.ticket.key) to “\(drift.target)”: \(failure)" }
        let prs = drift.pullRequests.map { "\($0.repoName)#\($0.number)" }.joined(separator: ", ")
        let because = drift.stage == .done ? "\(prs) merged" : "\(prs) open for review"
        return "\(because) — moving \(drift.ticket.key) to “\(drift.target)”"
    }
}

/// Checks, review decision and merge state in one cell: three columns of mostly-quiet badges read better
/// as one, and the inspector spells each out.
struct PullRequestStatus: View {
    var pr: PullRequest

    var body: some View {
        HStack(spacing: 5) {
            ChecksBadge(pr: pr)
            ReviewBadge(pr: pr)
            MergeBadge(pr: pr)
        }
    }
}
