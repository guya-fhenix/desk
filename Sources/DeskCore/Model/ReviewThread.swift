import Foundation

/// One unresolved review thread on your PR: where it sits, who started it and what the first comment says, so the PR
/// page can count the open threads by who started them. Read off GitHub on every refresh; the thread in full, to answer,
/// is the `Conversation`'s.
public struct ReviewThread: Codable, Sendable, Hashable, Identifiable {
    /// Who started the thread.
    public enum Source: Sendable {
        case codeRabbit, people
    }

    /// The node id.
    public var id: String
    public var path: String
    /// The line it sits on, or sat on before the code moved; nil on a comment on the whole file.
    public var line: Int?
    public var isOutdated: Bool
    /// The first comment on GitHub.
    public var url: String
    /// Who wrote the first comment, a bot's with its `[bot]`.
    public var author: String
    /// The first comment, as written.
    public var body: String
    /// Every comment in the thread, the first included.
    public var comments: Int
    /// Who wrote the newest comment, and when: whether the thread waits on the PR's author, and since when.
    public var lastAuthor: String?
    public var lastAt: Date?

    public init(
        id: String, path: String, line: Int? = nil, isOutdated: Bool = false, url: String, author: String, body: String,
        comments: Int = 1, lastAuthor: String? = nil, lastAt: Date? = nil
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.isOutdated = isOutdated
        self.url = url
        self.author = author
        self.body = body
        self.comments = comments
        self.lastAuthor = lastAuthor
        self.lastAt = lastAt
    }

    public var source: Source {
        return author == "coderabbitai" || author == PullRequest.codeRabbit ? .codeRabbit : .people
    }
}

extension Array where Element == ReviewThread {
    /// How many threads each one started: CodeRabbit first, then each person, the most first.
    public var byWho: [(who: String, count: Int)] {
        let tools: [(who: String, count: Int)] = [("CodeRabbit", filter { $0.source == .codeRabbit }.count)]
        let people = Dictionary(grouping: filter { $0.source == .people }, by: \.author)
            .map { (who: "@\($0.key)", count: $0.value.count) }
            .sorted { ($0.count, $1.who) > ($1.count, $0.who) }
        return tools.filter { $0.count > 0 } + people
    }
}

/// What the fhenix-workflow self-review leaves on a PR: only its label. Its findings stay in the author's session.
public enum SelfReview {
    /// The label the self-review adds once none of its Important findings is open, and takes off while one is: the one
    /// the review flow's `local-review-evidence` check looks for.
    public static let reviewedLabel = "local-reviewed"
}
