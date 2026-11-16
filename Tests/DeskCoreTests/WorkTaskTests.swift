import DeskCore
import Foundation
import Testing

@Suite struct WorkTaskTests {
    private let matcher = TicketKeyMatcher(projectKeys: ["PRO"])

    private func keys(_ prs: [PullRequest]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: prs.map { ($0.url, TicketSync.keys(for: $0, matcher: matcher)) })
    }

    private func session(
        _ id: String, name: String, state: String = "done", cwd: String = "/elsewhere", updated: Date = Fixtures.t0,
        ticket: String? = nil, linked: Set<String> = [], role: SessionRole = .other, request: String? = nil
    ) -> ClaudeJob {
        ClaudeJob(
            id: id, name: name, state: state, cwd: cwd, prKeys: linked, updatedAt: updated, createdAt: Fixtures.t0,
            ticketKey: ticket, linked: linked, role: role, request: request
        )
    }

    private func tasks(
        _ mine: [PullRequest], others: [PullRequest] = [], sessions: [ClaudeJob] = [], tracked: [String] = [],
        keep: Set<String> = [], now: Date = Fixtures.t0
    ) -> [WorkTask] {
        Linker.tasks(
            mine: mine, allOpen: mine + others, merged: [], ticketKeys: keys(mine), tickets: [Fixtures.ticket("PRO-650")],
            sessions: sessions, trackedRoots: tracked, keep: keep, now: now
        )
    }

    /// PRO-650 as it stands: one PR on master, one on a teammate's branch that has no PR. One task, named after the
    /// ticket, and the branch shows as what it depends on rather than as a rebase.
    @Test func aTicketsPullRequestsAcrossBasesAreOneTask() {
        let spike = Fixtures.pr(number: 116, repo: "FhenixProtocol/powershot", title: "PRO-650: spike", head: "worktree-pro-650-signer-spike", draft: true)
        let signer = Fixtures.pr(
            number: 117, repo: "FhenixProtocol/powershot", title: "PRO-650: FROST signer", head: "guy/pro-650-frost-signer",
            base: "ohad/back_to_super_majority"
        )
        let all = tasks([spike, signer])
        #expect(all.count == 1)
        #expect(all[0].id == "PRO-650")
        #expect(all[0].origin == .ticket)
        #expect(all[0].title == "Summary PRO-650")
        #expect(Set(all[0].pullRequests.map(\.number)) == [116, 117])
        #expect(all[0].dependsOn == ["fhenixprotocol/powershot@ohad/back_to_super_majority"])
        #expect(all[0].stage == .draft)
    }

    /// A stack that names no ticket is one task, named after its root, base first.
    @Test func aStackWithNoTicketIsOneTaskNamedAfterItsRoot() {
        let root = Fixtures.pr(number: 28, repo: "guya-fhenix/desk", title: "Keep the terminal", head: "terminal-collapse-fix", base: "master")
        let middle = Fixtures.pr(number: 29, repo: "guya-fhenix/desk", title: "Files tab", head: "pr-files-tab", base: "terminal-collapse-fix")
        let top = Fixtures.pr(number: 30, repo: "guya-fhenix/desk", title: "Your move", head: "up-next-threads", base: "pr-files-tab")
        let all = tasks([top, root, middle])
        #expect(all.map(\.id) == ["guya-fhenix/desk#28"])
        #expect(all[0].origin == .pullRequest)
        #expect(all[0].title == "Keep the terminal")
        #expect(all[0].pullRequests.map(\.number) == [28, 29, 30])
        #expect(all[0].dependsOn.isEmpty)
    }

    /// A PR stacked on someone else's open PR depends on that PR.
    @Test func aPullRequestOnSomeoneElsesDependsOnIt() {
        let theirs = Fixtures.pr(number: 119, repo: "FhenixProtocol/powershot", head: "roee/pro-646-1", author: "roeezolantz")
        let mine = Fixtures.pr(number: 200, repo: "FhenixProtocol/powershot", title: "On top", head: "guy/on-top", base: "roee/pro-646-1")
        #expect(tasks([mine], others: [theirs])[0].dependsOn == ["fhenixprotocol/powershot#119"])
    }

    /// A worker started on what the person asked, with no ticket and no PR yet, is a task of its own, titled by the ask.
    @Test func aWorkerWithNoTicketIsATask() {
        let worker = session(
            "aaaa1111", name: "testnet-decrypt-errors", state: "working", role: .worker,
            request: "find why decrypt requests fail on testnet"
        )
        let all = tasks([], sessions: [worker])
        #expect(all.map(\.id) == ["testnet-decrypt-errors"])
        #expect(all[0].origin == .session)
        #expect(all[0].title == "find why decrypt requests fail on testnet")
        #expect(all[0].worker == worker)
        #expect(all[0].stage == .working)
        #expect(all[0].waitingOn(asked: []) == .worker)
    }

    /// Once that worker opens a PR with no ticket key, the PR joins its task instead of starting one.
    @Test func aPullRequestAWorkerCarriesJoinsItsTask() {
        let fix = Fixtures.pr(number: 1190, title: "Redial on refused subscribe", head: "fix/redial")
        let worker = session(
            "aaaa1111", name: "testnet-decrypt-errors", linked: ["fhenixprotocol/cofhe#1190"], role: .worker,
            request: "find why decrypt requests fail on testnet"
        )
        let all = tasks([fix], sessions: [worker])
        #expect(all.map(\.id) == ["testnet-decrypt-errors"])
        #expect(all[0].pullRequests.map(\.number) == [1190])
    }

    /// The master and review sessions are never tasks. Another session is one only when it runs in a tracked clone, and
    /// drops off once it has sat done for days, unless the master still asks something about it.
    @Test func whichOtherSessionsAreTasks() {
        let master = session("m0000000", name: "master", state: "working", role: .master)
        let review = session("r0000000", name: "review-pro-646", state: "working", cwd: "/r/powershot", role: .review)
        let elsewhere = session("e0000000", name: "Openclaw on Hetzner", cwd: "/r/openclaw")
        let tracked = session("t0000000", name: "Powershot PR stack", cwd: "/r/powershot/sub")
        let stale = session("s0000000", name: "old-spike", cwd: "/r/powershot", updated: Fixtures.hours(-100))
        let ids = { (keep: Set<String>) in
            Set(tasks([], sessions: [master, review, elsewhere, tracked, stale], tracked: ["/r/powershot"], keep: keep).map(\.id))
        }
        #expect(ids([]) == ["Powershot PR stack"])
        #expect(ids(["old-spike"]) == ["Powershot PR stack", "old-spike"])
    }

    /// A session started on a ticket joins that ticket's task, with or without a PR.
    @Test func aTicketsSessionJoinsItsTask() {
        let worker = session("aaaa1111", name: "PRO-650", state: "working", ticket: "PRO-650", role: .worker)
        let all = tasks([], sessions: [worker])
        #expect(all.map(\.id) == ["PRO-650"])
        #expect(all[0].origin == .ticket)
        #expect(all[0].worker == worker)
    }

    @Test func whoATaskWaitsOn() {
        let ready = Fixtures.pr(number: 1, title: "PRO-650: a", head: "a")
        var task = WorkTask(id: "PRO-650", origin: .ticket, title: "t", pullRequests: [ready])
        #expect(task.waitingOn(asked: []) == .reviewers)
        #expect(task.waitingOn(asked: ["PRO-650"]) == .you)
        task.sessions = [session("w", name: "PRO-650", state: "working")]
        #expect(task.waitingOn(asked: []) == .worker)
        task.sessions = [session("w", name: "PRO-650", state: "blocked")]
        #expect(task.waitingOn(asked: []) == .you)
        #expect(WorkTask(id: "x", origin: .session, title: "x").waitingOn(asked: []) == .nobody)
    }
}
