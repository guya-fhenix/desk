import DeskCore
import Foundation
import Testing

@Suite struct DeskStateTests {
    var state: DeskState {
        var config = DeskConfig()
        config.reviewRoot = "/r/.reviews"
        var state = DeskState(config: config)
        state.github = GitHubSnapshot(login: "me", mine: [], reviewRequests: [], mergedRecent: [], reviewedByMe: [], fetchedAt: Fixtures.t0)
        return state
    }

    @Test func reviewWorktreesAreKeptApartFromWorkingOnes() {
        var state = state
        let main = Fixtures.worktree(path: "/r/cofhe", branch: "master", isMain: true)
        let review = Fixtures.worktree(path: "/r/.reviews/cofhe/pr-9", branch: nil)
        state.gitScan = GitScan(repos: [Fixtures.repo()], worktrees: [main, review])
        #expect(state.worktrees.map(\.path) == ["/r/cofhe"])
        #expect(state.reviewWorktrees.map(\.path) == ["/r/.reviews/cofhe/pr-9"])
    }

    @Test func reviewStatusComesFromTheRecordAndThePullRequest() {
        var state = state
        let pr = Fixtures.pr(number: 9, head: "y")
        state.github?.reviewRequests = [pr]
        state.reviews[pr.url] = Fixtures.record(
            pr: pr, head: "older", runs: 2, comments: [Fixtures.comment(state: .approved)], cost: 2
        )
        let status = try! #require(state.reviewStatus(for: pr))
        #expect(status.phase == .ready)
        #expect(status.costUSD == 2)
        #expect(status.headMoved)
        #expect(status.counts.approved == 1)
    }

    @Test func draftsAndBotPullRequestsStayOutOfTheReviewQueue() {
        var state = state
        let ready = Fixtures.pr(number: 1, head: "a", author: "alice")
        let draft = Fixtures.pr(number: 2, head: "b", author: "alice", draft: true)
        let bot = Fixtures.pr(number: 3, head: "c", author: "github-actions[bot]")
        let workflow = Fixtures.pr(number: 4, title: "Update Submodule from cofhe-contracts", head: "d", author: "liorbond")
        state.github?.reviewRequests = [ready, draft, bot, workflow]
        state.reviews[draft.url] = Fixtures.record(pr: draft)
        state.recompute(now: Fixtures.t0)
        #expect(state.reviewRequests.map(\.number) == [1])
        #expect(state.pastReviews.map(\.number) == [2])
        #expect(state.nudges.filter { $0.kind == .reviewRequested }.map(\.url) == [ready.url])
    }

    @Test func pastReviewsAreTheOnesOutsideTheQueue() {
        var state = state
        let queued = Fixtures.pr(number: 1, head: "a", author: "alice")
        let reviewed = Fixtures.pr(number: 2, head: "b", author: "alice")
        state.github?.reviewRequests = [queued]
        state.reviews = [queued.url: Fixtures.record(pr: queued), reviewed.url: Fixtures.record(pr: reviewed)]
        #expect(state.pastReviews.map(\.number) == [2])
        #expect(state.pullRequest(for: state.reviews[reviewed.url]!) == nil)
    }

    @Test func stateMarksWhichPullRequestsAreReadyToRun() {
        var state = state
        state.gitScan = GitScan(repos: [Fixtures.repo()], worktrees: [])
        let fresh = Fixtures.pr(number: 1, head: "a", author: "alice")
        var reRequested = Fixtures.pr(number: 2, head: "b", author: "alice")
        reRequested.reviewRequestEvents = [Fixtures.event(at: Fixtures.hours(1))]
        let done = Fixtures.pr(number: 3, head: "c", author: "alice")
        state.github?.reviewRequests = [fresh, reRequested, done]
        state.reviews = [
            reRequested.url: Fixtures.record(pr: reRequested, lastRun: Fixtures.t0),
            done.url: Fixtures.record(pr: done, lastRun: Fixtures.t0),
        ]
        state.recompute(now: Fixtures.hours(2))
        #expect(state.reviewNeed(for: fresh) == .notReviewed)
        #expect(state.reviewNeed(for: reRequested) == .reRequested)
        #expect(state.reviewNeed(for: done) == nil)
        // Oldest first, so the row worth pressing first is at the top.
        #expect(state.reviewsToRun.map(\.number) == [1, 2])
    }

    @Test func finishedReviewRaisesTheReadyNudge() {
        var state = state
        let pr = Fixtures.pr(number: 9, head: "y", author: "alice")
        state.github?.reviewRequests = [pr]
        state.reviews[pr.url] = Fixtures.record(
            pr: pr, runs: 2, comments: [Fixtures.comment(), Fixtures.comment(line: 50)]
        )
        state.recompute(now: Fixtures.t0)
        let ready = state.nudges.filter { $0.kind == .reviewReady }
        #expect(ready.count == 1)
        #expect(ready.first?.id == "prereview:\(pr.url):2")
        #expect(ready.first?.detail == "2 comments to look over")
        #expect(ready.first?.url == pr.url)
    }

