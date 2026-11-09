import DeskCore
import Foundation

enum Fixtures {
    static let t0 = Date(timeIntervalSince1970: 1_787_000_000)

    static func pr(
        number: Int, repo: String = "FhenixProtocol/cofhe", title: String = "A change", head: String, base: String = "master",
        author: String = "guya-fhenix", created: Date = t0, updated: Date = t0, merged: Date? = nil,
        checks: CheckState = .success, review: ReviewDecision = .reviewRequired, merge: MergeState = .blocked,
        reviews: [Review] = [], events: [ReviewRequestEvent] = [], draft: Bool = false
    ) -> PullRequest {
        PullRequest(
            number: number, title: title, url: "https://github.com/\(repo)/pull/\(number)", repo: repo, isDraft: draft,
            state: merged == nil ? .open : .merged, createdAt: created, updatedAt: updated, mergedAt: merged,
            baseRef: base, headRef: head, defaultBranch: "master", headSha: "sha\(number)", additions: 10, deletions: 2, author: author,
            reviewDecision: review, mergeState: merge, checks: checks, checkCount: 3, reviews: reviews, reviewRequestEvents: events
        )
    }

    static func hours(_ h: Double) -> Date { t0.addingTimeInterval(h * 3_600) }

    static func worktree(repo: String = "cofhe", path: String, branch: String?, isMain: Bool = false) -> Worktree {
        Worktree(repoName: repo, repoRoot: "/r/\(repo)", path: path, branch: branch, headSha: "abc", isMain: isMain, defaultBranch: "master")
    }

    static func repo(name: String = "cofhe", remote: String = "git@github-guya-fhenix:FhenixProtocol/cofhe.git") -> RepoRef {
        RepoRef(name: name, root: "/r/\(name)", remote: remote)
    }

    /// Your pending review.
    static func pending(comments: Int = 3, commit: String = "") -> PendingReview {
        PendingReview(id: "draft1", commitId: commit, comments: comments)
    }

    static func review(_ state: String = "COMMENTED", at: Date, by author: String = "me") -> Review {
        Review(state: state, submittedAt: at, author: author)
    }

    static func event(reviewer: String = "me", at: Date, team: Bool = false) -> ReviewRequestEvent {
        ReviewRequestEvent(createdAt: at, reviewer: reviewer, isTeam: team)
    }

    static func ticket(
        _ key: String, category: TicketStatusCategory = .inProgress, status: String = "In Progress",
        placement: TicketPlacement = .sprint, assignedToMe: Bool = true, assignee: String? = nil
    ) -> Ticket {
        Ticket(
            key: key, summary: "Summary \(key)", status: status, category: category,
            url: "https://j/browse/\(key)", assignedToMe: assignedToMe, assignee: assignee, placement: placement
        )
    }
}
