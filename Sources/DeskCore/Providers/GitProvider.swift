import Foundation

public struct GitScan: Sendable {
    public var repos: [RepoRef]
    public var worktrees: [Worktree]
    public var errors: [String]
    public var scannedAt: Date

    public init(repos: [RepoRef] = [], worktrees: [Worktree] = [], errors: [String] = [], scannedAt: Date = Date()) {
        self.repos = repos
        self.worktrees = worktrees
        self.errors = errors
        self.scannedAt = scannedAt
    }
}

public struct WorktreeEntry: Sendable, Equatable {
    public var path: String
    public var head: String
    public var branch: String?
    public var isPrunable: Bool
    public var isBare: Bool

    public init(path: String, head: String, branch: String?, isPrunable: Bool = false, isBare: Bool = false) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isPrunable = isPrunable
        self.isBare = isBare
    }
}

public enum GitParsing {
    /// Parses `git worktree list --porcelain`.
    public static func worktreeEntries(_ porcelain: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                if let entry = current { entries.append(entry) }
                current = nil
                continue
            }
            if line.hasPrefix("worktree ") {
                current = WorktreeEntry(path: String(line.dropFirst("worktree ".count)), head: "", branch: nil)
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                current?.branch = String(line.dropFirst("branch ".count)).replacingOccurrences(of: "refs/heads/", with: "")
            } else if line.hasPrefix("prunable") {
                current?.isPrunable = true
            } else if line == "bare" {
                current?.isBare = true
            }
        }
        if let entry = current { entries.append(entry) }
        return entries
    }

    /// Parses `git rev-list --left-right --count A...B` output "behind<TAB>ahead".
    public static func leftRightCount(_ text: String) -> (behind: Int, ahead: Int)? {
        let parts = text.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else { return nil }
        return (behind, ahead)
    }
}

public actor GitProvider {
    private let gitPath: String
    private let concurrency = 6

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    public func scan(roots: [String], org: String) async -> GitScan {
        var scan = GitScan()
        scan.repos = await discoverRepos(roots: roots, org: org)
        await withTaskGroup(of: (worktrees: [Worktree], error: String?).self) { group in
            for repo in scan.repos {
                group.addTask { await self.scanRepo(repo) }
            }
            for await result in group {
                scan.worktrees.append(contentsOf: result.worktrees)
                if let error = result.error { scan.errors.append(error) }
            }
        }
        scan.worktrees.sort { ($0.repoName, $0.isMain ? 0 : 1, $0.path) < ($1.repoName, $1.isMain ? 0 : 1, $1.path) }
        scan.scannedAt = Date()
        return scan
    }

    private func discoverRepos(roots: [String], org: String) async -> [RepoRef] {
        let orgMarker = "/\(org.lowercased())/"
        var candidates: [String] = []
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for name in names {
                let path = (root as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                let gitPath = (path as NSString).appendingPathComponent(".git")
                guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                candidates.append(path)
            }
        }
        var repos: [RepoRef] = []
        await withTaskGroup(of: RepoRef?.self) { group in
            for path in candidates {
                group.addTask {
                    guard let remote = try? await self.git(["remote", "get-url", "origin"], cwd: path) else { return nil }
                    let normalized = remote.lowercased().replacingOccurrences(of: ":", with: "/")
                    guard normalized.contains(orgMarker) else { return nil }
                    return RepoRef(name: (path as NSString).lastPathComponent, root: path, remote: remote)
                }
            }
            for await repo in group {
                if let repo { repos.append(repo) }
            }
        }
        return repos.sorted { $0.name < $1.name }
    }

    private func scanRepo(_ repo: RepoRef) async -> (worktrees: [Worktree], error: String?) {
        do {
            let porcelain = try await git(["worktree", "list", "--porcelain"], cwd: repo.root)
            let entries = GitParsing.worktreeEntries(porcelain).filter { !$0.isBare }
            let defaultBranch = await defaultBranch(repo: repo)
            var worktrees: [Worktree] = []
            await withTaskGroup(of: Worktree.self) { group in
                var pending = entries.makeIterator()
                var running = 0
                func startNext(_ group: inout TaskGroup<Worktree>) {
                    guard let entry = pending.next() else { return }
                    running += 1
                    group.addTask { await self.inspect(entry, repo: repo, defaultBranch: defaultBranch) }
                }
                for _ in 0..<concurrency { startNext(&group) }
                while running > 0, let worktree = await group.next() {
                    running -= 1
                    worktrees.append(worktree)
                    startNext(&group)
                }
            }
            return (worktrees, nil)
        } catch {
            return ([], "\(repo.name): \(error)")
        }
    }

    private func defaultBranch(repo: RepoRef) async -> String {
        if let ref = try? await git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: repo.root) {
            return ref.replacingOccurrences(of: "origin/", with: "")
        }
        if (try? await git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main"], cwd: repo.root)) != nil {
            return "main"
        }
        return "master"
    }

    private func inspect(_ entry: WorktreeEntry, repo: RepoRef, defaultBranch: String) async -> Worktree {
        var worktree = Worktree(
            repoName: repo.name, repoRoot: repo.root, path: entry.path, branch: entry.branch, headSha: entry.head,
            isMain: entry.path == repo.root, isPrunable: entry.isPrunable, defaultBranch: defaultBranch
        )
        guard !entry.isPrunable else { return worktree }
        let cwd = entry.path

        if let status = try? await git(["status", "--porcelain"], cwd: cwd) {
            worktree.dirtyFiles = status.split(separator: "\n").count
        }
        if let counts = try? await git(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], cwd: cwd),
           let parsed = GitParsing.leftRightCount(counts) {
            worktree.behind = parsed.behind
            worktree.ahead = parsed.ahead
        } else {
            worktree.hasUpstream = false
            if let ahead = try? await git(["rev-list", "--count", "origin/\(defaultBranch)..HEAD"], cwd: cwd) {
                worktree.ahead = Int(ahead) ?? 0
            }
        }
        if let behind = try? await git(["rev-list", "--count", "HEAD..origin/\(defaultBranch)"], cwd: cwd) {
            worktree.behindDefault = Int(behind) ?? 0
        }
        if let epoch = try? await git(["log", "-1", "--format=%ct"], cwd: cwd), let seconds = TimeInterval(epoch) {
            worktree.lastCommitAt = Date(timeIntervalSince1970: seconds)
        }
        return worktree
    }

    private func git(_ arguments: [String], cwd: String) async throws -> String {
        try await Shell.output(gitPath, arguments, cwd: cwd, timeout: 30).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
