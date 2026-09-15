import AppKit
import DeskCore
import SwiftUI

/// The diff, with each comment pinned under the line it is about.
///
/// This view never reads `model.state`. Everything it draws arrives as a value and it is used with
/// `.equatable()`, so the four pollers — one of them every 30 seconds — cannot walk a several-thousand
/// element ForEach for nothing. Actions go out as `model.method(…)` calls, which register no observation
/// dependency; reading a property would. Keep it that way.
struct DiffPane: View, Equatable {
    let document: DiffDocument
    let comments: [DraftComment]
    let target: DiffScrollTarget?
    let readOnly: Bool
    var model: AppModel
    var prUrl: String

    @Binding var drafts: [UUID: String]
    @State private var folded: Set<Int> = []
    @FocusState private var focused: UUID?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.document.headSha == rhs.document.headSha && lhs.document.rows.count == rhs.document.rows.count
            && lhs.comments == rhs.comments && lhs.target == rhs.target && lhs.readOnly == rhs.readOnly
            && lhs.drafts == rhs.drafts && lhs.prUrl == rhs.prUrl && lhs.model === rhs.model
    }

    var body: some View {
        // Hoisted: a computed property would re-index every comment once per visible row.
        let keys = document.commentableKeys
        let anchored = Dictionary(grouping: comments.filter { keys.contains($0.key) }, by: \.key)
        let loose = Dictionary(grouping: comments.filter { !keys.contains($0.key) }, by: \.path)
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(document.files) { file in
                        Section {
                            if !folded.contains(file.id) {
                                ForEach(document.rows[file.rowRange]) { row in
                                    DiffRowView(
                                        row: row, comments: commentsOn(row, in: anchored), readOnly: readOnly,
                                        model: model, prUrl: prUrl, drafts: $drafts, focused: $focused
                                    )
                                }
                            }
                            LooseComments(
                                comments: loose[file.path] ?? [], folded: folded.contains(file.id),
                                readOnly: readOnly, model: model, prUrl: prUrl, drafts: $drafts, focused: $focused
                            )
                        } header: {
                            DiffFileHeader(
                                file: file, folded: folded.contains(file.id), comments: count(file),
                                toggle: { toggle(file.id) }
                            )
                            .id(DiffAnchor.file(file.id))
                        }
                    }
                }
                .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in max(contentWidth, width) }
            }
            .textSelection(.enabled)
            // A diff shorter than the pane would otherwise be parked in the middle of it.
            .defaultScrollAnchor(.topLeading)
            .scrollBounceBehavior(.basedOnSize)
            // Without this the pinned header covers whatever was just scrolled to.
            .contentMargins(.top, DiffMetrics.headerHeight, for: .scrollContent)
            .onChange(of: target) { _, new in scroll(to: new, with: proxy) }
            .onAppear { foldLargeFiles() }
        }
    }

    private var contentWidth: CGFloat {
        DiffMetrics.gutterWidth + CGFloat(document.maxColumns) * DiffMetrics.charWidth + 24
    }

    private func commentsOn(_ row: DiffDocument.Row, in anchored: [CommentKey: [DraftComment]]) -> [DraftComment] {
        // A context line exists on both sides, so it can carry comments from either.
        (row.rightKey.flatMap { anchored[$0] } ?? []) + (row.leftKey.flatMap { anchored[$0] } ?? [])
    }

    private func count(_ file: DiffDocument.File) -> Int {
        comments.filter { $0.path == file.path }.count
    }

    private func toggle(_ id: Int) {
        if folded.contains(id) { folded.remove(id) } else { folded.insert(id) }
    }

    /// Long files start folded, and on a very large diff so does anything with nothing to say about it.
    private func foldLargeFiles() {
        guard folded.isEmpty else { return }
        let large = document.isLarge
        let commented = Set(comments.map(\.path))
        folded = Set(document.files.filter { file in
            file.lineCount > DiffMetrics.autoFoldLines || (large && !commented.contains(file.path))
        }.map(\.id))
    }

    private func scroll(to target: DiffScrollTarget?, with proxy: ScrollViewProxy) {
        guard let target else { return }
        folded.remove(target.fileID)
        // One turn later: a target inside a section that was folded a moment ago does not exist yet.
        Task { @MainActor in
            // `.topLeading`, never `.top`: `.top` is UnitPoint(0.5, 0), and the 0.5 centres the target
            // horizontally too. A file header is as wide as the whole diff, so centring it scrolls the
            // code out of sight to the left — while a 620pt comment card lands back near the edge, which
            // is why jumping to a comment appeared to fix it.
            proxy.scrollTo(target.anchor, anchor: .topLeading)
        }
    }
}

