import DeskCore
import Foundation
import Testing

@Suite struct NudgeEngineTests {
    var config: DeskConfig {
        var config = DeskConfig()
        config.claudeWaitingMinutes = 10
        config.stalePullRequestDays = 3
        return config
    }

    func input(mine: [PullRequest] = [], reviews: [PullRequest] = [], live: [LiveSession] = [], worktrees: [Worktree] = []) -> NudgeInput {
        NudgeInput(
            now: Fixtures.t0, login: "me", config: config, mine: mine, reviewRequests: reviews, worktrees: worktrees,
            liveSessions: live, openHeadsByRepo: Linker.openHeadsByRepo(mine + reviews), defaultBranches: ["cofhe": "master"]
        )
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

    @Test func idleClaudeSessionNudgesAfterThreshold() {
        let waiting = Fixtures.live(id: "w", cwd: "/r/cofhe", status: .idle, statusAge: 15 * 60)
        let fresh = Fixtures.live(id: "f", cwd: "/r/cofhe", status: .idle, statusAge: 2 * 60)
        let busy = Fixtures.live(id: "b", cwd: "/r/cofhe", status: .busy, statusAge: 60 * 60)
        let dead = Fixtures.live(id: "d", cwd: "/r/cofhe", status: .idle, statusAge: 60 * 60, alive: false)
        let nudges = NudgeEngine.nudges(input(live: [waiting, fresh, busy, dead]))
        #expect(nudges.map(\.kind) == [.claudeWaiting])
        #expect(nudges[0].title.contains("w"))
    }

    @Test func botReviewsCollapseIntoOneNudge() {
        let bot1 = Fixtures.pr(number: 10, head: "sub1", author: "github-actions[bot]")
        let bot2 = Fixtures.pr(number: 11, title: "Update Submodule from cofhe-contracts", head: "sub2", author: "liorbond")
        let human = Fixtures.pr(number: 12, head: "h", author: "alice")
        let nudges = NudgeEngine.nudges(input(reviews: [bot1, bot2, human]))
        #expect(nudges.filter { $0.kind == .botReviews }.count == 1)
        #expect(nudges.filter { $0.kind == .reviewRequested }.count == 1)
    }

    @Test func stalePullRequestAfterConfiguredDays() {
        let old = Fixtures.pr(number: 3, head: "c", updated: Fixtures.t0.addingTimeInterval(-4 * 86_400))
        let nudges = NudgeEngine.nudges(input(mine: [old]))
        #expect(nudges.map(\.kind) == [.stalePullRequest])
    }
}
