import DeskCore
import SwiftUI

/// The PR page's account of the PR's flow: its stage, what the session is doing, and the press the stage waits for.
/// All of it is read off GitHub and the session on each refresh.
struct FlowSection: View {
    var pr: PullRequest
    var session: ClaudeJob
    var model: AppModel

    var body: some View {
        let stage = FlowStage.of(pr, session: session)
        PanelSection("Flow") {
            LabeledContent("Stage") { StageChip(stage: stage) }
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
            Text("Approve to start the self-review: /pre-pr where the repo has the review flow, reviewing-code elsewhere, up to three rounds, until no Important finding is left.")
                .scaled(.caption).foregroundStyle(.secondary)
            if let skill, !skill.isReady { ReviewSkillMark(skill: skill, showsText: true) }
            HStack {
                Spacer()
                let blocker = model.approveBlocker(pr)
                DisabledReason(text: blocker)
                Button("Approve") { model.approveDraft(pr) }
                    .buttonStyle(.borderedProminent).handCursor()
                    .disabled(blocker != nil)
            }
        case .fixesToCheck:
            Text("The self-review is done: its evidence and any threads it left open are on this page.")
                .scaled(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.mini) }
                Button("Approve") { model.approveFixes(pr) }
                    .buttonStyle(.borderedProminent).handCursor()
                    .disabled(busy)
                    .help("Marks the PR ready for review and asks \(model.config.reviewTeam) to review it")
            }
        case .inReview:
            Text("Waiting for a review from \(model.config.reviewTeam).").scaled(.caption).foregroundStyle(.secondary)
        case .threadsToReview:
            Text("Open threads wait on you: they are listed on this page.").scaled(.caption).foregroundStyle(.secondary)
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
        case .working, .selfReview, .fixing, .merged, .closed:
            EmptyView()
        }
    }

    private var mergeHint: String {
        if pr.mergeState == .dirty { return "Approved, but it conflicts with \(pr.baseRef): resolve that first." }
        if pr.checks.isRed { return "Approved, but CI failed: GitHub may refuse the merge until it passes." }
        if pr.checks.isPending { return "Approved. CI is still running, so GitHub may refuse the merge until it passes." }
        return "Approved. Merge squashes it into \(pr.baseRef)."
    }
}

/// The PR's stage in the list, with a mark when its session asks you something or the last press failed.
struct FlowStageCell: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        if let session = model.state.session(for: pr) {
            HStack(spacing: 4) {
                StageChip(stage: FlowStage.of(pr, session: session)).fixedSize()
                if session.state == "blocked" {
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                        .help("The session is asking you something")
                } else if let error = model.flowErrors[pr.url] {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(error)
                }
            }
        }
    }
}
