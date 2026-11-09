import DeskCore
import Foundation
import Testing

/// Whether a PR in the queue waits on your review, from GitHub alone.
@Suite struct ReviewReadinessTests {
    func needs(_ queue: [PullRequest]) -> [String: ReviewNeed] {
        ReviewReadiness.needs(login: "me", queue: queue)
    }

    @Test func aPullRequestYouHaveNotReviewedNeedsReview() {
        let pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        #expect(needs([pr]) == [pr.url: .notReviewed])
        // A draft you have not submitted is not a review yet.
        var drafted = pr
        drafted.pendingReview = Fixtures.pending()
        #expect(needs([drafted]) == [pr.url: .notReviewed])
    }

    @Test func aReviewYouSubmittedIsDoneUntilYouAreAskedAgain() {
        var pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        pr.reviews = [Fixtures.review(.changesRequested, at: Fixtures.hours(1))]
        // A request from before your review is the one it answered.
        pr.reviewRequestEvents = [Fixtures.event(at: Fixtures.hours(0.5))]
        #expect(needs([pr]).isEmpty)

        pr.reviewRequestEvents = [Fixtures.event(at: Fixtures.hours(2))]
        #expect(needs([pr]) == [pr.url: .reRequested])

        // A request for somebody else, or for a team, is not a request of you.
        pr.reviewRequestEvents = [Fixtures.event(reviewer: "bob", at: Fixtures.hours(2))]
        #expect(needs([pr]).isEmpty)
        pr.reviewRequestEvents = [Fixtures.event(at: Fixtures.hours(2), team: true)]
        #expect(needs([pr]).isEmpty)
    }

    @Test func somebodyElsesReviewIsNotYours() {
        var pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        pr.reviews = [Fixtures.review(.approved, at: Fixtures.hours(1), by: "bob")]
        #expect(needs([pr]) == [pr.url: .notReviewed])
    }
}
