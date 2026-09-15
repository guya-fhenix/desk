import DeskCore
import SwiftUI

/// One PR's review: the summary, the diff, the comments, and the one button that posts.
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

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.record == rhs.record && lhs.pr == rhs.pr && lhs.model === rhs.model
    }

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeaderBar(record: record, pr: pr, model: model, hasDrafts: !drafts.isEmpty)
            if let body = pr?.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                PullRequestDescription(text: body)
            }
            if let submission = record.submission { SubmittedBanner(submission: submission, model: model) }
            if let error = record.submitError { Banner(text: error, color: .red) }
            if let error = record.error { Banner(text: error, color: .orange) }
            ReviewSummary(record: record, model: model)
            Divider()
            content
        }
        // Without this the workspace reports its content's ideal size as the window's, and a diff grows
        // the window past the screen. The window sizes the workspace, never the other way round.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: record.headSha) { await load() }
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
}

private struct ReviewHeaderBar: View {
    let record: ReviewRecord
    let pr: PullRequest?
    var model: AppModel
    let hasDrafts: Bool
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            Button { model.closeWorkspace() } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                // Not Escape: that belongs to the comment editor's Cancel.
                .keyboardShortcut("[", modifiers: .command)
            Button { model.open(record.prUrl) } label: { Text(record.label).font(.headline) }
                .buttonStyle(.link)
            Text(record.title).lineLimit(1).foregroundStyle(.secondary)
            if let pr { ChecksBadge(pr: pr) }
            Spacer(minLength: 12)
            status
            suggestedVerdict
            Button { model.review(prForRerun) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(rerunDisabled)
                .help(hasDrafts ? "Finish or discard your comment edits first" : "Review again")
            verdictPicker
            submitButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .confirmationDialog("Post this review to GitHub?", isPresented: $confirming, titleVisibility: .visible) {
            Button(record.effectiveVerdict.title) { model.submitReview(record.prUrl) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmation)
        }
    }

    @ViewBuilder private var status: some View {
        if record.phase.isBusy || model.busyReviews.contains(record.prUrl) {
            ProgressView().controlSize(.small)
            Text(record.phase.label).font(.caption).foregroundStyle(.secondary)
        }
        let counts = record.counts
        if counts.total > 0 {
            Text("\(counts.approved) of \(counts.total) approved")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        if record.costUSD > 0 {
            Text(Format.usd(record.costUSD)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
        }
    }

    /// What Claude decided. The picker beside it is yours to override, so the two are shown apart —
    /// otherwise an overridden verdict looks like the review's own conclusion.
    @ViewBuilder private var suggestedVerdict: some View {
        if let verdict = record.verdict {
            let overridden = record.chosenVerdict != nil && record.chosenVerdict != verdict
            Text("Claude: \(verdict.title)")
                .font(.caption)
                .foregroundStyle(overridden ? .orange : .secondary)
                .help(overridden ? "Claude suggested \(verdict.title); you changed it" : "Claude's verdict for this run")
        }
    }

    private var verdictPicker: some View {
        Picker("", selection: Binding(
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

    @ViewBuilder private var submitButton: some View {
        // Never `.defaultAction`: the app's only outward write must not be reachable by pressing Return.
        Button("Submit") { confirming = true }
            .controlSize(.small)
            .disabled(submitDisabled)
            .help(submitHelp)
    }

    private var isOwnPR: Bool { record.author == model.state.login }

    private var submitDisabled: Bool {
        if record.isSubmitted || record.phase.isBusy || model.busyReviews.contains(record.prUrl) { return true }
        // GitHub refuses a verdict on your own PR, and a comment review with nothing in it.
        if isOwnPR, record.effectiveVerdict != .comment { return true }
        return record.effectiveVerdict == .comment && record.counts.approved == 0 && record.summary.isEmpty
    }

    private var submitHelp: String {
        if record.isSubmitted { return "Already submitted" }
        if isOwnPR, record.effectiveVerdict != .comment { return "GitHub does not let you approve or request changes on your own PR" }
        if record.effectiveVerdict == .comment && record.counts.approved == 0 && record.summary.isEmpty {
            return "Nothing to send: approve a comment or write a summary"
        }
        return "Post one review with the comments you approved"
    }

    private var rerunDisabled: Bool {
        record.phase.isBusy || record.isSubmitted || hasDrafts || model.busyReviews.contains(record.prUrl)
    }

    /// The live PR when the snapshot still has it, else one rebuilt from the record so a re-run still works.
    private var prForRerun: PullRequest {
        pr ?? PullRequest(
            number: record.number, title: record.title, url: record.prUrl, repo: record.repo,
            createdAt: record.startedAt, updatedAt: record.lastRunAt, baseRef: record.baseRef,
            headRef: "", headSha: record.headSha, author: record.author
        )
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
                    .buttonStyle(.borderless).controlSize(.small).font(.caption)
                    .help("Posted as the review body when you submit")
            } else if let draft {
                TextEditor(text: Binding(get: { draft }, set: { self.draft = $0 }))
                    .font(.callout)
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
                    Text(record.summary).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
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
                    Text(raw).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// What the author wrote. Collapsible and height-capped: it is context for the diff, not the screen.
private struct PullRequestDescription: View {
    let text: String
    @AppStorage("review.showDescription") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView {
                    MarkdownText(text: text).padding(.top, 4).padding(.trailing, 8)
                }
                .frame(maxHeight: 200)
            } label: {
                Text("Description").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
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
                .font(.caption)
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
            Text(text).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
    }
}
