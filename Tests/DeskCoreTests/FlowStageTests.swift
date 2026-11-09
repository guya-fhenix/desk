import DeskCore
import Foundation
import Testing

/// The flow's stage is worked out from GitHub and the session alone: nothing of it is saved.
@Suite struct FlowStageTests {
    private static let evidence = "<!-- pre-pr:start -->\n## Testing\n- ok"

    private func session(
        _ state: String, prs: [PullRequest] = [], ticket: String? = nil, id: String = "aaaaaaaa", startedOn: [PullRequest] = []
    ) -> ClaudeJob {
        ClaudeJob(
            id: id, name: "s", state: state, cwd: "/r/cofhe", prKeys: Set(prs.compactMap { ClaudeJobs.prKey($0.url) }),
            updatedAt: Fixtures.t0, sessionId: "sid", ticketKey: ticket, startedOn: Set(startedOn.compactMap { ClaudeJobs.prKey($0.url) })
        )
    }

    private func pr(
        draft: Bool = false, evidence: String? = nil, threads: Int = 0, review: ReviewDecision = .reviewRequired,
        gate: String? = nil, merged: Bool = false, checks: CheckState = .success, merge: MergeState = .blocked
    ) -> PullRequest {
        var pr = Fixtures.pr(number: 1, head: "h", merged: merged ? Fixtures.t0 : nil, checks: checks, review: review, merge: merge, draft: draft)
        pr.evidence = evidence
        pr.unresolvedThreads = threads
        pr.approvalStatus = gate
        return pr
    }

    /// Run /pre-pr and Fix it go to an idle session only, and Run /pre-pr without one needs a clone and the skill.
    @Test func whatHoldsBackASendOrARunOfPrePR() {
        let draft = pr(draft: true)
        var state = DeskState(config: DeskConfig())
        state.github = GitHubSnapshot(login: "guya-fhenix", mine: [draft], reviewRequests: [], mergedRecent: [], fetchedAt: Fixtures.t0)
        /// Send's blocker, then Run /pre-pr's.
        func blockers(_ sessionState: String?, sessionId: String? = "sid", sending: Bool = false, starting: Bool = false) -> [String?] {
            var job = sessionState.map { session($0, startedOn: [draft]) }
            job?.sessionId = sessionId
            state.claudeJobs = job.map { [$0] } ?? []
            return [state.sendBlocker(draft, sending: sending), state.prePRBlocker(draft, sending: sending, startingSession: starting)]
        }
        #expect(blockers(nil) == ["No session", "No clone of cofhe here"])
        #expect(blockers(nil, starting: true)[1] == "Starting a session…")
        state.gitScan = GitScan(repos: [Fixtures.repo()])
        #expect(blockers(nil)[1] == "Self-review skill missing")
        state.reviewSkills = [Fixtures.repo().root: ReviewSkill(state: .ready)]
        #expect(blockers(nil) == ["No session", nil])
        #expect(blockers("done") == [nil, nil])
        #expect(blockers("done", sending: true) == ["Sending…", "Sending…"])
        #expect(blockers("blocked")[0] == "The session is asking you something")
        #expect(blockers("working")[0] == "The session is busy")
        #expect(blockers("done", sessionId: nil)[0] == "The session is busy")
    }

    @Test func eachStageFromGitHub() {
        let cases: [(String, PullRequest, FlowStage)] = [
            ("a draft, no evidence", pr(draft: true), .draft),
            ("a draft with /pre-pr's evidence", pr(draft: true, evidence: Self.evidence), .draft),
            ("a draft with evidence and threads left open", pr(draft: true, evidence: Self.evidence, threads: 2), .draft),
            ("ready, nothing open, not approved", pr(), .inReview),
            ("ready with open threads", pr(threads: 2), .inReview),
            ("ready, approved by GitHub, no gate", pr(review: .approved), .approved),
            ("approved but a thread still open", pr(threads: 1, review: .approved), .inReview),
            ("approved but CI failed", pr(review: .approved, checks: .failure), .inReview),
            ("approved but conflicting", pr(review: .approved, merge: .dirty), .inReview),
            ("approved, CI still running", pr(review: .approved, checks: .pending), .approved),
            ("the gate wants one more", pr(review: .approved, gate: "medium risk: 0 of 1 approvals on the latest commit"), .inReview),
            ("the gate is met", pr(gate: "medium risk: 1 of 1 approvals on the latest commit"), .approved),
            ("no approval needed", pr(gate: "low risk: no approval needed; CodeRabbit could not review"), .approved),
            ("waiting for CodeRabbit", pr(gate: "Waiting for CodeRabbit's review of the latest commit"), .inReview),
            ("merged", pr(merged: true), .merged),
        ]
        for (name, pr, stage) in cases {
            #expect(FlowStage.of(pr) == stage, "\(name)")
        }
        var closed = pr()
        closed.state = .closed
        #expect(FlowStage.of(closed) == .closed)
    }

