import DeskCore
import SwiftUI

/// Your open PR's first card: what its stage waits on and the one press that moves it, read off GitHub and the session on
/// each refresh. A draft says where /pre-pr stands and runs it, with Mark ready beside it; one in review says whose move
/// it is; one ready to merge says why it is, and merges, asked first — the page's one Merge. A conflict or red CI has its
/// Fix it here at any stage, and so does what the session is doing.
struct NextStepCard: View {
    var pr: PullRequest
    /// The background session carrying the PR, when it has one.
    var session: ClaudeJob?
    var model: AppModel
    /// Mark ready on a draft /pre-pr has not passed asks first.
    @State private var confirmingReady = false
    @State private var confirmingMerge = false
    @State private var mergeError: String?

    var body: some View {
        let stage = FlowStage.of(pr)
        SideCard(title: "Next step", edge: stage == .approved ? Color.green.opacity(0.6) : stage == .draft ? Theme.accent.opacity(0.6) : Theme.line) {
            if let key = session?.ticketKey { LabeledContent("Started from", value: key) }
            stageContent(stage)
            // The session itself, its state and Attach, is the page's header button; here only what it means for the flow.
            if session?.isAsking == true {
                Text("The session is asking you something: attach to it at the top to answer.").scaled(.caption).foregroundStyle(.orange)
            } else if session?.isRunning == true {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(stage == .draft
                        ? "Its session is working (on this PR or something else); Run /pre-pr and Mark ready wait until it’s done."
                        : "Its session is working, on this PR or something else.")
                        .scaled(.caption).foregroundStyle(.secondary)
                }
            }
            if pr.mergeState == .dirty { fixRow(.fixConflict, problem: "It conflicts with \(pr.baseRef).") }
            if pr.checks.isRed { fixRow(.fixChecks, problem: "CI failed.") }
            if let reason = model.state.rebaseReason(pr) {
                Text("Needs a rebase: \(reason.text)").scaled(.caption).foregroundStyle(.orange)
            }
            if let error = model.flowErrors[pr.url] ?? mergeError {
                Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        } trailing: {
            StageChip(stage: stage, sessionBusy: session?.isBusy ?? false).fixedSize()
        }
    }

