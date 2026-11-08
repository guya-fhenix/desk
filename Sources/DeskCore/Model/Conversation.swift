import Foundation

/// Everything said on a PR: its review threads with every reply, and the comments and review summaries on its
/// conversation. Fetched when its page or its review diff shows it, not kept between launches.
public struct Conversation: Sendable, Hashable {
    public var threads: [ConversationThread]
    /// The PR's own comments and the reviews that say something, oldest first.
    public var entries: [ConversationEntry]

    public init(threads: [ConversationThread], entries: [ConversationEntry]) {
        self.threads = threads
        self.entries = entries
    }

    public var openThreads: [ConversationThread] { threads.filter { !$0.isResolved } }
    public var resolvedThreads: [ConversationThread] { threads.filter(\.isResolved) }

    /// The threads the diff can show under a line: open or resolved, but not outdated, whose line moved away.
    public func threads(at path: String, side: DiffSide, line: Int) -> [ConversationThread] {
        threads.filter { !$0.isOutdated && $0.path == path && $0.side == side && $0.line == line }
    }
}

public struct ConversationComment: Sendable, Hashable, Identifiable {
    public var id: String
    /// A bot's with its `[bot]`.
    public var author: String
    /// The author's picture, as GitHub serves it: a bot's too, which `github.com/<login>.png` has not.
    public var avatar: String?
    public var body: String
    public var createdAt: Date
    public var url: String

    public init(id: String, author: String, avatar: String? = nil, body: String, createdAt: Date, url: String) {
        self.id = id
        self.author = author
        self.avatar = avatar
        self.body = body
        self.createdAt = createdAt
        self.url = url
    }

    public var isBot: Bool { author.hasSuffix("[bot]") }
    /// The name to show: a bot's without its `[bot]`, which the view marks its own way.
    public var name: String { isBot ? String(author.dropLast(5)) : author }

    /// Its first line of text, without the HTML comments and tags GitHub hides or Markdown's emphasis marks, for a
    /// folded thread.
    public var firstLine: String {
        let visible = body.replacing(/<!--[\s\S]*?-->/, with: "").replacing(/<[^>]+>/, with: "").replacing(/[*_`]+/, with: "")
        return visible.split(whereSeparator: \.isNewline)
            .map { $0.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

public struct ConversationThread: Sendable, Hashable, Identifiable {
    public var id: String
    public var path: String
    /// The line it ends on, on its side of the diff; for an outdated thread the line it sat on when written; nil on a
    /// comment on the whole file.
    public var line: Int?
    public var side: DiffSide
    public var isResolved: Bool
    public var isOutdated: Bool
    public var canReply: Bool
    /// Resolve while open, unresolve while resolved: GitHub says which you may.
    public var canToggle: Bool
    public var comments: [ConversationComment]

    public init(
        id: String, path: String, line: Int?, side: DiffSide = .right, isResolved: Bool = false, isOutdated: Bool = false,
        canReply: Bool = true, canToggle: Bool = true, comments: [ConversationComment]
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.side = side
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.canReply = canReply
        self.canToggle = canToggle
        self.comments = comments
    }

    /// "src/gate.rs:42", or the path alone on a file comment.
    public var location: String { line.map { "\(path):\($0)" } ?? path }
}

public struct ConversationEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case comment
        /// A submitted review, in GitHub's words: APPROVED, CHANGES_REQUESTED, COMMENTED or DISMISSED.
        case review(state: String)
    }

    public var kind: Kind
    public var comment: ConversationComment
    public var id: String { comment.id }

    /// What a review did, as its line says it: "approved", "requested changes", "reviewed"; nil on a comment.
    public var verb: String? {
        guard case .review(let state) = kind else { return nil }
        switch state {
        case "APPROVED": return "approved"
        case "CHANGES_REQUESTED": return "requested changes"
        case "DISMISSED": return "reviewed (dismissed)"
        default: return "reviewed"
        }
    }

    public init(kind: Kind, comment: ConversationComment) {
        self.kind = kind
        self.comment = comment
    }
}
