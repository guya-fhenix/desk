import DeskCore
import Foundation
import Testing

@Suite struct FlowEngineTests {
    private let start = Fixtures.hours(1)

    private func job(_ numbers: [Int]) -> ClaudeJob {
        ClaudeJob(
            id: "aaaaaaaa", name: "PRO-1", state: "done", cwd: "/r/cofhe",
            prKeys: Set(numbers.map { "fhenixprotocol/cofhe#\($0)" }), updatedAt: start
        )
    }

    private func flow(stage: FlowStage = .working, pr: Int? = nil) -> Flow {
        Flow(
            jobId: "aaaaaaaa", ticketKey: "PRO-1", repoRoot: "/r/cofhe",
            prURL: pr.map { "https://github.com/FhenixProtocol/cofhe/pull/\($0)" }, stage: stage, startedAt: start
        )
    }

    /// The session read #10 before it opened anything, and opened #12 on the side: the PR it opened for the
    /// ticket is #11.
    @Test func linksThePullRequestTheSessionOpenedForTheTicket() {
        let read = Fixtures.pr(number: 10, head: "other", created: Fixtures.hours(0), draft: true)
        let opened = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3), draft: true)
        let aside = Fixtures.pr(number: 12, head: "cleanup", created: Fixtures.hours(2), draft: true)
        let keys = [opened.url: ["PRO-1"]]

        let moved = FlowEngine.advance(flow(), job: job([10, 11, 12]), mine: [read, opened, aside], merged: [], ticketKeys: keys)
        #expect(moved.prURL == opened.url)
        #expect(moved.stage == .draft)

        // Nothing names the ticket: the first PR opened after the session started.
        let unnamed = FlowEngine.advance(flow(), job: job([10, 11, 12]), mine: [read, opened, aside], merged: [], ticketKeys: [:])
        #expect(unnamed.prURL == aside.url)
    }

    @Test func staysWorkingUntilTheSessionHasOpenedSomething() {
        let pr = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3), draft: true)
        #expect(FlowEngine.advance(flow(), job: nil, mine: [pr], merged: [], ticketKeys: [:]).stage == .working)
        #expect(FlowEngine.advance(flow(), job: job([]), mine: [pr], merged: [], ticketKeys: [:]).prURL == nil)
    }

    /// A session that opened its PR ready for review, or a draft you mark ready on GitHub, has skipped the
    /// draft stages.
    @Test func aReadyPullRequestIsInReview() {
        let ready = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3))
        #expect(FlowEngine.advance(flow(), job: job([11]), mine: [ready], merged: [], ticketKeys: [:]).stage == .inReview)
        #expect(FlowEngine.advance(flow(stage: .draft, pr: 11), job: nil, mine: [ready], merged: [], ticketKeys: [:]).stage == .inReview)
        // Self-review keeps the PR a draft on purpose; GitHub agreeing changes nothing.
        let draft = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3), draft: true)
        #expect(FlowEngine.advance(flow(stage: .selfReview, pr: 11), job: nil, mine: [draft], merged: [], ticketKeys: [:]).stage == .selfReview)
    }

    @Test func aMergeEndsTheFlowWhateverStageItWasIn() {
        let merged = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3), merged: Fixtures.hours(9))
        #expect(FlowEngine.advance(flow(stage: .inReview, pr: 11), job: nil, mine: [], merged: [merged], ticketKeys: [:]).stage == .merged)
    }
}
