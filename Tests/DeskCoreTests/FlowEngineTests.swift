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

    /// A teammate's review asks the session for fixes; yours and the bots' start nothing, and neither does one
    /// already answered. An approval with nothing left open is the end of review.
    @Test func aTeammatesReviewAsksForProposedFixes() {
        let since = Fixtures.hours(4)
        var waiting = flow(stage: .inReview, pr: 11)
        waiting.reviewsSince = since
        func pr(_ reviews: [Review], decision: ReviewDecision = .changesRequested, threads: Int = 1) -> PullRequest {
            var pr = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3), review: decision, reviews: reviews)
            pr.unresolvedThreads = threads
            return pr
        }
        func run(_ flow: Flow, _ pr: PullRequest) -> Flow {
            // Working: nothing goes out, so what was queued stays visible.
            FlowEngine.advance(flow, FlowInput(job: job([11], state: "working"), mine: [pr], merged: [], login: "me", bots: ["copilot"])).flow
        }

        let teammate = run(waiting, pr([Fixtures.review("CHANGES_REQUESTED", at: Fixtures.hours(5), by: "haim")]))
        #expect(teammate.pending == .proposeFixes && teammate.reviewsSince == Fixtures.hours(5))
        // Already handled: the same review a poll later queues nothing new.
        var handled = teammate
        handled.pending = nil
        #expect(run(handled, pr([Fixtures.review("CHANGES_REQUESTED", at: Fixtures.hours(5), by: "haim")])).pending == nil)

        #expect(run(waiting, pr([Fixtures.review(at: Fixtures.hours(5), by: "me")])).pending == nil)
        #expect(run(waiting, pr([Fixtures.review(at: Fixtures.hours(5), by: "copilot")])).pending == nil)
        #expect(run(waiting, pr([Fixtures.review(at: Fixtures.hours(5), by: "github-actions[bot]")])).pending == nil)
        #expect(run(waiting, pr([Fixtures.review(at: Fixtures.hours(3), by: "haim")])).pending == nil)

        let approved = run(waiting, pr([Fixtures.review("APPROVED", at: Fixtures.hours(5), by: "haim")], decision: .approved, threads: 0))
        #expect(approved.stage == .approved && approved.pending == nil)
        // Approved but a thread is still open: the session proposes fixes for it first.
        #expect(run(waiting, pr([Fixtures.review("APPROVED", at: Fixtures.hours(5), by: "haim")], decision: .approved)).pending == .proposeFixes)
        // An approval dismissed by a later change request puts it back in review.
        #expect(run(approved, pr([], decision: .changesRequested, threads: 0)).stage == .inReview)
    }

    @Test func proposalsWaitForYouAndAnEmptyAnswerGoesBackToReview() {
        let pr = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3))
        var proposing = flow(stage: .inReview, pr: 11)
        proposing.awaiting = .proposeFixes
        proposing.reviewsSince = Fixtures.hours(9)
        let file = Data(#"{"proposals": [{"thread": "PRRT_1", "reviewer": "haim", "file": "a.rs", "line": 3, "comment": "C", "fix": "F", "resolve": true}, {"comment": "Rename it", "fix": "Renamed"}]}"#.utf8)
        let proposed = FlowEngine.advance(proposing, FlowInput(job: job([11], state: "working"), mine: [pr], merged: [], result: file)).flow
        #expect(proposed.stage == .fixesProposed)
        #expect(proposed.proposals == [
            Proposal(thread: "PRRT_1", reviewer: "haim", file: "a.rs", line: 3, comment: "C", fix: "F", resolve: true),
            Proposal(comment: "Rename it", fix: "Renamed"),
        ])
        let empty = FlowEngine.advance(proposing, FlowInput(job: job([11], state: "working"), mine: [pr], merged: [], result: Data(#"{"proposals": []}"#.utf8))).flow
        #expect(empty.stage == .inReview && empty.note != nil)
    }

    /// After the fixes are in, a PR that is still not approved goes back to the review team.
    @Test func appliedFixesAskTheTeamAgainUnlessApproved() {
        var applying = flow(stage: .applying, pr: 11)
        applying.awaiting = .applyFixes
        applying.proposals = [Proposal(comment: "C", fix: "F", apply: true)]
        let file = Data(#"{"applied": 1, "summary": "S"}"#.utf8)
        let open = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3), review: .changesRequested)
        let notYet = FlowEngine.advance(applying, FlowInput(job: job([11], state: "working"), mine: [open], merged: [], result: file))
        #expect(notYet.flow.stage == .inReview && notYet.flow.proposals.isEmpty && notYet.effects == [.requestTeam])

        let approved = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3), review: .approved)
        let done = FlowEngine.advance(applying, FlowInput(job: job([11], state: "working"), mine: [approved], merged: [], result: file))
        #expect(done.flow.stage == .approved && done.effects.isEmpty)
    }

    @Test func theApplyInstructionListsOnlyTheFixesYouApproved() {
        let text = FlowEngine.approvedFixes([
            Proposal(thread: "PRRT_1", file: "a.rs", line: 3, comment: "C", fix: "Check for empty input.", resolve: true, apply: true),
            Proposal(thread: "PRRT_2", comment: "C", fix: "Skipped one.", apply: false),
            Proposal(thread: "PRRT_3", comment: "C", fix: "Rename the helper.", resolve: false, apply: true),
        ])
        #expect(text == "1. a.rs:3: Check for empty input. (thread PRRT_1: resolve it)\n2. Rename the helper. (thread PRRT_3: leave it open)")
    }

    @Test func aMergeEndsTheFlowWhateverStageItWasIn() {
        let merged = Fixtures.pr(number: 11, head: "worktree-pro-1", created: Fixtures.hours(3), merged: Fixtures.hours(9))
        #expect(FlowEngine.advance(flow(stage: .inReview, pr: 11), FlowInput(job: nil, mine: [], merged: [merged])).flow.stage == .merged)
    }
}
