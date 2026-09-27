import Foundation

public enum ReviewPlanner {
    /// Where a PR's review worktree lives. Fixed rather than recorded, so the path alone says which PR a
    /// worktree belongs to.
    public static func worktreePath(reviewRoot: String, pr: PullRequest) -> String {
        "\(reviewRoot)/\(pr.repoName)/pr-\(pr.number)"
    }

    /// The PR a review worktree was made for: its repo's `owner/name`, lowercased, and its number. Nil for
    /// anything not laid out by `worktreePath`.
    public static func pullRequest(ofWorktree path: String, reviewRoot: String, repoSlug: String) -> (url: String, number: Int)? {
        let root = reviewRoot.hasSuffix("/") ? reviewRoot : reviewRoot + "/"
        guard path.hasPrefix(root) else { return nil }
        let parts = path.dropFirst(root.count).split(separator: "/")
        guard parts.count == 2, parts[1].hasPrefix("pr-"), let number = Int(parts[1].dropFirst(3)), !repoSlug.isEmpty else { return nil }
        return ("https://github.com/\(repoSlug)/pull/\(number)", number)
    }
}
