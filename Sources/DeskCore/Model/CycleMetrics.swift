import Foundation

public struct PullRequestCycle: Sendable, Hashable, Identifiable {
    public var id: String { pullRequest.url }
    public var pullRequest: PullRequest
    public var toFirstReview: TimeInterval?
    public var toApproval: TimeInterval?
    public var toMerge: TimeInterval?
    public var total: TimeInterval?

    public init(pullRequest: PullRequest, toFirstReview: TimeInterval?, toApproval: TimeInterval?, toMerge: TimeInterval?, total: TimeInterval?) {
        self.pullRequest = pullRequest
        self.toFirstReview = toFirstReview
        self.toApproval = toApproval
        self.toMerge = toMerge
        self.total = total
    }
}

public struct WeeklyCycle: Sendable, Hashable, Identifiable {
    public var id: Date { weekStart }
    public var weekStart: Date
    public var merged: Int
    public var medianToFirstReview: TimeInterval?
    public var medianToApproval: TimeInterval?
    public var medianToMerge: TimeInterval?
    public var medianTotal: TimeInterval?

    public init(weekStart: Date, merged: Int, medianToFirstReview: TimeInterval?, medianToApproval: TimeInterval?, medianToMerge: TimeInterval?, medianTotal: TimeInterval?) {
        self.weekStart = weekStart
        self.merged = merged
        self.medianToFirstReview = medianToFirstReview
        self.medianToApproval = medianToApproval
        self.medianToMerge = medianToMerge
        self.medianTotal = medianTotal
    }
}

public struct ReviewLatency: Sendable, Hashable, Identifiable {
    public var id: String { pullRequest.url }
    public var pullRequest: PullRequest
    public var requestedAt: Date
    public var reviewedAt: Date
    public var latency: TimeInterval { reviewedAt.timeIntervalSince(requestedAt) }

    public init(pullRequest: PullRequest, requestedAt: Date, reviewedAt: Date) {
        self.pullRequest = pullRequest
        self.requestedAt = requestedAt
        self.reviewedAt = reviewedAt
    }
}
