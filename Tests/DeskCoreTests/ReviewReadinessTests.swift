import DeskCore
import Foundation
import Testing

/// Whether a PR wants a Claude run, from GitHub alone plus the runs going this session.
@Suite struct ReviewReadinessTests {
    let repos = [Fixtures.repo()]

    func needs(_ queue: [PullRequest], runs: [String: ReviewRun] = [:], repos: [RepoRef]? = nil) -> [String: ReviewNeed] {
        ReviewReadiness.needs(ReviewReadinessInput(login: "me", queue: queue, runs: runs, repos: repos ?? self.repos))
    }

    @Test func aPullRequestYouHaveNotReviewedIsReadyToRun() {
        let pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        #expect(needs([pr]) == [pr.url: .notReviewed])
    }

    @Test func nothingIsReadyWithoutALocalClone() {
        // There would be nothing to check the PR out into. The row says "no local clone" instead.
        let pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        #expect(needs([pr], repos: []).isEmpty)
    }

    /// A draft with Claude's comments waits on you; one you started by hand does not stop a run.
    @Test func aDraftWithClaudesCommentsIsNotReadyAgain() {
        var pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        pr.pendingReview = Fixtures.pending(claude: 2)
        #expect(needs([pr]).isEmpty)
        pr.pendingReview = Fixtures.pending(comments: 1, claude: 0)
        #expect(needs([pr]) == [pr.url: .notReviewed])
    }

    @Test func aReviewYouSubmittedIsDoneUntilYouAreAskedAgain() {
        var pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        pr.reviews = [Fixtures.review("CHANGES_REQUESTED", at: Fixtures.hours(1))]
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
        pr.reviews = [Fixtures.review("APPROVED", at: Fixtures.hours(1), by: "bob")]
        #expect(needs([pr]) == [pr.url: .notReviewed])
    }

    /// This session's run decides while it is going and once it has failed; after a clean run that found
    /// nothing there is no draft to show for it, and the run itself is what says it is done.
    @Test func thisSessionsRunDecidesWhileItLasts() {
        let pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        #expect(needs([pr], runs: [pr.url: ReviewRun(phase: .running)]).isEmpty)
        #expect(needs([pr], runs: [pr.url: ReviewRun(phase: .failed, error: "boom")]) == [pr.url: .failed])
        #expect(needs([pr], runs: [pr.url: ReviewRun(phase: .posted)]).isEmpty)
    }

    @Test func newCommitsAloneNeverAskForARun() {
        // GitHub marks the draft's comments on changed lines outdated by itself; a run costs money.
        var pr = Fixtures.pr(number: 1, head: "a", author: "alice")
        pr.pendingReview = Fixtures.pending(commit: "older")
        #expect(needs([pr]).isEmpty)
    }
}
