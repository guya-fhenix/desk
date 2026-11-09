import DeskCore
import SwiftUI

/// A status tag: a small tinted rectangle, the way the reference app marks "ready" or "failing".
struct Chip: View {
    var text: String
    var color: Color = .secondary
    /// A spinner before the text, for a state still under way.
    var spinning = false

    var body: some View {
        HStack(spacing: 5) {
            if spinning { ProgressView().controlSize(.mini).tint(color) }
            Text(text)
        }
            .scaled(.secondary)
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

/// A flow's stage. Orange when it waits on your press, so the column reads as a to-do list; a session at work means it
/// does not wait on you yet.
struct StageChip: View {
    var stage: FlowStage
    var sessionBusy = false

    var body: some View {
        let waits = stage.waitsOnYou && !sessionBusy
        Chip(text: stage.title, color: waits ? .orange : stage == .merged ? .purple : stage == .closed ? .secondary : .blue)
    }
}

/// What one of your PRs waits on, as its row's one pill: red when the move is yours to fix, green when it is yours to
/// merge, blue while it waits on someone else, grey for a draft.
struct StatePill: View {
    var state: RowState

    var body: some View {
        let color: Color = switch state.move {
        case .yoursToFix: .red
        case .yoursToMerge: .green
        case .others: .blue
        case .draft: .secondary
        }
        Text(state.title)
            .scaled(.secondary.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.45)))
            .fixedSize()
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

/// The checks as a sentence in a pill, "All checks passed · 11 checks", for a page's status line, which has the room a
/// row's icon does not.
struct ChecksPill: View {
    var pr: PullRequest

    var body: some View {
        HStack(spacing: 6) {
            ChecksBadge(pr: pr).accessibilityHidden(true)
            Text(sentence)
            if pr.checkCount > 0 {
                Text("·  \(pr.checkCount) \(pr.checkCount == 1 ? "check" : "checks")").foregroundStyle(.secondary)
            }
        }
        .pill()
        .accessibilityElement(children: .combine)
    }

    private var sentence: String {
        switch pr.checks {
        case .success: return "All checks passed"
        case .failure, .error: return "Checks failed"
        case .pending, .expected: return "Checks running"
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
        .buttonStyle(.plain).handCursor()
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
    var text: String
    /// What it copies, for the tooltip and VoiceOver.
    var what: String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").scaled(.caption)
        }
        .buttonStyle(IconButtonStyle())
        .help(copied ? "Copied" : "Copy \(what)")
        .accessibilityLabel(copied ? "Copied" : "Copy \(what)")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

extension View {
    /// The session button's look: filled and full size as a page's action, plain and small elsewhere.
    @ViewBuilder fileprivate func sessionStyle(_ prominent: Bool, menu: Bool = false) -> some View {
        if prominent {
            if menu { menuStyle(.button).buttonStyle(.borderedProminent).handCursor() } else { buttonStyle(.borderedProminent).handCursor() }
        } else {
            if menu { menuStyle(.borderlessButton).controlSize(.small).handCursor() } else { buttonStyle(.borderless).controlSize(.small).handCursor() }
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
        // A merged PR has no branch left to work on.
        if pr.state != .merged {
            Divider()
            if let job = model.state.claudeJobs(for: pr).first {
                Button("Attach to Session") { model.attach(job, for: pr) }
            } else {
                Button("Start Session") { model.startSession(for: pr) }.disabled(model.state.localRepo(for: pr) == nil)
            }
        }
    }
}

extension View {
    /// Filled for the one press a screen leads with, bordered for the rest: six filled buttons are six focal points.
    @ViewBuilder func primaryStyle(_ prominent: Bool) -> some View {
        if prominent { buttonStyle(.borderedProminent).handCursor() } else { buttonStyle(.bordered).handCursor() }
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

/// Where your review stands on GitHub, as chips — your draft, or the review you sent — and what changed since.
struct ReviewStatusChip: View {
    var status: ReviewStatus

    var body: some View {
        HStack(spacing: 4) {
            switch status.draft {
            case .pending(let comments):
                Chip(text: "Draft · \(comments)", color: .blue)
                    .help("Your pending review on GitHub: \(comments) \(comments == 1 ? "comment" : "comments"). Only you can see it.")
            case .submitted(let state):
                Chip(text: Self.submittedTitle(state), color: .green).help("Your latest review on GitHub")
            case nil:
                EmptyView()
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

    private static func submittedTitle(_ state: ReviewState) -> String {
        switch state {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .dismissed: return "Dismissed"
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
    /// Filled and full size, as a page's own action; plain and small where it sits among other things.
    var prominent = false

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
            .menuIndicator(.hidden).fixedSize()
            .sessionStyle(prominent, menu: true)
            .labelStyle(.titleAndIcon)
            .help(failure ?? "\(jobs.count) background sessions on this PR")
        } else if let job = jobs.first {
            Button { model.attach(job, for: pr) } label: {
                Label { Text("Attach") } icon: { icon("terminal.fill", job.isRunning ? .green : .accentColor) }
            }
            .sessionStyle(prominent)
            .labelStyle(.titleAndIcon)
            .help(failure ?? "Attach to “\(job.name)” (\(job.state)) in Desk’s terminal panel")
        } else {
            // Words, not only a hollow or filled terminal: which one it is was a tooltip's secret.
            Button { model.startSession(for: pr) } label: {
                Label { Text("Start session") } icon: { icon("terminal", .secondary) }
            }
            .sessionStyle(prominent)
            .labelStyle(.titleAndIcon)
            .disabled(model.state.localRepo(for: pr) == nil)
            .help(failure ?? startHelp)
        }
    }

    /// The last failure on this PR's button, which takes over the tooltip until the next press works.
    private var failure: String? { model.sessionErrors[pr.url] }

    /// Green while a session is running, the accent colour for one that has finished, grey for the button
    /// that would start the first — and red once a press has failed, whichever it was. On a filled button it takes
    /// the button's own text colour: none of those reads on the accent fill.
    @ViewBuilder private func icon(_ name: String, _ tint: Color) -> some View {
        if prominent {
            Image(systemName: name)
        } else {
            Image(systemName: name).foregroundStyle(failure == nil ? tint : .red)
        }
    }

    private var startHelp: String {
        guard model.state.localRepo(for: pr) != nil else { return "No local clone of \(pr.repo) to start a session in" }
        return "Start a background Claude session on \(pr.headRef)"
    }
}

/// Where a ticket's pull requests say it should be: a suggested move, which waits for your Move on the Jira screen,
/// the ticket's page or Up Next. A spinner while the move runs, red when Jira refused it. It names the pull requests
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
        return "\(drift.because), so \(drift.ticket.key) should be “\(drift.target)”. Suggested: it moves when you press Move."
    }
}

extension TicketDrift {
    /// The pull requests behind the suggestion and where they stand: "cofhe#1082 open for review".
    var because: String {
        let prs = pullRequests.map { "\($0.repoName)#\($0.number)" }.joined(separator: ", ")
        return stage == .done ? "\(prs) merged" : "\(prs) open for review"
    }
}

/// Checks, review decision and merge state in one cell; the inspector spells each out. Each chip sits in a
/// column as wide as its longest label, so down a list the three line up whatever the chip says or the text size.
struct PullRequestStatus: View {
    var pr: PullRequest

    var body: some View {
        HStack(spacing: 5) {
            ChecksBadge(pr: pr)
            column(widest: ["Changes requested", "Review required"]) { ReviewBadge(pr: pr) }
            column(widest: ["Conflicts", "Unstable"]) { MergeBadge(pr: pr) }
        }
    }

    private func column(widest: [String], @ViewBuilder chip: () -> some View) -> some View {
        ZStack(alignment: .leading) {
            ForEach(widest, id: \.self) { Chip(text: $0).hidden() }
            chip()
        }
    }
}

/// A PR page's Checks card: one line that sums up every check on its head commit, "✓ 14 passed, 2 skipped", and under it
/// the press that lists them all. Fetched when the page shows the PR, again when its head or overall state moves, and
/// every 20 s while a job is still running, since one finishing leaves the overall state pending until the last.
struct WorkflowsSection: View {
    var pr: PullRequest
    var model: AppModel
    /// The PR these were fetched for: the page keeps this view as it moves to another PR.
    @State private var loaded: (url: String, checks: [PullRequestCheck])?
    @State private var error: String?
    @State private var expanded = false

    var body: some View {
        let checks = loaded.flatMap { $0.url == pr.url ? $0.checks : nil }
        SideCard(title: "Checks") {
            if let checks {
                if checks.isEmpty {
                    Text("No checks on the latest commit.").foregroundStyle(.secondary)
                } else {
                    Button(expanded ? "Hide them" : "Show all \(checks.count)") { expanded.toggle() }
                        .buttonStyle(.link).handCursor()
                    if expanded { CheckList(checks: checks, model: model) }
                }
            } else if let error {
                Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        } trailing: {
            if let checks {
                if !checks.isEmpty {
                    let summary = CheckList.summary(checks)
                    HStack(spacing: 5) {
                        ChecksBadge(pr: pr).accessibilityHidden(true)
                        Text(summary).lineLimit(1)
                    }
                    .scaled(.secondary)
                    .help(summary)
                }
            } else if error == nil {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(pr.url) \(pr.headSha) \(pr.checks.rawValue)") {
            error = nil
            while !Task.isCancelled {
                do {
                    loaded = (pr.url, try await model.checks(for: pr))
                } catch {
                    if !Task.isCancelled { self.error = "Couldn't load the checks: \(error)" }
                    return
                }
                guard loaded?.checks.contains(where: { $0.outcome == .running }) == true else { return }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }
}

/// How long a check ran, or has been running: "5s", "29m 58s"; nil before it started.
private func elapsed(_ check: PullRequestCheck) -> String? {
    guard let start = check.startedAt else { return nil }
    return Duration.seconds(max((check.completedAt ?? Date()).timeIntervalSince(start), 0))
        .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
}

/// Every check in one list, PR Cockpit's way: a heading per outcome, worst first, and under it each check as
/// "Workflow / job" with how it ended under that; a failed one also says where it stopped and what it reported.
private struct CheckList: View {
    var checks: [PullRequestCheck]
    var model: AppModel

    var body: some View {
        let byOutcome = Dictionary(grouping: checks, by: \.outcome).sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: 16) {
            ForEach(byOutcome, id: \.key) { outcome, checks in
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(checks.count) \(Self.word(outcome))".uppercased())
                        .scaled(.caption.weight(.medium))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    // By workflow, the checks no workflow ran last, as GitHub lists them.
                    ForEach(checks.sorted { ($0.workflow ?? "\u{10FFFF}", $0.name) < ($1.workflow ?? "\u{10FFFF}", $1.name) }) {
                        CheckEntry(check: $0, model: model)
                    }
                }
            }
        }
    }

    /// "11 passed", or "2 failed, 9 passed".
    static func summary(_ checks: [PullRequestCheck]) -> String {
        Dictionary(grouping: checks, by: \.outcome).sorted { $0.key < $1.key }
            .map { "\($0.value.count) \($0.key.word)" }.joined(separator: ", ")
    }

    static func word(_ outcome: PullRequestCheck.Outcome) -> String {
        outcome == .passed ? "successful" : outcome.word
    }
}

/// One check of the list: its dot, "Workflow / job", which opens its log, and how it ended; under a failed one, the
/// step it stopped at and the errors it reported.
private struct CheckEntry: View {
    var check: PullRequestCheck
    var model: AppModel
    @Environment(\.textScale) private var scale

    var body: some View {
        // The dot's middle on the middle of the first line's capitals, as the page title's icons are.
        let lift = (AppTextStyle.body.size * scale).rounded() * 0.35
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(color: color, meaning: check.outcome.word)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
            VStack(alignment: .leading, spacing: 2) {
                Button { model.open(check.url) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text([check.workflow, check.name].compactMap { $0 }.joined(separator: " / "))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(ending).scaled(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).handCursor()
                .disabled(check.url == nil)
                .help(check.url == nil ? "" : "Open its log on GitHub")
                Group {
                    if let step = check.failedStep { Text("Failed at “\(step)”").foregroundStyle(.red) }
                    ForEach(check.errors, id: \.self) { Text($0).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                .scaled(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Successful in 5s", "Failed in 29m 58s", "Running for 3m"; the bare word when it never started.
    private var ending: String {
        let time = elapsed(check)
        switch check.outcome {
        case .passed: return time.map { "Successful in \($0)" } ?? "Successful"
        case .failed: return time.map { "Failed in \($0)" } ?? "Failed"
        case .running: return time.map { "Running for \($0)" } ?? "Queued"
        case .cancelled: return time.map { "Cancelled after \($0)" } ?? "Cancelled"
        case .neutral: return time.map { "Neutral in \($0)" } ?? "Neutral"
        case .skipped: return "Skipped"
        }
    }

    private var color: Color {
        switch check.outcome {
        case .passed: return .green
        case .failed: return .red
        case .running: return .orange
        case .cancelled, .neutral, .skipped: return .secondary
        }
    }
}

extension PullRequestCheck.Outcome {
    /// The outcome in a word: "failed", "running", "passed".
    var word: String {
        switch self {
        case .failed: return "failed"
        case .running: return "running"
        case .cancelled: return "cancelled"
        case .passed: return "passed"
        case .neutral: return "neutral"
        case .skipped: return "skipped"
        }
    }
}

/// A PR's description as GitHub renders it, or a line saying there is none.
struct PullRequestDescription: View {
    var pr: PullRequest

    var body: some View {
        if pr.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("No description.").foregroundStyle(.secondary)
        } else {
            MarkdownText(text: pr.body).textSelection(.enabled)
        }
    }
}

/// A PR page's headline: its title, editable on your own PR, with GitHub's mark beside it to open it there — on the
/// Files tab for a review, where your draft is; under it the repo, author and branches, with a copy button for the
/// branch.
struct PageHeadline: View {
    var pr: PullRequest
    var model: AppModel
    /// Where GitHub's mark goes: the PR, or for a review its Files tab, where your draft is.
    var gitHub: String
    var editable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditableTitle(prefix: "#\(pr.number)", title: pr.title, what: "the PR", editable: editable) {
                await model.retitle(pr, to: $0)
            } trailing: {
                Button { model.open(gitHub) } label: {
                    HStack(spacing: 3) {
                        GitHubMark()
                        Image(systemName: "arrow.up.right").scaled(.caption)
                    }
                }
                .buttonStyle(IconButtonStyle())
                .help("Open on GitHub")
                .accessibilityLabel("Open on GitHub")
            }
            HStack(spacing: 6) {
                Text("\(pr.repoName) · \(pr.author) · \(pr.baseRef) ← \(pr.headRef)")
                    .scaled(.secondary.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                CopyButton(text: pr.headRef, what: "the branch name")
            }
        }
    }
}

/// A page's title with the number or key it goes by set apart before it, and, when `editable`, a pencil on hover that
/// turns it into a field: Return saves it through `save`, Esc puts it back, the error if any under it. `trailing` is
/// what sits beside it, such as the mark that opens it on GitHub or in Jira.
struct EditableTitle<Trailing: View>: View {
    var prefix: String
    var title: String
    /// What it is the title of, for the pencil's tooltip: "the PR", "the ticket".
    var what: String
    var editable: Bool
    /// A page's title size, or a panel's smaller one.
    var style: AppTextStyle = .title
    /// Saves the new title; why it failed, or nil.
    var save: (String) async -> String?
    @ViewBuilder var trailing: Trailing
    @Environment(\.focusPage) private var focusPage
    @Environment(\.textScale) private var scale
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editing { field } else { headline }
            if let error { Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private var headline: some View {
        // Puts an icon's middle on the middle of the title's capitals, half a cap height above its baseline; on the
        // baseline itself, as an icon's own baseline is, it hung low. SF's capitals are 0.7 of the point size.
        let lift = (style.size * scale).rounded() * 0.35
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            // The number or key is GitHub's or Jira's, not part of the title, so it reads as a label beside it.
            (Text(verbatim: prefix.isEmpty ? "" : "\(prefix) ").foregroundStyle(.secondary) + Text(title))
                .scaled(style)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if editable {
                Button(action: start) { Image(systemName: "pencil").scaled(.secondary) }
                    .buttonStyle(IconButtonStyle())
                    // Kept in place while hidden, so the title does not shift when the pointer arrives; VoiceOver
                    // still finds it.
                    .opacity(hovering ? 1 : 0)
                    .help("Rename \(what)")
                    .accessibilityLabel("Rename \(what)")
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
            }
            trailing.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + lift }
        }
        // The whole row, gaps included: without it the space between the title's end and the pencil was outside, the
        // pencil faded on the way to it, and a faded button takes no click.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var field: some View {
        HStack(spacing: 6) {
            TextField("Title", text: $draft)
                .textFieldStyle(.plain)
                .scaled(style)
                .focused($fieldFocused)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
                .disabled(saving)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1.5))
            if saving {
                ProgressView().controlSize(.small)
            } else {
                Button(action: commit) { KeyCap(key: "↩") }.buttonStyle(.plain).handCursor().help("Save (Return)")
                Button(action: cancel) { KeyCap(key: "Esc") }.buttonStyle(.plain).handCursor().help("Cancel (Esc)")
            }
        }
    }

    private func start() {
        draft = title
        error = nil
        editing = true
        // Once the field is on screen; focusing it selects the whole title, ready to be typed over.
        Task {
            await Task.yield()
            fieldFocused = true
        }
    }

    private func cancel() {
        editing = false
        error = nil
        focusPage()
    }

    private func commit() {
        let new = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != title else { return cancel() }
        saving = true
        Task {
            error = await save(new)
            saving = false
            if error == nil {
                editing = false
                focusPage()
            }
        }
    }
}

/// A ticket's description, editable in place: Jira takes the markdown it reads as. Not offered for a description
/// holding what that markdown cannot carry — mentions, images, panels — since saving would drop them; Jira is the
/// place to edit those.
struct TicketDescription: View {
    var ticket: Ticket
    var model: AppModel

    var body: some View {
        EditableDescription(
            text: ticket.description, editable: ticket.descriptionEditable,
            editHelp: "Edit the description; saving writes it to Jira",
            lockedHelp: "It has mentions, images or panels that saving from here would drop: edit it in Jira"
        ) {
            await model.editTicket(ticket, description: $0)
        } rendered: {
            if ticket.description.isEmpty {
                Text("No description.").foregroundStyle(.secondary)
            } else {
                MarkdownText(text: ticket.description)
            }
        }
    }
}

/// A description with Edit beside its heading: a box holding its markdown, where ⌘↩ or Save writes it and Esc or
/// Cancel puts it back. A ticket's, and your own PR's.
struct EditableDescription<Rendered: View>: View {
    var text: String
    var editable: Bool
    var editHelp: String
    var lockedHelp: String
    /// Writes the edit; why it failed, or nil.
    var save: (String) async -> String?
    @ViewBuilder var rendered: Rendered
    @Environment(\.focusPage) private var focusPage
    @State private var editing = false
    @State private var draft = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Description").scaled(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if !editing {
                    Button("Edit", action: start)
                        .controlSize(.small)
                        .handCursor()
                        .disabled(!editable)
                        .help(editable ? editHelp : lockedHelp)
                }
            }
            if editing {
                TextEditor(text: $draft)
                    .scaled(.body)
                    .scrollContentBackground(.hidden)
                    .disabled(saving)
                    // A fixed height, the text scrolling inside: left to grow, the editor measures its text only on the
                    // first click and jumps taller, which carries Cancel out from under that very click.
                    .frame(height: 400)
                    .padding(8)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 1.5))
                HStack(spacing: 8) {
                    // Verbatim: the hint shows the syntax, so it must not be rendered as markdown itself.
                    Text(verbatim: "Markdown: # headings, - lists, **bold**, `code`, [links](https://…)")
                        .scaled(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    if saving { ProgressView().controlSize(.small) }
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).disabled(saving)
                    Button("Save", action: commit)
                        .buttonStyle(.borderedProminent).handCursor()
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(saving || draft == text)
                }
                if let error { Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled) }
            } else {
                rendered
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func start() {
        draft = text
        error = nil
        editing = true
    }

    private func cancel() {
        guard !saving else { return }
        editing = false
        error = nil
        focusPage()
    }

    private func commit() {
        saving = true
        Task {
            error = await save(draft)
            saving = false
            if error == nil {
                editing = false
                focusPage()
            }
        }
    }
}

/// GitHub's mark, from its SVG outline; a template, so it takes the text colour.
struct GitHubMark: View {
    var body: some View {
        Image(nsImage: Self.mark).resizable().scaledToFit().frame(width: 14, height: 14)
    }

    private static let mark: NSImage = {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill-rule="evenodd" d="M8 0C3.58 0 0 \
            3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94\
            -.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52\
            .28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 \
            2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56\
            .82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55\
            .38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>
            """
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}

/// An icon that is a button: faint until the pointer is on it, then on a raised square, as PR Cockpit's are.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { IconButtonBody(configuration: configuration) }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(5)
            .background(hovering || configuration.isPressed ? Theme.raised : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(hovering ? Theme.controlBorder : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .handCursor()
    }
}

/// Where the PR's background session stands, in place of the press that starts one: what it is doing, and a click
/// attaches to it. With more than one session on the PR, an arrow beside it lists them all, newest first, to attach
/// another. With no session, the press to start one.
struct SessionStatus: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        let jobs = model.state.claudeJobs(for: pr)
        if let newest = jobs.first {
            // One text and an icon: a menu button keeps no more of its label than that.
            let label = Label("Session · \(newest.state)", systemImage: newest.isRunning ? "terminal.fill" : "terminal")
                .labelStyle(.titleAndIcon)
            Group {
                if jobs.count > 1 {
                    Menu {
                        ForEach(jobs) { job in
                            Button("Attach to \(job.name) — \(job.state)") { model.attach(job, for: pr) }
                        }
                    } label: {
                        label
                    } primaryAction: {
                        model.attach(newest, for: pr)
                    }
                    .menuStyle(.button)
                } else {
                    Button { model.attach(newest, for: pr) } label: { label }
                }
            }
            .handCursor()
            .fixedSize()
            .help("“\(newest.name)”, \(newest.state). Click to attach it in Desk’s terminal panel"
                + (jobs.count > 1 ? "; the arrow lists the other sessions on this PR" : ""))
        } else {
            ClaudeSessionButton(pr: pr, model: model, prominent: true).fixedSize()
        }
    }
}
