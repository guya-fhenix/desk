import Foundation

/// Why a PR in the queue waits on your review.
public enum ReviewNeed: String, Sendable, Hashable {
    /// Waiting on your review, and you have not reviewed it.
    case notReviewed
    /// Your review was requested again after the last one you submitted.
    case reRequested

    public var title: String {
        switch self {
        // One name for this state across the app: the Reviews header, Up Next and the menu panel say the same.
        case .notReviewed: return "Needs review"
        case .reRequested: return "Review again"
        }
    }

    public var detail: String {
        switch self {
        case .notReviewed: return "This PR waits on your review and you have not reviewed it yet."
        case .reRequested: return "Your review was requested again after the last one you submitted."
        }
    }
}

/// What the review queue is waiting for, read off GitHub.
public enum ReviewReadiness {
    /// Which queued PRs wait on your review, and why. Keyed by PR url. `queue` is already free of drafts and bot PRs.
    public static func needs(login: String, queue: [PullRequest]) -> [String: ReviewNeed] {
        var needs: [String: ReviewNeed] = [:]
        for pr in queue {
            guard let answered = ReviewStatus.lastSubmitted(pr, by: login) else {
                needs[pr.url] = .notReviewed
                continue
            }
            if ReviewStatus.requested(pr, by: login, after: answered.submittedAt) {
                needs[pr.url] = .reRequested
            }
        }
        return needs
    }
}
