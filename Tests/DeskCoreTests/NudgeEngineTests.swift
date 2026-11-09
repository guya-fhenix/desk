import DeskCore
import Foundation
import Testing

@Suite struct NudgeEngineTests {
    var config: DeskConfig { DeskConfig() }

    func input(mine: [PullRequest] = [], reviews: [PullRequest] = [], merged: [PullRequest] = []) -> NudgeInput {
        NudgeInput(
            now: Fixtures.t0, login: "me", config: config, mine: mine, reviewRequests: reviews,
            mergedHeadsByRepo: Linker.mergedHeadsByRepo(merged)
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
        #expect(NudgeEngine.nudges(withFlow).first?.title == "cofhe#3 is a draft: run /pre-pr, or mark it ready")

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

    /// A draft /pre-pr ran on says whether it passed: its label, or an Important finding still open.
    @Test func aDraftSaysWhetherPrePRPassed() {
        var pr = Fixtures.pr(number: 4, head: "d", draft: true)
        pr.evidence = "<!-- pre-pr:start -->\n## Testing"
        let key = ClaudeJobs.prKey(pr.url)!
        var flow = input(mine: [pr])
        flow.sessions = [ClaudeJob(id: "aaaaaaaa", name: "s", state: "done", cwd: "/r/cofhe", prKeys: [key], updatedAt: Fixtures.t0, startedOn: [key])]
        let waiting = { NudgeEngine.nudges(flow).first { $0.kind == .flowWaiting }?.title }
        #expect(PrePRStatus.of(pr) == .importantOpen)
        #expect(waiting() == "cofhe#4: /pre-pr left an Important finding open")
        pr.labels = [PrePR.reviewedLabel]
        flow.mine = [pr]
        #expect(PrePRStatus.of(pr) == .passed)
        #expect(waiting() == "cofhe#4 passed /pre-pr: mark it ready")
        #expect(pr.isLocallyReviewed)
    }

    @Test func failedChecksAreUrgent() {
        let nudges = NudgeEngine.nudges(input(mine: [Fixtures.pr(number: 1, head: "a", checks: .failure)]))
        #expect(nudges.first?.kind == .ciFailed)
        #expect(nudges.first?.severity == .urgent)
    }

    /// Only a merged parent says a PR needs a rebase; a base Desk knows nothing about, such as a release branch, says nothing.
    @Test func aRebaseNeedsAMergedBase() {
        let release = Fixtures.pr(number: 1, head: "fix", base: "release/x")
        #expect(NudgeEngine.nudges(input(mine: [release])).isEmpty)
        let stacked = Fixtures.pr(number: 2, head: "part-2", base: "part-1")
        let parent = Fixtures.pr(number: 3, head: "part-1", merged: Fixtures.hours(1))
        #expect(NudgeEngine.nudges(input(mine: [stacked], merged: [parent])).map(\.kind) == [.needsRebase])
        // The default branch is GitHub's, so a repo on `develop` is no PR's merged base.
        var onDevelop = Fixtures.pr(number: 4, head: "feat", base: "develop")
        onDevelop.defaultBranch = "develop"
        #expect(NudgeEngine.nudges(input(mine: [onDevelop], merged: [Fixtures.pr(number: 5, head: "develop", base: "release", merged: Fixtures.hours(1))])).isEmpty)
    }

    @Test func approvedCleanPullRequestIsReadyToMerge() {
        let pr = Fixtures.pr(number: 2, head: "b", review: .approved, merge: .clean)
        let kinds = NudgeEngine.nudges(input(mine: [pr])).map(\.kind)
        #expect(kinds == [.readyToMerge])
    }

    /// A request that comes back after you reviewed is a new nudge, not one already delivered; someone else's review is not.
    @Test func aReRequestIsANewNudge() {
        let asked = Fixtures.pr(number: 5, head: "e", author: "alice")
        var answered = asked
        answered.reviews = [Review(state: "CHANGES_REQUESTED", submittedAt: Fixtures.hours(1), author: "me")]
        var othersOnly = asked
        othersOnly.reviews = [Review(state: "APPROVED", submittedAt: Fixtures.hours(1), author: "bob")]
        let id = { (pr: PullRequest) in NudgeEngine.nudges(input(reviews: [pr])).first { $0.kind == .reviewRequested }?.id }
        #expect(id(asked) != id(answered))
        #expect(id(asked) == id(othersOnly))
    }

    @Test func everyNudgeLandsOnTheScreenThatHandlesIt() {
        let mine = Fixtures.pr(number: 1, head: "a", checks: .failure)
        let theirs = Fixtures.pr(number: 2, head: "b", author: "alice")
        let byScreen = Dictionary(grouping: NudgeEngine.nudges(input(mine: [mine], reviews: [theirs])), by: \.kind.screen)
        #expect(byScreen[.pullRequests]?.map(\.kind) == [.ciFailed])
        #expect(byScreen[.reviews]?.map(\.kind) == [.reviewRequested])
    }
}
