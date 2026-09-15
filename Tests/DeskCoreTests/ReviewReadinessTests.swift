import DeskCore
import Foundation
import Testing

@Suite struct ReviewReadinessTests {
    let repos = [Fixtures.repo()]

    func input(
        queue: [PullRequest], records: [String: ReviewRecord] = [:], now: Date = Fixtures.t0, repos: [RepoRef]? = nil
    ) -> ReviewReadinessInput {
        ReviewReadinessInput(now: now, login: "me", queue: queue, records: records, repos: repos ?? self.repos)
    }

    @Test func aQueuedPullRequestWithNoRecordIsReadyToRun() {
        let pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        #expect(ReviewReadiness.needs(input(queue: [pr])) == [pr.url: .notReviewed])
    }

    @Test func nothingIsReadyWithoutALocalClone() {
        // There would be nothing to check the PR out into. The row says "no local clone" instead.
        let pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        #expect(ReviewReadiness.needs(input(queue: [pr], repos: [])).isEmpty)
    }

    @Test func aReviewedPullRequestIsNotWaitingOnAnything() {
        let pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        let records = [pr.url: Fixtures.record(pr: pr, comments: [Fixtures.comment()])]
        #expect(ReviewReadiness.needs(input(queue: [pr], records: records, now: Fixtures.hours(5))).isEmpty)
    }

    @Test func aReRequestNeedsToBeForMeAndAfterTheLastRun() {
        var pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        let records = [pr.url: Fixtures.record(pr: pr, lastRun: Fixtures.t0)]
        let later = Fixtures.hours(1)
        #expect(ReviewReadiness.needs(input(queue: [pr], records: records, now: later)).isEmpty)

        pr.reviewRequestEvents = [Fixtures.event(at: Fixtures.hours(0.5))]
        #expect(ReviewReadiness.needs(input(queue: [pr], records: records, now: later)) == [pr.url: .reRequested])

        // A request for somebody else, or for a team, is not a request of me.
        pr.reviewRequestEvents = [Fixtures.event(reviewer: "bob", at: Fixtures.hours(0.5))]
        #expect(ReviewReadiness.needs(input(queue: [pr], records: records, now: later)).isEmpty)
        pr.reviewRequestEvents = [Fixtures.event(reviewer: "me", at: Fixtures.hours(0.5), team: true)]
        #expect(ReviewReadiness.needs(input(queue: [pr], records: records, now: later)).isEmpty)
    }

    @Test func aRequestThatLandsSecondsBeforeTheRunIsNotARerequest() {
        // GitHub's event clock and ours are different clocks, so a request timestamped just after we
        // wrote `lastRunAt` is the one the run already answered.
        var pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        pr.reviewRequestEvents = [Fixtures.event(at: Fixtures.t0.addingTimeInterval(1))]
        let records = [pr.url: Fixtures.record(pr: pr, lastRun: Fixtures.t0)]
        #expect(ReviewReadiness.needs(input(queue: [pr], records: records, now: Fixtures.t0.addingTimeInterval(30))).isEmpty)
        #expect(ReviewReadiness.needs(input(queue: [pr], records: records, now: Fixtures.t0.addingTimeInterval(300))).count == 1)
    }

    @Test func aFailedRunIsReadyToTryAgainImmediately() {
        // No backoff any more: nothing retries on its own, so the only gate is the user pressing Review.
        let pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        let records = [pr.url: Fixtures.record(pr: pr, error: "boom", lastRun: Fixtures.t0)]
        #expect(ReviewReadiness.needs(input(queue: [pr], records: records, now: Fixtures.t0)) == [pr.url: .failed])
    }