private struct DiffFileHeader: View {
    let file: DiffDocument.File
    let folded: Bool
    let comments: Int
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: folded ? "chevron.right" : "chevron.down").font(.caption2)
            }
            .buttonStyle(.borderless)
            Text(file.path).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.head)
            if let previous = file.file.previousPath {
                Text("was \(previous)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if file.file.isBinary { Chip(text: "binary", color: .secondary) }
            if comments > 0 { Chip(text: "\(comments)", color: .orange) }
            Spacer(minLength: 12)
            AddDeleteCounts(additions: file.file.additions, deletions: file.file.deletions)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.caption2)
            }
            .buttonStyle(.borderless).help("Copy the path")
        }
        .padding(.horizontal, 10)
        .frame(height: DiffMetrics.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct DiffRowView: View {
    let row: DiffDocument.Row
    let comments: [DraftComment]
    let readOnly: Bool
    var model: AppModel
    var prUrl: String
    @Binding var drafts: [UUID: String]
    var focused: FocusState<UUID?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header = row.hunkHeader {
                Text(header)
                    .font(DiffMetrics.code)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .frame(height: DiffMetrics.rowHeight, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DiffPalette.hunk)
            } else if let line = row.line {
                HStack(spacing: 0) {
                    DiffGutter(old: line.oldLine, new: line.newLine, kind: line.kind)
                    Text(row.marker)
                        .frame(width: DiffMetrics.charWidth * 2, alignment: .center)
                        .foregroundStyle(.secondary)
                    Text(line.text)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                .font(DiffMetrics.code)
                .frame(height: DiffMetrics.rowHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DiffPalette.row(line.kind))
                .contextMenu {
                    Button("Copy line") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(line.text, forType: .string)
                    }
                }
            }
            ForEach(comments) { comment in
                CommentCard(
                    comment: comment, draft: draft(comment.id), readOnly: readOnly, model: model,
                    prUrl: prUrl, focused: focused
                )
                .padding(.leading, DiffMetrics.gutterWidth)
                .padding(.vertical, 4)
                .id(DiffAnchor.comment(comment.id))
            }
        }
    }

    private func draft(_ id: UUID) -> Binding<String?> {
        Binding(get: { drafts[id] }, set: { drafts[id] = $0 })
    }
}

private struct DiffGutter: View {
    let old: Int?
    let new: Int?
    let kind: DiffLineKind

    var body: some View {
        HStack(spacing: 0) {
            Text(old.map(String.init) ?? "").frame(width: DiffMetrics.numberWidth, alignment: .trailing)
            Text(new.map(String.init) ?? "").frame(width: DiffMetrics.numberWidth, alignment: .trailing)
        }
        .font(DiffMetrics.code)
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        .padding(.trailing, 8)
        .frame(width: DiffMetrics.gutterWidth, alignment: .trailing)
        .background(DiffPalette.gutter(kind))
    }
}

/// Comments whose line has left the diff entirely. They cannot be drawn inline, and dropping them would
/// lose findings the user may still want to send, so they sit under the file they came from.
private struct LooseComments: View {
    let comments: [DraftComment]
    let folded: Bool
    let readOnly: Bool
    var model: AppModel
    var prUrl: String
    @Binding var drafts: [UUID: String]
    var focused: FocusState<UUID?>.Binding

    var body: some View {
        if !comments.isEmpty, !folded {
            VStack(alignment: .leading, spacing: 4) {
                Text("Not in the current diff").font(.caption).foregroundStyle(.secondary)
                ForEach(comments) { comment in
                    CommentCard(
                        comment: comment, draft: Binding(get: { drafts[comment.id] }, set: { drafts[comment.id] = $0 }),
                        readOnly: readOnly, model: model, prUrl: prUrl, focused: focused
                    )
                    .id(DiffAnchor.comment(comment.id))
                }
            }
            .padding(.leading, DiffMetrics.gutterWidth)
            .padding(.vertical, 6)
        }
    }
}
