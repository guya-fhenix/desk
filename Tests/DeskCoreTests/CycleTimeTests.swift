import DeskCore
import Foundation
import Testing

@Suite struct CycleTimeTests {
    let bots: Set<String> = ["claude"]

    @Test func splitsCycleIntoPhasesAndIgnoresBots() {
        let pr = Fixtures.pr(
            number: 1, head: "a", merged: Fixtures.hours(6),
            reviews: [
                Review(state: "COMMENTED", submittedAt: Fixtures.hours(1), author: "claude"),
                Review(state: "COMMENTED", submittedAt: Fixtures.hours(2), author: "alice"),
                Review(state: "APPROVED", submittedAt: Fixtures.hours(5), author: "alice"),
            ]
        )
        let cycle = CycleTime.cycle(for: pr, botLogins: bots)
        #expect(cycle.toFirstReview == 2 * 3_600.0)
        #expect(cycle.toApproval == 3 * 3_600.0)
        #expect(cycle.toMerge == 1 * 3_600.0)
        #expect(cycle.total == 6 * 3_600.0)
    }

    @Test func mergeWithoutReviewMeasuresFromCreation() {
        let pr = Fixtures.pr(number: 2, head: "b", merged: Fixtures.hours(3))
        let cycle = CycleTime.cycle(for: pr, botLogins: bots)
        #expect(cycle.toFirstReview == nil)
        #expect(cycle.toMerge == 3 * 3_600.0)
    }

    @Test func medianHandlesEvenAndOddCounts() {
        #expect(CycleTime.median([]) == nil)
        #expect(CycleTime.median([3, 1, 2]) == 2)
        #expect(CycleTime.median([4, 1, 3, 2]) == 2.5)
    }

    @Test func weeklyFillsEveryWeekInWindow() {
        let pr = Fixtures.pr(number: 3, head: "c", merged: Fixtures.hours(1))
        let weekly = CycleTime.weekly(CycleTime.cycles([pr], botLogins: bots), weeks: 4, now: Fixtures.hours(2))
        #expect(weekly.count == 4)
        #expect(weekly.last?.merged == 1)
        #expect(weekly.first?.merged == 0)
    }

    @Test func reviewLatencyStartsAtTheRequestToMe() {
        let pr = Fixtures.pr(
            number: 4, head: "d", author: "bob",
            reviews: [Review(state: "APPROVED", submittedAt: Fixtures.hours(10), author: "me")],
            events: [
                ReviewRequestEvent(createdAt: Fixtures.hours(1), reviewer: "Protocol Team", isTeam: true),
                ReviewRequestEvent(createdAt: Fixtures.hours(4), reviewer: "me", isTeam: false),
            ]
        )
        let latencies = CycleTime.reviewLatencies([pr], login: "me")
        #expect(latencies.count == 1)
        #expect(latencies[0].latency == 6 * 3_600.0)
    }
}
