import DeskCore
import SwiftUI

/// The PR details panel's account of the PR's flow: where it stands, what the session is doing, and the press
/// the stage is waiting for.
struct FlowSection: View {
    var flow: Flow
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        let job = model.state.job(id: flow.jobId)
        Section("Flow") {
            LabeledContent("Stage") {
                HStack(spacing: 6) {
                    StageChip(stage: flow.stage)
                    if flow.paused { Chip(text: "paused", color: .secondary) }
                }
            }
            if let key = flow.ticketKey { LabeledContent("Started from", value: key) }
            LabeledContent("Session") {
                HStack(spacing: 6) {
                    Text(job?.state ?? "gone").foregroundStyle(.secondary)
                    Button("Attach") { model.attach(jobId: flow.jobId, errorKey: pr.url) }.controlSize(.small).disabled(job == nil)
                }
            }
            sessionLine(job)
            stageContent
            Toggle("Pause", isOn: Binding(get: { flow.paused }, set: { model.setPaused(flow, $0) }))
                .help("While paused the app sends this session nothing, and you drive it yourself.")
            if let note = flow.note {
                Text(note).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    /// What is between the session and the next step, if anything.
    @ViewBuilder private func sessionLine(_ job: ClaudeJob?) -> some View {
        if job == nil {
            Text("The session is gone. Start a new one under Background session to carry on from this stage.")
                .scaled(.caption).foregroundStyle(.orange)
        } else if job?.state == "blocked" {
            Text("The session is asking you something. Attach to answer it.").scaled(.caption).foregroundStyle(.orange)
        } else if let pending = flow.pending {
            Text(flow.paused
                ? "\(pending.title) is queued and goes out once you unpause."
                : pending.isAutomatic
                ? "\(pending.title) is queued: it goes out once the session has been idle for 10 minutes."
                : "\(pending.title) is queued: it goes out when the session finishes what it is doing.")
                .scaled(.caption).foregroundStyle(.secondary)
        } else if let awaiting = flow.awaiting {
            if FlowEngine.isStalled(flow, job: job) {
                Text("The session stopped without writing its summary of \(awaiting.title.lowercased()).")
                    .scaled(.caption).foregroundStyle(.orange)
                HStack {
                    Button("Send again") { model.resendAwaited(flow) }
                    Button("Continue without it") { model.skipAwaited(flow) }
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("\(awaiting.title) — the session is on it.").scaled(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var stageContent: some View {
        let busy = model.busyFlows.contains(flow.id)
        switch flow.stage {
        case .draft:
            let skill = model.state.reviewSkill(for: pr)
            Text("Approve to start the self-review: reviewing-code, up to three rounds, until no High or Medium finding is left.")
                .scaled(.caption).foregroundStyle(.secondary)
            if let skill, !skill.isReady { ReviewSkillMark(skill: skill, showsText: true) }
            HStack {
                Spacer()
                Button("Approve") { model.approveDraft(flow) }
                    .buttonStyle(.borderedProminent)
                    .disabled(skill?.isReady != true || flow.paused || flow.pending != nil || flow.awaiting != nil)
            }
        case .fixesToCheck:
            SelfReviewList(review: flow.selfReview)
            HStack {
                if let base = flow.baseSha, !base.isEmpty {
                    Button("View changes") { model.open("\(pr.url)/files/\(base)..\(pr.headSha)") }
                        .help("GitHub's diff of the commits since the self-review started")
                }
                Spacer()
                if busy { ProgressView().controlSize(.mini) }
                Button("Approve") { model.approveFixes(flow) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || flow.paused)
                    .help("Marks the PR ready for review and asks \(model.config.reviewTeam) to review it")
            }
        case .inReview:
            Text("Waiting for a review from \(model.config.reviewTeam).").scaled(.caption).foregroundStyle(.secondary)
        case .working, .selfReview, .fixesProposed, .applying, .approved, .merged:
            EmptyView()
        }
    }
}

/// What the self-review found and what it did about each finding.
private struct SelfReviewList: View {
    var review: SelfReview?

    var body: some View {
        if let review {
            Text(summary(review)).scaled(.caption).foregroundStyle(review.clean == false ? .orange : .secondary)
            ForEach(Array(review.findings.enumerated()), id: \.offset) { _, finding in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Chip(text: finding.severity.capitalized, color: color(finding.severity))
                        Text(finding.line.map { "\(finding.file):\($0)" } ?? finding.file)
                            .scaled(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if finding.fixed == false { Chip(text: "left", color: .secondary) }
                    }
                    Text(finding.problem).scaled(.caption).fixedSize(horizontal: false, vertical: true)
                    Text("→ \(finding.fix)").scaled(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .textSelection(.enabled)
            }
        } else {
            Text("No summary from the self-review. View changes shows what it did.").scaled(.caption).foregroundStyle(.secondary)
        }
    }

    private func summary(_ review: SelfReview) -> String {
        let rounds = review.rounds.map { "\($0) \($0 == 1 ? "round" : "rounds")" } ?? "Done"
        let state = review.clean == false ? "High or Medium findings are left" : "no High or Medium finding left"
        return "\(rounds) · \(review.findings.count) \(review.findings.count == 1 ? "finding" : "findings") · \(state)"
    }

    private func color(_ severity: String) -> Color {
        switch severity.lowercased() {
        case "high": return .red
        case "medium": return .orange
        default: return .secondary
        }
    }
}

/// The PR's stage in the table, with what stands between it and the next step.
struct FlowStageCell: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        if let flow = model.state.flow(for: pr) {
            HStack(spacing: 4) {
                StageChip(stage: flow.stage).fixedSize()
                if model.state.job(id: flow.jobId)?.state == "blocked" {
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                        .help("The session is asking you something")
                } else if flow.note != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(flow.note ?? "")
                } else if flow.paused {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary).help("Paused: the app sends this session nothing")
                }
            }
        } else {
            Text("–").foregroundStyle(.secondary).help("Not in a flow: start a session on it to carry it from its current stage")
        }
    }
}
