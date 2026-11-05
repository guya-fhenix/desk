import Foundation

/// One unresolved review thread on your PR, as its page lists it: where it sits, who started it and what the first
/// comment says. Read off GitHub on every refresh; the app never writes to a thread.
public struct ReviewThread: Codable, Sendable, Hashable, Identifiable {
    /// Who started the thread, in the order the page groups them.
    public enum Source: Int, Sendable, CaseIterable, Identifiable {
        case prePR, codeRabbit, people

        public var id: Self { self }

        public var title: String {
            switch self {
            case .prePR: return "/pre-pr"
            case .codeRabbit: return "CodeRabbit"
            case .people: return "People"
            }
        }
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

    public var severity: CommentSeverity? { Self.severity(of: body) }

    /// `path:line`, or the path alone.
    public var place: String { line.map { "\(path):\($0)" } ?? path }

    /// The first comment on one line, without its HTML comments: a collapsed row, and the prompt's quote.
    public var preview: String {
        body.replacing(/<!--[\s\S]*?-->/, with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The severity a comment leads with, read off the emphasis on its first line: /pre-pr's `**Important**` or `**Nit**`
    /// under its marker, CodeRabbit's `**Major** · **Security** · …`, or its older `_⚠️ Potential issue_ | _🟠 Major_`.
    /// Critical and Major read as Important; Minor, Trivial and Nitpick as Nit; anything else as none. A line that does not
    /// open with emphasis is prose, whatever it stresses further on.
    public static func severity(of body: String) -> CommentSeverity? {
        let first = body.replacing(/<!--[\s\S]*?-->/, with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard first.hasPrefix("**") || first.hasPrefix("_") else { return nil }
        for match in first.matches(of: /\*\*([^*]+)\*\*|_([^_]+)_/) {
            let text = match.output.1 ?? match.output.2 ?? ""
            for word in text.split(whereSeparator: { !$0.isLetter }) {
                switch word.lowercased() {
                case "important", "critical", "major": return .important
                case "nit", "nitpick", "minor", "trivial": return .nit
                default: continue
                }
            }
        }
        return nil
    }
}

extension Array where Element == ReviewThread {
    /// /pre-pr's first, then CodeRabbit's, then people's; in each, Important, then Nit, then the rest, then by file and line.
    public var ordered: [ReviewThread] {
        sorted { a, b in
            let rank = { (t: ReviewThread) in (t.source.rawValue, t.severity?.rank ?? CommentSeverity.allCases.count, t.path, t.line ?? 0) }
            return rank(a) < rank(b)
        }
    }
}

/// What the fhenix-workflow /pre-pr command leaves on a PR: one evidence comment, edited in place on every run, and a
/// marker on the first comment of each finding thread it starts.
public enum PrePR {
    public static let evidenceMarker = "<!-- pre-pr:start -->"
    public static let findingMarker = "<!-- pre-pr:finding -->"

    /// The parts of the evidence comment a PR page shows.
    public struct Evidence: Sendable, Hashable {
        public struct Section: Sendable, Hashable {
            public var title: String
            /// Markdown, HTML comments gone.
            public var text: String
        }

        /// Risk's tier line: "Tier: low. Needs a person: no. Expected approvals: 0."
        public var tier: String?
        /// Testing, Risk and How to revert, the ones the comment has, in its order.
        public var sections: [Section]
    }

    private static let shownSections = ["Testing", "Risk", "How to revert"]

    /// Splits the comment at its `## ` headings and keeps the sections the page shows.
    public static func evidence(_ body: String) -> Evidence {
        var sections: [Evidence.Section] = []
        var current: Evidence.Section?
        let visible = body.replacingOccurrences(of: "\r\n", with: "\n").replacing(/<!--[\s\S]*?-->/, with: "")
        for line in visible.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if let current { sections.append(current) }
                current = Evidence.Section(title: line.dropFirst(3).trimmingCharacters(in: .whitespaces), text: "")
            } else {
                current?.text += line + "\n"
            }
        }
        if let current { sections.append(current) }
        let shown = sections
            .filter { shownSections.contains($0.title) }
            .map { Evidence.Section(title: $0.title, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let tier = shown.first { $0.title == "Risk" }?.text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-* ")) }
            .first { $0.hasPrefix("Tier:") }
        return Evidence(tier: tier, sections: shown)
    }
}
