import DeskCore
import SwiftUI

/// The PR page's account of the PR's flow: its stage, what the session is doing, and the press the stage waits for.
/// All of it is read off GitHub and the session on each refresh.
struct FlowSection: View {
    var pr: PullRequest
    var session: ClaudeJob
    var model: AppModel
    /// Approve on a self-reviewed draft without /pre-pr's label asks first.
    @State private var confirmingReady = false

    var body: some View {
        let stage = FlowStage.of(pr)
        PanelSection("Flow") {
            LabeledContent("Stage") { StageChip(stage: stage, sessionBusy: session.isBusy) }
            if let key = session.ticketKey { LabeledContent("Started from", value: key) }
            LabeledContent("Session") {
                HStack(spacing: 6) {
                    Text(session.state).foregroundStyle(.secondary)
                    Button("Attach") { model.attach(session, for: pr) }.controlSize(.small)
                }
            }
            if session.state == "blocked" {
                Text("The session is asking you something. Attach to answer it.").scaled(.caption).foregroundStyle(.orange)
            } else if session.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("The session is on it.").scaled(.caption).foregroundStyle(.secondary)
                }
            }
            stageContent(stage)
            if pr.state == .open, pr.mergeState == .dirty { fixRow(.fixConflict, problem: "It conflicts with \(pr.baseRef).") }
            if pr.state == .open, pr.checks.isRed { fixRow(.fixChecks, problem: "CI failed.") }
            if let error = model.flowErrors[pr.url] {
                Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func stageContent(_ stage: FlowStage) -> some View {
        let busy = model.busyFlows.contains(pr.url)
        switch stage {
        case .draft:
            let skill = model.state.reviewSkill(for: pr)
            Text("Approve to start the self-review: one /pre-pr run where the repo has the review flow, one reviewing-code pass elsewhere. It changes no code: its findings come back as threads on the PR, each with a suggested fix.")
                .scaled(.caption).foregroundStyle(.secondary)
            if let skill, !skill.has(skill.selfReview) { ReviewSkillMark(skill: skill, showsText: true) }
            HStack {
                Spacer()
                let blocker = model.approveBlocker(pr)
                DisabledReason(text: blocker)
                Button("Approve") { model.approveDraft(pr) }
                    .buttonStyle(.borderedProminent).handCursor()
                    .disabled(blocker != nil)
            }
        case .selfReviewed:
            if pr.isLocallyReviewed {
                Text("Self-reviewed: /pre-pr passed it, and its findings are threads on the PR.")
                    .scaled(.caption).foregroundStyle(.secondary)
            } else {
                // No label: /pre-pr left an Important finding open, or stopped before its label. Ready without it fails
                // the local-review-evidence check from Enforce on.
                Text("Self-reviewed, but without the local-reviewed label: an Important finding is open. Settle it with the session, or resolve its thread as your decision, then run /pre-pr again.")
                    .scaled(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.mini) }
                // A self-review still running may push again: the PR goes ready only once the session is done.
                let blocker = busy ? nil : session.isBusy ? "The session is busy" : nil
                DisabledReason(text: blocker)
                Button("Approve") { if pr.isLocallyReviewed { model.approveFixes(pr) } else { confirmingReady = true } }
                    .buttonStyle(.borderedProminent).handCursor()
                    .disabled(busy || blocker != nil)
                    .help("Marks the PR ready for review and asks \(model.config.reviewTeam) to review it")
            }
            .confirmationDialog(
                // Verbatim: a localized title prints the number as "1,082".
                Text(verbatim: "Mark #\(pr.number) ready without local-reviewed?"),
                isPresented: $confirmingReady
            ) {
                Button("Mark it ready anyway") { model.approveFixes(pr) }
            } message: {
                Text("/pre-pr has not passed it: an Important finding is open. From Enforce on, its local-review-evidence check fails without the label.")
            }
        case .inReview:
            Text("Waiting for a review from \(model.config.reviewTeam).").scaled(.caption).foregroundStyle(.secondary)
        case .approved:
            Text(mergeHint).scaled(.caption).foregroundStyle(pr.mergeState == .dirty || pr.checks.isRed ? .orange : .secondary)
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.mini) }
                let blocker = busy ? "Merging…" : pr.mergeBlocker
                if !busy { DisabledReason(text: blocker) }
                Button("Merge") { model.merge(pr) }
                    .buttonStyle(.borderedProminent).handCursor()
                    .disabled(blocker != nil)
                    .help(blocker ?? "Squash-merges the PR into \(pr.baseRef)")
            }
        case .working, .merged, .closed:
            EmptyView()
        }
    }

    /// A problem the session can fix, with the press that sends it the fix.
    private func fixRow(_ prompt: PromptID, problem: String) -> some View {
        let blocker = model.sendBlocker(pr)
        return HStack {
            Text(problem).scaled(.caption).foregroundStyle(.orange)
            Spacer()
            DisabledReason(text: blocker)
            Button("Fix it") { model.fix(prompt, for: pr) }
                .handCursor()
                .disabled(blocker != nil)
                .help("Sends the session \"\(prompt.title)\": it fixes and pushes, and asks you only for a decision it can't make")
        }
    }

    private var mergeHint: String {
        if pr.mergeState == .dirty { return "Approved, but it conflicts with \(pr.baseRef): resolve that first." }
        if pr.checks.isRed { return "Approved, but CI failed: GitHub may refuse the merge until it passes." }
        if pr.checks.isPending { return "Approved. CI is still running, so GitHub may refuse the merge until it passes." }
        return "Approved. Merge squashes it into \(pr.baseRef)."
    }
}

/// How many review threads are open on your PR, by who started them — /pre-pr, CodeRabbit, and each person — and the way
/// to them on GitHub, where they are read and answered.
struct ThreadsCard: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        let rows = pr.threads.byWho
        SideCard(title: "Open threads", count: pr.threads.count) {
            if rows.isEmpty {
                Text("None open.").foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.who) { row in LabeledContent(row.who, value: "\(row.count)") }
                Button("Read them on GitHub") { model.open(pr.url + "/files") }
                    .buttonStyle(.link).handCursor()
            }
        }
    }
}

/// The PR's stage in the list, with a mark when its session asks you something or the last press failed.
struct FlowStageCell: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        if let session = model.state.session(for: pr) {
            HStack(spacing: 4) {
                StageChip(stage: FlowStage.of(pr), sessionBusy: session.isBusy).fixedSize()
                if session.isRunning {
                    ProgressView().controlSize(.mini).help("The session is working")
                } else if session.state == "blocked" {
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                        .help("The session is asking you something")
                } else if let error = model.flowErrors[pr.url] {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(error)
                }
            }
        }
    }
}
