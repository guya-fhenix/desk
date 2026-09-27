import Foundation

/// Why a PR is waiting for you to run a review on it.
public enum ReviewNeed: String, Sendable, Hashable {
    /// Waiting on your review, and you have not reviewed it.
    case notReviewed
    /// Your review was requested again after the last one you submitted.
    case reRequested
    /// This session's run failed, so there is nothing to read.
    case failed

    public var title: String {
        switch self {
        case .notReviewed: return "ready to review"
        case .reRequested: return "review again"
        case .failed: return "run failed"
        }
    }

    public var detail: String {
        switch self {
        case .notReviewed: return "This PR waits on your review and you have not reviewed it yet."
        case .reRequested: return "Your review was requested again after the last one you submitted."
        case .failed: return "The last run failed. Press Review to try again."
        }
    }
}

public struct ReviewReadinessInput: Sendable {
    public var login: String
    /// Already free of drafts and bot PRs.
    public var queue: [PullRequest]
    /// This session's runs, by PR url.
    public var runs: [String: ReviewRun]
    public var repos: [RepoRef]

    public init(login: String, queue: [PullRequest], runs: [String: ReviewRun], repos: [RepoRef]) {
        self.login = login
        self.queue = queue
        self.runs = runs
        self.repos = repos
    }
}

/// What the review queue is waiting for, read off GitHub. Nothing here starts a review: running one costs
/// money and is always a deliberate press. The app's whole job is to make it obvious which PRs are worth
/// pressing.
public enum ReviewReadiness {
    /// Which queued PRs want a review run on them, and why. Keyed by PR url.
    public static func needs(_ input: ReviewReadinessInput) -> [String: ReviewNeed] {
        var needs: [String: ReviewNeed] = [:]
        for pr in input.queue {
            // Nothing to check out, so nothing to review. The row says so on its own.
            guard Linker.repo(for: pr, in: input.repos) != nil else { continue }
            let run = input.runs[pr.url]
            if run?.phase.isBusy == true { continue }
            if run?.phase == .failed {
                needs[pr.url] = .failed
                continue
            }
            // A draft with Claude's comments in it waits on you, not on another run; so does a run that
            // finished this session and found nothing to say.
            if (pr.pendingReview?.claudeComments ?? 0) > 0 || run?.phase == .posted { continue }
            guard let answered = ReviewStatus.lastSubmitted(pr, by: input.login) else {
                needs[pr.url] = .notReviewed
                continue
            }
            if ReviewStatus.requested(pr, by: input.login, after: answered.submittedAt) {
                needs[pr.url] = .reRequested
            }
        }
        return needs
    }
}
