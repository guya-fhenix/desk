import Foundation

public enum ReviewPlanner {
    /// Reviews whose PR is no longer open. `closed` is every PR the snapshot knows; anything not open in
    /// it has been merged or closed.
    public static func cleanups(records: [String: ReviewRecord], closed: [PullRequest]) -> [ReviewRecord] {
        let gone = Set(closed.filter { $0.state != .open }.map(\.url))
        return records.values.filter { gone.contains($0.prUrl) }.sorted { $0.prUrl < $1.prUrl }
    }

    public static func worktreePath(reviewRoot: String, pr: PullRequest) -> String {
        "\(reviewRoot)/\(pr.repoName)/pr-\(pr.number)"
    }
}
