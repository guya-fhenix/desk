import DeskCore
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

    @Test func parsesLeftRightCount() {
        let counts = GitParsing.leftRightCount("3\t5\n")
        #expect(counts?.behind == 3)
        #expect(counts?.ahead == 5)
        #expect(GitParsing.leftRightCount("garbage") == nil)
    }
}
