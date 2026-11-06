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

    @Test func prepareBranchChecksOutThePullRequestBranchAndFallsBackToItsHead() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("desk-branch-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let (remote, author, mine) = (base + "/remote.git", base + "/author", base + "/mine")

        try await run(["init", "--quiet", "--bare", "--initial-branch=master", remote], cwd: base)
        try await run(["init", "--quiet", "--initial-branch=master", author], cwd: base)
        try await run(["commit", "--quiet", "--allow-empty", "-m", "first"], cwd: author)
        try await run(["remote", "add", "origin", remote], cwd: author)
        try await run(["push", "--quiet", "-u", "origin", "master"], cwd: author)
        try await run(["clone", "--quiet", remote, mine], cwd: base)
        // The PR's branch, pushed after the clone: only a fetch can see it.
        try await run(["checkout", "--quiet", "-b", "guy/pro-1"], cwd: author)
        try await run(["commit", "--quiet", "--allow-empty", "-m", "work"], cwd: author)
        try await run(["push", "--quiet", "origin", "guy/pro-1"], cwd: author)
        let head = try await run(["rev-parse", "HEAD"], cwd: author)

        let worktrees = BranchWorktrees(gitPath: git)
        let pr = Fixtures.pr(number: 7, head: "guy/pro-1")
        let path = try await worktrees.prepareBranch(pr: pr, repoRoot: mine)
        #expect(path == mine + "/.claude/worktrees/guy-pro-1")
        #expect(try await run(["rev-parse", "HEAD"], cwd: path) == head)
        // On the branch, not detached, and pushing back to the PR needs no arguments.
        #expect(try await run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path) == "guy/pro-1")
        #expect(try await run(["rev-parse", "--abbrev-ref", "@{upstream}"], cwd: path) == "origin/guy/pro-1")
        // Asked again, the same worktree comes back rather than a second one.
        #expect(try await worktrees.prepareBranch(pr: pr, repoRoot: mine) == path)

        // A fork's branch is in no remote here, so the PR head is checked out detached.
        try await run(["push", "--quiet", "origin", "HEAD:refs/pull/8/head"], cwd: author)
        let fork = Fixtures.pr(number: 8, head: "someone/fork-branch")
        let forkPath = try await worktrees.prepareBranch(pr: fork, repoRoot: mine)
        #expect(forkPath == mine + "/.claude/worktrees/someone-fork-branch")
        #expect(try await run(["rev-parse", "HEAD"], cwd: forkPath) == head)
        #expect(try await run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: forkPath) == "HEAD")
    }
}
