import Foundation

/// Which side of the diff a line number belongs to, in GitHub's vocabulary: RIGHT is the new file (added
/// and unchanged lines), LEFT the old one (removed lines).
public enum DiffSide: String, Sendable, Hashable {
    case right = "RIGHT"
    case left = "LEFT"
}

public enum DiffLineKind: String, Sendable, Hashable {
    case context, added, removed
}

public struct DiffLine: Sendable, Hashable {
    public var kind: DiffLineKind
    /// Number in the old file; nil for an added line.
    public var oldLine: Int?
    /// Number in the new file; nil for a removed line.
    public var newLine: Int?
    /// The line itself, without its leading `+`, `-` or space.
    public var text: String

    public init(kind: DiffLineKind, oldLine: Int?, newLine: Int?, text: String) {
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
    }

    public func number(on side: DiffSide) -> Int? { side == .right ? newLine : oldLine }
}

public struct DiffHunk: Sendable, Hashable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Whatever follows the closing `@@`, usually the enclosing function.
    public var heading: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.heading = heading
        self.lines = lines
    }

    public var header: String {
        let old = oldCount == 1 ? "\(oldStart)" : "\(oldStart),\(oldCount)"
        let new = newCount == 1 ? "\(newStart)" : "\(newStart),\(newCount)"
        return "@@ -\(old) +\(new) @@" + (heading.isEmpty ? "" : " \(heading)")
    }
}

public enum DiffFileStatus: String, Sendable, Hashable {
    case added, modified, removed, renamed
}

/// One row of a file on the review screen: a hunk's header or one of its lines.
public enum DiffRow: Sendable, Hashable {
    case hunk(String)
    case line(DiffLine)
}

extension Array where Element == DiffRow {
    /// Where the review screen's line cursor goes from `index` on ↓ (`step` 1) or ↑ (−1): the next line that way, past
    /// any hunk header. From no index, the first line, or going up the last. Nil past either end of the file.
    public func lineIndex(after index: Int?, step: Int) -> Int? {
        var next = index.map { $0 + step } ?? (step > 0 ? startIndex : endIndex - 1)
        while indices.contains(next) {
            if case .line = self[next] { return next }
            next += step
        }
        return nil
    }
}

public struct DiffFile: Sendable, Hashable, Identifiable {
    public var id: String { path }
    /// The new path; for a deletion the old one, because that is the only one there is.
    public var path: String
    /// Set on a rename or copy, so the screen can say where the file came from.
    public var previousPath: String?
    public var status: DiffFileStatus
    /// No hunks: shown as a one-line note.
    public var isBinary: Bool
    public var hunks: [DiffHunk]
    public var additions: Int
    public var deletions: Int

    public init(
        path: String, previousPath: String? = nil, status: DiffFileStatus = .modified,
        isBinary: Bool = false, hunks: [DiffHunk] = [], additions: Int = 0, deletions: Int = 0
    ) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.isBinary = isBinary
        self.hunks = hunks
        self.additions = additions
        self.deletions = deletions
    }

    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    /// The line at `number` on `side`, or nil when that line is not part of the diff.
    public func line(_ number: Int, on side: DiffSide) -> DiffLine? {
        hunks.lazy.flatMap(\.lines).first { $0.number(on: side) == number }
    }

    /// The rows the review screen draws, in order: each hunk's header, then its lines.
    public var rows: [DiffRow] {
        hunks.flatMap { [DiffRow.hunk($0.header)] + $0.lines.map(DiffRow.line) }
    }

    /// The row a link to `number` on `side` lands on: that line, or the nearest line the diff has on that
    /// side when the session named one just outside a hunk. Nil when the file has no line on that side.
    public func row(nearest number: Int, on side: DiffSide) -> Int? {
        let rows = self.rows
        return rows.indices.compactMap { index -> (index: Int, distance: Int)? in
            guard case .line(let line) = rows[index], let n = line.number(on: side) else { return nil }
            return (index, abs(n - number))
        }
        .min { $0.distance < $1.distance }?.index
    }
}
