import DeskCore
import Foundation
import Testing

@Suite struct LinkerTests {
    let matcher = TicketKeyMatcher(projectKeys: ["PRO"])

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

    @Test func stackedKeepsEachStackContiguousBeneathItsRoot() {
        let root = Fixtures.pr(number: 1, head: "a", base: "master", updated: Fixtures.t0 + 30)
        let middle = Fixtures.pr(number: 2, head: "b", base: "a")
        let top = Fixtures.pr(number: 3, head: "c", base: "b")
        let fresh = Fixtures.pr(number: 4, head: "d", base: "master", updated: Fixtures.t0 + 60)
        let theirs = Fixtures.pr(number: 5, head: "z", base: "master", author: "someone-else")
        let onTheirs = Fixtures.pr(number: 6, head: "e", base: "z")
        let all = [root, middle, top, fresh, theirs, onTheirs]
        let order = [KeyPathComparator(\StackedPullRequest.pullRequest.repoName), KeyPathComparator(\StackedPullRequest.pullRequest.updatedAt, order: .reverse)]
        let rows = Linker.stacked([top, onTheirs, root, fresh, middle], parents: Linker.stackParents(all), order: order)
        #expect(rows.map(\.pullRequest.number) == [4, 1, 2, 3, 6])
        #expect(rows.map(\.depth) == [0, 0, 1, 2, 0])
        #expect(rows.map(\.stackSize) == [1, 3, 2, 1, 1])
    }

    @Test func rebaseReasonPrefersMergeStateThenMissingBase() {
        let conflicted = Fixtures.pr(number: 1, head: "a", base: "master", merge: .dirty)
        #expect(Linker.rebaseReason(conflicted, openHeads: [], defaultBranch: "master") == .conflicts)
        let orphan = Fixtures.pr(number: 2, head: "b", base: "merged-branch", merge: .blocked)
        #expect(Linker.rebaseReason(orphan, openHeads: ["a"], defaultBranch: "master") == .baseMerged)
        let stacked = Fixtures.pr(number: 3, head: "c", base: "a", merge: .blocked)
        #expect(Linker.rebaseReason(stacked, openHeads: ["a"], defaultBranch: "master") == nil)
    }

    @Test func repoForPullRequestPrefersTheRemoteThenTheDirectoryName() {
        let pr = Fixtures.pr(number: 1, head: "a")
        let sameName = Fixtures.repo(name: "cofhe", remote: "git@github.com:Someone/cofhe.git")
        let fork = Fixtures.repo(name: "cofhe-work", remote: "git@github-guya-fhenix:FhenixProtocol/cofhe.git")
        #expect(Linker.repo(for: pr, in: [sameName, fork])?.name == "cofhe-work")
        #expect(Linker.repo(for: pr, in: [sameName])?.name == "cofhe")
        #expect(Linker.repo(for: pr, in: [Fixtures.repo(name: "teecryptor", remote: "git@github.com:FhenixProtocol/teecryptor.git")]) == nil)
    }
}
