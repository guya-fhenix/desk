import Foundation

/// The prose half of a submitted review: the summary, plus the approved comments that could not be
/// attached to a line. Folding them in rather than dropping them is the whole point — a finding the user
/// approved must reach the author even when GitHub will not take it inline.
public enum ReviewBody {
    public static func compose(
        summary: String, verdict: ReviewVerdict, folded: [DraftComment], inlineCount: Int, repo: String, sha: String
    ) -> String {
        var parts: [String] = []
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        } else if verdict.needsBody {
            // GitHub rejects a review that requests changes or comments with no body at all.
            parts.append(inlineCount > 0 ? "See the inline comments." : "No further comments.")
        }
        if !folded.isEmpty {
            parts.append(details(folded, repo: repo, sha: sha))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func details(_ comments: [DraftComment], repo: String, sha: String) -> String {
        let heading = comments.count == 1
            ? "1 note on a line that is no longer in the diff"
            : "\(comments.count) notes on lines that are no longer in the diff"
        let items = comments.map { item($0, repo: repo, sha: sha) }
        return (["<details>", "<summary>\(heading)</summary>", ""] + items + ["</details>"]).joined(separator: "\n")
    }

    private static func item(_ comment: DraftComment, repo: String, sha: String) -> String {
        let link = "[`\(comment.path):\(comment.line)`](https://github.com/\(repo)/blob/\(sha)/\(comment.path)#L\(comment.line))"
        let outdated = comment.isOutdated ? " *(outdated)*" : ""
        // Continuation lines are indented so a multi-line body stays inside its own bullet.
        let body = comment.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .joined(separator: "\n  ")
        return "- **\(comment.severity.rawValue)** · \(link)\(outdated) — \(body)"
    }
}
