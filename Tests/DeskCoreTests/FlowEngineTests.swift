import DeskCore
import Foundation
import Testing

@Suite struct FlowEngineTests {
    private let start = Fixtures.hours(1)

    private func job(_ numbers: [Int], state: String = "done", updated: Date? = nil) -> ClaudeJob {
        ClaudeJob(
            id: "aaaaaaaa", name: "PRO-1", state: state, cwd: "/r/cofhe",
            prKeys: Set(numbers.map { "fhenixprotocol/cofhe#\($0)" }), updatedAt: updated ?? start, sessionId: "aaaaaaaa-uuid"
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

        let moved = FlowEngine.advance(flow(), FlowInput(job: job([10, 11, 12]), mine: [read, opened, aside], merged: [], ticketKeys: keys)).flow
        #expect(moved.prURL == opened.url)
        #expect(moved.stage == .draft)

        // Nothing names the ticket: the first PR opened after the session started.
        let unnamed = FlowEngine.advance(flow(), FlowInput(job: job([10, 11, 12]), mine: [read, opened, aside], merged: [])).flow
        #expect(unnamed.prURL == aside.url)
    }

    @Test func staysWorkingUntilTheSessionHasOpenedSomething() {
        let pr = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3), draft: true)
        #expect(FlowEngine.advance(flow(), FlowInput(job: nil, mine: [pr], merged: [])).flow.stage == .working)
        #expect(FlowEngine.advance(flow(), FlowInput(job: job([]), mine: [pr], merged: [])).flow.prURL == nil)
    }

    /// A session that opened its PR ready for review, or a draft you mark ready on GitHub, has skipped the
    /// draft stages.
    @Test func aReadyPullRequestIsInReview() {
        let ready = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3))
        #expect(FlowEngine.advance(flow(), FlowInput(job: job([11]), mine: [ready], merged: [])).flow.stage == .inReview)
        #expect(FlowEngine.advance(flow(stage: .draft, pr: 11), FlowInput(job: nil, mine: [ready], merged: [])).flow.stage == .inReview)
        // Self-review keeps the PR a draft on purpose; GitHub agreeing changes nothing.
        let draft = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3), draft: true)
        #expect(FlowEngine.advance(flow(stage: .selfReview, pr: 11), FlowInput(job: nil, mine: [draft], merged: [])).flow.stage == .selfReview)
    }

    /// The session rules: an instruction goes out only to a session that has finished its turn, never to one
    /// that is working or asking you something; an automatic one also waits for ten idle minutes; pause holds all.
    @Test func aQueuedInstructionWaitsForTheSessionToBeFree() {
        let draft = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3), draft: true)
        var queued = flow(stage: .selfReview, pr: 11)
        queued.pending = .selfReview
        let now = Fixtures.hours(5)
        func run(_ flow: Flow, _ job: ClaudeJob) -> (flow: Flow, effects: [FlowEffect]) {
            FlowEngine.advance(flow, FlowInput(job: job, mine: [draft], merged: [], now: now))
        }

        #expect(run(queued, job([11], state: "working")).effects.isEmpty)
        #expect(run(queued, job([11], state: "blocked")).effects.isEmpty)
        let sent = run(queued, job([11], updated: now))
        #expect(sent.effects == [.send(.selfReview)])
        #expect(sent.flow.pending == nil && sent.flow.awaiting == .selfReview && sent.flow.step == 1 && sent.flow.sentAt == now)
        // Already on something: the next one waits for its result.
        #expect(run(sent.flow, job([11], updated: now)).effects.isEmpty)

        var paused = queued
        paused.paused = true
        #expect(run(paused, job([11], updated: now)).effects.isEmpty)

        var automatic = flow(stage: .inReview, pr: 11)
        automatic.pending = .fixConflict
        #expect(run(automatic, job([11], updated: now.addingTimeInterval(-300))).effects.isEmpty)
        #expect(run(automatic, job([11], updated: now.addingTimeInterval(-600))).effects == [.send(.fixConflict)])
    }

    @Test func theSelfReviewsResultFileBringsItsFindingsToYou() {
        let draft = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3), draft: true)
        var running = flow(stage: .selfReview, pr: 11)
        running.awaiting = .selfReview
        running.step = 1
        let file = Data(#"{"rounds": 2, "clean": true, "findings": [{"severity": "high", "file": "src/a.rs", "line": 4, "problem": "P", "fix": "F", "round": 1, "fixed": true}]}"#.utf8)

        #expect(FlowEngine.advance(running, FlowInput(job: job([11]), mine: [draft], merged: [])).flow.stage == .selfReview)
        let done = FlowEngine.advance(running, FlowInput(job: job([11]), mine: [draft], merged: [], result: file)).flow
        #expect(done.stage == .fixesToCheck && done.awaiting == nil)
        #expect(done.selfReview == SelfReview(rounds: 2, clean: true, findings: [
            Finding(severity: "high", file: "src/a.rs", line: 4, problem: "P", fix: "F", round: 1, fixed: true),
        ]))

        // A summary that does not read still lets you look at the changes, and says so.
        let garbled = FlowEngine.advance(running, FlowInput(job: job([11]), mine: [draft], merged: [], result: Data("nope".utf8))).flow
        #expect(garbled.stage == .fixesToCheck && garbled.selfReview == nil && garbled.note != nil)
    }

    @Test func aSessionThatWentQuietWithoutItsResultIsStalled() {
        var running = flow(stage: .selfReview, pr: 11)
        running.awaiting = .selfReview
        running.sentAt = Fixtures.hours(2)
        let now = Fixtures.hours(3)
        // Not yet seen working again since the send: the scan is behind, not the session.
        #expect(!FlowEngine.isStalled(running, job: job([], updated: Fixtures.hours(1)), now: now))
        #expect(!FlowEngine.isStalled(running, job: job([], updated: now.addingTimeInterval(-30)), now: now))
        #expect(!FlowEngine.isStalled(running, job: job([], state: "working", updated: Fixtures.hours(2.5)), now: now))
        #expect(FlowEngine.isStalled(running, job: job([], updated: Fixtures.hours(2.5)), now: now))
    }

    /// A flows.json written before a field existed still loads.
    @Test func anOlderFlowsFileStillLoads() throws {
        let old = Data(#"[{"jobId": "aaaaaaaa", "ticketKey": "PRO-1", "repoRoot": "/r/cofhe", "stage": "draft", "startedAt": "2026-10-11T10:00:00Z"}]"#.utf8)
        let flows = try JSON.decoder().decode([Flow].self, from: old)
        #expect(flows.first?.stage == .draft && flows.first?.paused == false && flows.first?.step == 0)
        let again = try JSON.decoder().decode([Flow].self, from: JSON.encoder().encode(flows))
        #expect(again == flows)
    }

    @Test func aMergeEndsTheFlowWhateverStageItWasIn() {
        let merged = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3), merged: Fixtures.hours(9))
        #expect(FlowEngine.advance(flow(stage: .inReview, pr: 11), FlowInput(job: nil, mine: [], merged: [merged])).flow.stage == .merged)
    }
}
