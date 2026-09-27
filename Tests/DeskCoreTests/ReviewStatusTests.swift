import DeskCore
import Foundation
import Testing

/// A review's state is read off the PR; only a run going this session comes from anywhere else.
@Suite struct ReviewStatusTests {
    let pr = Fixtures.pr(number: 9, head: "y", author: "alice")

    func status(pending: PendingReview? = nil, reviews: [Review] = [], events: [ReviewRequestEvent] = [], run: ReviewRun? = nil) -> ReviewStatus {
        var pr = pr
        pr.pendingReview = pending
        pr.reviews = reviews
        pr.reviewRequestEvents = events
        return ReviewStatus.derive(pr: pr, run: run, login: "me")
    }

    @Test func aPendingReviewIsTheDraft() {
        #expect(status(pending: Fixtures.pending(comments: 5, claude: 3)).draft == .pending(comments: 5, claude: 3))
        // Even with a review submitted earlier: the draft is what waits on you now.
        #expect(status(pending: Fixtures.pending(), reviews: [Fixtures.review(at: Fixtures.hours(1))]).draft == .pending(comments: 3, claude: 3))
    }

    @Test func withoutADraftYourLatestReviewIsTheState() {
        let reviews = [
            Fixtures.review("COMMENTED", at: Fixtures.hours(1)),
            Fixtures.review("APPROVED", at: Fixtures.hours(2)),
            Fixtures.review("CHANGES_REQUESTED", at: Fixtures.hours(3), by: "bob"),
        ]
        #expect(status(reviews: reviews).draft == .submitted(state: "APPROVED"))
        #expect(status().draft == nil)
    }

    @Test func headMovedComparesTheDraftsCommit() {
        #expect(status(pending: Fixtures.pending(commit: "older")).headMoved)
        #expect(!status(pending: Fixtures.pending(commit: pr.headSha)).headMoved)
        // Unknown is not moved, and no draft has nothing to be behind.
        #expect(!status(pending: Fixtures.pending(commit: "")).headMoved)
        #expect(!status().headMoved)
    }

    @Test func reRequestedIsARequestForYouAfterYourLastReview() {
        let reviews = [Fixtures.review(at: Fixtures.hours(1))]
        #expect(status(reviews: reviews, events: [Fixtures.event(at: Fixtures.hours(2))]).reRequested)
        #expect(!status(reviews: reviews, events: [Fixtures.event(at: Fixtures.hours(0.5))]).reRequested)
        #expect(!status(reviews: reviews, events: [Fixtures.event(reviewer: "bob", at: Fixtures.hours(2))]).reRequested)
        #expect(!status(reviews: reviews, events: [Fixtures.event(at: Fixtures.hours(2), team: true)]).reRequested)
        // Never reviewed: a request is the first one, not a re-request.
        #expect(!status(events: [Fixtures.event(at: Fixtures.hours(2))]).reRequested)
    }

    @Test func busyCoversEverythingWithWorkInFlight() {
        #expect(ReviewPhase.preparing.isBusy)
        #expect(ReviewPhase.running.isBusy)
        // Posting too: a second run then would race the first for the same draft.
        #expect(ReviewPhase.posting.isBusy)
        #expect(!ReviewPhase.posted.isBusy)
        #expect(!ReviewPhase.failed.isBusy)
        #expect(status(run: ReviewRun(phase: .running)).isBusy)
        #expect(!status().isBusy)
    }
}
