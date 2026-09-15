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

    /// `owner/name`, lowercased, from any remote URL form: `git@host:Org/repo.git`, `ssh://git@host/Org/repo`,
    /// `https://host/Org/repo`. Host-agnostic because remotes here use SSH host aliases such as
    /// `github-guya-fhenix`, so matching on github.com would find nothing.
    public static func repoSlug(fromRemote remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix(".git") { text.removeLast(4) }
        let parts = text.replacingOccurrences(of: ":", with: "/").split(separator: "/").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return "\(parts[parts.count - 2])/\(parts[parts.count - 1])".lowercased()
    }

    /// Undoes the C-style quoting git puts on a path holding a control character, a quote, a backslash
    /// or any non-ASCII byte. Diff headers carry the quoted form; GitHub's API wants the real path.
    public static func unquotePath(_ value: String) -> String {
        let utf8 = Array(value.utf8)
        guard utf8.count >= 2, utf8.first == UInt8(ascii: "\""), utf8.last == UInt8(ascii: "\"") else { return value }
        var bytes: [UInt8] = []
        var index = 1
        let end = utf8.count - 1
        while index < end {
            let byte = utf8[index]
            index += 1
            guard byte == UInt8(ascii: "\\"), index < end else {
                bytes.append(byte)
                continue
            }
            let escape = utf8[index]
            index += 1
            switch escape {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                // Three octal digits, which is how git writes every byte of a non-ASCII name.
                var value = Int(escape - UInt8(ascii: "0"))
                var digits = 1
                while digits < 3, index < end, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(utf8[index]) {
                    value = value * 8 + Int(utf8[index] - UInt8(ascii: "0"))
                    index += 1
                    digits += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(escape)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
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

    /// `slugs` are the tracked `owner/name`s. A clone is only interesting when it is one of them: the
    /// repo list comes from GitHub now, and the local folder only says where a tracked repo is checked out.
    public func scan(roots: [String], slugs: [String]) async -> GitScan {
        guard !slugs.isEmpty else { return GitScan() }
        var scan = GitScan()
        scan.repos = await discoverRepos(roots: roots, slugs: Set(slugs))
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

    private func discoverRepos(roots: [String], slugs: Set<String>) async -> [RepoRef] {
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
                    guard let remote = try? await self.git(["remote", "get-url", "origin"], cwd: path),
                          let slug = GitParsing.repoSlug(fromRemote: remote), slugs.contains(slug) else { return nil }
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
            let defaultBranch = await Self.defaultBranch(root: repo.root, gitPath: gitPath)
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

    /// The branch `origin/HEAD` names when the clone records it, else `main` when `origin/main` exists,
    /// else `master`. Also what a review reads other clones at.
    public nonisolated static func defaultBranch(root: String, gitPath: String) async -> String {
        func git(_ arguments: [String]) async -> String? {
            try? await Shell.output(gitPath, arguments, cwd: root, timeout: 30).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let ref = await git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) {
            return ref.replacingOccurrences(of: "origin/", with: "")
        }
        if await git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main"]) != nil { return "main" }
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
