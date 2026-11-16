import DeskCore
import SwiftUI

/// A PR's conversation, under its description: its review threads, the open ones in full with a reply box always open and
/// the resolved ones folded to a line each, in one card; then the PR's comments and the reviews, oldest first; and a
/// comment box always open. Everything posted goes to GitHub as you.
struct ConversationSection: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let conversation = model.conversations[pr.url] {
                content(conversation)
            } else if let error = model.conversationErrors[pr.url] {
                Text("Couldn't load the conversation: \(error)").scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Again whenever the PR changes on GitHub, as a new comment or reply changes it.
        .task(id: "\(pr.url) \(pr.updatedAt)") { await model.loadConversation(pr) }
    }

    @ViewBuilder private func content(_ conversation: Conversation) -> some View {
        let open = conversation.openThreads
        let resolved = conversation.resolvedThreads
        if !conversation.threads.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Review threads · " + [open.isEmpty ? nil : "\(open.count) open", resolved.isEmpty ? nil : "\(resolved.count) resolved"]
                    .compactMap { $0 }.joined(separator: " · "))
                ForEach(open) { ThreadView(thread: $0, pr: pr, model: model) }
                if !resolved.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(resolved.enumerated()), id: \.element.id) { index, thread in
                            ThreadView(thread: thread, pr: pr, model: model, framed: false)
                                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Theme.ruleSoft).frame(height: 1) } }
                        }
                    }
                    .conversationCard()
                }
            }
        }
        if !conversation.entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(conversation.entries) { TimelineItem(entry: $0) }
            }
        }
        CommentBox(prompt: "Leave a comment…", submit: "Comment") { await model.comment(pr, body: $0) }
    }
}

/// A comment or a review on the PR's conversation: a card with who, what and when over what they wrote. A review with
/// nothing written is one ruled line: its verdict.
private struct TimelineItem: View {
    var entry: ConversationEntry

    var body: some View {
        let comment = entry.comment
        if comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 18)
                HStack(spacing: 4) {
                    AuthorName(comment: comment)
                    Text(entry.verb ?? "commented")
                }
                Spacer(minLength: 8)
                When(date: comment.createdAt)
            }
            .padding(.horizontal, 2)
            .frame(minHeight: 36)
            .overlay(alignment: .top) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    AuthorName(comment: comment)
                    Text("· \(entry.verb ?? "commented")").foregroundStyle(entry.verb == nil ? Theme.quiet : color)
                    Spacer(minLength: 8)
                    When(date: comment.createdAt)
                }
                .scaled(.secondary)
                .foregroundStyle(Theme.quiet)
                .padding(.horizontal, 14).padding(.vertical, 8)
                Rectangle().fill(Theme.ruleSoft).frame(height: 1)
                CommentBody(comment: comment).padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
            }
            .conversationCard()
        }
    }

    private var icon: String {
        switch entry.verb {
        case "approved": "checkmark.circle"
        case "requested changes": "minus.circle"
        default: "eye.circle"
        }
    }

    private var color: Color {
        switch entry.verb {
        case "approved": Theme.ok
        case "requested changes": Theme.danger
        default: Theme.quiet
        }
    }
}

/// One review thread: a bar with where it sits and Resolve, every comment, and a reply box always open. A resolved thread
/// is folded to one line — who started it, its first words and a Resolved chip — until opened. Under its own line in the
/// diff it leaves out where it sits. `framed` false where the resolved threads share one card.
struct ThreadView: View {
    var thread: ConversationThread
    var pr: PullRequest
    var model: AppModel
    var showsLocation = true
    var framed = true
    @State private var expanded = false
    @State private var toggling = false
    @State private var error: String?

