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
    /// The diff around the line, as GitHub keeps it with the first comment: its `@@` header, then the hunk down to the
    /// commented line. Nil on a comment on the whole file.
    public var diffHunk: String?

    public init(
        id: String, path: String, line: Int? = nil, isOutdated: Bool = false, url: String, author: String, body: String,
        comments: Int = 1, diffHunk: String? = nil
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.isOutdated = isOutdated
        self.url = url
        self.author = author
        self.body = body
        self.comments = comments
        self.diffHunk = diffHunk
    }

    public var source: Source {
        if body.contains(PrePR.findingMarker) { return .prePR }
        return author == "coderabbitai" || author == PullRequest.codeRabbit ? .codeRabbit : .people
    }

    public var severity: CommentSeverity? { Self.severity(of: body) }

    /// `path:line`, or the path alone.
    public var place: String { line.map { "\(path):\($0)" } ?? path }

    /// The finding on one line: its title, or its first line of text. A collapsed row, and the prompt's quote.
    public var preview: String {
        let finding = finding
        return finding.title ?? finding.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
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

// MARK: - What a thread says, and the code it is on

extension ReviewThread {
    /// The first comment as a finding: its title, where the tool gives one, and the rest as markdown, without the HTML
    /// and the collapsed boilerplate review tools wrap it in.
    public struct Finding: Sendable, Hashable {
        public var title: String?
        public var text: String
    }

    public var finding: Finding {
        var lines = Self.clean(body).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func dropLeadingBlanks() { while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() } }
        dropLeadingBlanks()
        var title: String?
        switch source {
        case .prePR:
            // `**Important** · <rule> · <title>`: the title is the last part.
            if let first = lines.first, first.hasPrefix("**") {
                title = Self.unbold(first.components(separatedBy: " · ").last ?? first)
                lines.removeFirst()
            }
        case .codeRabbit:
            // `**Major** · **Category** · **Effort**`, then the title in bold on a line of its own.
            if let first = lines.first, first.hasPrefix("**") || first.hasPrefix("_"), first.contains("·") || first.contains("|") {
                lines.removeFirst()
                dropLeadingBlanks()
            }
            if let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("**"), first.hasSuffix("**"),
               first.count > 4 {
                title = Self.unbold(first)
                lines.removeFirst()
            }
        case .people:
            break
        }
        dropLeadingBlanks()
        return Finding(title: title, text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func unbold(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Summaries of `<details>` blocks a reader has no use for: the tools' own working and their prompts for agents.
    private static let boilerplate = [
        "prompt for ai agents", "supported by static analysis", "analysis chain", "script executed", "committable suggestion",
        "review details", "learnings", "additional comments", "tools", "fingerprint",
    ]

    /// A comment's body without HTML comments, pictures and images, without the boilerplate `<details>` blocks, and with
    /// the others opened into a bold heading and their content.
    public static func clean(_ body: String) -> String {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n").replacing(/<!--[\s\S]*?-->/, with: "")
        // Innermost first: the last `<details` has no other one inside it.
        while let open = text.range(of: "<details", options: .backwards),
              let close = text.range(of: "</details>", range: open.upperBound..<text.endIndex) {
            let block = String(text[open.lowerBound..<close.upperBound])
            let summary = block.firstMatch(of: /<summary>([\s\S]*?)<\/summary>/).map { String($0.output.1) } ?? ""
            let plainSummary = summary.replacing(/<[^>]*>/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement: String
            if boilerplate.contains(where: { plainSummary.lowercased().contains($0) }) {
                replacement = ""
            } else {
                let inner = block
                    .replacing(/^<details[^>]*>/, with: "")
                    .replacing(/<\/details>$/, with: "")
                    .replacing(/<summary>[\s\S]*?<\/summary>/, with: "")
                replacement = (plainSummary.isEmpty ? "" : "\n**\(plainSummary)**\n") + inner + "\n"
            }
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: replacement)
        }
        text = text
            // A picture sits inside the bold, before its word: `**<picture>…</picture> Minor**`. It goes with the spaces
            // after it, and never a line break.
            .replacing(/<picture>[\s\S]*?<\/picture>[ \t]*/, with: "")
            .replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
            .replacing(/<\/?(?:img|source|sub|sup|dl|dd|dt|br|p|div|span|blockquote)\b[^>]*>[ \t]*/.ignoresCase(), with: "")
            .replacing(/\n{3,}/, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The last lines of the diff hunk, down to the commented line, each with its number in the new file.
    public func codeLines(last count: Int = 6) -> [HunkLine] {
        guard let diffHunk else { return [] }
        return Array(HunkLine.parse(diffHunk).suffix(count))
    }
}

/// One line of a diff hunk, as a thread shows the code it is on.
public struct HunkLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case context, added, removed }
    public var kind: Kind
    /// Its number in the new file; nil for a removed line.
    public var number: Int?
    public var text: String

    /// The lines after a `@@ -a,b +c,d @@` header, numbered from `c`.
    public static func parse(_ hunk: String) -> [HunkLine] {
        var lines: [HunkLine] = []
        var next = 1
        for raw in hunk.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("@@") {
                if let match = raw.firstMatch(of: /\+(\d+)/), let start = Int(match.output.1) { next = start }
                continue
            }
            let text = String(raw.dropFirst())
            switch raw.first {
            case "+":
                lines.append(HunkLine(kind: .added, number: next, text: text)); next += 1
            case "-":
                lines.append(HunkLine(kind: .removed, number: nil, text: text))
            case "\\":
                continue // "\ No newline at end of file"
            default:
                lines.append(HunkLine(kind: .context, number: next, text: text)); next += 1
            }
        }
        return lines
    }
}
