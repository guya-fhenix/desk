import DeskCore
import SwiftUI

/// A PR's conversation, under its description, laid out as GitHub's: the open review threads first, each a card with
/// where it sits, every comment, and a reply box always open; then the PR's comments and the reviews that say
/// something, oldest first, and a comment box always open; the resolved threads folded at the end. Everything posted
/// goes to GitHub as you.
struct ConversationSection: View {
    var pr: PullRequest
    var model: AppModel
    @State private var showingResolved = false

    var body: some View {
        PanelSection("Conversation") {
            if let conversation = model.conversations[pr.url] {
                content(conversation)
            } else if let error = model.conversationErrors[pr.url] {
                Text("Couldn't load the conversation: \(error)").scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        // Again whenever the PR changes on GitHub, as a new comment or reply changes it.
        .task(id: "\(pr.url) \(pr.updatedAt)") { await model.loadConversation(pr) }
    }

    @ViewBuilder private func content(_ conversation: Conversation) -> some View {
        let open = conversation.openThreads
        let resolved = conversation.resolvedThreads
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if !open.isEmpty {
                group("Open threads", open.count) {
                    ForEach(open) { ThreadView(thread: $0, pr: pr, model: model) }
                }
            }
            group("Comments & reviews", conversation.entries.count) {
                ForEach(conversation.entries) { TimelineItem(entry: $0) }
                HStack(alignment: .top, spacing: 10) {
                    Avatar(login: model.state.login, size: 28)
                    CommentBox(prompt: "Leave a comment…", submit: "Comment") { await model.comment(pr, body: $0) }
                }
            }
            if !resolved.isEmpty {
                DisclosureGroup(isExpanded: $showingResolved) {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(resolved) { ThreadView(thread: $0, pr: pr, model: model) }
                    }
                    .padding(.top, Theme.Space.s)
                } label: {
                    caption("Resolved threads", resolved.count)
                }
            }
        }
    }

    private func group<Content: View>(_ title: String, _ count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            caption(title, count)
            content()
        }
    }

    /// As the Checks card heads its groups.
    private func caption(_ title: String, _ count: Int) -> some View {
        Text("\(title) · \(count)".uppercased())
            .scaled(.caption.weight(.medium))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// A comment or a review on the PR's conversation: the author's picture beside a card with who, what and when, then
/// what they wrote. A review with nothing written is one line: its verdict.
private struct TimelineItem: View {
    var entry: ConversationEntry

    var body: some View {
        let comment = entry.comment
        if comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 8) {
                Avatar(login: comment.author, url: comment.avatar, size: 20).frame(width: 28)
                Image(systemName: icon).foregroundStyle(color)
                AuthorName(comment: comment)
                Text(entry.verb ?? "commented").foregroundStyle(color)
                When(date: comment.createdAt)
            }
            .scaled(.secondary)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Avatar(login: comment.author, url: comment.avatar, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        AuthorName(comment: comment)
                        Text(entry.verb ?? "commented").foregroundStyle(entry.verb == nil ? .secondary : color)
                        When(date: comment.createdAt)
                    }
                    .scaled(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.raised)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    CommentBody(comment: comment).padding(12)
                }
                .card()
            }
        }
    }

    private var icon: String {
        switch entry.verb {
        case "approved": "checkmark.circle.fill"
        case "requested changes": "exclamationmark.circle.fill"
        default: "eye.circle.fill"
        }
    }

    private var color: Color {
        switch entry.verb {
        case "approved": .green
        case "requested changes": .orange
        default: .secondary
        }
    }
}

/// One review thread, as a card: a bar with where it sits and Resolve, every comment with its author's picture, and a
/// reply box always open. A resolved thread is folded to its bar, with who started it and how, until opened. Under its
/// own line in the diff it leaves out where it sits.
struct ThreadView: View {
    var thread: ConversationThread
    var pr: PullRequest
    var model: AppModel
    var showsLocation = true
    @State private var expanded = false
    @State private var toggling = false
    @State private var error: String?

    var body: some View {
        let open = !thread.isResolved || expanded
        VStack(alignment: .leading, spacing: 0) {
            bar(open: open)
            if open {
                Rectangle().fill(Theme.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(thread.comments) { comment in
                        HStack(alignment: .top, spacing: 10) {
                            Avatar(login: comment.author, url: comment.avatar, size: 24)
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
                }
                .padding(12)
                if thread.canReply {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    HStack(alignment: .top, spacing: 10) {
                        Avatar(login: model.state.login, size: 24)
                        CommentBox(prompt: "Write a reply…", submit: "Reply") { await model.reply(pr, in: thread, body: $0) }
                    }
                    .padding(12)
                }
            }
            if let error {
                Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled).padding([.horizontal, .bottom], 12)
            }
        }
        .card()
    }

    private func bar(open: Bool) -> some View {
        HStack(spacing: 8) {
            if thread.isResolved {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .scaled(.caption).foregroundStyle(.secondary).frame(width: 10)
            }
            if showsLocation {
                Text(thread.location).font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1).truncationMode(.head)
            } else if let line = thread.line {
                Text("Line \(line)").scaled(.caption).foregroundStyle(.secondary)
            }
            if thread.isOutdated { Chip(text: "Outdated") }
            if thread.isResolved {
                Chip(text: "Resolved", color: .green)
                // Folded: who started it and its first words, so it can be told from the others without opening it.
                if !open, let first = thread.comments.first {
                    Text("\(first.name): \(first.firstLine)").scaled(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if toggling { ProgressView().controlSize(.mini) }
            if thread.canToggle {
                Button(thread.isResolved ? "Unresolve" : "Resolve") {
                    Task {
                        toggling = true
                        error = await model.setResolved(pr, thread, !thread.isResolved)
                        toggling = false
                    }
                }
                .controlSize(.small).handCursor()
                .disabled(toggling)
            }
            if let url = thread.comments.first?.url {
                Button { model.open(url) } label: { GitHubMark() }
                    .buttonStyle(.plain).handCursor()
                    .help("The thread on GitHub")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised)
        .contentShape(Rectangle())
        .onTapGesture { if thread.isResolved { expanded.toggle() } }
    }
}

/// Who wrote it: the name, and a bot marked as GitHub marks one.
private struct AuthorName: View {
    var comment: ConversationComment

    var body: some View {
        HStack(spacing: 4) {
            Text(comment.name).fontWeight(.semibold).foregroundStyle(.primary)
            if comment.isBot {
                Text("bot").scaled(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Theme.line))
            }
        }
    }
}

/// How long ago, the exact time on hover.
private struct When: View {
    var date: Date

    var body: some View {
        Text("\(Format.age(date)) ago").foregroundStyle(.secondary).help(Format.date(date))
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
                    .buttonStyle(.link).handCursor().scaled(.caption)
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
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Theme.accent : Theme.controlBorder))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(prompt).scaled(.body).foregroundStyle(.tertiary)
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .focused($focused)
                Button(submit) { Task { await send() } }
                    .buttonStyle(.borderedProminent).handCursor()
                    // Only from this box: the review diff's Ask Claude has ⌘↩ too.
                    .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .disabled(posting || empty)
                    .help("Posts it to GitHub as you (⌘↩)")
            }
            if posting { ProgressView().controlSize(.mini) }
            if let error { Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled) }
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
    /// A conversation card's frame: an edge and rounded corners, the header bar inside clipped to them.
    func card() -> some View {
        background(Theme.raised.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}
