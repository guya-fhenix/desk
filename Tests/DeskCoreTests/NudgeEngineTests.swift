import DeskCore
import Foundation
import Testing

@Suite struct NudgeEngineTests {
    var config: DeskConfig {
        var config = DeskConfig()
        config.stalePullRequestDays = 3
        return config
    }

    func input(mine: [PullRequest] = [], reviews: [PullRequest] = []) -> NudgeInput {
        NudgeInput(
            now: Fixtures.t0, login: "me", config: config, mine: mine, reviewRequests: reviews,
            openHeadsByRepo: Linker.openHeadsByRepo(mine + reviews), defaultBranches: ["cofhe": "master"]
        )
    }

    /// A flow's own nudges stand in for the PR ones it handles itself; a paused flow hands them back.
    @Test func aFlowSaysWhatWaitsOnYouInsteadOfTheNudgesItHandles() {
        let pr = Fixtures.pr(number: 3, head: "c", checks: .failure, review: .approved, merge: .clean)
        var flow = Flow(jobId: "aaaaaaaa", ticketKey: "PRO-1", repoRoot: "/r/cofhe", prURL: pr.url, stage: .approved, startedAt: Fixtures.t0)
        var withFlow = input(mine: [pr])
        withFlow.flows = [flow]
        #expect(NudgeEngine.nudges(withFlow).map(\.kind) == [.flowWaiting])
        #expect(NudgeEngine.nudges(withFlow).first?.title == "cofhe#3 is approved: merge it")

        withFlow.sessionStates = ["aaaaaaaa": "blocked"]
        #expect(Set(NudgeEngine.nudges(withFlow).map(\.kind)) == [.flowWaiting, .sessionNeedsYou])

        flow.paused = true
        withFlow.flows = [flow]
        withFlow.sessionStates = [:]
        #expect(Set(NudgeEngine.nudges(withFlow).map(\.kind)) == [.flowWaiting, .ciFailed])

        // Nothing to press while the session is on the stage's instruction.
        flow.paused = false
        flow.stage = .draft
        flow.awaiting = .fixConflict
        withFlow.flows = [flow]
        #expect(NudgeEngine.nudges(withFlow).isEmpty)
    }

    @Test func failedChecksAreUrgent() {
        let nudges = NudgeEngine.nudges(input(mine: [Fixtures.pr(number: 1, head: "a", checks: .failure)]))
        #expect(nudges.first?.kind == .ciFailed)
        #expect(nudges.first?.severity == .urgent)
    }

    @Test func approvedCleanPullRequestIsReadyToMerge() {
        let pr = Fixtures.pr(number: 2, head: "b", review: .approved, merge: .clean)
        let kinds = NudgeEngine.nudges(input(mine: [pr])).map(\.kind)
        #expect(kinds == [.readyToMerge])
    }

    @Test func stalePullRequestAfterConfiguredDays() {
        let old = Fixtures.pr(number: 3, head: "c", updated: Fixtures.t0.addingTimeInterval(-4 * 86_400))
        let nudges = NudgeEngine.nudges(input(mine: [old]))
        #expect(nudges.map(\.kind) == [.stalePullRequest])
    }

    @Test func finishedReviewNudgesWithItsCommentCount() {
        let pr = Fixtures.pr(number: 12, head: "h", author: "alice")
        var input = input(reviews: [pr])
        input.readyReviews = [ReadyReview(pr: pr, comments: 3, draftId: "draft1")]
        let nudges = NudgeEngine.nudges(input).filter { $0.kind == .reviewReady }
        #expect(nudges.count == 1)
        // Straight at the draft: pending comments show in the Files tab.
        #expect(nudges[0].url == "\(pr.url)/files")
        #expect(nudges[0].title == "Claude reviewed cofhe#12")
        #expect(nudges[0].detail == "3 comments waiting in your draft review")
        // Keyed by the draft, so a new draft on the same PR is news again.
        #expect(nudges[0].id == "prereview:draft1")
    }

    @Test func everyNudgeLandsOnTheScreenThatHandlesIt() {
        let mine = Fixtures.pr(number: 1, head: "a", checks: .failure)
        let theirs = Fixtures.pr(number: 2, head: "b", author: "alice")
        var input = input(mine: [mine], reviews: [theirs])
        input.readyReviews = [ReadyReview(pr: theirs, comments: 1, draftId: "d")]
        let byScreen = Dictionary(grouping: NudgeEngine.nudges(input), by: \.kind.screen)
        #expect(byScreen[.pullRequests]?.map(\.kind) == [.ciFailed])
        #expect(byScreen[.reviews]?.map(\.kind).sorted { "\($0)" < "\($1)" } == [.reviewReady, .reviewRequested])
    }
}
