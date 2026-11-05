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
        gate: String? = nil, merged: Bool = false
    ) -> PullRequest {
        var pr = Fixtures.pr(number: 1, head: "h", merged: merged ? Fixtures.t0 : nil, review: review, draft: draft)
        pr.evidence = evidence
        pr.unresolvedThreads = threads
        pr.approvalStatus = gate
        return pr
    }

    @Test func eachStageFromGitHubAndTheSession() {
        let cases: [(String, PullRequest, String?, FlowStage)] = [
            ("a draft, no evidence, idle session", pr(draft: true), "done", .draft),
            ("a draft with no session at all", pr(draft: true), nil, .draft),
            ("a draft whose session runs", pr(draft: true), "working", .selfReview),
            ("a draft whose session asks something mid-turn", pr(draft: true, evidence: Self.evidence), "blocked", .selfReview),
            ("a draft with /pre-pr's evidence, idle", pr(draft: true, evidence: Self.evidence), "done", .fixesToCheck),
            ("a draft with evidence and threads left open", pr(draft: true, evidence: Self.evidence, threads: 2), "done", .fixesToCheck),
            ("ready, nothing open, not approved", pr(), "done", .inReview),
            ("ready with open threads", pr(threads: 2), "done", .threadsToReview),
            ("ready, the session fixing", pr(threads: 2), "working", .fixing),
            ("ready, approved by GitHub, no gate", pr(review: .approved), "done", .approved),
            ("approved but a thread still open", pr(threads: 1, review: .approved), "done", .threadsToReview),
            ("the gate wants one more", pr(review: .approved, gate: "medium risk: 0 of 1 approvals on the latest commit"), "done", .inReview),
            ("the gate is met", pr(gate: "medium risk: 1 of 1 approvals on the latest commit"), "done", .approved),
            ("no approval needed", pr(gate: "low risk: no approval needed; CodeRabbit could not review"), "done", .approved),
            ("waiting for CodeRabbit", pr(gate: "Waiting for CodeRabbit's review of the latest commit"), "done", .inReview),
            ("merged", pr(merged: true), "working", .merged),
        ]
        for (name, pr, state, stage) in cases {
            #expect(FlowStage.of(pr, session: state.map { session($0) }) == stage, "\(name)")
        }
        var closed = pr()
        closed.state = .closed
        #expect(FlowStage.of(closed, session: nil) == .closed)
    }

    /// A PR is in the flow while a session works on it; a ticket's session is Working until it opens its PR.
    /// A busy session that only touched a PR, as one long session touches many, does not make it Fixing: only a session
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
