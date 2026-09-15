import Foundation

/// Fetches and caches the diff GitHub itself computes for a PR.
///
/// Deliberately `gh pr diff` and not a local `git diff`: GitHub refuses an inline comment on a line
/// outside *its* diff, and local git disagrees with it in three configurable ways — rename detection,
/// hunk boundaries, and which merge base a best-effort fetch happened to leave behind. All three produce
/// a diff that parses cleanly and is rejected only at submit time, long after the user has triaged it.
/// The review prompt runs the same command, so the model and the validator read the same bytes.
public actor ReviewDiffs {
    public static let directory = "diffs"
    /// A diff nobody has asked for in this long is not coming back.
    public static let retention: TimeInterval = 14 * 86_400
    private static let attempts = 3

    private var ghPath: String?
    private let support: AppSupport
    private var cache: [String: PullRequestDiff] = [:]

    public init(ghPath: String?, support: AppSupport) {
        self.ghPath = ghPath
        self.support = support
    }

    public func update(ghPath: String?) {
        self.ghPath = ghPath
    }

    public func diff(repo: String, number: Int, headSha: String) async throws -> PullRequestDiff {
        let key = "\(repo)#\(number)@\(headSha)"
        if let cached = cache[key] { return cached }
        let text: String
        if let onDisk = try? String(contentsOf: file(repo: repo, number: number, sha: headSha), encoding: .utf8) {
            text = onDisk
        } else {
            text = try await fetch(repo: repo, number: number)
            try? write(text, repo: repo, number: number, sha: headSha)
        }
        let diff = PullRequestDiff(files: DiffParser.parse(text), headSha: headSha)
        cache[key] = diff
        return diff
    }

    /// Drops a PR's cached diffs, so the next read fetches the head that just landed.
    public func evict(repo: String, number: Int) {
        let prefix = "\(repo)#\(number)@"
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        let stem = "\(name(repo))-\(number)-"
        for url in files() where url.lastPathComponent.hasPrefix(stem) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func prune() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        for url in files() {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func fetch(repo: String, number: Int) async throws -> String {
        guard let ghPath else { throw DeskError.ghNotFound }
        // `--color never`: the default is off on a pipe, but "off because you happened to be piped" is
        // not a guarantee worth parsing against.
        let arguments = ["pr", "diff", "\(number)", "--repo", repo, "--color", "never"]
        var attempt = 0
        while true {
            let result = try await Shell.run(ghPath, arguments, stdin: Data(), timeout: 120)
            if result.status == 0 { return result.text }
            attempt += 1
            // A GET is idempotent, so a retry costs nothing but the wait.
            guard attempt < Self.attempts, GitHubError.isTransient(stderr: result.stderr) else {
                throw ShellError.failed(command: "gh pr diff \(number) --repo \(repo)", status: result.status, stderr: result.stderr)
            }
            try await Task.sleep(for: .seconds(Double(attempt) * 2))
        }
    }

    private func write(_ text: String, repo: String, number: Int, sha: String) throws {
        let url = file(repo: repo, number: number, sha: sha)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Raw diff text rather than encoded JSON: it is smaller, and re-parsing it costs microseconds.
    private func file(repo: String, number: Int, sha: String) -> URL {
        support.url(Self.directory).appendingPathComponent("\(name(repo))-\(number)-\(sha.prefix(7)).diff")
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: support.url(Self.directory), includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
    }

    private func name(_ repo: String) -> String { repo.split(separator: "/").last.map(String.init) ?? repo }
}
