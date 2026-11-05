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

/// Your PR's open review threads as GitHub shows them, each on its code and with its whole conversation, grouped by who
/// started them — /pre-pr, CodeRabbit, people — the most severe first. Under each, your instruction for the session; Apply,
/// on top, sends the ones you wrote to the PR's session, which makes the changes, replies in each thread and resolves the
/// ones a review tool started. The app itself never writes to a thread.
struct ThreadsSection: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        let threads = pr.threads.ordered
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if threads.isEmpty {
                Text("No open threads.").foregroundStyle(.secondary)
            } else {
                applyBar(count: threads.count)
                ForEach(ReviewThread.Source.allCases) { source in
                    let group = threads.filter { $0.source == source }
                    if !group.isEmpty {
                        Text("\(source.title) · \(group.count)").scaled(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(group) { ThreadCard(thread: $0, model: model) }
                    }
                }
            }
        }
    }

    private func applyBar(count: Int) -> some View {
        let noted = model.notedThreads(pr).count
        let blocker = model.sendBlocker(pr)
        return HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) open \(count == 1 ? "thread" : "threads")").scaled(.body.weight(.semibold))
                Text(noted == 0
                    ? "Write an instruction under the threads you want handled, then Apply sends them to the PR's session."
                    : "\(noted) with an instruction. Apply sends \(noted == 1 ? "it" : "them") to the PR's session.")
                    .scaled(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if noted > 0 { DisabledReason(text: blocker) }
            Button { model.applyThreadNotes(pr) } label: {
                Label(noted == 0 ? "Apply" : "Apply \(noted)", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent).controlSize(.large).handCursor()
            .disabled(noted == 0 || blocker != nil)
            .help("Sends the threads with an instruction to the PR's session: it makes the changes and pushes, replies in each thread, and resolves the ones /pre-pr or CodeRabbit started")
        }
        .padding(Theme.Space.m)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(noted > 0 ? Theme.accent : Theme.controlBorder))
    }
}

/// One open thread as GitHub draws it: the file and line on top, the diff down to the commented line, then the whole
/// conversation, each comment in full; and at the bottom your instruction for the session.
private struct ThreadCard: View {
    var thread: ReviewThread
    var model: AppModel
    @FocusState private var editing: Bool

    var body: some View {
        let code = thread.codeLines()
        let note = model.threadNotes[thread.id] ?? ""
        let hasNote = !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(thread.place).scaled(.callout.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if thread.isOutdated { Chip(text: "Outdated") }
                Spacer(minLength: 4)
                if let severity = thread.severity { Chip(text: severity.title, color: severity == .important ? .red : .yellow) }
                Button { model.open(thread.url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).handCursor()
                    .help("Open the thread on GitHub")
                    .accessibilityLabel("Open the thread on GitHub")
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.raised)
            if !code.isEmpty {
                Divider()
                DiffLines(lines: code)
            }
            Divider()
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CommentView(author: thread.author, createdAt: thread.createdAt, text: thread.body)
                ForEach(thread.replies, id: \.self) { reply in
                    Divider()
                    CommentView(author: reply.author, createdAt: reply.createdAt, text: reply.body)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("Your instruction to the session", systemImage: "pencil.line")
                        .scaled(.caption.weight(.semibold))
                        .foregroundStyle(hasNote || editing ? Theme.accent : .secondary)
                    TextField(
                        "What should the session do with this thread? For example: fix it as suggested, or reply that it is on purpose because…",
                        text: Binding(get: { note }, set: { model.threadNotes[thread.id] = $0 }), axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .focused($editing)
                    .lineLimit(3...10)
                    .padding(Theme.Space.s)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(hasNote || editing ? Theme.accent : Theme.controlBorder, lineWidth: hasNote || editing ? 1.5 : 1)
                    )
                }
                .padding(.top, 4)
            }
            .padding(Theme.Space.m)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder))
    }
}

/// One comment of a thread: who wrote it and when, then all of it, rendered, without the HTML and the collapsed
/// boilerplate review tools wrap their comments in.
private struct CommentView: View {
    var author: String
    var createdAt: Date?
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Avatar(login: author.replacingOccurrences(of: "[bot]", with: ""), size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(author).scaled(.callout.weight(.semibold))
                    if let createdAt {
                        Text("\(Format.age(createdAt)) ago").scaled(.caption).foregroundStyle(.secondary).help(Format.date(createdAt))
                    }
                }
                MarkdownText(text: ReviewThread.clean(text))
            }
        }
    }
}

/// The diff lines a thread is on, as GitHub shows them: the old and the new line number, the sign, and the code, added
/// lines green and removed ones red across the whole row; the commented line, the last, marked on its edge.
private struct DiffLines: View {
    var lines: [HunkLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                let commented = index == lines.count - 1
                HStack(alignment: .top, spacing: 0) {
                    Rectangle().fill(commented ? Theme.accent : .clear).frame(width: 3)
                    Text(line.old.map(String.init) ?? "").foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    Text(line.number.map(String.init) ?? "").foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                        .foregroundStyle(line.kind == .added ? .green : line.kind == .removed ? .red : .secondary)
                        .frame(width: 22)
                    Text(line.text.isEmpty ? " " : line.text).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .scaled(.callout.monospaced())
                .padding(.vertical, 2)
                .background(background(line.kind))
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }

    private func background(_ kind: HunkLine.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.14)
        case .removed: return Color.red.opacity(0.14)
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
