import Foundation

/// Ties a comment to a line of code rather than to a line number, so a later push can be judged: a line
/// that only moved keeps its comment, a line that changed marks it outdated.
public enum Anchoring {
    /// How far to look for the line before giving up on the window and scanning the file. Wide enough for
    /// an insert above, narrow enough that a match this far out is still plausibly the same line.
    public static let window = 200
    /// A line shorter than this needs a neighbour to agree before a comment is moved to it. `}` and
    /// `else {` match everywhere, and a wrong "still current" is worse than a false "outdated".
    public static let distinctiveLength = 8

    /// Turns the model's findings into draft comments, correcting each line number against the diff.
    public static func resolve(
        _ proposed: [ProposedComment], in diff: PullRequestDiff, baseSha: String, run: Int, now: Date = Date()
    ) -> [DraftComment] {
        proposed.map { item in
            let resolved = line(for: item, in: diff)
            let context = diff.context(path: item.path, line: resolved.line, side: item.side)
            return DraftComment(
                path: item.path,
                line: resolved.line,
                side: item.side,
                severity: item.severity,
                body: item.body,
                anchor: CommentAnchor(
                    text: diff.text(path: item.path, line: resolved.line, side: item.side) ?? item.lineText,
                    before: context.before,
                    after: context.after,
                    sha: item.side == .right ? diff.headSha : baseSha
                ),
                isUnverified: !resolved.verified,
                run: run,
                now: now
            )
        }
    }

    /// The line a finding really belongs on. The model's number is a guess; the line it quoted is the
    /// evidence, so a quote that matches elsewhere in the file wins over the number.
    static func line(for item: ProposedComment, in diff: PullRequestDiff) -> (line: Int, verified: Bool) {
        let quoted = item.lineText.trimmingCharacters(in: .whitespaces)
        guard !quoted.isEmpty else { return (item.line, false) }
        if let text = diff.text(path: item.path, line: item.line, side: item.side),
           text.trimmingCharacters(in: .whitespaces) == quoted {
            return (item.line, true)
        }
        if let snapped = diff.snap(path: item.path, near: item.line, side: item.side, matching: item.lineText) {
            return (snapped, true)
        }
        return (item.line, false)
    }

    /// Where `anchor` sits in `lines` now, or nil when the line it named is gone or too ambiguous to move
    /// a comment onto. `lines` is the whole file at the new sha.
    public static func locate(_ anchor: CommentAnchor, at line: Int, in lines: [String], window: Int = window) -> Int? {
        let trimmed = anchor.text.trimmingCharacters(in: .whitespaces)
        // A blank anchor would match half the file.
        guard !trimmed.isEmpty, !lines.isEmpty else { return nil }
        if line >= 1, line <= lines.count, lines[line - 1] == anchor.text { return line }

        var candidates = matches(anchor.text, in: lines, near: line, window: window)
        // A refactor can move a function thousands of lines; the window is a shortcut, not a limit.
        if candidates.isEmpty, window < lines.count {
            candidates = matches(anchor.text, in: lines, near: line, window: lines.count)
        }
        let best = candidates
            .map { (number: $0, score: contextScore(anchor, at: $0, in: lines)) }
            .max { left, right in
                if left.score != right.score { return left.score < right.score }
                let leftDistance = abs(left.number - line)
                let rightDistance = abs(right.number - line)
                if leftDistance != rightDistance { return leftDistance > rightDistance }
                return left.number > right.number
            }
        guard let best, best.score >= 1 || trimmed.count >= distinctiveLength else { return nil }
        return best.number
    }

    /// Re-anchors every comment on one side against the files at `sha`. A comment whose file is missing,
    /// or whose line cannot be placed, comes back outdated with its old line intact so the UI still shows it.
    public static func reanchored(
        _ comments: [DraftComment], contents: [String: [String]], sha: String, side: DiffSide, now: Date = Date()
    ) -> [DraftComment] {
        comments.map { comment in
            guard comment.side == side, comment.anchor.sha != sha else { return comment }
            var updated = comment
            updated.anchor.sha = sha
            updated.updatedAt = now
            guard let lines = contents[comment.path], let line = locate(comment.anchor, at: comment.line, in: lines) else {
                updated.isOutdated = true
                return updated
            }
            updated.line = line
            updated.isOutdated = false
            // Refresh the neighbours so the next push is matched against what the file says now.
            updated.anchor.before = Array(lines[max(0, line - 1 - 3)..<(line - 1)])
            updated.anchor.after = Array(lines[min(lines.count, line)..<min(lines.count, line + 3)])
            return updated
        }
    }

    /// Exact matches first; only if there are none does whitespace stop counting, because re-indentation
    /// is a change to the line but not to what it says.
    private static func matches(_ text: String, in lines: [String], near line: Int, window: Int) -> [Int] {
        let lower = max(1, line - window)
        let upper = min(lines.count, line + window)
        guard lower <= upper else { return [] }
        let exact = (lower...upper).filter { lines[$0 - 1] == text }
        if !exact.isEmpty { return exact }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return (lower...upper).filter { lines[$0 - 1].trimmingCharacters(in: .whitespaces) == trimmed }
    }

    /// How many of the anchor's neighbours still sit where they did: 0 to 6.
    private static func contextScore(_ anchor: CommentAnchor, at line: Int, in lines: [String]) -> Int {
        var score = 0
        for (offset, text) in anchor.before.reversed().enumerated() {
            let index = line - 2 - offset
            if index >= 0, index < lines.count, lines[index] == text { score += 1 }
        }
        for (offset, text) in anchor.after.enumerated() {
            let index = line + offset
            if index >= 0, index < lines.count, lines[index] == text { score += 1 }
        }
        return score
    }
}