    @ViewBuilder private func stageContent(_ stage: FlowStage) -> some View {
        let busy = model.busyFlows.contains(pr.url)
        switch stage {
        case .draft:
            // Two presses, both yours and in any order: /pre-pr's run, which posts its findings and adds the
            // local-reviewed label once no Important one is open, and Mark ready, the one to lead with once it has.
            let status = PrePRStatus.of(pr)
            let skill = model.state.reviewSkill(for: pr)
            LabeledContent("/pre-pr") {
                switch status {
                case .notRun: Text("not run")
                case .passed: Text("passed").foregroundStyle(.green)
                case .importantOpen: Text("finding open").foregroundStyle(.orange)
                }
            }
            LabeledContent("Ready for review", value: "no · asks \(model.config.reviewTeam)")
            if status == .importantOpen {
                // Ready without the label fails the local-review-evidence check from Enforce on.
                Text("/pre-pr left an Important finding open, so there is no local-reviewed label. Settle it with the session, or resolve its thread as your decision, then run /pre-pr again.")
                    .scaled(.caption).foregroundStyle(.orange)
            }
            if let skill, !skill.has(skill.selfReview) { ReviewSkillMark(skill: skill, showsText: true) }
            let blocker = busy ? nil : model.prePRBlocker(pr)
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.mini) }
                // A /pre-pr run still going may push again: the PR goes ready only once the session is done.
                Button("Mark ready") { if pr.isLocallyReviewed { model.markReady(pr) } else { confirmingReady = true } }
                    .primaryStyle(status == .passed)
                    .disabled(busy || session?.isBusy == true)
                    .help("Marks the PR ready for review and asks \(model.config.reviewTeam) to review it")
                RunPrePRButton(startsSession: session == nil) { model.runPrePR(pr) }
                    .primaryStyle(status != .passed)
                    .disabled(busy || blocker != nil)
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
            DisabledReason(text: blocker).frame(maxWidth: .infinity, alignment: .trailing)
        case .inReview:
            // A change request or a red CI or conflict is yours to fix; otherwise the move is the reviewers'.
            let row = RowState.of(pr)
            LabeledContent("Waiting on", value: row.move == .yoursToFix ? "you · \(row.title.lowercased())" : model.config.reviewTeam)
        case .approved:
            Text(readiness).scaled(.caption).foregroundStyle(.secondary)
            Button { confirmingMerge = true } label: {
                Label("Squash and merge…", systemImage: "arrow.triangle.merge").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).handCursor()
            .tint(.green)
            .controlSize(.large)
            // A merge, or a flow press, holds the PR in `busyFlows` until it is done.
            .disabled(pr.mergeBlocker != nil || busy)
            .confirmationDialog(
                Text(verbatim: "Squash and merge #\(pr.number) into \(pr.baseRef)?"), isPresented: $confirmingMerge
            ) {
                Button("Squash and merge") {
                    mergeError = nil
                    Task { mergeError = await model.squashMerge(pr) }
                }
            } message: {
                Text("Its commits become one commit on \(pr.baseRef).")
            }
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini) }
                Text(pr.mergeBlocker ?? mergeHint).scaled(.caption).foregroundStyle(.secondary)
            }
        case .working, .merged, .closed:
            EmptyView()
        }
    }

    /// What makes it ready, as GitHub's merge box would say it: "Approved by noa-r · checks passed · no conflicts with
    /// main". Ready to merge already rules out red CI and conflicts.
    private var readiness: String {
        let approvers = pr.reviewerStatuses.filter { $0.state == .approved }.map(\.name)
        let checks = pr.checks == .success ? "checks passed" : pr.checks.isPending ? "checks running" : "no checks"
        return [approvers.isEmpty ? "Approvals met" : "Approved by \(approvers.joined(separator: ", "))", checks, "no conflicts with \(pr.baseRef)"]
            .joined(separator: " · ")
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

    /// Ready to merge already rules out red CI and conflicts; CI still running is the one wait left.
    private var mergeHint: String {
        if pr.checks.isPending { return "CI is still running, so GitHub may refuse the merge until it passes." }
        return "Asks first. Its commits become one commit on \(pr.baseRef)."
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

/// The facts of a PR in one card, a row each: its open threads — in the row's orange, the same count — by who started
/// them, with the way to them on GitHub; who reviewed it and where each stands, then who is asked and has not answered;
/// its labels as GitHub has them; its size; when it was opened and last updated, the exact times on hover; and the stack
/// it sits in, when it sits in one. An ended PR's threads and stack are over, so it leaves those out.
struct AboutCard: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        let open = pr.state == .open
        SideCard(title: "About this PR") {
            if open {
                LabeledContent("Open threads") { threads }
            }
            LabeledContent("Reviewers") { reviewers }
            LabeledContent("Labels") {
                if pr.labels.isEmpty {
                    Text("None")
                } else {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(pr.labels.sorted(), id: \.self) { Chip(text: $0) }
                    }
                }
            }
            LabeledContent("Size") { DiffStat(pr: pr) }
            LabeledContent("Opened · updated", value: "\(Format.age(pr.createdAt)) · \(Format.age(pr.updatedAt)) ago")
                .help("Opened \(Format.date(pr.createdAt)) · updated \(Format.date(pr.updatedAt))")
            if open {
                if let parent = model.state.stackParent(of: pr) { stackLine("Stacked on", parent) }
                ForEach((model.state.github?.allOpen ?? []).filter { model.state.stackParents[$0.url] == pr.url }) {
                    stackLine("Under it", $0)
                }
            }
        }
    }

    /// They are read and answered in the page's conversation too.
    @ViewBuilder private var threads: some View {
        if pr.unresolvedThreads == 0 {
            Text("None")
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(pr.unresolvedThreads) unresolved").foregroundStyle(.orange)
                Text(pr.threads.byWho.map { "\($0.who) \($0.count)" }.joined(separator: " · "))
                    .scaled(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                Button("Read them on GitHub") { model.open(pr.url + "/files") }
                    .buttonStyle(.link).handCursor()
            }
        }
    }

    @ViewBuilder private var reviewers: some View {
        let reviewers = pr.reviewerStatuses
        if reviewers.isEmpty {
            Text("None yet")
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(reviewers) { reviewer in
                    let (word, symbol, color) = Self.look(reviewer.state)
                    HStack(spacing: 6) {
                        Avatar(login: reviewer.name, size: 16)
                        Text(reviewer.name).lineLimit(1)
                        Image(systemName: symbol).foregroundStyle(color)
                    }
                    .help("\(reviewer.name): \(word)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(reviewer.name), \(word)")
                }
            }
        }
    }

    private static func look(_ state: ReviewerStatus.State) -> (word: String, symbol: String, color: Color) {
        switch state {
        case .approved: return ("approved", "checkmark.circle.fill", .green)
        case .changesRequested: return ("changes requested", "xmark.circle.fill", .red)
        case .commented: return ("commented", "text.bubble.fill", .orange)
        case .dismissed: return ("dismissed", "minus.circle", .secondary)
        case .pending: return ("pending", "clock", .secondary)
        }
    }

    private func stackLine(_ label: String, _ other: PullRequest) -> some View {
        LabeledContent(label) {
            Button { model.open(other.url) } label: { Text(verbatim: "#\(other.number) \(other.title)").lineLimit(1) }
                .buttonStyle(.link).handCursor()
        }
    }
}

/// Beside a PR row's pill, what its session is doing: a spinner while it works, a bubble while it asks you something, or a
/// red mark when the last press on it failed.
struct SessionMarks: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        if let session = model.state.session(for: pr) {
            if session.isRunning {
                ProgressView().controlSize(.mini).help("The session is working")
            } else if session.isAsking {
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                    .help("The session is asking you something")
            } else if let error = model.flowErrors[pr.url] {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(error)
            }
        }
    }
}
