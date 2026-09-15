import DeskCore
import SwiftUI

/// One of Claude's findings, with the three things you can do to it.
///
/// The draft body is a binding into the diff pane's own state, never `@State` here: this card lives in a
/// `LazyVStack`, which discards a view and its state once it scrolls out of the realization window. A
/// half-typed edit held locally would simply vanish.
struct CommentCard: View {
    let comment: DraftComment
    @Binding var draft: String?
    let readOnly: Bool
    var model: AppModel
    var prUrl: String
    var focused: FocusState<UUID?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let draft {
                CommentEditor(
                    text: Binding(get: { draft }, set: { self.draft = $0 }), focused: focused, id: comment.id
                )
                HStack(spacing: 8) {
                    Button("Save & approve") { save(draft, approve: true) }
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("Save") { save(draft, approve: false) }
                    Button("Cancel") { self.draft = nil }.keyboardShortcut(.cancelAction)
                    if comment.isUserEdited {
                        Button("Revert to Claude's") { save(comment.body, approve: false) }
                    }
                }
                .controlSize(.small)
            } else {
                Text(comment.text)
                    .font(.callout)
                    // Required inside the diff's horizontal ScrollView, which proposes infinite width:
                    // without it this renders on one line and stretches the whole diff sideways.
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !readOnly { actions }
            }
        }
        .padding(10)
        .frame(width: DiffMetrics.commentWidth, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: 1))
        .opacity(comment.state == .rejected ? 0.55 : 1)
    }

    private var header: some View {
        HStack(spacing: 6) {
            StatusDot(color: DiffPalette.severity(comment.severity))
            Text(comment.severity.title).font(.caption.weight(.semibold))
            if comment.isOutdated {
                Chip(text: "outdated", color: .secondary)
                    .help("The line this points at changed in a later push, so it will be sent in the review body")
            }
            if comment.isUnverified {
                Chip(text: "line unverified", color: .secondary)
                    .help("Claude's quoted line did not match the diff, so this line number is its own guess")
            }
            if comment.isUserEdited { Chip(text: "edited", color: .blue).help("You rewrote this") }
            Spacer(minLength: 8)
            Chip(text: comment.state.title, color: DiffPalette.state(comment.state))
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if comment.state == .pending {
                Button { set(.approved) } label: { Label("Approve", systemImage: "checkmark") }
                Button { set(.rejected) } label: { Label("Reject", systemImage: "xmark") }
            } else {
                Button { set(.pending) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            }
            Button { draft = comment.text } label: { Label("Edit", systemImage: "pencil") }
            Spacer(minLength: 0)
            Text("\(comment.path):\(comment.line)")
                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var border: Color {
        comment.state == .approved ? .green.opacity(0.6) : .primary.opacity(0.1)
    }

    private func set(_ state: CommentState) {
        model.setComment(comment.id, in: prUrl, state: state)
    }

    private func save(_ body: String, approve: Bool) {
        model.editComment(comment.id, in: prUrl, body: body, approve: approve)
        draft = nil
    }
}

/// `TextEditor` has no intrinsic height, so a hidden `Text` in the same font measures it.
private struct CommentEditor: View {
    @Binding var text: String
    var focused: FocusState<UUID?>.Binding
    let id: UUID

    private var width: CGFloat { DiffMetrics.commentWidth - 20 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(text.isEmpty ? " " : text)
                .font(.callout)
                .padding(.horizontal, 5)
                .padding(.vertical, 8)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
            TextEditor(text: $text)
                .font(.callout)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .focused(focused, equals: id)
        }
        .frame(width: width)
        .frame(minHeight: 54)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .onAppear { focused.wrappedValue = id }
    }
}
