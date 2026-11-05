import DeskCore
import SwiftUI

/// The PR page's account of the PR's flow: its stage, what the session is doing, and the press the stage waits for.
/// All of it is read off GitHub and the session on each refresh.
struct FlowSection: View {
    var pr: PullRequest
    var session: ClaudeJob
    var model: AppModel

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
            Text("Approve to start the self-review: one /pre-pr run where the repo has the review flow, one reviewing-code pass elsewhere. It changes no code: its findings come back as threads with suggested fixes, for your notes and Apply.")
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
        case .selfReviewed:
            Text("Self-reviewed: its evidence and any threads it left open are on this page.")
                .scaled(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.mini) }
                // A self-review still running may push again: the PR goes ready only once the session is done.
                let blocker = busy ? nil : session.isBusy ? "The session is busy" : nil
                DisabledReason(text: blocker)
                Button("Approve") { model.approveFixes(pr) }
                    .buttonStyle(.borderedProminent).handCursor()
                    .disabled(busy || blocker != nil)
                    .help("Marks the PR ready for review and asks \(model.config.reviewTeam) to review it")
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

/// Your PR's open review threads, grouped by who started them — /pre-pr, CodeRabbit, people — the most severe first, each
/// with a note of what you want done with it. Apply sends the noted ones to the PR's session, which makes the changes,
/// replies in each thread and resolves the ones a review tool started; the app itself never writes to a thread.
struct ThreadsSection: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        let threads = pr.threads.ordered
        PanelSection("Open threads") {
            if threads.isEmpty {
                Text("None open.").foregroundStyle(.secondary)
            } else {
                ForEach(ReviewThread.Source.allCases) { source in
                    let group = threads.filter { $0.source == source }
                    if !group.isEmpty {
                        Text("\(source.title) · \(group.count)").scaled(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(group) { ThreadRow(thread: $0, model: model) }
                    }
                }
                applyBar
            }
        }
    }

    private var applyBar: some View {
        let noted = model.notedThreads(pr).count
        let blocker = model.sendBlocker(pr)
        return HStack {
            Text(noted == 0 ? "Write what you want done with a thread, then Apply." : "\(noted) \(noted == 1 ? "thread" : "threads") with a note")
                .scaled(.caption).foregroundStyle(.secondary)
            Spacer()
            if noted > 0 { DisabledReason(text: blocker) }
            Button("Apply") { model.applyThreadNotes(pr) }
                .buttonStyle(.borderedProminent).handCursor()
                .disabled(noted == 0 || blocker != nil)
                .help("Sends the threads with a note to the PR's session: it makes the changes and pushes, replies in each thread, and resolves the ones /pre-pr or CodeRabbit started")
        }
    }
}

/// One open thread: its severity, where it sits, who started it, its first comment a line or two until opened, the way
/// to it on GitHub, and your note.
private struct ThreadRow: View {
    var thread: ReviewThread
    var model: AppModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let severity = thread.severity { Chip(text: severity.title, color: severity == .important ? .red : .yellow) }
                Text(thread.place).scaled(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if thread.isOutdated { Chip(text: "Outdated") }
                Text("@\(thread.author)").scaled(.caption).foregroundStyle(.secondary).lineLimit(1)
                if thread.comments > 1 { Text("\(thread.comments) comments").scaled(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                Button { model.open(thread.url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).handCursor()
                    .help("Open the thread on GitHub")
                    .accessibilityLabel("Open the thread on GitHub")
            }
            DisclosureGroup(isExpanded: $expanded) {
                MarkdownText(text: thread.body)
            } label: {
                Text(expanded ? AttributedString("First comment") : Markdown.inline(thread.preview)).scaled(.caption).lineLimit(2)
            }
            TextField("What I want done with it", text: Binding(
                get: { model.threadNotes[thread.id] ?? "" }, set: { model.threadNotes[thread.id] = $0 }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
        }
        .padding(.vertical, 4)
    }
}

/// What /pre-pr reported on the PR — its tier line, Testing, Risk and How to revert — and where the review gate has the
/// approvals; or that it has not reported.
struct EvidenceSection: View {
    var pr: PullRequest

    var body: some View {
        PanelSection("/pre-pr evidence") {
            if let gate = pr.approvalStatus {
                LabeledContent("Review gate", value: gate).textSelection(.enabled)
            }
            if let body = pr.evidence {
                let evidence = PrePR.evidence(body)
                if let tier = evidence.tier { Text(tier).scaled(.body.weight(.medium)).textSelection(.enabled) }
                ForEach(evidence.sections, id: \.title) { section in
                    Text(section.title).scaled(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    MarkdownText(text: section.text)
                }
            } else {
                Text("No /pre-pr evidence comment on this PR.").foregroundStyle(.secondary)
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
