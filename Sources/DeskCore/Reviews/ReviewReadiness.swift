import Foundation

/// Why a PR is waiting for you to run a review on it.
public enum ReviewNeed: String, Sendable, Hashable {
    /// Waiting on your review and never reviewed.
    case notReviewed
    /// Your review was requested again since the last run.
    case reRequested
    /// The last run failed, so there is nothing to read.
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
        case .notReviewed: return "This PR waits on your review and has not been reviewed yet."
        case .reRequested: return "Your review was requested again after the last run."
        case .failed: return "The last run failed. Press Review to try again."
        }
    }
}

public struct ReviewReadinessInput: Sendable {
    public var now: Date
    public var login: String
    /// Already free of drafts and bot PRs.
    public var queue: [PullRequest]
    public var records: [String: ReviewRecord]
    public var repos: [RepoRef]

    public init(now: Date, login: String, queue: [PullRequest], records: [String: ReviewRecord], repos: [RepoRef]) {
        self.now = now
        self.login = login
        self.queue = queue
        self.records = records
        self.repos = repos
    }
}

/// What the review queue is waiting for. Nothing here starts a review: running one costs money and is
/// always a deliberate press. The app's whole job is to make it obvious which PRs are worth pressing.
///
/// The one thing that still happens on its own is `staleAnchors`, because re-pointing existing comments
/// at a head that moved spends no tokens and is what keeps "outdated" honest.
public enum ReviewReadiness {
    /// GitHub's event clock and ours are different clocks. Without this, a request that lands a second
    /// before we write `lastRunAt` reads as newer than the run, and the row claims a re-request that
    /// already happened.
    public static let minReRunInterval: TimeInterval = 120

    /// Which queued PRs want a review run on them, and why. Keyed by PR url.
    public static func needs(_ input: ReviewReadinessInput) -> [String: ReviewNeed] {
        var needs: [String: ReviewNeed] = [:]
        for pr in input.queue {
            // Nothing to check out, so nothing to review. The row says so on its own.
            guard Linker.repo(for: pr, in: input.repos) != nil else { continue }
            guard let record = input.records[pr.url] else {
                needs[pr.url] = .notReviewed
                continue
            }
            guard !record.phase.isBusy else { continue }

            if record.phase == .submitted {
                // A submitted review is finished until the author genuinely asks again.
                if let last = record.submission?.at, requested(pr, by: input.login, after: last) {
                    needs[pr.url] = .reRequested
                }
                continue
            }
            if input.now.timeIntervalSince(record.lastRunAt) > minReRunInterval,
               requested(pr, by: input.login, after: record.lastRunAt) {
                needs[pr.url] = .reRequested
                continue
            }
            // A run that came back as prose the parser could not use is not a review: a refusal, a spend
            // limit and a crash all read exactly like this. Offer it again rather than letting the row
            // sit there looking reviewed.
            if record.phase == .failed || (record.rawOutput != nil && record.comments.isEmpty) {
                needs[pr.url] = .failed
            }
        }
        return needs
    }

    /// PRs whose head moved since their review. Their diff is refetched and their comments re-anchored;
    /// Claude is never run, however far the head moved.
    public static func staleAnchors(_ input: ReviewReadinessInput) -> [PullRequest] {
        input.queue.filter { pr in
            guard let record = input.records[pr.url], !record.phase.isBusy else { return false }
            guard !record.headSha.isEmpty, !pr.headSha.isEmpty else { return false }
            return pr.headSha != record.headSha
        }
    }

    private static func requested(_ pr: PullRequest, by login: String, after date: Date) -> Bool {
        pr.reviewRequestEvents.contains { !$0.isTeam && $0.reviewer == login && $0.createdAt > date }
    }
}
