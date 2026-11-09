import DeskCore
import SwiftUI

/// Draws the blocks `Markdown` finds — a PR body or a Jira description. Spaced the way Jira spaces a
/// description, since that is what these read best next to: roomy lines, a clear gap between paragraphs,
/// list items kept together, headings set off from what came before, and code on a tinted ground.
struct MarkdownText: View {
    @Environment(\.textScale) private var scale
    let text: String

    private static let bodySize: CGFloat = 13
    private static let lineSpacing: CGFloat = 3.5

    var body: some View {
        stack(Markdown.blocks(text))
            // Never `fixedSize` on the whole stack: it asks for an ideal height at whatever width is proposed,
            // and a near-zero proposal makes this thousands of points tall.
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// Blocks one under another, the text's and a quote's own.
    private func stack(_ blocks: [MarkdownBlock]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // By position: two identical paragraphs are legitimate, and an id built from text would collide.
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, index == 0 ? 0 : gap(after: blocks[index - 1], before: block) * scale)
            }
        }
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .scaled(level <= 1 ? .headline : .body.weight(.semibold))
        case .paragraph(let text):
            prose(text)
        case .bullet(let indent, let text):
            item(indent: indent, marker: Text(Self.bullets[min(indent, Self.bullets.count - 1)]), text: text)
        case .task(let indent, let done, let text):
            item(
                indent: indent,
                marker: Text(Image(systemName: done ? "checkmark.square.fill" : "square"))
                    .foregroundStyle(done ? Color.green : .secondary),
                text: text
            )
        case .numbered(let indent, let number, let text):
            item(indent: indent, marker: Text("\(number)."), text: text)
        case .code(_, let text):
            ScrollView(.horizontal) {
                Text(text)
                    .scaled(.code)
                    .lineSpacing(2)
                    .padding(10)
            }
            // The same for a long code line's scroller.
            .contentMargins(.bottom, 6, for: .scrollContent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        case .quote(let blocks):
            HStack(spacing: 10) {
                Rectangle().fill(.tertiary).frame(width: 3)
                // Type-erased: a quote's blocks may hold a quote, and an opaque type can't hold itself.
                AnyView(stack(blocks)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows, inline: inline)
        case .rule:
            Divider()
        }
    }

    /// Jira's rhythm: list items sit close, blocks breathe, and a heading takes more room above it than below.
    private func gap(after previous: MarkdownBlock, before block: MarkdownBlock) -> CGFloat {
        if case .heading = block { return 18 }
        if case .heading = previous { return 6 }
        if previous.isListItem && block.isListItem { return 4 }
        return 12
    }

    private func prose(_ text: String) -> some View {
        Text(inline(text))
            .scaled(.body)
            .lineSpacing(Self.lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func item(indent: Int, marker: Text, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker.scaled(.body).foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
            prose(text)
        }
        .padding(.leading, CGFloat(min(indent, 4)) * 20 * scale)
    }

    /// The marker changes with depth, as Jira's does, so a nested list reads as nested at a glance.
    private static let bullets = ["•", "◦", "▪︎"]

    /// Inline markdown with code set on a tinted ground. SwiftUI's own rendering only switches the font,
    /// which in a sentence full of identifiers makes them hard to pick out.
    private func inline(_ text: String) -> AttributedString {
        var string = Markdown.inline(text)
        for run in string.runs where run.inlinePresentationIntent?.contains(.code) == true {
            string[run.range].font = .system(size: ((Self.bodySize - 1) * scale).rounded(), design: .monospaced)
            string[run.range].backgroundColor = Color.secondary.opacity(0.14)
        }
        return string
    }
}

/// A pipe table as a grid with ruled cells and a shaded header, scrolled sideways when it is wider than
/// the column it sits in. Cells wrap up to a cap, so one long cell cannot push the rest out of sight.
private struct MarkdownTable: View {
    let header: [String]?
    let rows: [[String]]
    let inline: (String) -> AttributedString

    private var columns: Int { max(header?.count ?? 0, rows.map(\.count).max() ?? 0) }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                if let header {
                    GridRow { ForEach(0..<columns, id: \.self) { cell(header, $0, isHeader: true) } }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(0..<columns, id: \.self) { cell(row, $0, isHeader: false) } }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // Room under the grid for the horizontal scroller, which otherwise draws over the last row.
        .contentMargins(.bottom, 12, for: .scrollContent)
    }

    private func cell(_ row: [String], _ column: Int, isHeader: Bool) -> some View {
        Text(inline(column < row.count ? row[column] : ""))
            .scaled(isHeader ? .secondary.weight(.semibold) : .secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 60, maxWidth: 260, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isHeader ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
            .overlay(Rectangle().strokeBorder(.separator, lineWidth: 0.5))
    }
}

private extension MarkdownBlock {
    var isListItem: Bool {
        switch self {
        case .bullet, .task, .numbered: return true
        default: return false
        }
    }
}