    @Test func aRunningReviewRaisesNoNudgeYet() {
        var state = state
        let pr = Fixtures.pr(number: 9, head: "y", author: "alice")
        state.github?.reviewRequests = [pr]
        state.reviews[pr.url] = Fixtures.record(pr: pr, phase: .running, comments: [Fixtures.comment()])
        state.recompute(now: Fixtures.t0)
        #expect(!state.nudges.contains { $0.kind == .reviewReady })
    }

}

@Suite struct ReviewScopeTests {
    var state: DeskState {
        var config = DeskConfig()
        config.reviewRoot = "/r/.reviews"
        var state = DeskState(config: config)
        state.github = GitHubSnapshot(login: "me", mine: [], reviewRequests: [], mergedRecent: [], reviewedByMe: [], fetchedAt: Fixtures.t0)
        return state
    }

    @Test func openForReviewDropsWhatIsAlreadyOnYouOrAlreadyReviewed() {
        var state = state
        let onMe = Fixtures.pr(number: 1, head: "a", author: "alice")
        let fresh = Fixtures.pr(number: 2, head: "b", author: "alice")
        let mineAlready = Fixtures.pr(
            number: 3, head: "c", author: "alice",
            reviews: [Review(state: "APPROVED", submittedAt: Fixtures.t0, author: "me")]
        )
        let draft = Fixtures.pr(number: 4, head: "d", author: "alice", draft: true)
        let bot = Fixtures.pr(number: 5, head: "e", author: "dependabot")
        state.github?.reviewRequests = [onMe]
        state.github?.openForReview = [onMe, fresh, mineAlready, draft, bot]

        #expect(state.openForReview.map(\.number) == [2])
        #expect(state.reviewQueue(.onMe).map(\.number) == [1])
        #expect(state.reviewQueue(.all).map(\.number) == [1, 2])
    }

    @Test func aReviewOfAnOpenPullRequestIsNotAPastReview() {
        var state = state
        let other = Fixtures.pr(number: 7, head: "g", author: "alice")
        state.github?.openForReview = [other]
        state.reviews[other.url] = Fixtures.record(pr: other)
        #expect(state.pastReviews.isEmpty)
    }

    @Test func reviewIsOfferedOnPullRequestsNobodyAssignedYou() {
        var state = state
        let other = Fixtures.pr(number: 8, head: "h", author: "alice")
        state.gitScan = GitScan(repos: [Fixtures.repo()], worktrees: [])
        state.github?.openForReview = [other]
        state.recompute(now: Fixtures.t0)
        // Without this the Review button never appears for a PR outside your own queue.
        #expect(state.reviewNeed(for: other) == .notReviewed)
    }
}

@Suite struct ReviewWindowTests {
    @Test func theQueueDefaultsToTheLastTwoWeeks() {
        var state = DeskState(config: DeskConfig())
        let fresh = Fixtures.pr(number: 1, head: "a", author: "alice", created: Fixtures.hours(-24))
        let old = Fixtures.pr(number: 2, head: "b", author: "alice", created: Fixtures.hours(-24 * 30))
        state.github = GitHubSnapshot(
            login: "me", mine: [], reviewRequests: [fresh, old], mergedRecent: [], reviewedByMe: [], fetchedAt: Fixtures.t0
        )
        #expect(state.reviewQueue(.onMe, recentOnly: true, now: Fixtures.t0).map(\.number) == [1])
        #expect(state.reviewQueue(.onMe, recentOnly: false, now: Fixtures.t0).map(\.number) == [1, 2])
    }
}

@Suite struct TicketGroupingTests {
    @Test func groupsOpenTicketsByStatusInWorkflowOrderAndDropsDone() {
        var state = DeskState(config: DeskConfig())
        state.tickets = [
            Fixtures.ticket("PRO-3", category: .inProgress, status: "Review Ready", placement: .sprint),
            Fixtures.ticket("PRO-1", category: .todo, status: "To Do", placement: .sprint),
            Fixtures.ticket("PRO-2", category: .inProgress, status: "Review Ready", placement: .sprint),
            Fixtures.ticket("PRO-9", category: .done, status: "Done", placement: .sprint),
            Fixtures.ticket("PRO-7", category: .todo, status: "To Do", placement: .backlog),
        ]
        let sprint = state.ticketGroups(.sprint)
        #expect(sprint.map(\.status) == ["To Do", "Review Ready"])
        #expect(sprint.map(\.tickets.count) == [1, 2])
        // Done is not work left to do, so it never reaches the screen.
        #expect(!sprint.contains { $0.category == .done })
        #expect(state.ticketGroups(.backlog).map(\.status) == ["To Do"])
        #expect(state.openTickets.count == 4)
    }
}
