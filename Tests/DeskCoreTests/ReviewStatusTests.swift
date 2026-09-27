import DeskCore
import Foundation
import Testing

@Suite struct ReviewStatusTests {
    let pr = Fixtures.pr(number: 9, head: "y", author: "alice")

    @Test func phaseComesStraightFromTheRecord() {
        // There is no session file to read it back out of, so the record is the only authority.
        for phase in [ReviewPhase.queued, .preparing, .running, .posting, .posted] {
            let record = Fixtures.record(pr: pr, phase: phase)
            #expect(ReviewStatus.derive(record: record, pr: pr, login: "me").phase == phase)
        }
        #expect(ReviewStatus.derive(record: Fixtures.record(pr: pr, error: "git fetch failed"), pr: pr, login: "me").phase == .failed)
    }

    @Test func busyCoversEverythingWithWorkInFlight() {
        #expect(ReviewPhase.queued.isBusy)
        #expect(ReviewPhase.preparing.isBusy)
        #expect(ReviewPhase.running.isBusy)
        // Posting too: a second run then would race the first for the same draft.
        #expect(ReviewPhase.posting.isBusy)
        #expect(!ReviewPhase.posted.isBusy)
        #expect(!ReviewPhase.failed.isBusy)
    }

    @Test func headMovedComparesTheRecordedSha() {
        #expect(ReviewStatus.derive(record: Fixtures.record(pr: pr, head: "old"), pr: pr, login: "me").headMoved)
        #expect(!ReviewStatus.derive(record: Fixtures.record(pr: pr), pr: pr, login: "me").headMoved)
        // An empty sha on either side is unknown, not moved.
        var headless = pr
        headless.headSha = ""
        #expect(!ReviewStatus.derive(record: Fixtures.record(pr: pr, head: "old"), pr: headless, login: "me").headMoved)
        #expect(!ReviewStatus.derive(record: Fixtures.record(pr: pr, head: ""), pr: pr, login: "me").headMoved)
    }

    @Test func reRequestedNeedsARequestForMeAfterTheLastRun() {
        let record = Fixtures.record(pr: pr, lastRun: Fixtures.t0)
        func status(_ events: [ReviewRequestEvent]) -> ReviewStatus {
            var pr = pr
            pr.reviewRequestEvents = events
            return ReviewStatus.derive(record: record, pr: pr, login: "me")
        }
        #expect(status([Fixtures.event(at: Fixtures.hours(1))]).reRequested)
        #expect(!status([Fixtures.event(at: Fixtures.hours(-1))]).reRequested)
        #expect(!status([Fixtures.event(reviewer: "someone-else", at: Fixtures.hours(1))]).reRequested)
        // A team request is not a request of me.
        #expect(!status([Fixtures.event(reviewer: "me", at: Fixtures.hours(1), team: true)]).reRequested)
    }

    /// Where the draft stands is GitHub's to say: pending while your pending review is the one the run
    /// wrote, sent once you submitted a review after it, thrown away when neither is true.
    @Test func draftStatusIsReadOffThePullRequest() {
        let record = Fixtures.record(pr: pr, draft: "draft1", postedAt: Fixtures.t0)
        func status(pending: PendingReview? = nil, reviews: [Review] = []) -> DraftStatus? {
            var pr = pr
            pr.pendingReview = pending
            pr.reviews = reviews
            return ReviewStatus.derive(record: record, pr: pr, login: "me").draft
        }
        #expect(status(pending: PendingReview(id: "draft1", comments: 5)) == .pending(comments: 5))
        #expect(status(reviews: [Review(state: "APPROVED", submittedAt: Fixtures.hours(1), author: "me")]) == .submitted(state: "APPROVED"))
        // Somebody else's review, or one of yours from before the draft, is not the draft sent.
        #expect(status(reviews: [Review(state: "APPROVED", submittedAt: Fixtures.hours(1), author: "alice")]) == .discarded)
        #expect(status(reviews: [Review(state: "COMMENTED", submittedAt: Fixtures.hours(-1), author: "me")]) == .discarded)
        // A pending review that is not the draft's is a new one of yours; the run's draft is gone.
        #expect(status(pending: PendingReview(id: "other", comments: 1)) == .discarded)
        #expect(status() == .discarded)
    }

    @Test func noDraftOrNoPullRequestHasNoDraftStatus() {
        #expect(ReviewStatus.derive(record: Fixtures.record(pr: pr, draft: nil), pr: pr, login: "me").draft == nil)
        #expect(ReviewStatus.derive(record: Fixtures.record(pr: pr), pr: nil, login: "me").draft == nil)
    }

    @Test func ledgerKeepsAWeekOfSpend() {
        var ledger = ReviewLedger()
        ledger.record(cost: 2, prUrl: "a", now: Fixtures.t0)
        ledger.record(cost: 3, prUrl: "b", now: Fixtures.t0)
        #expect(ledger.spent(since: Fixtures.hours(-24)) == 5)
        #expect(ledger.spent(since: Fixtures.hours(1)) == 0)
        // A zero-cost run is not worth a row.
        ledger.record(cost: 0, prUrl: "c", now: Fixtures.t0)
        #expect(ledger.spend.count == 2)
        // Anything past the retention window is dropped on the next write.
        ledger.record(cost: 1, prUrl: "d", now: Fixtures.t0.addingTimeInterval(8 * 86_400))
        #expect(ledger.spend.count == 1)
    }
}
