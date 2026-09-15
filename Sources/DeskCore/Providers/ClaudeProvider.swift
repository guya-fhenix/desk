import Foundation

public enum ClaudePaths {
    public static func path(_ path: String, isUnder prefixes: [String]) -> Bool {
        prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

/// One Claude Code background session, as its `~/.claude/jobs/<id>/state.json` records it. Interactive
/// sessions have no job directory, so everything found this way is a background agent by construction.
public struct ClaudeJob: Sendable, Hashable, Identifiable {
    /// The short id `claude attach`, `logs` and `stop` take.
    public var id: String
    public var name: String
    /// `working`, `done`, and whatever else Claude Code writes there; shown, never matched on.
    public var state: String
    public var cwd: String
    /// `owner/name#number` of every PR the session touched, from Claude Code's own scan of the transcript.
    public var prKeys: Set<String>
    public var updatedAt: Date

    public init(id: String, name: String, state: String, cwd: String, prKeys: Set<String>, updatedAt: Date) {
        self.id = id
        self.name = name
        self.state = state
        self.cwd = cwd
        self.prKeys = prKeys
        self.updatedAt = updatedAt
    }

    public var isRunning: Bool { state == "working" }
}

/// Reads the background sessions off disk. Only the small per-job state files, never a transcript: the
/// PR links in them are already the product of Claude Code's own link scan.
public enum ClaudeJobs {
    public static let home = ("~/.claude" as NSString).expandingTildeInPath

    /// Background sessions that mention a pull request, newest first. Sessions that mention none are
    /// dropped: nothing on a PR screen could show them.
    public static func scan(home: String = ClaudeJobs.home) -> [ClaudeJob] {
        let root = URL(fileURLWithPath: home).appendingPathComponent("jobs")
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        let decoder = JSON.decoder()
        return ids.compactMap { id in
            let file = root.appendingPathComponent(id).appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: file), let state = try? decoder.decode(JobState.self, from: data) else { return nil }
            let keys = state.prKeys
            guard !keys.isEmpty else { return nil }
            return ClaudeJob(
                id: id, name: state.label(fallback: id), state: state.state ?? "unknown", cwd: state.cwd ?? "",
                prKeys: keys, updatedAt: state.updatedAt ?? .distantPast
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The short id `claude --bg` prints ("backgrounded · 1a2b3c4d"), out of ANSI-coloured output.
    public static func startedID(in output: String) -> String? {
        output.matches(of: /\b[0-9a-f]{8}\b/).first.map { String($0.output) }
    }

    /// Every PR url in a piece of text, for the prompt a session was started from.
    public static func prKeys(in text: String) -> Set<String> {
        Set(text.matches(of: /https:\/\/github\.com\/[^\/\s]+\/[^\/\s]+\/pull\/\d+/).compactMap { prKey(String($0.output)) })
    }

    /// `owner/name#number`, the one shape a PR url and a session's recorded link agree on.
    public static func prKey(_ url: String) -> String? {
        let parts = url.split(separator: "/")
        guard parts.count >= 4, parts[parts.count - 2] == "pull", let number = Int(parts[parts.count - 1]) else { return nil }
        return "\(parts[parts.count - 4])/\(parts[parts.count - 3])#\(number)".lowercased()
    }

    /// Every key is optional: the file is Claude Code's, and a missing field must not cost us the session.
    private struct JobState: Decodable {
        struct Child: Decodable {
            var href: String?
            var kind: String?
        }

        var state: String?
        var name: String?
        /// The prompt the session started from, for sessions Claude Code never named.
        var intent: String?
        var cwd: String?
        var children: [Child]?
        var updatedAt: Date?

        /// The PRs this session is about: the ones Claude Code's link scan saw it work with, plus any
        /// named in the prompt it was started from — which is the only trace of a session opened on a PR
        /// that has not touched it yet.
        var prKeys: Set<String> {
            let linked = (children ?? []).filter { $0.kind == "pr" }.compactMap { $0.href.flatMap(ClaudeJobs.prKey) }
            return Set(linked).union(intent.map(ClaudeJobs.prKeys(in:)) ?? [])
        }

        func label(fallback: String) -> String {
            let candidates = [name, intent?.split(separator: "\n").first.map(String.init)]
            let text = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            return text ?? fallback
        }
    }
}
