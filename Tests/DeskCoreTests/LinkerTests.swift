import DeskCore
import Foundation
import Testing

@Suite struct LinkerTests {
    let matcher = TicketKeyMatcher(projectKeys: ["PRO"])

    @Test func joinsTicketPullRequestWorktreeAndSessionsByKey() {
        let pr = Fixtures.pr(number: 1, head: "feat/pro-492-engine-alerts")
        let worktree = Fixtures.worktree(path: "/r/cofhe/.claude/worktrees/pro-492-alerts", branch: "feat/pro-492-engine-alerts")
        let session = Fixtures.session(id: "s1", cwd: "/r/cofhe", branches: ["master", "feat/pro-492-engine-alerts"])
        let live = Fixtures.live(id: "s1", cwd: "/r/cofhe/.claude/worktrees/pro-492-alerts", status: .busy)
        let items = Linker.workItems(LinkerInput(
            pullRequests: [pr], worktrees: [worktree], sessions: [session], liveSessions: [live],
            tickets: [Fixtures.ticket("PRO-492")], matcher: matcher
        ))
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.ticketKey == "PRO-492")
        #expect(item.pullRequests.map(\.number) == [1])
        #expect(item.worktrees.map(\.path) == [worktree.path])
        #expect(item.sessions.map(\.sessionId) == ["s1"])
        #expect(item.liveSessions.map(\.sessionId) == ["s1"])
    }

    @Test func pullRequestWithoutKeyOwnsAnItemAndLinksSessionsByPrLink() {
        let pr = Fixtures.pr(number: 7, head: "fix/resilient-ws")
        let link = PullRequestRef(repo: "FhenixProtocol/cofhe", number: 7, url: pr.url)
        let session = Fixtures.session(id: "s2", cwd: "/r/cofhe", branches: ["master"], prLinks: [link])
        let items = Linker.workItems(LinkerInput(pullRequests: [pr], worktrees: [], sessions: [session], liveSessions: [], tickets: [], matcher: matcher))
        #expect(items.count == 1)
        #expect(items[0].id == pr.url)
        #expect(items[0].ticketKey == nil)
        #expect(items[0].sessions.map(\.sessionId) == ["s2"])
    }

    @Test func branchOnlyWorktreeBecomesItsOwnItem() {
        let worktree = Fixtures.worktree(path: "/r/cofhe/.claude/worktrees/spike", branch: "spike/idea")
        let main = Fixtures.worktree(path: "/r/cofhe", branch: "master", isMain: true)
        let items = Linker.workItems(LinkerInput(pullRequests: [], worktrees: [main, worktree], sessions: [], liveSessions: [], tickets: [], matcher: matcher))
        #expect(items.map(\.id) == [worktree.path])
    }

    @Test func sessionsOnlyAttachToExistingItems() {
        let session = Fixtures.session(id: "old", cwd: "/r/cofhe", branches: ["feat/pro-1-old"])
        let items = Linker.workItems(LinkerInput(pullRequests: [], worktrees: [], sessions: [session], liveSessions: [], tickets: [], matcher: matcher))
        #expect(items.isEmpty)
    }

    @Test func stackParentsFollowBaseBranches() {
        let root = Fixtures.pr(number: 1, head: "a", base: "master")
        let middle = Fixtures.pr(number: 2, head: "b", base: "a")
        let top = Fixtures.pr(number: 3, head: "c", base: "b")
        let parents = Linker.stackParents([root, middle, top])
        #expect(parents[top.url] == middle.url)
        #expect(parents[middle.url] == root.url)
        #expect(parents[root.url] == nil)
        #expect(Linker.stackDepth(top.url, parents: parents) == 2)
    }

    @Test func rebaseReasonPrefersMergeStateThenMissingBase() {
        let conflicted = Fixtures.pr(number: 1, head: "a", base: "master", merge: .dirty)
        #expect(Linker.rebaseReason(conflicted, openHeads: [], defaultBranch: "master") == .conflicts)
        let orphan = Fixtures.pr(number: 2, head: "b", base: "merged-branch", merge: .blocked)
        #expect(Linker.rebaseReason(orphan, openHeads: ["a"], defaultBranch: "master") == .baseMerged)
        let stacked = Fixtures.pr(number: 3, head: "c", base: "a", merge: .blocked)
        #expect(Linker.rebaseReason(stacked, openHeads: ["a"], defaultBranch: "master") == nil)
    }

    @Test func repoNameUsesLongestContainingWorktree() {
        let main = Fixtures.worktree(path: "/r/cofhe", branch: "master", isMain: true)
        let nested = Fixtures.worktree(repo: "cofhe", path: "/r/cofhe/.claude/worktrees/x", branch: "x")
        let other = Fixtures.worktree(repo: "teecryptor", path: "/r/teecryptor", branch: "main", isMain: true)
        #expect(Linker.repoName(forPath: "/r/cofhe/.claude/worktrees/x/src", worktrees: [main, nested, other]) == "cofhe")
        #expect(Linker.repoName(forPath: "/r/teecryptor", worktrees: [main, nested, other]) == "teecryptor")
        #expect(Linker.repoName(forPath: "/elsewhere", worktrees: [main]) == nil)
    }
}
