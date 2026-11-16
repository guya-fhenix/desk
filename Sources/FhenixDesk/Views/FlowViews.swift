import DeskCore
import SwiftUI

/// Your open PR's first card: what its stage waits on, read off GitHub and the session on each refresh. A draft says where
/// its self-review stands; one in review says whose move it is; one ready to merge says why it is, and merges, asked
/// first: the page's one Merge. A conflict, red CI or a base to rebase onto shows here at any stage, for the worker to fix
/// when the master hands it over; so does a question the session is asking you.
struct NextStepCard: View {
    var pr: PullRequest
    /// The background session carrying the PR, when it has one.
    var session: ClaudeJob?
    var model: AppModel
    @State private var confirmingMerge = false
    @State private var mergeError: String?

    var body: some View {
        let stage = FlowStage.of(pr)
        SideCard(title: "Next step", edge: stage == .approved ? Color.green.opacity(0.6) : stage == .draft ? Theme.accent.opacity(0.6) : Theme.line) {
            if let key = session?.ticketKey { LabeledContent("Started from", value: key) }
            stageContent(stage)
            // The session itself, its state and Attach, is the page's header button; here only what it means for the PR.
            if let session, session.isAsking {
                // Its question is often the last line of a long report, easy to read past once attached; so it is said here.
                Text(session.question.map { "The session asks: “\($0)” Attach to it at the top to answer." }
                     ?? "The session is asking you something: attach to it at the top to answer.")
                    .scaled(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else if let session, session.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(session.detail ?? "Its session is working, on this PR or something else.")
                        .scaled(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if pr.hasConflicts { problem("It conflicts with \(pr.baseRef).") }
            if pr.checks.isRed { problem("CI failed.") }
            if let reason = model.state.rebaseReason(pr) { problem("Needs a rebase: \(reason.text).") }
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
            LabeledContent("Self-review") {
                switch PrePRStatus.of(pr) {
                case .notRun: Text("not yet")
                case .passed: Text("passed").foregroundStyle(.green)
                case .importantOpen: Text("finding open").foregroundStyle(.orange)
                }
            }
            Text("Its worker self-reviews it and fixes what you pick, on your word through the master. Ready for Review is in ⋯.")
                .scaled(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .inReview:
            // A change request or a red CI or conflict is yours to fix; otherwise the move is the reviewers'.
            let row = RowState.of(pr)
            LabeledContent("Waiting on", value: row.move == .yoursToFix ? "you · \(row.title.lowercased())" : "reviewers")
        case .approved:
            Text(readiness).scaled(.caption).foregroundStyle(.secondary)
            Button { confirmingMerge = true } label: {
                Label("Squash and merge…", systemImage: "arrow.triangle.merge").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            // A merge holds the PR in `busyFlows` until it is done.
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

    private func problem(_ text: String) -> some View {
        Text(text).scaled(.caption).foregroundStyle(.orange)
    }

    /// What makes it ready, as GitHub's merge box would say it: "Approved by noa-r · checks passed · no conflicts with
    /// main". Ready to merge already rules out red CI and conflicts.
    private var readiness: String {
        let approvers = pr.reviewerStatuses.filter { $0.state == .approved }.map(\.name)
        let checks = pr.checks == .success ? "checks passed" : pr.checks.isPending ? "checks running" : "no checks"
        return [approvers.isEmpty ? "Approvals met" : "Approved by \(approvers.joined(separator: ", "))", checks, "no conflicts with \(pr.baseRef)"]
            .joined(separator: " · ")
    }

    /// Ready to merge already rules out red CI and conflicts; CI still running is the one wait left.
    private var mergeHint: String {
        if pr.checks.isPending { return "CI is still running, so GitHub may refuse the merge until it passes." }
        return "Asks first. Its commits become one commit on \(pr.baseRef)."
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
                    .help(session.asking)
            } else if let error = model.flowErrors[pr.url] {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(error)
            }
        }
    }
}
