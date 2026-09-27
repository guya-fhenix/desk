import Foundation

/// Puts each of the model's findings on the line it is really about before it is posted. Models miscount
/// hunk offsets, and GitHub rejects the whole draft over one comment on a line outside the diff.
public enum Anchoring {
    /// Turns the model's findings into draft comments, correcting each line number against the diff.
    public static func resolve(_ proposed: [ProposedComment], in diff: PullRequestDiff) -> [DraftComment] {
        proposed.map { item in
            let resolved = line(for: item, in: diff)
            return DraftComment(
                path: item.path, line: resolved.line, side: item.side, severity: item.severity, body: item.body,
                isUnverified: !resolved.verified
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
}
