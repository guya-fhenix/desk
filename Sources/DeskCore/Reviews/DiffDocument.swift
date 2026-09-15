import Foundation

/// A diff flattened into display order: one array of rows, each knowing its file, so the whole thing can
/// be drawn by a single lazy stack. Built once per head sha, off the main actor.
///
/// Row ids are `Int` and assigned here rather than derived while rendering: `ForEach` builds the full id
/// list on every update even inside a lazy container, and several thousand string interpolations every
/// time a poller reassigns state is exactly the stutter this screen has to avoid.
public struct DiffDocument: Sendable {
    public struct File: Sendable, Identifiable, Hashable {
        public let id: Int
        public let file: DiffFile
        /// Slice into `rows`.
        public let rowRange: Range<Int>

        public var path: String { file.path }
        public var lineCount: Int { rowRange.count }
    }

    public struct Row: Sendable, Identifiable, Equatable {
        public let id: Int
        public let fileID: Int
        public let path: String
        /// Set on a `@@` row; `line` is then nil.
        public let hunkHeader: String?
        public let line: DiffLine?

        /// Where a RIGHT-side comment on this row would sit, if one can.
        public var rightKey: CommentKey? {
            guard let number = line?.newLine else { return nil }
            return CommentKey(path: path, line: number, side: .right)
        }

        public var leftKey: CommentKey? {
            guard let number = line?.oldLine else { return nil }
            return CommentKey(path: path, line: number, side: .left)
        }

        public var marker: String {
            switch line?.kind {
            case .added: return "+"
            case .removed: return "-"
            default: return " "
            }
        }
    }

    public let headSha: String
    public let files: [File]
    public let rows: [Row]
    /// The longest line, clamped: one minified vendor line would otherwise give the whole diff an
    /// eight-thousand-point horizontal scroll range.
    public let maxColumns: Int
    /// Every line a comment can sit on. Built once here so the view can split anchored comments from the
    /// ones whose line has left the diff without walking the rows on every render.
    public let commentableKeys: Set<CommentKey>

    public static let columnLimit = 500
    public static let tabWidth = 4

    public init(_ diff: PullRequestDiff) {
        headSha = diff.headSha
        var files: [File] = []
        var rows: [Row] = []
        var columns = 0
        var keys: Set<CommentKey> = []
        for (index, file) in diff.files.enumerated() {
            let start = rows.count
            for hunk in file.hunks {
                rows.append(Row(id: rows.count, fileID: index, path: file.path, hunkHeader: hunk.header, line: nil))
                for line in hunk.lines {
                    var line = line
                    // Expanded here, not while rendering: SwiftUI lays out a tab with its own stops, which
                    // breaks column alignment and makes the width below a lie.
                    line.text = Self.expandingTabs(line.text)
                    columns = max(columns, line.text.count + 1)
                    let row = Row(id: rows.count, fileID: index, path: file.path, hunkHeader: nil, line: line)
                    if let key = row.rightKey { keys.insert(key) }
                    if let key = row.leftKey { keys.insert(key) }
                    rows.append(row)
                }
            }
            files.append(File(id: index, file: file, rowRange: start..<rows.count))
        }
        self.files = files
        self.rows = rows
        commentableKeys = keys
        maxColumns = min(columns, Self.columnLimit)
    }

    public var isLarge: Bool { rows.count > 3_000 }

    public func file(_ id: Int) -> File? { files.first { $0.id == id } }

    static func expandingTabs(_ text: String) -> String {
        guard text.contains("\t") else { return text }
        var result = ""
        for character in text {
            if character == "\t" {
                result += String(repeating: " ", count: tabWidth - (result.count % tabWidth))
            } else {
                result.append(character)
            }
        }
        return result
    }
}
