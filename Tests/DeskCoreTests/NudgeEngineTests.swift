import DeskCore
import Foundation
import Testing

@Suite struct NudgeEngineTests {
    var config: DeskConfig { DeskConfig() }

    func input(mine: [PullRequest] = [], reviews: [PullRequest] = []) -> NudgeInput {
        NudgeInput(
            now: Fixtures.t0, login: "me", config: config, mine: mine, reviewRequests: reviews,
            openHeadsByRepo: Linker.openHeadsByRepo(mine + reviews), defaultBranches: ["cofhe": "master"]
        )
    }

    /// A PR with a session says what its stage waits on you for, in place of the plain ready-to-merge nudge; a session that
    /// asks something says so, and one at work leaves nothing to press.
    @Test func aFlowSaysWhatWaitsOnYou() {
        let pr = Fixtures.pr(number: 3, head: "c", review: .approved, merge: .clean)
        func session(_ state: String) -> ClaudeJob {
            ClaudeJob(
                id: "aaaaaaaa", name: "s", state: state, cwd: "/r/cofhe", prKeys: [ClaudeJobs.prKey(pr.url)!], updatedAt: Fixtures.t0,
                startedOn: [ClaudeJobs.prKey(pr.url)!]
            )
        }
        var withFlow = input(mine: [pr])
        withFlow.sessions = [session("done")]
        #expect(NudgeEngine.nudges(withFlow).map(\.kind) == [.flowWaiting])
        #expect(NudgeEngine.nudges(withFlow).first?.title == "cofhe#3 is approved: merge it")

        withFlow.sessions = [session("blocked")]
        #expect(Set(NudgeEngine.nudges(withFlow).map(\.kind)) == [.sessionNeedsYou])

        var draft = pr
        draft.isDraft = true
        withFlow.mine = [draft]
        withFlow.sessions = [session("working")]
        #expect(NudgeEngine.nudges(withFlow).isEmpty)
        withFlow.sessions = [session("done")]
        #expect(NudgeEngine.nudges(withFlow).first?.title == "cofhe#3 is a draft waiting for your approval")

        // Red CI is no flow's to fix on its own any more: it is nudged as on any PR.
        var red = pr
        red.checks = .failure
        withFlow.mine = [red]
        #expect(Set(NudgeEngine.nudges(withFlow).map(\.kind)) == [.ciFailed, .flowWaiting])

        // A planning session asking something, before it has a PR.
        withFlow.mine = []
        withFlow.sessions = [ClaudeJob(id: "b", name: "p", state: "blocked", cwd: "/r", prKeys: [], updatedAt: Fixtures.t0, ticketKey: "PRO-1")]
        #expect(NudgeEngine.nudges(withFlow).map(\.title) == ["PRO-1: the session is asking you something"])
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
