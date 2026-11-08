import DeskCore
import SwiftUI

/// A PR's conversation, under its description: the open review threads first, each with where it sits, every reply,
/// and Reply and Resolve; then the PR's comments and the reviews that say something, oldest first; the resolved threads
/// folded at the end. Write a comment posts on the PR's conversation. Everything posted goes to GitHub as you.
struct ConversationSection: View {
    var pr: PullRequest
    var model: AppModel
    @State private var writing = false
    @State private var showingResolved = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Conversation").scaled(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if !writing { Button("Write a comment") { writing = true }.handCursor() }
            }
            if writing {
                CommentComposer(prompt: "Comment on the PR", submit: "Comment") {
                    await model.comment(pr, body: $0)
                } done: {
                    writing = false
                }
            }
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
        if conversation.threads.isEmpty && conversation.entries.isEmpty {
            Text("Nothing said yet.").foregroundStyle(.secondary)
        }
        if !open.isEmpty {
            subheading("Open threads", open.count)
            ForEach(open) { ThreadView(thread: $0, pr: pr, model: model) }
        }
        if !conversation.entries.isEmpty {
            subheading("Comments & reviews", conversation.entries.count)
            ForEach(conversation.entries) { entry in
                CommentView(comment: entry.comment, verb: entry.verb).sideCard()
            }
        }
        if !resolved.isEmpty {
            DisclosureGroup(isExpanded: $showingResolved) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(resolved) { ThreadView(thread: $0, pr: pr, model: model) }
                }
                .padding(.top, Theme.Space.s)
            } label: {
                subheading("Resolved threads", resolved.count)
            }
        }
    }

    private func subheading(_ title: String, _ count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).scaled(.body.weight(.medium))
            Text("\(count)").scaled(.secondary).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// One review thread: where it sits, every comment, then Reply and Resolve, or Unresolve once resolved. A resolved
/// thread is folded to one line until opened. Under its own line in the diff it leaves out where it sits.
struct ThreadView: View {
    var thread: ConversationThread
    var pr: PullRequest
    var model: AppModel
    var showsLocation = true
    @State private var expanded = false
    @State private var replying = false
    @State private var toggling = false
    @State private var error: String?

    var body: some View {
        let open = !thread.isResolved || expanded
        VStack(alignment: .leading, spacing: 10) {
            header(open: open)
            if open {
                ForEach(thread.comments) { CommentView(comment: $0) }
                if replying {
                    CommentComposer(prompt: "Reply", submit: "Reply") {
                        await model.reply(pr, in: thread, body: $0)
                    } done: {
                        replying = false
                    }
                } else {
                    actions
                }
                if let error { Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .sideCard()
    }

    private func header(open: Bool) -> some View {
        HStack(spacing: 6) {
            if thread.isResolved {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .scaled(.caption).foregroundStyle(.secondary).frame(width: 12)
            }
            if showsLocation {
                Text(thread.location).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
            }
            if thread.isOutdated { Chip(text: "Outdated") }
            if thread.isResolved {
                Chip(text: "Resolved", color: .green)
                // Folded: who started it and its first words, so it can be told from the others without opening it.
                if !open, let first = thread.comments.first {
                    Text("\(first.author): \(first.firstLine)").scaled(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let url = thread.comments.first?.url {
                Button { model.open(url) } label: { GitHubMark() }
                    .buttonStyle(.plain).handCursor()
                    .help("The thread on GitHub")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if thread.isResolved { expanded.toggle() } }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if thread.canReply { Button("Reply") { replying = true }.handCursor() }
            if thread.canToggle {
                Button(thread.isResolved ? "Unresolve" : "Resolve") {
                    Task {
                        toggling = true
                        error = await model.setResolved(pr, thread, !thread.isResolved)
                        toggling = false
                    }
                }
                .handCursor()
                .disabled(toggling)
            }
            if toggling { ProgressView().controlSize(.mini) }
        }
        .controlSize(.small)
    }
}

/// One comment: who wrote it, what a review did, and when; then what it says. A long one, such as a bot's walkthrough,
/// shows its start until opened.
struct CommentView: View {
    var comment: ConversationComment
    var verb: String? = nil
    @State private var expanded = false
    /// Past this many characters a comment is folded.
    private static let fold = 700

    var body: some View {
        let long = comment.body.count > Self.fold
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(comment.author).fontWeight(.semibold)
                if let verb { Text(verb).foregroundStyle(verbColor) }
                Text("\(Format.age(comment.createdAt)) ago").foregroundStyle(.secondary).help(Format.date(comment.createdAt))
            }
            .scaled(.caption)
            if !comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownText(text: comment.body)
                    .frame(maxHeight: long && !expanded ? 140 : nil, alignment: .top)
                    .clipped()
                    .mask {
                        LinearGradient(
                            stops: [.init(color: .black, location: 0.6), .init(color: .black.opacity(long && !expanded ? 0 : 1), location: 1)],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                if long {
                    Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
                        .buttonStyle(.link).handCursor().scaled(.caption)
                }
            }
        }
    }

    private var verbColor: Color {
        switch verb {
        case "approved": .green
        case "requested changes": .orange
        default: .secondary
        }
    }
}

/// A box to write in, with the press that posts it and Cancel; ⌘↩ posts while it has the focus. What it posts goes to
/// GitHub as you, exactly as written.
struct CommentComposer: View {
    var prompt: String
    var submit: String
    /// Posts the text: why it failed, or nil.
    var post: (String) async -> String?
    var done: () -> Void
    @State private var text = ""
    @State private var posting = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .scaled(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 70, maxHeight: 220)
                .padding(6)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.controlBorder))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(prompt).scaled(.body).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .focused($focused)
            if let error { Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack(spacing: 8) {
                Text("Markdown. Posted to GitHub as you.").scaled(.caption).foregroundStyle(.secondary)
                Spacer()
                if posting { ProgressView().controlSize(.mini) }
                Button("Cancel") { done() }.handCursor().disabled(posting)
                Button(submit) { Task { await send() } }
                    .buttonStyle(.borderedProminent).handCursor()
                    // Only from this box: the review diff's Ask Claude has ⌘↩ too.
                    .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .disabled(posting || empty)
            }
            .controlSize(.small)
        }
        .onAppear { focused = true }
    }

    private func send() async {
        posting = true
        error = await post(text)
        posting = false
        if error == nil {
            text = ""
            done()
        }
    }
}
