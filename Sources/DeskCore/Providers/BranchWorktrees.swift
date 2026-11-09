import Foundation

public enum BranchWorktreeError: Error, CustomStringConvertible, Sendable {
    case notAWorktree(String)

    public var description: String {
        switch self {
        case .notAWorktree(let path): return "\((path as NSString).abbreviatingWithTildeInPath) exists but is not a worktree of this repo"
        }
    }
}

/// The only place the app changes git state: the branch worktree a background session works in. Never `--force`.
/// Operations on one repo run one at a time because two worktree commands in the same `.git` race on its lock files,
/// and an actor alone does not serialise across its own `await`s.
public actor BranchWorktrees {
    private let gitPath: String
    private var chains: [String: Task<Void, Never>] = [:]

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    /// A worktree with the PR's own branch checked out, for a session that will commit to it. It goes where
    /// `claude -w` puts the worktrees it makes itself, under the repo's `.claude/worktrees`. An existing one is reused
    /// as it is: it is the user's, not ours.
    public func prepareBranch(pr: PullRequest, repoRoot: String) async throws -> String {
        try await serialized(repoRoot) {
            let path = Self.branchWorktree(branch: pr.headRef, repoRoot: repoRoot)
            // A record for a directory that is gone goes on claiming its branch, and `worktree add`
            // refuses to check a branch out twice. Pruning first is what lets the branch be used again;
            // it only ever drops records whose directory has already vanished.
            _ = try? await self.git(["worktree", "prune"], cwd: repoRoot)
            if try await self.isWorktree(path, of: repoRoot) { return path }
            if FileManager.default.fileExists(atPath: path) { throw BranchWorktreeError.notAWorktree(path) }
            try? await self.excludeWorktrees(repoRoot: repoRoot)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            _ = try? await self.git(["fetch", "--no-tags", "origin", pr.headRef], cwd: repoRoot)
            if (try? await self.git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(pr.headRef)"], cwd: repoRoot)) != nil {
                // An existing local branch is checked out as it stands; a new one tracks origin so a push works.
                let local = (try? await self.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(pr.headRef)"], cwd: repoRoot)) != nil
                let arguments = local
                    ? ["worktree", "add", path, pr.headRef]
                    : ["worktree", "add", "--track", "-b", pr.headRef, path, "origin/\(pr.headRef)"]
                try await self.git(arguments, cwd: repoRoot)
            } else {
                // A fork's branch is in no remote of this clone; the PR head always is, and nothing can
                // be pushed back to it from here, so it is checked out detached.
                try await self.git(["fetch", "--no-tags", "origin", "pull/\(pr.number)/head"], cwd: repoRoot)
                try await self.git(["worktree", "add", "--detach", path, "FETCH_HEAD"], cwd: repoRoot)
            }
            return path
        }
    }

    /// Branch names carry slashes; the directory name flattens them the way `claude -w` does.
    public nonisolated static func branchWorktree(branch: String, repoRoot: String) -> String {
        let name = branch.replacingOccurrences(of: "/", with: "-")
        return (repoRoot as NSString).appendingPathComponent(".claude/worktrees/\(name)")
    }

    /// Untracked, the worktrees would make the main checkout count as dirty, and a session's `git add -A` there would
    /// stage them. The clone's own `info/exclude` keeps them out without changing anything the repo tracks.
    private nonisolated func excludeWorktrees(repoRoot: String) async throws {
        let pattern = "/.claude/worktrees/"
        let commonDir = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: repoRoot)
        let exclude = (commonDir as NSString).appendingPathComponent("info/exclude")
        let text = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        guard !text.split(separator: "\n").contains(Substring(pattern)) else { return }
        try FileManager.default.createDirectory(atPath: (exclude as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        try (text + separator + pattern + "\n").write(toFile: exclude, atomically: true, encoding: .utf8)
    }

    private nonisolated func isWorktree(_ path: String, of repoRoot: String) async throws -> Bool {
        let porcelain = try await git(["worktree", "list", "--porcelain"], cwd: repoRoot)
        let wanted = Self.canonical(path)
        return GitParsing.worktreeEntries(porcelain).contains { Self.canonical($0.path) == wanted }
    }

    @discardableResult
    private nonisolated func git(_ arguments: [String], cwd: String) async throws -> String {
        try await Shell.output(gitPath, arguments, cwd: cwd, environment: GitProvider.environment, timeout: 300).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func serialized<T: Sendable>(_ key: String, _ body: @Sendable @escaping () async throws -> T) async throws -> T {
        let previous = chains[key]
        let task = Task<T, any Error> {
            await previous?.value
            return try await body()
        }
        chains[key] = Task { _ = try? await task.value }
        return try await task.value
    }
}
