import Foundation

/// The little of GitHub-flavoured markdown a PR description actually uses, split into blocks the UI can
/// draw. Inline emphasis is left in the text for `AttributedString` to handle; this only finds structure.
public enum MarkdownBlock: Sendable, Hashable, Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(indent: Int, text: String)
    /// A `- [ ]` / `- [x]` checklist item, which PR templates lean on heavily.
    case task(indent: Int, done: Bool, text: String)
    case numbered(indent: Int, number: String, text: String)
    case code(language: String?, text: String)
    case quote(String)
    /// A pipe table. `header` is nil when the table has no separator row under its first line.
    case table(header: [String]?, rows: [[String]])
    case rule

    public var id: String {
        switch self {
        case .heading(let level, let text): return "h\(level):\(text)"
        case .paragraph(let text): return "p:\(text)"
        case .bullet(let indent, let text): return "b\(indent):\(text)"
        case .task(let indent, let done, let text): return "t\(indent):\(done):\(text)"
        case .numbered(let indent, let number, let text): return "n\(indent):\(number):\(text)"
        case .code(let language, let text): return "c:\(language ?? ""):\(text)"
        case .quote(let text): return "q:\(text)"
        case .table(let header, let rows): return "tbl:\(header ?? []):\(rows)"
        case .rule: return "hr"
        }
    }
}

public enum Markdown {
    /// Fenced code wins over everything: a `#` or `-` inside a fence is code, not a heading or a bullet.
    ///
    /// A line ending in a backslash or two spaces is a hard break (CommonMark's): the next plain line
    /// stays on a line of its own in the same paragraph or list item instead of being run into it. Jira
    /// descriptions are full of them, and joining them turns a list of steps into one long sentence.
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph = ""
        var fence: (language: String?, lines: [String])?
        var table: [String] = []
        var brokeLine = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph))
            paragraph = ""
        }

        func flushTable() {
            guard !table.isEmpty else { return }
            blocks.append(tableBlock(table))
            table = []
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            let continues = brokeLine
            brokeLine = false

            if fence == nil, trimmed.hasPrefix("|") {
                flushParagraph()
                table.append(trimmed)
                continue
            }
            flushTable()

            if trimmed.hasPrefix("```") {
                if let open = fence {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    flushParagraph()
                    let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    fence = (language.isEmpty ? nil : language, [])
                }
                continue
            }
            if fence != nil {
                fence?.lines.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if line.hasSuffix("  ") || (trimmed.hasSuffix("\\") && !trimmed.hasSuffix("\\\\")) {
                brokeLine = true
                if trimmed.hasSuffix("\\") { trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces) }
                // Two breaks in a row are a blank line: the block ends there, as it does in Jira.
                if trimmed.isEmpty {
                    flushParagraph()
                    brokeLine = false
                    continue
                }
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(trimmed == ">" ? 1 : 2))))
                continue
            }
            let indent = (line.prefix { $0 == " " || $0 == "\t" }.count) / 2
            if let marker = trimmed.first, "-*+".contains(marker), trimmed.dropFirst().hasPrefix(" ") {
                flushParagraph()
                let item = String(trimmed.dropFirst(2))
                if let box = checkbox(item) {
                    blocks.append(.task(indent: indent, done: box.done, text: box.text))
                } else {
                    blocks.append(.bullet(indent: indent, text: item))
                }
                continue
            }
            if let numbered = numbered(trimmed, indent: indent) {
                flushParagraph()
                blocks.append(numbered)
                continue
            }
            // A line after a hard break continues whatever it broke: the paragraph, or the list item above.
            if continues, paragraph.isEmpty, let last = blocks.popLast() {
                blocks.append(appending(trimmed, to: last))
            } else if paragraph.isEmpty {
                paragraph = trimmed
            } else {
                paragraph += (continues ? "\n" : " ") + trimmed
            }
        }
        flushTable()

        // An unterminated fence is still code; dropping it would lose the text entirely. The trailing
        // blank line a file's final newline leaves behind is not part of it.
        if let open = fence {
            var lines = open.lines
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            blocks.append(.code(language: open.language, text: lines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    /// Adds a broken-off line to the block it belongs to. Only text-carrying items can take one; anything
    /// else keeps its shape and the line starts a paragraph of its own after it.
    private static func appending(_ line: String, to block: MarkdownBlock) -> MarkdownBlock {
        switch block {
        case .bullet(let indent, let text): return .bullet(indent: indent, text: text + "\n" + line)
        case .task(let indent, let done, let text): return .task(indent: indent, done: done, text: text + "\n" + line)
        case .numbered(let indent, let number, let text): return .numbered(indent: indent, number: number, text: text + "\n" + line)
        case .paragraph(let text): return .paragraph(text + "\n" + line)
        default: return block
        }
    }

    /// Consecutive `|` lines. A second line of only dashes (and colons) makes the first one the header.
    private static func tableBlock(_ lines: [String]) -> MarkdownBlock {
        var rows = lines.map(cells)
        let isSeparator: ([String]) -> Bool = { row in
            !row.isEmpty && row.allSatisfy { cell in
                let bare = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return bare.count >= 3 && bare.allSatisfy { $0 == "-" }
            }
        }
        var header: [String]?
        if rows.count > 1, isSeparator(rows[1]) {
            header = rows[0]
            rows.removeFirst(2)
        }
        return .table(header: header, rows: rows)
    }

    /// The cells of one `| a | b |` line. `\|` is a pipe inside a cell, not a border.
    private static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        // The borders at either end leave an empty cell outside the table.
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    private static func checkbox(_ item: String) -> (done: Bool, text: String)? {
        let marks = ["[ ] ": false, "[x] ": true, "[X] ": true]
        for (prefix, done) in marks where item.hasPrefix(prefix) {
            return (done, String(item.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return .heading(level: hashes, text: String(trimmed.dropFirst(hashes + 1)))
    }

    private static func numbered(_ trimmed: String, indent: Int) -> MarkdownBlock? {
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return .numbered(indent: indent, number: String(digits), text: String(trimmed.dropFirst(digits.count + 2)))
    }

    /// Inline markdown for one block of text. Falls back to the raw text when it will not parse, which
    /// matters for descriptions full of half-written markup.
    public static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
