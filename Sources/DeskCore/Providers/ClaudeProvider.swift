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
    /// The full id `claude --resume` takes, which is how the app sends the session its next instruction.
    public var sessionId: String?
    /// The Jira key the prompt it started from names first: a session started on a ticket, before it has a PR.
    public var ticketKey: String?
    /// The PRs the prompt it started from names: a session the app started on a PR.
    public var startedOn: Set<String>

    public init(
        id: String, name: String, state: String, cwd: String, prKeys: Set<String>, updatedAt: Date, sessionId: String? = nil,
        ticketKey: String? = nil, startedOn: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.cwd = cwd
        self.prKeys = prKeys
        self.updatedAt = updatedAt
        self.sessionId = sessionId
        self.ticketKey = ticketKey
        self.startedOn = startedOn
    }

    /// Whether this session carries the PR through the flow: it was started on the PR, or on its ticket. A session that
    /// only touched the PR on the way, as one long session touches many, does not.
    public func carries(_ prKey: String, tickets: [String]) -> Bool {
        startedOn.contains(prKey) || ticketKey.map(tickets.contains) == true
    }

    public var isRunning: Bool { state == "working" }
    /// In the middle of a turn: working, or asking you something.
    public var isBusy: Bool { isRunning || state == "blocked" }
    /// Done with its turn: the one state an instruction may be sent in. Stopping a session that works or asks would cut
    /// it off.
    public var isIdle: Bool { state == "done" }
}

/// Reads the background sessions off disk. Only the small per-job state files, never a transcript: the
/// PR links in them are already the product of Claude Code's own link scan.
public enum ClaudeJobs {
    public static let home = ("~/.claude" as NSString).expandingTildeInPath

