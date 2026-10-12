import DeskCore
import SwiftUI

/// A status tag: a small tinted rectangle, the way the reference app marks "ready" or "failing".
struct Chip: View {
    var text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .scaled(.caption.weight(.medium))
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs / 2)
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
    /// What the dot says, for VoiceOver. Without one the dot is decoration and stays silent.
    var meaning: String?

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .accessibilityHidden(meaning == nil)
            .accessibilityLabel(meaning ?? "")
    }
}

extension PullRequest {
    /// The checks in a word, for the details panels.
    var checksText: String {
        switch checks {
        case .success: return "Passed"
        case .failure, .error: return "Failed"
        case .pending, .expected: return "Running"
        case .none: return "No checks"
        }
    }
}

struct ChecksBadge: View {
    var pr: PullRequest

    var body: some View {
        switch pr.checks {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Checks passed").accessibilityLabel("Checks passed")
        case .failure, .error: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Checks failed").accessibilityLabel("Checks failed")
        case .pending, .expected: Image(systemName: "clock.fill").foregroundStyle(.orange).help("Checks running").accessibilityLabel("Checks running")
        case .none: Image(systemName: "minus.circle").foregroundStyle(.secondary).help("No checks").accessibilityLabel("No checks")
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
            case .changesRequested: Chip(text: "Changes requested", color: .red)
            case .reviewRequired: Chip(text: "Review required", color: .orange)
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
        // A shape as well as a colour, so urgent reads without telling red from orange.
        case .urgent:
            Image(systemName: "exclamationmark.circle.fill").scaled(.caption).foregroundStyle(.red).accessibilityLabel("Urgent")
        case .warning: StatusDot(color: .orange, meaning: "Warning")
        case .info: StatusDot(color: .blue, meaning: "Info")
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
        .help(model.syncHelp)
    }
}

extension AppModel {
    /// The sync controls' tooltip: each failed source with its error, or what pressing does.
    var syncHelp: String {
        let errors = Source.allCases.compactMap { source in state.errors[source].map { "\(source.title): \($0)" } }
        if !errors.isEmpty { return errors.joined(separator: "\n") }
        return refreshing.isEmpty ? "Sync GitHub, Git and Jira now" : "Syncing…"
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

/// The general pasteboard, for the Copy presses in menus and panels.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A Copy press that says it worked: its title reads "Copied" for a moment after.
struct CopyButton: View {
    var title: String
    var text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : title) {
            Clipboard.copy(text)
            copied = true
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// The right-click menu of a pull request row: the ways out to GitHub and the clipboard, and its session.
struct PullRequestMenu: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        Button("Open on GitHub") { model.open(pr.url) }
        Button("Copy Link") { Clipboard.copy(pr.url) }
        Button("Copy Branch") { Clipboard.copy(pr.headRef) }
        Divider()
        if let job = model.state.claudeJobs(for: pr).first {
            Button("Attach to Session") { model.attach(job, for: pr) }
        } else {
            Button("Start Session") { model.startSession(for: pr) }.disabled(model.state.localRepo(for: pr) == nil)
        }
    }
}

extension View {
    /// Filled for the one press a screen leads with, bordered for the rest: six filled buttons are six focal points.
    @ViewBuilder func primaryStyle(_ prominent: Bool) -> some View {
        if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
}

/// Why the button beside it is dead, in words next to it rather than in a tooltip: a greyed-out press that does not
/// say why reads as broken.
struct DisabledReason: View {
    var text: String?

    var body: some View {
        if let text { Text(text).scaled(.caption).foregroundStyle(.secondary).lineLimit(1) }
    }
}

/// What a list shows when it has nothing to show: an icon, one sentence on why, and the one press that helps.
struct EmptyState: View {
    var icon: String?
    var text: String
    /// The raw reason, when there is one: selectable, and kept short.
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 4) {
                Text(text).scaled(.callout).foregroundStyle(.secondary)
                if let detail {
                    Text(detail).scaled(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled).help(detail)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action).controlSize(.small).padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Over a list whose last sync failed. The rows under it are the last good ones, so they stay; this says they are
/// stale, why, and offers the retry.
struct StaleBanner: View {
    @Environment(AppModel.self) private var model
    var source: Source

    var body: some View {
        if let error = model.state.errors[source] {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Out of date: \(error)").scaled(.caption).lineLimit(1).truncationMode(.tail).help(error)
                Spacer(minLength: 8)
                Button("Retry") { Task { await model.refresh(source) } }.controlSize(.small)
            }
            .padding(.vertical, 6)
        }
    }
}

extension AppModel {
    /// Opens Settings on one of its panes, for the empty states whose fix lives there.
    func openSettings(_ pane: SettingsPane) {
        settings.pane = pane
        showingSettings = true
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
                Text("Starting").scaled(.caption2).foregroundStyle(.secondary)
            case .running:
                ProgressView().controlSize(.mini)
                Text("Reviewing").scaled(.caption2).foregroundStyle(.secondary)
            case .posting:
                ProgressView().controlSize(.mini)
                Text("Posting draft").scaled(.caption2).foregroundStyle(.secondary)
            case .failed:
                Chip(text: "Failed", color: .red).help(status.run?.error ?? "")
            case .posted, nil:
                github
            }
            if status.headMoved {
                Chip(text: "New commits", color: .orange)
                    .help("The head moved since your draft's comments were written; GitHub marks the ones on changed lines outdated")
            }
            if status.reRequested {
                Chip(text: "Re-requested", color: .orange).help("Your review was requested again after you last submitted one")
            }
        }
    }

    @ViewBuilder private var github: some View {
        switch status.draft {
        case .pending(let comments, let claude):
            Chip(text: "Draft · \(comments)", color: .blue)
                .help("Your pending review on GitHub: \(comments) \(comments == 1 ? "comment" : "comments"), \(claude) of them Claude's. Only you can see it.")
        case .submitted(let state):
            Chip(text: Self.submittedTitle(state), color: .green).help("Your latest review on GitHub")
        case nil:
            if status.run?.phase == .posted {
                Chip(text: "No comments", color: .green).help(noCommentsHelp)
            }
        }
    }

    private var noCommentsHelp: String {
        let skipped = status.run?.skipped ?? 0
        return skipped == 0 ? "Claude found nothing to comment on" : "Nothing posted; \(skipped) could not be placed on this PR's lines"
    }

    private static func submittedTitle(_ state: String) -> String {
        switch state {
        case "APPROVED": return "Approved"
        case "CHANGES_REQUESTED": return "Changes requested"
        case "DISMISSED": return "Dismissed"
        default: return "Commented"
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
                Label { Text("Attach") } icon: { icon("terminal.fill", newest.isRunning ? .green : .accentColor) }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
            .help(failure ?? "\(jobs.count) background sessions on this PR")
        } else if let job = jobs.first {
            Button { model.attach(job, for: pr) } label: {
                Label { Text("Attach") } icon: { icon("terminal.fill", job.isRunning ? .green : .accentColor) }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
            .help(failure ?? "Attach to “\(job.name)” (\(job.state)) in Terminal")
        } else {
            // Words, not only a hollow or filled terminal: which one it is was a tooltip's secret.
            Button { model.startSession(for: pr) } label: {
                Label { Text("Start session") } icon: { icon("terminal", .secondary) }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
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
