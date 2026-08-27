import DeskCore
import Foundation

enum Fixtures {
    static let t0 = Date(timeIntervalSince1970: 1_787_000_000)

    static func pr(
        number: Int, repo: String = "FhenixProtocol/cofhe", title: String = "A change", head: String, base: String = "master",
        author: String = "guya-fhenix", created: Date = t0, updated: Date = t0, merged: Date? = nil,
        checks: CheckState = .success, review: ReviewDecision = .reviewRequired, merge: MergeState = .blocked,
        reviews: [Review] = [], events: [ReviewRequestEvent] = []
    ) -> PullRequest {
        PullRequest(
            number: number, title: title, url: "https://github.com/\(repo)/pull/\(number)", repo: repo,
            state: merged == nil ? .open : .merged, createdAt: created, updatedAt: updated, mergedAt: merged,
            baseRef: base, headRef: head, headSha: "sha\(number)", additions: 10, deletions: 2, author: author,
            reviewDecision: review, mergeState: merge, checks: checks, checkCount: 3, reviews: reviews, reviewRequestEvents: events
        )
    }

    static func hours(_ h: Double) -> Date { t0.addingTimeInterval(h * 3_600) }

    static func worktree(repo: String = "cofhe", path: String, branch: String?, isMain: Bool = false) -> Worktree {
        Worktree(repoName: repo, repoRoot: "/r/\(repo)", path: path, branch: branch, headSha: "abc", isMain: isMain, defaultBranch: "master")
    }

    static func session(id: String, cwd: String, branches: [String] = [], title: String? = nil, prLinks: [PullRequestRef] = []) -> SessionSummary {
        var summary = SessionSummary(sessionId: id, filePath: "/x/\(id).jsonl")
        summary.cwd = cwd
        summary.branches = branches
        summary.title = title
        summary.prLinks = prLinks
        summary.lastActivityAt = t0
        return summary
    }

    static func live(id: String, cwd: String, status: LiveStatus, statusAge: TimeInterval = 0, alive: Bool = true) -> LiveSession {
        LiveSession(pid: 1, sessionId: id, cwd: cwd, name: id, kind: .interactive, status: status, startedAt: t0, statusUpdatedAt: t0.addingTimeInterval(-statusAge), isAlive: alive)
    }

    static func ticket(_ key: String, category: TicketStatusCategory = .inProgress) -> Ticket {
        Ticket(key: key, summary: "Summary \(key)", status: "In Progress", category: category, url: "https://j/browse/\(key)", updatedAt: t0, assignedToMe: true)
    }
}
