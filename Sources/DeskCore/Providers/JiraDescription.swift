import Foundation

/// A node of Atlassian Document Format, the tree Jira returns a description as. Every field is optional:
/// this is somebody else's format and a node shape we have not seen must read as empty, never as a crash.
public struct ADFNode: Decodable, Sendable, Hashable {
    public var type: String?
    public var text: String?
    public var content: [ADFNode]?
    public var marks: [ADFMark]?
    public var attrs: ADFAttrs?
}

public struct ADFMark: Decodable, Sendable, Hashable {
    public var type: String?
    public var attrs: ADFAttrs?
}

/// The handful of attributes the nodes here actually carry. Heterogeneous in the format, so each is
/// optional and only the ones that belong to a given node are ever read.
public struct ADFAttrs: Decodable, Sendable, Hashable {
    public var level: Int?
    /// An inline card's address.
    public var url: String?
    /// A link mark's address: links carry `href`, cards `url`.
    public var href: String?
    public var language: String?
}

/// Turns a Jira description into markdown, so `Markdown`/`MarkdownText` can draw it — the same pair that
/// already draws a pull request body. Writing a second renderer for ADF would mean two of everything.
///
/// Not a full implementation of the format: it covers the nodes Jira descriptions here actually contain,
/// and anything else falls through to its text, which is the readable half of whatever it was.
public enum JiraDescription {
    public static func markdown(_ node: ADFNode?) -> String {
        guard let node else { return "" }
        return blocks(node).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The block-level nodes, each already rendered as one markdown block.
    private static func blocks(_ node: ADFNode, depth: Int = 0) -> [String] {
        let children = node.content ?? []
        switch node.type {
        case "paragraph":
            let text = inline(children)
            return text.isEmpty ? [] : [text]
        case "heading":
            let level = min(max(node.attrs?.level ?? 1, 1), 6)
            return ["\(String(repeating: "#", count: level)) \(inline(children))"]
        case "codeBlock":
            return ["```\(node.attrs?.language ?? "")\n\(inline(children))\n```"]
        case "blockquote":
            // One block: a quote broken across markdown blocks stops being a quote.
            return [children.flatMap { blocks($0, depth: depth) }.joined(separator: "\n").split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")]
        case "bulletList", "orderedList":
            let ordered = node.type == "orderedList"
            let indent = String(repeating: "  ", count: depth)
            var items: [String] = []
            for (offset, item) in children.enumerated() {
                let marker = ordered ? "\(offset + 1)." : "-"
                // A list item holds paragraphs, and may hold a list of its own; the first line takes the
                // marker and the rest are indented under it.
                let lines = blocks(item, depth: depth + 1)
                guard let first = lines.first else { continue }
                items.append("\(indent)\(marker) \(first)")
                for line in lines.dropFirst() { items.append(line) }
            }
            // One block, or the renderer reads each bullet as a paragraph of its own.
            return items.isEmpty ? [] : [items.joined(separator: "\n")]
        case "listItem":
            return children.flatMap { blocks($0, depth: depth) }
        case "table":
            return table(children)
        case "rule":
            return ["---"]
        case "doc", nil:
            return children.flatMap { blocks($0, depth: depth) }
        default:
            // An unknown block still has its text worth showing.
            let text = inline(children)
            return text.isEmpty ? [] : [text]
        }
    }

    /// A pipe table, one line per row. The first row is the header when Jira marked its cells as headers;
    /// a cell's paragraphs and breaks fold onto its one line, since a row cannot span lines.
    private static func table(_ rows: [ADFNode]) -> [String] {
        let lines = rows.filter { $0.type == "tableRow" }.map { row in
            (row.content ?? []).map { cell in
                (cell.content ?? []).flatMap { blocks($0) }.joined(separator: " ")
                    .replacingOccurrences(of: "\\\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
            }
        }
        guard let first = lines.first, !first.isEmpty else { return [] }
        let hasHeader = rows.first?.content?.contains { $0.type == "tableHeader" } == true
        func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        var out = lines.map(line)
        // No separator row without header cells: the first row is data, and `Markdown` reads it as such.
        if hasHeader { out.insert(line(first.map { _ in "---" }), at: 1) }
        return [out.joined(separator: "\n")]
    }

    /// The text of a run of inline nodes, with the marks Jira puts on them.
    private static func inline(_ nodes: [ADFNode]) -> String {
        nodes.map(inline).joined()
    }

    private static func inline(_ node: ADFNode) -> String {
        switch node.type {
        // CommonMark's hard break, which `Markdown` keeps as a line of its own rather than running it on.
        case "hardBreak": return "\\\n"
        case "inlineCard": return node.attrs?.url ?? ""
        case "text":
            // Text Jira stores as plain must stay plain when the markdown is read back: an asterisk is not emphasis.
            let code = node.marks?.contains { $0.type == "code" } == true
            return marked(code ? node.text ?? "" : escaped(node.text ?? ""), by: node.marks ?? [])
        default:
            let nested = inline(node.content ?? [])
            return nested.isEmpty ? (node.text ?? "") : nested
        }
    }

    private static func marked(_ text: String, by marks: [ADFMark]) -> String {
        guard !text.isEmpty else { return "" }
        var result = text
        for mark in marks {
            switch mark.type {
            case "code": result = "`\(result)`"
            case "strong": result = "**\(result)**"
            case "em": result = "*\(result)*"
            case "strike": result = "~~\(result)~~"
            case "link": if let url = mark.attrs?.href ?? mark.attrs?.url { result = "[\(result)](\(url))" }
            default: break
            }
        }
        return result
    }

    /// Markdown's inline markers, backslashed, so plain text reads back as itself.
    private static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\`*_~[]".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    // MARK: Writing back

    /// Whether `markdown(_:)` says everything this description holds, so writing that markdown back loses nothing:
    /// every node and mark is one converted both ways. Mentions, images, panels, task lists, emoji, status lozenges,
    /// dates, colours and underlines are not, and a description with any of them is edited in Jira, not here.
    public static func roundTrips(_ node: ADFNode?) -> Bool {
        guard let node else { return true }
        guard let type = node.type, Self.nodes.contains(type) else { return false }
        if node.marks?.contains(where: { !Self.marks.contains($0.type ?? "") }) == true { return false }
        return (node.content ?? []).allSatisfy(roundTrips)
    }

    private static let nodes: Set<String> = [
        "doc", "paragraph", "heading", "codeBlock", "blockquote", "bulletList", "orderedList", "listItem", "table", "tableRow",
        "tableHeader", "tableCell", "rule", "text", "hardBreak", "inlineCard",
    ]
    private static let marks: Set<String> = ["code", "strong", "em", "strike", "link"]

    /// Markdown, as the edit box holds it, into the ADF Jira stores: the nodes `markdown(_:)` reads, so a description
    /// goes back the way it came. A bare address becomes a link, as an inline card read as one.
    public static func adf(fromMarkdown text: String) -> [String: Any] {
        var content: [[String: Any]] = []
        var items: [ListEntry] = []
        func flushList() {
            if !items.isEmpty { content += lists(items[...]) }
            items = []
        }
        for block in Markdown.blocks(text) {
            switch block {
            case .bullet(let indent, let text): items.append(ListEntry(indent: indent, ordered: false, number: nil, text: text))
            case .numbered(let indent, let number, let text):
                items.append(ListEntry(indent: indent, ordered: true, number: Int(number), text: text))
            case .task(let indent, let done, let text):
                items.append(ListEntry(indent: indent, ordered: false, number: nil, text: (done ? "[x] " : "[ ] ") + text))
            default:
                flushList()
                content += node(block)
            }
        }
        flushList()
        return ["type": "doc", "version": 1, "content": content]
    }

    private struct ListEntry {
        var indent: Int
        var ordered: Bool
        var number: Int?
        var text: String
    }

    private static func node(_ block: MarkdownBlock) -> [[String: Any]] {
        switch block {
        case .heading(let level, let text):
            return [["type": "heading", "attrs": ["level": level], "content": inline(text)]]
        case .paragraph(let text):
            return [paragraph(text)]
        case .code(let language, let text):
            var code: [String: Any] = ["type": "codeBlock", "content": text.isEmpty ? [] : [["type": "text", "text": text]]]
            if let language { code["attrs"] = ["language": language] }
            return [code]
        case .quote(let text):
            let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }.map(paragraph)
            return [["type": "blockquote", "content": paragraphs]]
        case .table(let header, let rows):
            func row(_ cells: [String], header: Bool) -> [String: Any] {
                ["type": "tableRow", "content": cells.map { ["type": header ? "tableHeader" : "tableCell", "content": [paragraph($0)]] }]
            }
            return [["type": "table", "content": (header.map { [row($0, header: true)] } ?? []) + rows.map { row($0, header: false) }]]
        case .rule:
            return [["type": "rule"]]
        case .bullet, .numbered, .task:
            return []
        }
    }

    /// Consecutive list lines as lists, nested by indent: a deeper line belongs to the item above it, and a change
    /// of kind at one level starts a new list.
    private static func lists(_ items: ArraySlice<ListEntry>) -> [[String: Any]] {
        guard let level = items.map(\.indent).min() else { return [] }
        var nodes: [[String: Any]] = []
        var index = items.startIndex
        while index < items.endIndex {
            let ordered = items[index].ordered
            let first = items[index].number
            var entries: [[String: Any]] = []
            while index < items.endIndex, items[index].indent <= level, items[index].ordered == ordered {
                var nested = index + 1
                while nested < items.endIndex, items[nested].indent > level { nested += 1 }
                var itemContent = [paragraph(items[index].text)]
                if nested > index + 1 { itemContent += lists(items[(index + 1)..<nested]) }
                entries.append(["type": "listItem", "content": itemContent])
                index = nested
            }
            if entries.isEmpty {
                // Deeper than any line before it at this level: a list of its own.
                var nested = index
                while nested < items.endIndex, items[nested].indent > level { nested += 1 }
                nodes += lists(items[index..<nested])
                index = nested
                continue
            }
            var list: [String: Any] = ["type": ordered ? "orderedList" : "bulletList", "content": entries]
            if ordered, let first, first != 1 { list["attrs"] = ["order": first] }
            nodes.append(list)
        }
        return nodes
    }

    private static func paragraph(_ text: String) -> [String: Any] {
        ["type": "paragraph", "content": inline(text)]
    }

    /// One block's text as text nodes with their marks; a line break inside it is a hard break. Code takes no other
    /// mark than a link, as ADF allows.
    private static func inline(_ text: String) -> [[String: Any]] {
        let parsed = Markdown.inline(text)
        var nodes: [[String: Any]] = []
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var marks: [[String: Any]] = []
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                marks.append(["type": "code"])
            } else {
                if intent.contains(.stronglyEmphasized) { marks.append(["type": "strong"]) }
                if intent.contains(.emphasized) { marks.append(["type": "em"]) }
                if intent.contains(.strikethrough) { marks.append(["type": "strike"]) }
            }
            if let link = run.link { marks.append(["type": "link", "attrs": ["href": link.absoluteString]]) }
            for (offset, line) in piece.components(separatedBy: "\n").enumerated() {
                if offset > 0 { nodes.append(["type": "hardBreak"]) }
                if line.isEmpty { continue }
                nodes += run.link == nil && !intent.contains(.code) ? linkingAddresses(line, marks: marks) : [textNode(line, marks)]
            }
        }
        return nodes
    }

    private static func textNode(_ text: String, _ marks: [[String: Any]]) -> [String: Any] {
        marks.isEmpty ? ["type": "text", "text": text] : ["type": "text", "text": text, "marks": marks]
    }

    /// Plain text with each bare http(s) address in it made a link.
    private static func linkingAddresses(_ line: String, marks: [[String: Any]]) -> [[String: Any]] {
        var nodes: [[String: Any]] = []
        var rest = Substring(line)
        while let match = rest.firstMatch(of: /https?:\/\/[^\s<>()]+/) {
            if match.range.lowerBound > rest.startIndex { nodes.append(textNode(String(rest[..<match.range.lowerBound]), marks)) }
            let address = String(match.output)
            nodes.append(textNode(address, marks + [["type": "link", "attrs": ["href": address]]]))
            rest = rest[match.range.upperBound...]
        }
        if !rest.isEmpty { nodes.append(textNode(String(rest), marks)) }
        return nodes
    }
}
