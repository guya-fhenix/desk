import DeskCore
import Foundation
import Testing

@Suite struct GitParsingTests {
    @Test func parsesWorktreeListPorcelain() {
        let text = """
        worktree /Users/me/Repos/cofhe
        HEAD 9870aacd0000000000000000000000000000abcd
        branch refs/heads/master

        worktree /Users/me/Repos/cofhe/.claude/worktrees/oz
        HEAD 8d6787f60000000000000000000000000000abcd
        branch refs/heads/fix/oz-relayer

        worktree /tmp/scratch/pr36
        HEAD 8324f9e00000000000000000000000000000abcd
        detached
        prunable gitdir file points to non-existent location

        """
        let entries = GitParsing.worktreeEntries(text)
        #expect(entries.count == 3)
        #expect(entries[0].branch == "master")
        #expect(entries[1].path == "/Users/me/Repos/cofhe/.claude/worktrees/oz")
        #expect(entries[1].branch == "fix/oz-relayer")
        #expect(entries[2].branch == nil)
        #expect(entries[2].isPrunable)
    }

    @Test func readsDirtyFilesAndUpstreamCountsFromStatusV2() {
        let tracked = """
        # branch.oid 9870aacd0000000000000000000000000000abcd
        # branch.head feat/x
        # branch.upstream origin/feat/x
        # branch.ab +3 -1
        1 .M N... 100644 100644 100644 abc abc src/a.rs
        2 R. N... 100644 100644 100644 abc abc R100 src/new.rs	src/old.rs
        ? notes.txt
        """
        let status = GitParsing.branchStatus(tracked)
        #expect(status.dirtyFiles == 3)
        #expect(status.upstream?.ahead == 3 && status.upstream?.behind == 1)
        // No upstream, or one that is gone, has no ab line; a clean tree has no entries.
        let gone = GitParsing.branchStatus("# branch.oid abc\n# branch.head feat/y\n# branch.upstream origin/feat/y")
        #expect(gone.dirtyFiles == 0 && gone.upstream == nil)
    }

    @Test func readsBranchTipsFromForEachRef() {
        let tips = GitParsing.branchTips("refs/heads/master\t1794176687\t0 2\nrefs/heads/feat/x\t1794205070\t26 0\nbroken line")
        #expect(tips.count == 2)
        #expect(tips["master"] == BranchTip(committedAt: Date(timeIntervalSince1970: 1_794_176_687), ahead: 0, behind: 2))
        #expect(tips["feat/x"]?.ahead == 26 && tips["feat/x"]?.behind == 0)
        // Asked without ahead-behind: the dates alone.
        #expect(GitParsing.branchTips("refs/heads/main\t1794176687") == ["main": BranchTip(committedAt: Date(timeIntervalSince1970: 1_794_176_687))])
    }

    @Test func parsesLeftRightCount() {
        let counts = GitParsing.leftRightCount("3\t5\n")
        #expect(counts?.behind == 3)
        #expect(counts?.ahead == 5)
        #expect(GitParsing.leftRightCount("garbage") == nil)
    }
}

@Suite struct RepoSlugTests {
    @Test func readsOwnerAndNameFromAnyRemoteForm() {
        #expect(GitParsing.repoSlug(fromRemote: "git@github-guya-fhenix:FhenixProtocol/cofhe.git\n") == "fhenixprotocol/cofhe")
        #expect(GitParsing.repoSlug(fromRemote: "git@github.com:FhenixProtocol/cofhe") == "fhenixprotocol/cofhe")
        #expect(GitParsing.repoSlug(fromRemote: "ssh://git@github.com/FhenixProtocol/cofhe.git") == "fhenixprotocol/cofhe")
        #expect(GitParsing.repoSlug(fromRemote: "https://github.com/FhenixProtocol/cofhe.git") == "fhenixprotocol/cofhe")
        #expect(GitParsing.repoSlug(fromRemote: "https://user@github.com/FhenixProtocol/cofhe/") == "fhenixprotocol/cofhe")
        #expect(GitParsing.repoSlug(fromRemote: "nope") == nil)
    }
}
