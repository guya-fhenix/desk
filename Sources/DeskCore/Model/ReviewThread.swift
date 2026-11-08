import Foundation

/// One unresolved review thread on your PR: where it sits, who started it and what the first comment says, so the PR
/// page can count the open threads by who started them. Read off GitHub on every refresh; the thread in full, to answer,
/// is the `Conversation`'s.
public struct ReviewThread: Codable, Sendable, Hashable, Identifiable {
    /// Who started the thread.
    public enum Source: Sendable {
        case prePR, codeRabbit, people
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

    public init(
        id: String, path: String, line: Int? = nil, isOutdated: Bool = false, url: String, author: String, body: String,
        comments: Int = 1
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.isOutdated = isOutdated
        self.url = url
        self.author = author
        self.body = body
        self.comments = comments
    }

    public var source: Source {
        if body.contains(PrePR.findingMarker) { return .prePR }
        return author == "coderabbitai" || author == PullRequest.codeRabbit ? .codeRabbit : .people
    }
}

extension Array where Element == ReviewThread {
    /// How many threads each one started: /pre-pr and CodeRabbit first, then each person, the most first.
    public var byWho: [(who: String, count: Int)] {
        let tools: [(who: String, count: Int)] = [
            ("/pre-pr", filter { $0.source == .prePR }.count),
            ("CodeRabbit", filter { $0.source == .codeRabbit }.count),
        ]
        let people = Dictionary(grouping: filter { $0.source == .people }, by: \.author)
            .map { (who: "@\($0.key)", count: $0.value.count) }
            .sorted { ($0.count, $1.who) > ($1.count, $0.who) }
        return tools.filter { $0.count > 0 } + people
    }
}

/// What the fhenix-workflow /pre-pr command leaves on a PR: one evidence comment, edited in place on every run, and a
/// marker on the first comment of each finding thread it starts.
public enum PrePR {
    public static let evidenceMarker = "<!-- pre-pr:start -->"
    public static let findingMarker = "<!-- pre-pr:finding -->"
    /// The label /pre-pr adds once none of its Important findings is open, and takes off while one is: the one the
    /// review flow's `local-review-evidence` check looks for.
    public static let reviewedLabel = "local-reviewed"
}
