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
        PanelSection {
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

/// One open thread as a card: its severity, where it sits and who started it, the code it is on, the finding — its title,
/// and its text a paragraph at a time — the way to it on GitHub, and your note.
private struct ThreadRow: View {
    var thread: ReviewThread
    var model: AppModel
    @State private var expanded = false

    var body: some View {
        let finding = thread.finding
        let code = thread.codeLines()
        let paragraphs = finding.text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                if let severity = thread.severity { Chip(text: severity.title, color: severity == .important ? .red : .yellow) }
                Text(thread.place).scaled(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if thread.isOutdated { Chip(text: "Outdated") }
                Spacer(minLength: 4)
                Text("@\(thread.author)").scaled(.caption).foregroundStyle(.secondary).lineLimit(1)
                if thread.comments > 1 { Text("\(thread.comments) comments").scaled(.caption).foregroundStyle(.secondary) }
                Button { model.open(thread.url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).handCursor()
                    .help("Open the thread on GitHub")
                    .accessibilityLabel("Open the thread on GitHub")
            }
            if !code.isEmpty { CodeSnippet(lines: code) }
            if let title = finding.title {
                Text(Markdown.inline(title)).scaled(.body.weight(.semibold)).textSelection(.enabled)
            }
            if expanded {
                MarkdownText(text: finding.text)
            } else if let first = paragraphs.first {
                Text(Markdown.inline(first)).scaled(.callout).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            }
            if paragraphs.count > 1 || (paragraphs.first?.count ?? 0) > 320 {
                Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                    .buttonStyle(.link).scaled(.caption)
            }
            TextField("What I want done with it", text: Binding(
                get: { model.threadNotes[thread.id] ?? "" }, set: { model.threadNotes[thread.id] = $0 }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
        }
        .padding(Theme.Space.m)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder))
    }
}

/// The lines of the diff a thread is on, numbered as in the new file: added ones green, removed ones red, and the
/// commented line, the last, marked.
private struct CodeSnippet: View {
    var lines: [HunkLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                let commented = index == lines.count - 1
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Text(line.number.map(String.init) ?? "").foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").foregroundStyle(.secondary)
                    Text(line.text.isEmpty ? " " : line.text).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .scaled(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(background(line.kind, commented: commented))
            }
        }
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    private func background(_ kind: HunkLine.Kind, commented: Bool) -> Color {
        if commented { return Theme.accent.opacity(0.18) }
        switch kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .context: return .clear
        }
    }
}

/// The PR page's main column, a tab at a time: its open threads, what /pre-pr reported, and its description. It opens on
/// the threads while any are open.
struct PullRequestTabs<Description: View>: View {
    enum Tab: Hashable { case threads, evidence, description }

    var pr: PullRequest
    var model: AppModel
    @ViewBuilder var description: Description
    @State private var chosen: Tab?

    var body: some View {
        let tab = chosen ?? (pr.threads.isEmpty ? .description : .threads)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            PillTabs(
                options: [
                    .init(value: .threads, title: "Threads", count: pr.threads.count),
                    .init(value: .evidence, title: "Evidence", count: nil),
                    .init(value: .description, title: "Description", count: nil),
                ],
                selection: Binding(get: { tab }, set: { chosen = $0 })
            )
            switch tab {
            case .threads: ThreadsSection(pr: pr, model: model)
            case .evidence: EvidenceSection(pr: pr)
            case .description: description
            }
        }
    }
}

/// What /pre-pr reported on the PR — its tier line, Testing, Risk and How to revert — and where the review gate has the
/// approvals; or that it has not reported.
struct EvidenceSection: View {
    var pr: PullRequest

    var body: some View {
        PanelSection {
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
