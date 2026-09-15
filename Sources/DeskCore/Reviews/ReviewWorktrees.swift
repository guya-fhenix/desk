import Foundation

public enum ReviewWorktreeError: Error, CustomStringConvertible, Sendable {
    case dirty(String)
    case notAWorktree(String)

    public var description: String {
        switch self {
        case .dirty(let path): return "worktree has local changes: \((path as NSString).abbreviatingWithTildeInPath)"
        case .notAWorktree(let path): return "\((path as NSString).abbreviatingWithTildeInPath) exists but is not a worktree of this repo"
        }
    }
}

/// The only place the app changes git state: review worktrees, detached at a PR head, under the review
/// root, the branch worktree a background session works in, and fetches of the default branch in the
/// other clones a review reads. Never `--force`: a dirty worktree is left alone and reported. Operations on one repo run one at a time because two fetches or
/// worktree commands in the same `.git` race on its lock files, and an actor alone does not serialise
/// across its own `await`s.
public actor ReviewWorktrees {
    private let gitPath: String
    private var chains: [String: Task<Void, Never>] = [:]

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    /// Makes `path` a worktree of `repoRoot` checked out at the PR head, creating it or moving an
    /// existing clean one. Returns the sha actually checked out.
    public func prepare(pr: PullRequest, repoRoot: String, path: String) async throws -> String {
        try await serialized(repoRoot) {
            // Base first, head last: FETCH_HEAD then names the PR head for the fallback below.
            _ = try? await self.git(["fetch", "--no-tags", "origin", pr.baseRef], cwd: repoRoot)
            try await self.git(["fetch", "--no-tags", "origin", "pull/\(pr.number)/head"], cwd: repoRoot)
            if try await self.isWorktree(path, of: repoRoot) {
                guard try await self.isClean(path) else { throw ReviewWorktreeError.dirty(path) }
                try await self.checkout(pr.headSha, in: path)
            } else if FileManager.default.fileExists(atPath: path) {
                throw ReviewWorktreeError.notAWorktree(path)
            } else {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try await self.add(pr.headSha, at: path, repoRoot: repoRoot)
            }
            return try await self.git(["rev-parse", "HEAD"], cwd: path)
        }
    }

    /// A worktree with the PR's own branch checked out, for a session that will commit to it — not a
    /// review's detached head. It goes where `claude -w` puts the worktrees it makes itself, under the
    /// repo's `.claude/worktrees`. An existing one is reused as it is: it is the user's, not ours.
    public func prepareBranch(pr: PullRequest, repoRoot: String) async throws -> String {
        try await serialized(repoRoot) {
            let path = Self.branchWorktree(branch: pr.headRef, repoRoot: repoRoot)
            if try await self.isWorktree(path, of: repoRoot) { return path }
            if FileManager.default.fileExists(atPath: path) { throw ReviewWorktreeError.notAWorktree(path) }
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

    /// The other clones a review may read, each with its remote default branch fetched so the ref is
    /// current. Fetches run concurrently across repos. A failed fetch still lists the ref as it was; a
    /// clone with no `origin/<default>` at all is left out.
    public func otherRepos(_ repos: [RepoRef]) async -> [OtherRepo] {
        var others: [OtherRepo] = []
        await withTaskGroup(of: OtherRepo?.self) { group in
            for repo in repos {
                group.addTask { await self.fetchDefaultBranch(of: repo) }
            }
            for await other in group {
                if let other { others.append(other) }
            }
        }
        return others.sorted { $0.name < $1.name }
    }

    private func fetchDefaultBranch(of repo: RepoRef) async -> OtherRepo? {
        try? await serialized(repo.root) {
            let branch = await GitProvider.defaultBranch(root: repo.root, gitPath: self.gitPath)
            // A minute, not the worktree's five: one slow remote must not hold up the whole launch.
            let fetched = (try? await self.git(["fetch", "--no-tags", "origin", branch], cwd: repo.root, timeout: 60)) != nil
            guard (try? await self.git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], cwd: repo.root)) != nil else { return nil }
            return OtherRepo(name: repo.name, root: repo.root, ref: "origin/\(branch)", fetched: fetched)
        }
    }

    /// Removes the worktree when it is clean; a stray directory that is not a worktree is left alone.
    public func remove(repoRoot: String, path: String) async throws {
        try await serialized(repoRoot) {
            if try await self.isWorktree(path, of: repoRoot) {
                guard try await self.isClean(path) else { throw ReviewWorktreeError.dirty(path) }
                try await self.git(["worktree", "remove", path], cwd: repoRoot)
            }
            _ = try? await self.git(["worktree", "prune"], cwd: repoRoot)
        }
    }

    public nonisolated func isClean(_ path: String) async throws -> Bool {
        try await git(["status", "--porcelain"], cwd: path).isEmpty
    }

    private nonisolated func isWorktree(_ path: String, of repoRoot: String) async throws -> Bool {
        let porcelain = try await git(["worktree", "list", "--porcelain"], cwd: repoRoot)
        let wanted = Self.canonical(path)
        return GitParsing.worktreeEntries(porcelain).contains { Self.canonical($0.path) == wanted }
    }

    /// Files at a commit, read straight from the object database so the checkout can sit at another sha
    /// and a review can be running in it. A path the commit does not have is simply absent, which is how
    /// a comment on a deleted file ends up outdated. The timeout is short on purpose: a wedged fetch on
    /// this repo should cost one poll's re-anchoring, not the refresh loop.
    public func blobs(sha: String, paths: [String], repoRoot: String) async -> [String: [String]] {
        guard !sha.isEmpty, !paths.isEmpty else { return [:] }
        return await (try? serialized(repoRoot) {
            var contents: [String: [String]] = [:]
            for path in paths {
                // Not `git(…)`: that trims, and trimming a file whose first line is blank or indented
                // shifts every line number after it — which is the one thing anchoring cannot survive.
                guard let text = try? await Shell.output(
                    self.gitPath, ["show", "\(sha):\(path)"], cwd: repoRoot, timeout: 30
                ) else { continue }
                var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                // `git show` ends with a newline, which splits into a trailing empty line the file has not got.
                if lines.last == "" { lines.removeLast() }
                contents[path] = lines
            }
            return contents
        }) ?? [:]
    }

    /// Where the PR branched from its base, which is what a LEFT-side line number counts against.
    public func mergeBase(baseRef: String, sha: String, repoRoot: String) async -> String? {
        try? await serialized(repoRoot) {
            try? await self.git(["merge-base", "origin/\(baseRef)", sha], cwd: repoRoot, timeout: 30)
        }
    }

    /// Fetches one ref on its own, for a re-anchor that has no review run behind it.
    @discardableResult
    public func fetch(ref: String, repoRoot: String) async -> Bool {
        ((try? await serialized(repoRoot) {
            try? await self.git(["fetch", "--no-tags", "origin", ref], cwd: repoRoot, timeout: 120)
        }) ?? nil) != nil
    }

    /// Removes clean review worktrees no record claims. Without this a ledger reset would strand them:
    /// nothing would ever ask for their removal, and they would hold worktree registrations in real clones.
    public func pruneOrphans(repoRoots: [String], reviewRoot: String, keeping paths: Set<String>) async {
        for root in repoRoots {
            guard let porcelain = try? await serialized(root, { try await self.git(["worktree", "list", "--porcelain"], cwd: root) }) else { continue }
            // A main checkout never sits under the review root, so being under it is the whole test.
            for entry in GitParsing.worktreeEntries(porcelain) where !entry.isBare {
                guard ClaudePaths.path(entry.path, isUnder: [reviewRoot]), !paths.contains(entry.path) else { continue }
                try? await remove(repoRoot: root, path: entry.path)
            }
        }
    }

    /// The head may have moved between the GitHub search and the fetch; FETCH_HEAD is then the newer one.
    private nonisolated func checkout(_ sha: String, in path: String) async throws {
        do {
            try await git(["checkout", "--detach", sha], cwd: path)
        } catch {
            try await git(["checkout", "--detach", "FETCH_HEAD"], cwd: path)
        }
    }

    private nonisolated func add(_ sha: String, at path: String, repoRoot: String) async throws {
        do {
            try await git(["worktree", "add", "--detach", path, sha], cwd: repoRoot)
        } catch {
            try await git(["worktree", "add", "--detach", path, "FETCH_HEAD"], cwd: repoRoot)
        }
    }

    @discardableResult
    private nonisolated func git(_ arguments: [String], cwd: String, timeout: TimeInterval = 300) async throws -> String {
        try await Shell.output(gitPath, arguments, cwd: cwd, timeout: timeout).trimmingCharacters(in: .whitespacesAndNewlines)
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