    /// Background sessions that mention a pull request, or whose prompt names a ticket, newest first. The rest are
    /// dropped: nothing on a PR or ticket screen could show them. A ticket's session is shown on the ticket before it
    /// has opened anything.
    public static func scan(home: String = ClaudeJobs.home, tickets: TicketKeyMatcher = TicketKeyMatcher(projectKeys: [])) -> [ClaudeJob] {
        let root = URL(fileURLWithPath: home).appendingPathComponent("jobs")
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        let decoder = JSON.decoder()
        return ids.compactMap { id in
            let file = root.appendingPathComponent(id).appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: file), let state = try? decoder.decode(JobState.self, from: data) else { return nil }
            let keys = state.prKeys
            let ticketKey = state.intent.flatMap { tickets.keys(in: $0).first }
            guard !keys.isEmpty || ticketKey != nil else { return nil }
            return ClaudeJob(
                id: id, name: state.label(fallback: id), state: state.state ?? "unknown", cwd: state.cwd ?? "",
                prKeys: keys, updatedAt: state.updatedAt ?? .distantPast, sessionId: state.sessionId, ticketKey: ticketKey,
                startedOn: state.intent.map(ClaudeJobs.prKeys(in:)) ?? []
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The short id `claude --bg` prints ("backgrounded · 1a2b3c4d"), out of ANSI-coloured output. Read off the
    /// "backgrounded" line when there is one: a resume that started a copy names the original first.
    public static func startedID(in output: String) -> String? {
        let plain = output.replacing(/\u{1B}\[[0-9;]*m/, with: "")
        let line = plain.split(separator: "\n").first { $0.contains("backgrounded") }.map(String.init) ?? plain
        return line.matches(of: /\b[0-9a-f]{8}\b/).first.map { String($0.output) }
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
        var sessionId: String?
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

/// Whether a repository's sessions can run the two skills Desk's presses call by name: `fhenix-workflow` enabled for the
/// repo and installed at a version that ships them. Run /pre-pr on a draft runs the self-review — /pre-pr where the repo has
/// adopted the review flow, reviewing-code elsewhere — and Start review runs review-pr.
public struct ReviewSkill: Sendable, Hashable {
    public enum State: Sendable, Hashable { case ready, noSkill, notInstalled, notEnabled }

    public var state: State
    /// The installed plugin version, when there is one.
    public var version: String?
    /// `REVIEW.md` and `.github/review/tier.sh` in the repo: what decides which skill the self-review runs.
    public var adopted: Bool
    /// The skills the installed version lacks.
    public var missing: [String]

    public init(state: State, version: String? = nil, adopted: Bool = false, missing: [String] = []) {
        self.state = state
        self.version = version
        self.adopted = adopted
        self.missing = missing
    }

    /// The skill Run /pre-pr on a draft runs here.
    public var selfReview: String { adopted ? ClaudePlugins.prePR : ClaudePlugins.reviewingCode }
    public var skills: [String] { [selfReview, ClaudePlugins.reviewPR] }

    /// Every skill there.
    public var isReady: Bool { state == .ready }

    /// One skill there, whatever the other.
    public func has(_ skill: String) -> Bool { (state == .ready || state == .noSkill) && !missing.contains(skill) }

    public var text: String {
        let plugin = ClaudePlugins.plugin
        switch state {
        case .ready: return "\(plugin) \(version ?? "") · \(skills.joined(separator: ", "))"
        case .noSkill: return "\(plugin) \(version ?? "") has no \(missing.joined(separator: ", ")) — update the plugin"
        case .notInstalled: return "\(plugin) is enabled here but not installed"
        case .notEnabled: return "\(plugin) is not enabled in this repo"
        }
    }
}

/// Reads the plugin files Claude Code reads, never the plugins themselves.
public enum ClaudePlugins {
    public static let plugin = "fhenix-workflow"
    public static let prePR = "pre-pr"
    public static let reviewingCode = "reviewing-code"
    /// The skill a review session starts with.
    public static let reviewPR = "review-pr"

    /// `enabledPlugins` decides first, in Claude Code's own order — the repo's local settings, then its shared
    /// settings, then the user's, and the first that names the plugin wins. Then the install record for this
    /// repo, or for the user, says which version is there and whether it carries the skill.
    public static func reviewSkill(repoRoot: String, adopted: Bool = false, home: String = ClaudeJobs.home) -> ReviewSkill {
        let files = ["\(repoRoot)/.claude/settings.local.json", "\(repoRoot)/.claude/settings.json", "\(home)/settings.json"]
        guard let enabled = files.lazy.compactMap(enabledEntry(in:)).first, enabled.on else {
            return ReviewSkill(state: .notEnabled, adopted: adopted)
        }
        guard let install = install(of: enabled.name, repoRoot: repoRoot, home: home) else {
            return ReviewSkill(state: .notInstalled, adopted: adopted)
        }
        let missing = ReviewSkill(state: .ready, adopted: adopted).skills
            .filter { !FileManager.default.fileExists(atPath: "\(install.path)/skills/\($0)/SKILL.md") }
        return ReviewSkill(state: missing.isEmpty ? .ready : .noSkill, version: install.version, adopted: adopted, missing: missing)
    }

    /// `fhenix-workflow@<marketplace>` and whether this file turns it on, or nil when the file does not name it.
    private static func enabledEntry(in path: String) -> (name: String, on: Bool)? {
        guard let plugins = object(at: path)?["enabledPlugins"] as? [String: Any],
              let entry = plugins.first(where: { $0.key.hasPrefix(plugin + "@") })
        else { return nil }
        return (entry.key, entry.value as? Bool ?? false)
    }

    /// The install for this repo, or failing that the user-wide one.
    private static func install(of name: String, repoRoot: String, home: String) -> (path: String, version: String?)? {
        let records = (object(at: "\(home)/plugins/installed_plugins.json")?["plugins"] as? [String: Any])?[name] as? [[String: Any]] ?? []
        let root = URL(fileURLWithPath: repoRoot).standardizedFileURL.path
        let mine = records.first { ($0["projectPath"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path } == root }
        guard let record = mine ?? records.first(where: { $0["scope"] as? String == "user" }),
              let path = record["installPath"] as? String
        else { return nil }
        return (path, record["version"] as? String)
    }

    private static func object(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
