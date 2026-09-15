import DeskCore
import Foundation
import Testing

/// Real git in a temporary directory: a bare "remote", an author clone that pushes to it, and a reader
/// clone that the review would consult.
@Suite struct ReviewWorktreesTests {
    let git = "/usr/bin/git"

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

        let worktrees = ReviewWorktrees(gitPath: git)
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

    @Test func otherReposFetchTheDefaultBranchAndSkipClonesWithoutOne() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("desk-worktrees-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let (remote, author, reader, loner) = (base + "/remote.git", base + "/author", base + "/reader", base + "/loner")

        try await run(["init", "--quiet", "--bare", "--initial-branch=master", remote], cwd: base)
        try await run(["init", "--quiet", "--initial-branch=master", author], cwd: base)
        try await run(["commit", "--quiet", "--allow-empty", "-m", "first"], cwd: author)
        try await run(["remote", "add", "origin", remote], cwd: author)
        try await run(["push", "--quiet", "-u", "origin", "master"], cwd: author)
        // A clone records origin/HEAD, which is how the default branch is found.
        try await run(["clone", "--quiet", remote, reader], cwd: base)
        try await run(["commit", "--quiet", "--allow-empty", "-m", "second"], cwd: author)
        try await run(["push", "--quiet", "origin", "master"], cwd: author)
        let newest = try await run(["rev-parse", "HEAD"], cwd: author)
        // No remote at all: nothing a review could read.
        try await run(["init", "--quiet", "--initial-branch=main", loner], cwd: base)

        let worktrees = ReviewWorktrees(gitPath: git)
        let repos = [RepoRef(name: "reader", root: reader, remote: remote), RepoRef(name: "loner", root: loner, remote: "")]
        let others = await worktrees.otherRepos(repos)
        #expect(others == [OtherRepo(name: "reader", root: reader, ref: "origin/master", fetched: true)])
        let fetched = try await run(["rev-parse", "origin/master"], cwd: reader)
        #expect(fetched == newest)
        // The checkout stayed behind: the review reads the ref, not the working tree.
        let checkedOut = try await run(["rev-parse", "HEAD"], cwd: reader)
        #expect(checkedOut != newest)

        // With the remote gone the fetch fails, and the ref is still offered as it was.
        try FileManager.default.removeItem(atPath: remote)
        let stale = await worktrees.otherRepos(repos)
        #expect(stale == [OtherRepo(name: "reader", root: reader, ref: "origin/master", fetched: false)])
    }
}
