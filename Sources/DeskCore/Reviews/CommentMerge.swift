import Foundation

/// Folds a new run's findings into the comments already on a record. The rule the whole thing turns on:
/// an existing comment wins its line. That is what keeps an approval, a rewrite or a rejection from being
/// undone by a re-run — and it means a finding the user has already dismissed cannot come back.
public enum CommentMerge {
    public static func merge(existing: [DraftComment], incoming: [DraftComment], run: Int, now: Date = Date()) -> [DraftComment] {
        var merged = existing
        var index: [CommentKey: Int] = [:]
        for (position, comment) in merged.enumerated() { index[comment.key] = position }

        for comment in incoming {
            guard let position = index[comment.key] else {
                var fresh = comment
                fresh.firstRun = run
                fresh.lastRun = run
                index[fresh.key] = merged.count
                merged.append(fresh)
                continue
            }
            // The run refreshes what it can see and nothing the user owns: not the state, not the wording.
            merged[position].lastRun = run
            merged[position].severity = comment.severity
            merged[position].anchor = comment.anchor
            merged[position].isOutdated = false
            merged[position].isUnverified = comment.isUnverified
            merged[position].updatedAt = now
        }
        return sorted(merged)
    }

    /// File order, so the list reads the way the diff does.
    public static func sorted(_ comments: [DraftComment]) -> [DraftComment] {
        comments.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.line != $1.line { return $0.line < $1.line }
            return $0.side.rawValue < $1.side.rawValue
        }
    }
}