    @Test func aRunThatReturnedProseInsteadOfAReviewIsReadyToRunAgain() {
        // How a refusal, a spend limit and a crash all look: prose the parser could not use, no comments.
        // Left as-is the row would read "reviewed" when nothing was reviewed.
        let pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        var record = Fixtures.record(pr: pr, lastRun: Fixtures.t0)
        record.rawOutput = "You've hit your individual spend limit"
        #expect(ReviewReadiness.needs(input(queue: [pr], records: [pr.url: record], now: Fixtures.hours(5))) == [pr.url: .failed])

        // Prose plus findings is a review that merely failed to format itself, and is worth reading.
        record.comments = [Fixtures.comment()]
        #expect(ReviewReadiness.needs(input(queue: [pr], records: [pr.url: record], now: Fixtures.hours(5))).isEmpty)

        // And a clean PR with genuinely nothing to say is finished, not failed.
        var clean = Fixtures.record(pr: pr, lastRun: Fixtures.t0)
        clean.summary = "Nothing to flag."
        #expect(ReviewReadiness.needs(input(queue: [pr], records: [pr.url: clean], now: Fixtures.hours(5))).isEmpty)
    }

    @Test func aRunningReviewIsNeitherReadyNorReanchored() {
        let pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        let records = [pr.url: Fixtures.record(pr: pr, head: "older", phase: .running)]
        let state = input(queue: [pr], records: records, now: Fixtures.hours(5))
        #expect(ReviewReadiness.needs(state).isEmpty)
        #expect(ReviewReadiness.staleAnchors(state).isEmpty)
    }

    @Test func aSubmittedReviewIsDoneUntilTheAuthorAsksAgain() {
        var pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        var record = Fixtures.record(pr: pr, lastRun: Fixtures.t0, phase: .submitted)
        record.history = [SubmittedRound(at: Fixtures.hours(1), event: .requestChanges, url: "u", inlineCount: 2, foldedCount: 0)]

        // A request from before the review was sent is the one it answered.
        pr.reviewRequestEvents = [Fixtures.event(at: Fixtures.hours(0.5))]
        #expect(ReviewReadiness.needs(input(queue: [pr], records: [pr.url: record], now: Fixtures.hours(3))).isEmpty)

        pr.reviewRequestEvents = [Fixtures.event(at: Fixtures.hours(2))]
        #expect(ReviewReadiness.needs(input(queue: [pr], records: [pr.url: record], now: Fixtures.hours(3))) == [pr.url: .reRequested])
    }

    @Test func newCommitsReanchorAndAreNeverReadyToRun() {
        // The whole reason these are two functions: one spends tokens, the other does not.
        let pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        let records = [pr.url: Fixtures.record(pr: pr, head: "older", lastRun: Fixtures.t0)]
        let state = input(queue: [pr], records: records, now: Fixtures.hours(5))
        #expect(ReviewReadiness.needs(state).isEmpty)
        #expect(ReviewReadiness.staleAnchors(state).map(\.number) == [1])

        // Nothing to re-anchor once the record is at the same head.
        let current = input(queue: [pr], records: [pr.url: Fixtures.record(pr: pr)], now: Fixtures.hours(5))
        #expect(ReviewReadiness.staleAnchors(current).isEmpty)
    }

    @Test func everyQueuedPullRequestIsJudgedOnItsOwn() {
        let fresh = Fixtures.pr(number: 1, head: "a", author: "alice")
        var reRequested = Fixtures.pr(number: 2, head: "b", author: "alice")
        reRequested.reviewRequestEvents = [Fixtures.event(at: Fixtures.hours(1))]
        let done = Fixtures.pr(number: 3, head: "c", author: "alice")
        let records = [
            reRequested.url: Fixtures.record(pr: reRequested, lastRun: Fixtures.t0),
            done.url: Fixtures.record(pr: done, lastRun: Fixtures.t0),
        ]
        let needs = ReviewReadiness.needs(input(queue: [fresh, reRequested, done], records: records, now: Fixtures.hours(2)))
        #expect(needs[fresh.url] == .notReviewed)
        #expect(needs[reRequested.url] == .reRequested)
        #expect(needs[done.url] == nil)
    }
}