    var body: some View {
        let open = !thread.isResolved || expanded
        let content = VStack(alignment: .leading, spacing: 0) {
            bar(open: open)
            if open {
                Rectangle().fill(Theme.ruleSoft).frame(height: 1)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(self.thread.comments) { comment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                AuthorName(comment: comment)
                                When(date: comment.createdAt)
                            }
                            .scaled(.secondary)
                            CommentBody(comment: comment)
                        }
                    }
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                if self.thread.canReply {
                    Rectangle().fill(Theme.ruleSoft).frame(height: 1)
                    CommentBox(prompt: "Write a reply…", submit: "Reply") { await model.reply(pr, in: self.thread, body: $0) }
                        .padding(EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 14))
                }
            }
            if let error {
                Text(error).scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled).padding([.horizontal, .bottom], 14)
            }
        }
        if framed { content.conversationCard() } else { content }
    }

    private func bar(open: Bool) -> some View {
        let first = thread.comments.first
        return HStack(spacing: 10) {
            if thread.isResolved {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.quiet).frame(width: 14)
            }
            if thread.isResolved, !open, let first {
                // Folded: who started it and its first words, so it can be told from the others without opening it.
                Text(first.name).fontWeight(.semibold).lineLimit(1).frame(minWidth: 72, alignment: .leading).fixedSize()
                Text(first.firstLine).foregroundStyle(Theme.quiet).lineLimit(1)
            } else if showsLocation {
                Text(thread.location).scaled(.code.weight(.medium)).lineLimit(1).truncationMode(.head)
            } else if let line = thread.line {
                Text("Line \(line)").scaled(.secondary).foregroundStyle(Theme.quiet)
            }
            if thread.isOutdated { StageChip2(text: "Outdated") }
            Spacer(minLength: 8)
            if thread.isResolved {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ok)
                    Text("Resolved")
                }
                .scaled(.caption.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
            }
            if open {
                if toggling { ProgressView().controlSize(.mini) }
                if thread.canToggle {
                    Button(thread.isResolved ? "Unresolve" : "Resolve") {
                        Task {
                            toggling = true
                            error = await model.setResolved(pr, thread, !thread.isResolved)
                            toggling = false
                        }
                    }
                    .buttonStyle(.desk(.secondary, .small))
                    .disabled(toggling)
                }
                if let url = first?.url {
                    Button { model.open(url) } label: { GitHubMark() }
                        .buttonStyle(IconButtonStyle()).handCursor()
                        .help("The thread on GitHub")
                        .accessibilityLabel("The thread on GitHub")
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if thread.isResolved { expanded.toggle() } }
        .accessibilityAddTraits(thread.isResolved ? .isButton : [])
        .accessibilityAction { if thread.isResolved { expanded.toggle() } }
    }
}

/// Who wrote it: the name, and a bot marked as GitHub marks one.
private struct AuthorName: View {
    var comment: ConversationComment

    var body: some View {
        HStack(spacing: 4) {
            Text(comment.name).fontWeight(.semibold).foregroundStyle(Theme.ink)
            if comment.isBot {
                Text("bot").scaled(.caption).foregroundStyle(Theme.quiet)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Theme.rule))
            }
        }
    }
}

/// How long ago, in DM Mono, the exact time on hover.
private struct When: View {
    var date: Date

    var body: some View {
        Text(Format.age(date)).scaled(.code).foregroundStyle(Theme.quiet).help(Format.date(date))
    }
}

/// What a comment says. A long one, such as a bot's walkthrough, shows its start until opened.
private struct CommentBody: View {
    var comment: ConversationComment
    @State private var expanded = false
    /// Past this many characters a comment is folded.
    private static let fold = 700

    var body: some View {
        let folded = comment.body.count > Self.fold && !expanded
        VStack(alignment: .leading, spacing: 6) {
            // Folded, at its full height and cut from the bottom: within a shorter frame it is centred, and its first
            // line cut.
            MarkdownText(text: comment.body)
                .fixedSize(horizontal: false, vertical: folded)
                .frame(maxHeight: folded ? 150 : nil, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [.init(color: .black, location: 0.55), .init(color: .black.opacity(folded ? 0 : 1), location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            if comment.body.count > Self.fold {
                Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
                    .buttonStyle(.plain).underline().scaled(.secondary).foregroundStyle(Theme.quiet).handCursor()
            }
        }
    }
}

/// A box to write in, always open, with its button beside it; ⌘↩ posts while it has the focus. It grows with what is
/// written, up to ten lines. What it posts goes to GitHub as you, exactly as written.
struct CommentBox: View {
    var prompt: String
    var submit: String
    /// Posts the text: why it failed, or nil.
    var post: (String) async -> String?
    @State private var text = ""
    @State private var posting = false
    @State private var error: String?
    @FocusState private var focused: Bool
    @Environment(\.textScale) private var scale

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // ponytail: wrapped lines counted at about 90 characters each; measure the text if the box ever sizes wrong.
        let lines = min(max(text.split(separator: "\n", omittingEmptySubsequences: false).count + text.count / 90, 1), 10)
        VStack(alignment: .leading, spacing: 4) {
            // Centred on one line; from two on, the button stays by the last.
            HStack(alignment: lines == 1 ? .center : .bottom, spacing: 8) {
                TextEditor(text: $text)
                    .scaled(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: (CGFloat(lines) * 17 * scale).rounded())
                    .padding(.horizontal, 4).padding(.vertical, 6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.accentInk : Theme.control))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(prompt).scaled(.body).foregroundStyle(Theme.quiet)
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .focused($focused)
                Button(submit) { Task { await send() } }
                    .buttonStyle(.deskPrimary)
                    // Only from this box.
                    .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .disabled(posting || empty)
                    .help("Posts it to GitHub as you (⌘↩)")
            }
            if posting { ProgressView().controlSize(.mini) }
            if let error { Text(error).scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled) }
        }
    }

    private func send() async {
        posting = true
        error = await post(text)
        posting = false
        if error == nil { text = "" }
    }
}

private extension View {
    /// A conversation card's frame: white, an edge and rounded corners, a header bar inside clipped to them.
    func conversationCard() -> some View {
        background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rule))
    }
}
