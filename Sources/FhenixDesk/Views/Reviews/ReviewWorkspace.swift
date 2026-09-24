import DeskCore
import SwiftUI

/// One PR's review: the diff and its comments fill the window, the verdict and the one button that posts
/// sit in the toolbar, and what you read around the diff — description, summary, run — is in the inspector.
struct ReviewWorkspace: View, Equatable {
    let record: ReviewRecord
    let pr: PullRequest?
    var model: AppModel

    @State private var document: DiffDocument?
    @State private var loadError: String?
    @State private var target: DiffScrollTarget?
    @State private var nonce = 0
    /// Comment bodies being edited. Held here, above the lazy stack, so scrolling a card out of view
    /// cannot take the edit with it.
    @State private var drafts: [UUID: String] = [:]
    @State private var confirming = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.record == rhs.record && lhs.pr == rhs.pr && lhs.model === rhs.model
    }

    var body: some View {
        VStack(spacing: 0) {
            if let submission = record.submission { SubmittedBanner(submission: submission, model: model) }
            if let error = record.submitError { Banner(text: error, color: .red) }
            if let error = record.error { Banner(text: error, color: .orange) }
            content
        }
        // Without this the workspace reports its content's ideal size as the window's, and a diff grows
        // the window past the screen. The window sizes the workspace, never the other way round.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: record.headSha) { await load() }
        .navigationTitle(record.label)
        .navigationSubtitle(record.title)
        // Toolbar items are hosted apart from this view and can outlive its environment, so each one is
        // handed the model rather than reading it from there.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.closeWorkspace() } label: { Label("Back", systemImage: "chevron.left") }
                    // Not Escape: that belongs to the comment editor's Cancel.
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back to the queue (⌘[)")
            }
            ToolbarItem(placement: .primaryAction) { ReviewProgress(record: record, pr: pr, model: model) }
            ToolbarItem(placement: .primaryAction) {
                RerunButton(record: record, pr: pr, model: model, hasDrafts: !drafts.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) { VerdictPicker(record: record, model: model) }
            ToolbarItem(placement: .primaryAction) {
                SubmitButton(record: record, model: model) { confirming = true }
            }
        }
        .confirmationDialog("Post this review to GitHub?", isPresented: $confirming, titleVisibility: .visible) {
            Button(record.effectiveVerdict.title) { model.submitReview(record.prUrl) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmation)
        }
        .deskInspector("review") { ReviewInspector(record: record, pr: pr, model: model) }
    }

    @ViewBuilder private var content: some View {
        if let document {
            HSplitView {
                ReviewFileList(
                    document: document, comments: record.comments,
                    select: { file in
                        nonce += 1
                        target = DiffScrollTarget(anchor: .file(file.id), fileID: file.id, nonce: nonce)
                    },
                    jump: { comment in
                        nonce += 1
                        let fileID = document.files.first { $0.path == comment.path }?.id ?? 0
                        target = DiffScrollTarget(anchor: .comment(comment.id), fileID: fileID, nonce: nonce)
                    }
                )
                .frame(minWidth: 190, idealWidth: 240, maxWidth: 340, alignment: .top)
                DiffPane(
                    document: document, comments: record.comments, target: target, readOnly: record.isSubmitted,
                    model: model, prUrl: record.prUrl, drafts: $drafts
                )
                .equatable()
                // `.top`: a diff shorter than the pane sits at the top of it, not floating in the middle.
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            EmptyText(text: loadError).padding()
            Spacer()
        } else if record.phase.isBusy {
            Spacer()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(record.phase == .running ? "Claude is reviewing this PR…" : "Preparing the worktree…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        } else if record.headSha.isEmpty {
            // The run never got as far as a head, so there is no diff to show. The banner above says why.
            EmptyText(text: "This review has no diff yet. Press the reload button to try again.").padding()
            Spacer()
        } else {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        }
    }

    private func load() async {
        guard !record.headSha.isEmpty else { return }
        loadError = nil
        do {
            // Parsed inside the service, off the main actor. It is megabytes, which is also why it never
            // goes into `state`.
            document = DiffDocument(try await model.diff(for: record))
        } catch {
            loadError = "Could not load the diff: \(error)"
        }
    }

    private var confirmation: String {
        let counts = record.counts
        var parts = ["Posts \(counts.approved) \(counts.approved == 1 ? "comment" : "comments") and “\(record.effectiveVerdict.title)” to \(record.label)."]
        if counts.outdated > 0 {
            parts.append("Outdated comments go in the review body rather than on a line.")
        }
        if counts.pending > 0 {
            parts.append("\(counts.pending) undecided \(counts.pending == 1 ? "comment" : "comments") will not be posted.")
        }
        parts.append("The author is notified immediately.")
        return parts.joined(separator: " ")
    }
}

/// Where the run stands, how far your decisions have got, what it cost, and what Claude concluded.
private struct ReviewProgress: View {
    let record: ReviewRecord
    let pr: PullRequest?
    var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if let pr { ChecksBadge(pr: pr) }
            if record.phase.isBusy || model.busyReviews.contains(record.prUrl) {
                ProgressView().controlSize(.small)
                Text(record.phase.label).scaled(.caption).foregroundStyle(.secondary)
            }
            let counts = record.counts
            if counts.total > 0 {
                Text("\(counts.approved) of \(counts.total) approved")
                    .scaled(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if record.costUSD > 0 {
                Text(Format.usd(record.costUSD)).scaled(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
            suggestedVerdict
        }
        .fixedSize()
    }

    /// What Claude decided. The picker beside it is yours to override, so the two are shown apart —
    /// otherwise an overridden verdict looks like the review's own conclusion.
    @ViewBuilder private var suggestedVerdict: some View {
        if let verdict = record.verdict {
            let overridden = record.chosenVerdict != nil && record.chosenVerdict != verdict
            Text("Claude: \(verdict.title)")
                .scaled(.caption)
                .foregroundStyle(overridden ? .orange : .secondary)
                .help(overridden ? "Claude suggested \(verdict.title); you changed it" : "Claude's verdict for this run")
        }
    }
}

private struct RerunButton: View {
    let record: ReviewRecord
    let pr: PullRequest?
    var model: AppModel
    let hasDrafts: Bool

    var body: some View {
        Button { model.review(prForRerun) } label: { Label("Review again", systemImage: "arrow.clockwise") }
            .disabled(record.phase.isBusy || record.isSubmitted || hasDrafts || model.busyReviews.contains(record.prUrl))
            .help(hasDrafts ? "Finish or discard your comment edits first" : "Review again")
    }

    /// The live PR when the snapshot still has it, else one rebuilt from the record so a re-run still works.
    private var prForRerun: PullRequest {
        pr ?? PullRequest(
            number: record.number, title: record.title, url: record.prUrl, repo: record.repo,
            createdAt: record.startedAt, updatedAt: record.lastRunAt, baseRef: record.baseRef,
            headRef: "", headSha: record.headSha, author: record.author
        )
    }
}

private struct VerdictPicker: View {
    let record: ReviewRecord
    var model: AppModel

    var body: some View {
        Picker("Verdict", selection: Binding(
            get: { record.effectiveVerdict },
            set: { model.setVerdict($0, in: record.prUrl) }
        )) {
            ForEach(ReviewVerdict.allCases) { verdict in
                Text(verdict.title).tag(verdict)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(record.isSubmitted)
    }
}

private struct SubmitButton: View {
    let record: ReviewRecord
    var model: AppModel
    let confirm: () -> Void

    var body: some View {
        // Never `.defaultAction`: the app's only outward write must not be reachable by pressing Return.
        Button("Submit…", action: confirm)
            .buttonStyle(.borderedProminent)
            .disabled(disabled)
            .help(help)
    }

    private var isOwnPR: Bool { record.author == model.state.login }

    private var disabled: Bool {
        if record.isSubmitted || record.phase.isBusy || model.busyReviews.contains(record.prUrl) { return true }
        // GitHub refuses a verdict on your own PR, and a comment review with nothing in it.
        if isOwnPR, record.effectiveVerdict != .comment { return true }
        return record.effectiveVerdict == .comment && record.counts.approved == 0 && record.summary.isEmpty
    }

    private var help: String {
        if record.isSubmitted { return "Already submitted" }
        if isOwnPR, record.effectiveVerdict != .comment { return "GitHub does not let you approve or request changes on your own PR" }
        if record.effectiveVerdict == .comment && record.counts.approved == 0 && record.summary.isEmpty {
            return "Nothing to send: approve a comment or write a summary"
        }
        return "Post one review with the comments you approved"
    }
}

/// What you read around the diff: the author's description, the summary you will post, and the run itself.
private struct ReviewInspector: View {
    let record: ReviewRecord
    let pr: PullRequest?
    var model: AppModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(record.label) \(record.title)").scaled(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("by \(record.author) · into \(record.baseRef)").scaled(.caption).foregroundStyle(.secondary)
                }
                Button("Open on GitHub") { model.open(record.prUrl) }.controlSize(.small)
            }
            if let body = pr?.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Description") { MarkdownText(text: body) }
            }
            Section {
                ReviewSummary(record: record, model: model)
            } header: {
                Text("Summary")
            } footer: {
                Text("Posted as the review body when you submit.").scaled(.caption).foregroundStyle(.secondary)
            }
            Section("This run") {
                LabeledContent("Status") {
                    ReviewStatusChip(status: model.state.reviewStatus(for: record, pr: pr))
                }
                LabeledContent("Ran", value: "\(Format.age(record.lastRunAt)) ago · \(record.runs) \(record.runs == 1 ? "run" : "runs")")
                if !record.headSha.isEmpty {
                    LabeledContent("Head") { Text(record.headSha.prefix(7)).scaled(.callout.monospaced()).textSelection(.enabled) }
                }
                if record.costUSD > 0 { LabeledContent("Cost", value: Format.usd(record.costUSD)) }
                LabeledContent("Worktree") {
                    Text(record.worktreePath).scaled(.caption).lineLimit(1).truncationMode(.head).help(record.worktreePath)
                }
                HStack {
                    Button("Reveal worktree") { model.reveal(record.worktreePath) }
                    Button("Remove review", role: .destructive) { model.removeReview(record) }
                        .disabled(record.phase.isBusy)
                        .help("Delete the review and its worktree (kept when the worktree has local changes)")
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ReviewSummary: View {
    let record: ReviewRecord
    var model: AppModel
    @State private var draft: String?

    /// Nothing general to say and nothing to write it with: the section disappears rather than leaving a
    /// placeholder line and its padding on every clean review.
    private var canWriteOne: Bool { !record.isSubmitted && !record.phase.isBusy }
    private var hasAnything: Bool {
        draft != nil || !record.summary.isEmpty || record.rawOutput != nil || canWriteOne
    }

    @ViewBuilder var body: some View {
        if hasAnything { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if draft == nil, record.summary.isEmpty, record.rawOutput == nil {
                Button("Add a summary") { draft = "" }
                    .controlSize(.small)
            } else if let draft {
                TextEditor(text: Binding(get: { draft }, set: { self.draft = $0 }))
                    .scaled(.callout)
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                HStack(spacing: 8) {
                    Button("Save") {
                        model.setSummary(draft, in: record.prUrl)
                        self.draft = nil
                    }
                    Button("Cancel") { self.draft = nil }
                }
                .controlSize(.small)
            } else if !record.summary.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // No `fixedSize`: it asks for the ideal height at whatever width is proposed, and
                    // during layout that width can be near zero — the text then wraps one character
                    // per line and drags the window to several screen-heights.
                    Text(record.summary).scaled(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 8)
                    if !record.isSubmitted {
                        Button { draft = record.summary } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .help("The summary is posted as the review body, so it should be yours")
                    }
                }
            }
            if let raw = record.rawOutput {
                DisclosureGroup("Claude's answer did not parse — show it") {
                    Text(raw).scaled(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scaled(.caption)
            }
        }
    }
}

private struct SubmittedBanner: View {
    let submission: SubmittedRound
    var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            Text("Submitted “\(submission.event.title)” \(Format.age(submission.at)) ago · \(submission.inlineCount) inline"
                + (submission.foldedCount > 0 ? ", \(submission.foldedCount) in the body" : ""))
                .scaled(.caption)
            Spacer()
            if !submission.url.isEmpty {
                Button("View on GitHub") { model.open(submission.url) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.green.opacity(0.12))
    }
}

private struct Banner: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text).scaled(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
    }
}
