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
    public var url: String?
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
            return children.flatMap { blocks($0, depth: depth) }
        case "tableRow":
            // `Markdown` draws no tables, so a row reads as its cells: still the information, in order.
            let cells = children.map { inline($0.content ?? []) }.filter { !$0.isEmpty }
            return cells.isEmpty ? [] : [cells.joined(separator: " · ")]
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

    /// The text of a run of inline nodes, with the marks Jira puts on them.
    private static func inline(_ nodes: [ADFNode]) -> String {
        nodes.map(inline).joined()
    }

    private static func inline(_ node: ADFNode) -> String {
        switch node.type {
        case "hardBreak": return "\n"
        case "inlineCard": return node.attrs?.url ?? ""
        case "text": return marked(node.text ?? "", by: node.marks ?? [])
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
            case "link": if let url = mark.attrs?.url { result = "[\(result)](\(url))" }
            default: break
            }
        }
        return result
    }
}
