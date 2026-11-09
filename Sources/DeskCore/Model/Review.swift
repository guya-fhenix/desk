import Foundation

/// Where your review of a PR stands on GitHub.
public enum DraftStatus: Sendable, Hashable {
    /// Your pending review, with how many comments it holds.
    case pending(comments: Int)
    /// Your latest submitted review, by its GitHub state.
    case submitted(state: ReviewState)
}

/// A PR's review, read off the PR the last poll brought back. Nothing here is stored.
public struct ReviewStatus: Sendable, Hashable {
    public var draft: DraftStatus?
    /// The PR head moved past the commit your pending review's comments were written against.
    public var headMoved: Bool
    /// Your review was requested after you last submitted one.
    public var reRequested: Bool

    public init(draft: DraftStatus?, headMoved: Bool, reRequested: Bool) {
        self.draft = draft
        self.headMoved = headMoved
        self.reRequested = reRequested
    }

    public static func derive(pr: PullRequest, login: String) -> ReviewStatus {
        let answered = lastSubmitted(pr, by: login)
        let draft: DraftStatus?
        if let pending = pr.pendingReview {
            draft = .pending(comments: pending.comments)
        } else {
            draft = answered.map { .submitted(state: $0.state) }
        }
        return ReviewStatus(
            draft: draft,
            headMoved: pr.pendingReview.map { !$0.commitId.isEmpty && !pr.headSha.isEmpty && $0.commitId != pr.headSha } ?? false,
            reRequested: answered.map { requested(pr, by: login, after: $0.submittedAt) } ?? false
        )
    }

    /// The latest review you submitted on the PR.
    public static func lastSubmitted(_ pr: PullRequest, by login: String) -> Review? {
        pr.reviews.filter { $0.author == login }.max { $0.submittedAt < $1.submittedAt }
    }

    /// A request for you personally — a team request is not — made after `date`.
    public static func requested(_ pr: PullRequest, by login: String, after date: Date) -> Bool {
        pr.reviewRequestEvents.contains { !$0.isTeam && $0.reviewer == login && $0.createdAt > date }
    }
}
