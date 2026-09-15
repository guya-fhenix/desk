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
        case .rule: return "hr"
        }
    }
}

public enum Markdown {
    /// Fenced code wins over everything: a `#` or `-` inside a fence is code, not a heading or a bullet.
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fence: (language: String?, lines: [String])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

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
            paragraph.append(trimmed)
        }

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
