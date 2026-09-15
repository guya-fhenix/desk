import Foundation

public enum ReviewPlanner {
    /// Reviews whose PR is no longer open. `closed` is every PR the snapshot knows; anything not open in
    /// it has been merged or closed.
    public static func cleanups(records: [String: ReviewRecord], closed: [PullRequest]) -> [ReviewRecord] {
        let gone = Set(closed.filter { $0.state != .open }.map(\.url))
        return records.values.filter { gone.contains($0.prUrl) }.sorted { $0.prUrl < $1.prUrl }
    }

    /// Reviews whose PR appears in none of the snapshot's searches. A PR nobody asked you to review and
    /// you never submitted on leaves every one of them the moment it merges, so absence is the only trace
    /// it leaves behind — and absence is not evidence, which is why these get asked about one by one
    /// rather than swept.
    public static func unresolved(records: [String: ReviewRecord], seen: [PullRequest]) -> [ReviewRecord] {
        let known = Set(seen.map(\.url))
        return records.values.filter { !known.contains($0.prUrl) }.sorted { $0.prUrl < $1.prUrl }
    }

    public static func worktreePath(reviewRoot: String, pr: PullRequest) -> String {
        "\(reviewRoot)/\(pr.repoName)/pr-\(pr.number)"
    }
}