    /// A row says one thing, the first that holds: conflicts, CI failed, changes requested, ready to merge, draft, then
    /// waiting on review.
    @Test func aRowSaysTheFirstThingItWaitsOn() {
        let cases: [(String, PullRequest, RowState, RowState.Move)] = [
            ("conflicts outrank red CI", pr(review: .changesRequested, checks: .failure, merge: .dirty), .conflicts, .yoursToFix),
            ("red CI outranks changes requested", pr(review: .changesRequested, checks: .failure), .ciFailed, .yoursToFix),
            ("changes requested", pr(review: .changesRequested), .changesRequested, .yoursToFix),
            ("a draft with red CI", pr(draft: true, checks: .error), .ciFailed, .yoursToFix),
            ("approved and nothing open", pr(review: .approved, merge: .clean), .readyToMerge, .yoursToMerge),
            ("the gate is met", pr(gate: "medium risk: 1 of 1 approvals on the latest commit"), .readyToMerge, .yoursToMerge),
            ("approved, a thread still open", pr(threads: 1, review: .approved), .waitingOnReview, .others),
            ("a draft /pre-pr has not run on", pr(draft: true), .draft(.notRun), .draft),
            ("a draft /pre-pr left a finding open on", pr(draft: true, evidence: Self.evidence), .draft(.importantOpen), .draft),
            ("waiting on review", pr(), .waitingOnReview, .others),
        ]
        for (name, pr, state, move) in cases {
            #expect(RowState.of(pr) == state, "\(name)")
            #expect(RowState.of(pr).move == move, "\(name)")
        }
        var passed = pr(draft: true, evidence: Self.evidence)
        passed.labels = [PrePR.reviewedLabel]
        #expect(RowState.of(passed).title == "Draft · mark ready")
    }

    /// The session at work is shown beside the stage, never as one: a draft whose self-review runs is still a draft.
    @Test func aWorkingSessionLeavesTheStageAlone() {
        var state = DeskState(config: DeskConfig())
        let draft = Fixtures.pr(number: 8, head: "d", draft: true)
        state.github = GitHubSnapshot(login: "me", mine: [draft], reviewRequests: [], mergedRecent: [], fetchedAt: Fixtures.t0)
        state.recompute(now: Fixtures.t0)
        state.claudeJobs = [session("working", prs: [draft], startedOn: [draft])]
        #expect(state.stage(for: draft) == .draft)
        state.claudeJobs = [session("done", prs: [draft], startedOn: [draft])]
        #expect(state.stage(for: draft) == .draft)
    }

    /// A busy session that only touched a PR, as one long session touches many, does not put it in the flow: only a session
    /// started on the PR, or on its ticket, carries it.
    @Test func onlyASessionStartedOnThePullRequestCarriesIt() {
        var state = DeskState(config: DeskConfig())
        let pr = Fixtures.pr(number: 7, head: "x")
        state.github = GitHubSnapshot(login: "me", mine: [pr], reviewRequests: [], mergedRecent: [], fetchedAt: Fixtures.t0)
        state.recompute(now: Fixtures.t0)
        state.claudeJobs = [session("working", prs: [pr], id: "cccccccc")]
        #expect(state.session(for: pr) == nil)
        #expect(state.stage(for: pr) == nil)
        state.claudeJobs = [session("working", prs: [pr], id: "cccccccc"), session("done", prs: [pr], startedOn: [pr])]
        #expect(state.session(for: pr)?.id == "aaaaaaaa")
        #expect(state.stage(for: pr) == .inReview)
    }

    @Test func sessionsPutPullRequestsAndTicketsInTheFlow() {
        var config = DeskConfig()
        config.jiraProjectKeys = ["PRO"]
        var state = DeskState(config: config)
        let mine = Fixtures.pr(number: 1, title: "PRO-1 the fix", head: "pro-1", draft: true)
        let other = Fixtures.pr(number: 2, head: "b")
        state.github = GitHubSnapshot(login: "me", mine: [mine, other], reviewRequests: [], mergedRecent: [], fetchedAt: Fixtures.t0)
        state.recompute(now: Fixtures.t0)
        #expect(state.stage(for: mine) == nil)

        let planning = session("working", ticket: "PRO-9", id: "bbbbbbbb")
        let opened = session("done", prs: [other, mine], ticket: "PRO-1")
        state.claudeJobs = [planning, opened]
        #expect(state.stage(for: mine) == .draft)
        // It also touched another PR, which names no ticket: that one is not its flow.
        #expect(state.stage(for: other) == nil)
        #expect(state.sessions(forTicket: "PRO-9").map(\.id) == ["bbbbbbbb"])
        #expect(state.stage(of: planning) == .working)
        // It touched two PRs of yours; the one naming its ticket is the one it opened.
        #expect(state.pullRequest(of: opened)?.number == 1)
        #expect(state.stage(of: opened) == .draft)
        // A ticket with a session on it is under way, not one to start.
        state.tickets = [Fixtures.ticket("PRO-8", category: .todo, status: "To Do"), Fixtures.ticket("PRO-9", category: .todo, status: "To Do")]
        #expect(state.ticketsToStart.map(\.key) == ["PRO-8"])
    }
}
