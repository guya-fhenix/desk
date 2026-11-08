import DeskCore
import SwiftUI

/// The PR page's account of the PR's flow: its stage, what the session is doing, and the press the stage waits for.
/// All of it is read off GitHub and the session on each refresh.
struct FlowSection: View {
    var pr: PullRequest
    /// The background session carrying the PR, when it has one.
    var session: ClaudeJob?
    var model: AppModel
    /// Mark ready on a draft /pre-pr has not passed asks first.
    @State private var confirmingReady = false

    var body: some View {
        let stage = FlowStage.of(pr)
        PanelSection("Flow") {
            LabeledContent("Stage") { StageChip(stage: stage, sessionBusy: session?.isBusy ?? false) }
            if let key = session?.ticketKey { LabeledContent("Started from", value: key) }
            // The session itself, its state and Attach, is the page's header button; here only what it means for the flow.
            if session?.state == "blocked" {
                Text("The session is asking you something: attach to it at the top to answer.").scaled(.caption).foregroundStyle(.orange)
            } else if session?.isRunning == true {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Its session is working (on this PR or something else); Run /pre-pr and Mark ready wait until it’s done.").scaled(.caption).foregroundStyle(.secondary)
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
            // Two presses, both yours and in any order: /pre-pr's run, which posts its findings and adds the
            // local-reviewed label once no Important one is open, and Mark ready.
            let skill = model.state.reviewSkill(for: pr)
            switch PrePRStatus.of(pr) {
            case .notRun:
                Text("/pre-pr hasn't run on it.").scaled(.caption).foregroundStyle(.secondary)
            case .passed:
                Text("/pre-pr passed it: the local-reviewed label is on.").scaled(.caption).foregroundStyle(.secondary)
            case .importantOpen:
                // Ready without the label fails the local-review-evidence check from Enforce on.
                Text("/pre-pr left an Important finding open, so there is no local-reviewed label. Settle it with the session, or resolve its thread as your decision, then run /pre-pr again.")
                    .scaled(.caption).foregroundStyle(.orange)
            }
            if let skill, !skill.has(skill.selfReview) { ReviewSkillMark(skill: skill, showsText: true) }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.mini) }
                let blocker = busy ? nil : model.prePRBlocker(pr)
                DisabledReason(text: blocker)
                RunPrePRButton(startsSession: session == nil) { model.runPrePR(pr) }
                    .disabled(busy || blocker != nil)
                // A /pre-pr run still going may push again: the PR goes ready only once the session is done.
                Button("Mark ready") { if pr.isLocallyReviewed { model.markReady(pr) } else { confirmingReady = true } }
                    .handCursor()
                    .disabled(busy || session?.isBusy == true)
                    .help("Marks the PR ready for review and asks \(model.config.reviewTeam) to review it")
            }
            .confirmationDialog(
                // Verbatim: a localized title prints the number as "1,082".
                Text(verbatim: "Mark #\(pr.number) ready without local-reviewed?"),
                isPresented: $confirmingReady
            ) {
                Button("Mark it ready anyway") { model.markReady(pr) }
            } message: {
                Text("/pre-pr has not passed it. From Enforce on, the local-review-evidence check fails without its label.")
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

/// Run /pre-pr with an ⓘ in its label: resting the pointer on it opens what /pre-pr does. A popover, not `.help`: the
/// system tooltip comes late, or never, in this accessory app's window. AppKit draws the button, so the ⓘ inside it
/// has no hover of its own; the whole button opens it.
private struct RunPrePRButton: View {
    var startsSession: Bool
    var action: () -> Void
    @State private var hovering = false
    @State private var explaining = false

    private var explanation: String {
        "/pre-pr reviews the PR once and changes no code: its findings come back as threads on the PR, each with a "
            + "suggested fix, and it adds the local-reviewed label once no Important finding is open. "
            + (startsSession ? "The PR has no session, so this starts one on its branch." : "The PR's session runs it.")
    }

    var body: some View {
        Button {
            explaining = false
            action()
        } label: {
            HStack(spacing: 4) {
                Text("Run /pre-pr")
                Image(systemName: "info.circle")
            }
        }
        .handCursor()
        .onHover { hovering = $0 }
        .task(id: hovering) {
            // A short rest first, so crossing it on the way to Mark ready opens nothing.
            guard hovering, (try? await Task.sleep(for: .milliseconds(350))) != nil else {
                explaining = false
                return
            }
            explaining = true
        }
        .popover(isPresented: $explaining, arrowEdge: .bottom) {
            Text(explanation).scaled(.callout).padding(12).frame(width: 300).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityHint(explanation)
    }
}

/// How many review threads are open on your PR — in the row's orange, the same count — then by who started them:
/// /pre-pr, CodeRabbit, and each person. And the way to them on GitHub, where they are read and answered.
struct ThreadsCard: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        let rows = pr.threads.byWho
        SideCard(title: "Open threads") {
            if pr.unresolvedThreads == 0 {
                Text("None open.").foregroundStyle(.secondary)
            } else {
                Text("\(pr.unresolvedThreads) unresolved thread\(pr.unresolvedThreads == 1 ? "" : "s")").foregroundStyle(.orange)
                ForEach(rows, id: \.who) { row in LabeledContent(row.who, value: "\(row.count)") }
                Button("Read them on GitHub") { model.open(pr.url + "/files") }
                    .buttonStyle(.link).handCursor()
            }
        }
    }
}

/// The PR's labels as GitHub has them: CodeRabbit's `risk:*` and `needs-human`, the `area:*` floors, `local-reviewed`.
struct LabelsCard: View {
    var pr: PullRequest

    var body: some View {
        SideCard(title: "Labels", count: pr.labels.isEmpty ? nil : pr.labels.count) {
            if pr.labels.isEmpty {
                Text("None.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pr.labels.sorted(), id: \.self) { Chip(text: $0) }
                }
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
