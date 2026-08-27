import Foundation

public enum CycleTime {
    public static func cycle(for pr: PullRequest, botLogins: Set<String>) -> PullRequestCycle {
        let reviews = pr.humanReviews(botLogins: botLogins)
        let firstReview = reviews.map(\.submittedAt).min()
        let approval = reviews.filter(\.isApproval).map(\.submittedAt).max()
        let toFirstReview = firstReview.map { $0.timeIntervalSince(pr.createdAt) }
        let toApproval: TimeInterval? = if let firstReview, let approval { approval.timeIntervalSince(firstReview) } else { nil }
        let toMerge = pr.mergedAt.map { $0.timeIntervalSince(approval ?? firstReview ?? pr.createdAt) }
        let total = pr.mergedAt.map { $0.timeIntervalSince(pr.createdAt) }
        return PullRequestCycle(pullRequest: pr, toFirstReview: toFirstReview, toApproval: toApproval, toMerge: toMerge, total: total)
    }

    public static func cycles(_ merged: [PullRequest], botLogins: Set<String>) -> [PullRequestCycle] {
        merged.filter { $0.mergedAt != nil }.map { cycle(for: $0, botLogins: botLogins) }.sorted { $0.pullRequest.mergedAt! > $1.pullRequest.mergedAt! }
    }

    /// One row per week from `weeks` ago until `now`, weeks with no merges included.
    public static func weekly(_ cycles: [PullRequestCycle], weeks: Int, now: Date = Date(), calendar: Calendar = .current) -> [WeeklyCycle] {
        var byWeek: [Date: [PullRequestCycle]] = [:]
        for cycle in cycles {
            guard let mergedAt = cycle.pullRequest.mergedAt, let week = calendar.dateInterval(of: .weekOfYear, for: mergedAt)?.start else { continue }
            byWeek[week, default: []].append(cycle)
        }
        guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        return (0..<max(weeks, 1)).reversed().compactMap { offset -> WeeklyCycle? in
            guard let week = calendar.date(byAdding: .weekOfYear, value: -offset, to: currentWeek) else { return nil }
            let rows = byWeek[week] ?? []
            return WeeklyCycle(
                weekStart: week,
                merged: rows.count,
                medianToFirstReview: median(rows.compactMap(\.toFirstReview)),
                medianToApproval: median(rows.compactMap(\.toApproval)),
                medianToMerge: median(rows.compactMap(\.toMerge)),
                medianTotal: median(rows.compactMap(\.total))
            )
        }
    }

    /// How long the user took to post a first review after being asked.
    public static func reviewLatencies(_ reviewed: [PullRequest], login: String) -> [ReviewLatency] {
        reviewed.compactMap { pr in
            guard let reviewedAt = pr.reviews.filter({ $0.author == login }).map(\.submittedAt).min() else { return nil }
            let direct = pr.reviewRequestEvents.filter { !$0.isTeam && $0.reviewer == login }.map(\.createdAt).min()
            let team = pr.reviewRequestEvents.filter(\.isTeam).map(\.createdAt).min()
            let requestedAt = direct ?? team ?? pr.createdAt
            return ReviewLatency(pullRequest: pr, requestedAt: requestedAt, reviewedAt: max(reviewedAt, requestedAt))
        }.sorted { $0.reviewedAt > $1.reviewedAt }
    }

    public static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
