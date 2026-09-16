import DeskCore
import SwiftUI

/// The changed files, with what each one carries. Clicking a file scrolls the diff to it; clicking a
/// comment scrolls straight to the card.
struct ReviewFileList: View {
    let document: DiffDocument
    let comments: [DraftComment]
    let select: (DiffDocument.File) -> Void
    let jump: (DraftComment) -> Void

    var body: some View {
        let byPath = Dictionary(grouping: comments, by: \.path)
        List {
            Section("Files (\(document.files.count))") {
                ForEach(document.files) { file in
                    FileRow(file: file, comments: byPath[file.path] ?? [], select: { select(file) }, jump: jump)
                }
            }
            if !comments.isEmpty {
                Section("Undecided (\(comments.filter { $0.state == .pending }.count))") {
                    ForEach(comments.filter { $0.state == .pending }) { comment in
                        CommentLink(comment: comment, jump: jump)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct FileRow: View {
    let file: DiffDocument.File
    let comments: [DraftComment]
    let select: () -> Void
    let jump: (DraftComment) -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Text(file.file.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if !comments.isEmpty {
                    Chip(text: "\(comments.count)", color: comments.contains { $0.severity.isBlocking } ? .red : .orange)
                }
                AddDeleteCounts(additions: file.file.additions, deletions: file.file.deletions)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.path)
    }
}

private struct CommentLink: View {
    let comment: DraftComment
    let jump: (DraftComment) -> Void

    var body: some View {
        Button { jump(comment) } label: {
            HStack(spacing: 6) {
                StatusDot(color: DiffPalette.severity(comment.severity))
                VStack(alignment: .leading, spacing: 1) {
                    Text(comment.text).scaled(.caption).lineLimit(2)
                    Text("\(comment.path.split(separator: "/").last.map(String.init) ?? comment.path):\(comment.line)")
                        .scaled(.caption2).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
