import DeskCore
import Foundation
import Testing

/// Real git in a temporary directory: a bare "remote", an author clone that pushes to it, and your clone.
@Suite struct BranchWorktreesTests {
    let git = "/usr/bin/git"

    @discardableResult
    func run(_ arguments: [String], cwd: String) async throws -> String {
        let identity = ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"]
        return try await Shell.output(git, identity + arguments, cwd: cwd).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func temporaryBase() throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("desk-branch-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }

    /// The remote with one commit on master, and the author's clone and yours of it, under `base`.
    func clones(in base: String) async throws -> (author: String, mine: String) {
        let (remote, author, mine) = (base + "/remote.git", base + "/author", base + "/mine")
        try await run(["init", "--quiet", "--bare", "--initial-branch=master", remote], cwd: base)
        try await run(["init", "--quiet", "--initial-branch=master", author], cwd: base)
        try await run(["commit", "--quiet", "--allow-empty", "-m", "first"], cwd: author)
        try await run(["remote", "add", "origin", remote], cwd: author)
        try await run(["push", "--quiet", "-u", "origin", "master"], cwd: author)
        try await run(["clone", "--quiet", remote, mine], cwd: base)
        return (author, mine)
    }

    @Test func prepareBranchChecksOutThePullRequestBranchAndFallsBackToItsHead() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let (author, mine) = try await clones(in: base)
        // The PR's branch, pushed after the clone: only a fetch can see it.
        try await run(["checkout", "--quiet", "-b", "guy/pro-1"], cwd: author)
        try await run(["commit", "--quiet", "--allow-empty", "-m", "work"], cwd: author)
        try await run(["push", "--quiet", "origin", "guy/pro-1"], cwd: author)
        let head = try await run(["rev-parse", "HEAD"], cwd: author)

        let worktrees = BranchWorktrees(gitPath: git)
        let pr = Fixtures.pr(number: 7, head: "guy/pro-1")
        let path = try await worktrees.prepareBranch(pr: pr, repoRoot: mine)
        #expect(path == mine + "/.claude/worktrees/guy-pro-1")
        // Excluded, the worktree leaves the main checkout clean.
        #expect(try await run(["status", "--porcelain"], cwd: mine) == "")
        #expect(try await run(["rev-parse", "HEAD"], cwd: path) == head)
        // On the branch, not detached, and pushing back to the PR needs no arguments.
        #expect(try await run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path) == "guy/pro-1")
        #expect(try await run(["rev-parse", "--abbrev-ref", "@{upstream}"], cwd: path) == "origin/guy/pro-1")
        // Asked again, the same worktree comes back rather than a second one.
        #expect(try await worktrees.prepareBranch(pr: pr, repoRoot: mine) == path)
        // But not once another branch is checked out in it.
        try await run(["switch", "--quiet", "-c", "other"], cwd: path)
        await #expect(throws: BranchWorktreeError.self) { try await worktrees.prepareBranch(pr: pr, repoRoot: mine) }

        // A fork's branch is in no remote here, so the PR head is checked out detached.
        try await run(["push", "--quiet", "origin", "HEAD:refs/pull/8/head"], cwd: author)
        var fork = Fixtures.pr(number: 8, head: "someone/fork-branch")
        fork.isCrossRepository = true
        let forkPath = try await worktrees.prepareBranch(pr: fork, repoRoot: mine)
        #expect(forkPath == mine + "/.claude/worktrees/someone-fork-branch")
        #expect(try await run(["rev-parse", "HEAD"], cwd: forkPath) == head)
        #expect(try await run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: forkPath) == "HEAD")
    }

    /// Fork PRs whose head is `master` are common: origin's branch of the same name is not their code.
    @Test func prepareBranchChecksOutAForksHeadEvenWhenOriginHasItsBranchName() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let (author, mine) = try await clones(in: base)
        try await run(["checkout", "--quiet", "-b", "fork-work"], cwd: author)
        try await run(["commit", "--quiet", "--allow-empty", "-m", "fork work"], cwd: author)
        try await run(["push", "--quiet", "origin", "HEAD:refs/pull/9/head"], cwd: author)
        let head = try await run(["rev-parse", "HEAD"], cwd: author)

        let worktrees = BranchWorktrees(gitPath: git)
        var fork = Fixtures.pr(number: 9, head: "master")
        fork.isCrossRepository = true
        let path = try await worktrees.prepareBranch(pr: fork, repoRoot: mine)
        #expect(path == mine + "/.claude/worktrees/master")
        #expect(try await run(["rev-parse", "HEAD"], cwd: path) == head)
        #expect(try await run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path) == "HEAD")
        // Reused while it stays detached; a branch checked out there is someone's work, not the fork's head.
        #expect(try await worktrees.prepareBranch(pr: fork, repoRoot: mine) == path)
        try await run(["switch", "--quiet", "-c", "local-work"], cwd: path)
        await #expect(throws: BranchWorktreeError.self) { try await worktrees.prepareBranch(pr: fork, repoRoot: mine) }
    }
}
