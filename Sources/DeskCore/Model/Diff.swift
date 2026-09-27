import Foundation

/// Which side of the diff a line belongs to, in GitHub's own vocabulary. RIGHT covers added and
/// unchanged lines, LEFT only deleted ones; getting that backwards is the most common way to have a
/// review rejected.
public enum DiffSide: String, Codable, Sendable, Hashable {
    case right = "RIGHT"
    case left = "LEFT"
}

public enum DiffLineKind: String, Sendable, Hashable {
    case context, added, removed

    /// The sides this line can be commented on: context lines exist on both.
    public var sides: [DiffSide] {
        switch self {
        case .context: return [.right, .left]
        case .added: return [.right]
        case .removed: return [.left]
        }
    }
}

public struct DiffLine: Sendable, Hashable {
    public var kind: DiffLineKind
    /// Number in the pre-image; nil for an added line.
    public var oldLine: Int?
    /// Number in the post-image; nil for a removed line.
    public var newLine: Int?
    /// The line itself, without its leading `+`, `-` or space.
    public var text: String
    /// Lines below this file's first `@@`, counting hunk headers: GitHub's `position`. The review API
    /// took `position` before it took `line`/`side`, so it is kept as the escape hatch if this org's
    /// API turns out to be the older kind.
    public var position: Int

    public init(kind: DiffLineKind, oldLine: Int?, newLine: Int?, text: String, position: Int) {
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
        self.position = position
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

    /// Whether a line number on one side falls inside this hunk, so a scan can skip whole hunks.
    func covers(_ number: Int, on side: DiffSide) -> Bool {
        let start = side == .right ? newStart : oldStart
        let count = side == .right ? newCount : oldCount
        // A hunk with a zero count sits between two lines and covers nothing.
        return count > 0 && number >= start && number < start + count
    }
}

public enum DiffFileStatus: String, Sendable, Hashable {
    case added, modified, removed, renamed
}

public struct DiffFile: Sendable, Hashable, Identifiable {
    public var id: String { path }
    /// The post-image path, which is what a comment addresses. For a deletion it is the pre-image path,
    /// because that is the only one there is.
    public var path: String
    /// Set on a rename or copy, so the UI can say where the file came from.
    public var previousPath: String?
    public var status: DiffFileStatus
    /// No hunks and nothing to comment on. Rendered as a one-line note.
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
        for hunk in hunks where hunk.covers(number, on: side) {
            if let line = hunk.lines.first(where: { $0.number(on: side) == number }) { return line }
        }
        return nil
    }

    /// Every line on one side, in file order. The basis for snapping and for context.
    public func lines(on side: DiffSide) -> [DiffLine] {
        hunks.flatMap(\.lines).filter { $0.number(on: side) != nil }
    }
}

/// One PR's diff as GitHub computes it. `headSha` is what the app believes the diff is of — `gh pr diff`
/// does not report the sha it diffed, so the pair is only confirmed when a review is submitted and
/// GitHub validates the `commit_id`.
public struct PullRequestDiff: Sendable, Hashable {
    public var files: [DiffFile]
    public var headSha: String
    public var fetchedAt: Date

    public init(files: [DiffFile], headSha: String, fetchedAt: Date = Date()) {
        self.files = files
        self.headSha = headSha
        self.fetchedAt = fetchedAt
    }

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    public func file(_ path: String) -> DiffFile? { files.first { $0.path == path } }

    /// Whether GitHub will accept an inline comment there. A comment that fails this is rejected with a
    /// 422 that takes the whole review down with it, so every comment is checked before submitting.
    public func isCommentable(path: String, line: Int, side: DiffSide) -> Bool {
        guard let file = file(path), !file.isBinary else { return false }
        return file.line(line, on: side) != nil
    }

    /// The diff's own text for a line. Authoritative: the model's quoted line is only a hint, this is
    /// what the anchor is built from.
    public func text(path: String, line: Int, side: DiffSide) -> String? {
        file(path)?.line(line, on: side)?.text
    }

    /// The commentable line nearest `line` whose text matches, within `window` lines. This is how a
    /// model's line number gets corrected from the line it quoted.
    public func snap(path: String, near line: Int, side: DiffSide, matching text: String, window: Int = 40) -> Int? {
        guard let file = file(path), !file.isBinary else { return nil }
        let wanted = text.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        let candidates = file.lines(on: side)
            .filter { $0.text.trimmingCharacters(in: .whitespaces) == wanted }
            .compactMap { $0.number(on: side) }
            .filter { abs($0 - line) <= window }
        // Ties go to the line the model named, then to the earlier line so the result never wobbles.
        return candidates.min { abs($0 - line) == abs($1 - line) ? $0 < $1 : abs($0 - line) < abs($1 - line) }
    }
}
