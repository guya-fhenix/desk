import DeskCore
import SwiftUI

/// Draws the blocks `Markdown` finds. Deliberately small: a PR description is prose, lists and the odd
/// code fence, not a document format.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Markdown.blocks(text)) { block in
                switch block {
                case .heading(let level, let text):
                    Text(Markdown.inline(text))
                        .font(.system(size: level <= 1 ? 15 : level == 2 ? 13.5 : 12.5, weight: .semibold))
                        .padding(.top, 2)
                case .paragraph(let text):
                    Text(Markdown.inline(text)).font(.callout)
                case .bullet(let indent, let text):
                    row(indent: indent, marker: "•", text: text)
                case .task(let indent, let done, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: done ? "checkmark.square.fill" : "square")
                            .font(.caption)
                            .foregroundStyle(done ? Color.green : .secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(Markdown.inline(text)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(min(indent, 4)) * 14)
                case .numbered(let indent, let number, let text):
                    row(indent: indent, marker: "\(number).", text: text)
                case .code(_, let text):
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                case .quote(let text):
                    HStack(spacing: 8) {
                        Rectangle().fill(.tertiary).frame(width: 3)
                        Text(Markdown.inline(text)).font(.callout).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .rule:
                    Divider()
                }
            }
        }
        // Never `fixedSize` on the whole stack: it asks for an ideal height at whatever width is proposed,
        // and a near-zero proposal makes this thousands of points tall.
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func row(indent: Int, marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker).font(.callout).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
            Text(Markdown.inline(text)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(min(indent, 4)) * 14)
    }
}
