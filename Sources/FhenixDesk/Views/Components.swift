import DeskCore
import SwiftUI

struct Chip: View {
    var text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .scaled(.caption2.weight(.medium))
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

/// Sits beside the refresh button and zooms the window. macOS offers no system text size, so this is the
/// app's own — and it is remembered across launches.
struct TextSizeControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            step("minus", -1, "Smaller text", enabled: model.canZoomText.smaller)
            Text(percent)
                .scaled(.caption).monospacedDigit()
                .foregroundStyle(model.textScale == 1 ? .tertiary : .secondary)
                .frame(width: 38)
                .help("Text size")
            step("plus", 1, "Larger text", enabled: model.canZoomText.larger)
        }
    }

    private var percent: String { "\(Int((model.textScale * 100).rounded()))%" }

    private func step(_ icon: String, _ steps: Int, _ label: String, enabled: Bool) -> some View {
        Button { model.zoomText(steps) } label: {
            Image(systemName: icon).frame(width: 18, height: 18)
        }
        .disabled(!enabled)
        .help("\(label) (\(percent))")
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

struct PullRequestLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale: Double
    var pr: PullRequest
    var showRepo = true

    var body: some View {
        Button {
            model.open(pr.url)
        } label: {
            HStack(spacing: 8) {
                ChecksBadge(pr: pr)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title).lineLimit(1).scaled(.callout)
                    HStack(spacing: 6) {
                        Text(showRepo ? "\(pr.repoName)#\(pr.number)" : "#\(pr.number)").scaled(.caption).foregroundStyle(.secondary)
                        if let parent = model.state.stackParent(of: pr) {
                            Text("↑ #\(parent.number)").scaled(.caption).foregroundStyle(.secondary).help("Stacked on #\(parent.number)")
                        }
                        if let reason = model.state.rebaseReason(pr) {
                            Chip(text: "rebase: \(reason.text)", color: .orange)
                        }
                    }
                }
                Spacer(minLength: 4)
                ReviewBadge(pr: pr)
                Text(Format.age(pr.updatedAt)).scaled(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 36 * scale, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// Where a review stands, as chips: the phase, what it found, and what changed under it since.
struct ReviewStatusChip: View {
    var status: ReviewStatus
    var showCounts = true

    var body: some View {
        HStack(spacing: 4) {
            switch status.phase {
            case .queued, .preparing:
                ProgressView().controlSize(.mini)
                Text("starting").scaled(.caption2).foregroundStyle(.secondary)
            case .running:
                ProgressView().controlSize(.mini)
                Text("reviewing").scaled(.caption2).foregroundStyle(.secondary)
            case .submitting:
                ProgressView().controlSize(.mini)
                Text("sending").scaled(.caption2).foregroundStyle(.secondary)
            case .failed:
                Chip(text: "failed", color: .red)
            case .submitted:
                Chip(text: "submitted", color: .green)
            case .ready:
                if showCounts { counts }
            }
            if status.phase != .submitted, showCounts, status.counts.outdated > 0 {
                Chip(text: "\(status.counts.outdated) outdated", color: .secondary)
                    .help("The lines these point at changed in a later push")
            }
            if status.headMoved {
                Chip(text: "new commits", color: .orange)
                    .help("The head moved since the review; comments have been re-anchored")
            }
            if status.reRequested {
                Chip(text: "re-requested", color: .orange).help("Your review was requested again")
            }
        }
    }

    @ViewBuilder private var counts: some View {
        let counts = status.counts
        if counts.total == 0 {
            Chip(text: "no comments", color: .green).help("Claude found nothing to say")
        } else if counts.pending > 0 {
            Chip(text: "\(counts.pending) to review", color: counts.blocking > 0 ? .red : .orange)
        } else {
            Chip(text: "\(counts.approved) approved", color: .blue).help("Ready to send")
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
