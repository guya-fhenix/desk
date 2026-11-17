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
    /// `working`, `blocked`, `done`, and whatever else Claude Code writes there; read only by `isRunning`, `isAsking` and
    /// `isIdle`.
    public var state: String
    public var cwd: String
    /// `owner/name#number` of every PR the session touched, from Claude Code's own scan of the transcript.
    public var prKeys: Set<String>
    public var updatedAt: Date
    /// When Claude Code started it; nil where its file does not say.
    public var createdAt: Date?
    /// The full id `claude --resume` takes, which is how the app sends the session its next instruction.
    public var sessionId: String?
    /// The Jira key the prompt it started from names first: a session started on a ticket, before it has a PR.
    public var ticketKey: String?
    /// The PRs the prompt it started from names: a session the app started on a PR.
    public var startedOn: Set<String>
    /// The PRs Claude Code's link scan found in its output: its `children` of kind `pr`. The PR it opened is one, and so
    /// is every PR it only mentioned.
    public var linked: Set<String>
    /// What it is asking, as Claude Code sums it up (`needs`), while it asks. Often the last line of a long message, which
    /// reads as the end of a report rather than a question, so Desk says it outright.
    public var question: String?
    /// What it is doing, in a line, as Claude Code keeps it up to date (`detail`).
    public var detail: String?
    /// What it was started as, read off the prompt it started from.
    public var role: SessionRole
    /// For a worker started on what the person asked rather than on a ticket, the ask: "find why decrypt requests fail".
    public var request: String?

    public init(
        id: String, name: String, state: String, cwd: String, prKeys: Set<String>, updatedAt: Date, createdAt: Date? = nil,
        sessionId: String? = nil, ticketKey: String? = nil, startedOn: Set<String> = [], linked: Set<String> = [],
        question: String? = nil, detail: String? = nil, role: SessionRole = .other, request: String? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.cwd = cwd
        self.prKeys = prKeys
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.sessionId = sessionId
        self.ticketKey = ticketKey
        self.startedOn = startedOn
        self.linked = linked
        self.question = question
        self.detail = detail
        self.role = role
        self.request = request
    }

    public var isRunning: Bool { state == "working" }
    /// Waiting on your answer to something it asked.
    public var isAsking: Bool { state == "blocked" }
    /// Its state in a word for people: Claude Code's "blocked" reads as stuck, when it is waiting on your answer.
    public var status: String { isAsking ? "asks you" : state }
    /// What it asks, or that it asks something, for wherever Desk says so.
    public var asking: String { question.map { "The session asks: \($0)" } ?? "The session is asking you something" }
    /// In the middle of a turn: working, or asking you something.
    public var isBusy: Bool { isRunning || isAsking }
    /// Done with its turn: the one state an instruction may be sent in. Stopping a session that works or asks would cut
    /// it off.
    public var isIdle: Bool { state == "done" }
}

/// What a session was started as, by the skill its prompt names: the master the person talks to, a worker on one task, a
/// review of a teammate's PRs, or anything else.
public enum SessionRole: String, Sendable, Codable {
    case master, worker, review, other

    /// The master is also known by its name, which Desk and the person give it.
    public static func of(name: String?, intent: String?) -> SessionRole {
        let prompt = intent ?? ""
        if name == "master" || prompt.contains("coordinate-tasks") { return .master }
        if prompt.contains("work-on-task") { return .worker }
        if prompt.contains("review-teammate-task") { return .review }
        return .other
    }
}

/// Reads the background sessions off disk. Only the small per-job state files, never a transcript: the
/// PR links in them are already the product of Claude Code's own link scan.
public enum ClaudeJobs {
    public static let home = ("~/.claude" as NSString).expandingTildeInPath

    /// Background sessions that mention a pull request, whose prompt names a ticket, that run a Fhenix Desk role (the
    /// master, a worker, a review), or that run in one of `keepIn`, the tracked clones: a session started there with no
    /// ticket is still a task. Newest first. The rest, a session in some other folder about nothing Desk tracks, are
    /// dropped.
    public static func scan(
        home: String = ClaudeJobs.home, tickets: TicketKeyMatcher = TicketKeyMatcher(projectKeys: []), keepIn: [String] = []
    ) -> [ClaudeJob] {
        let root = URL(fileURLWithPath: home).appendingPathComponent("jobs")
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        let decoder = JSON.decoder()
        return ids.compactMap { id in
            let file = root.appendingPathComponent(id).appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: file), let state = try? decoder.decode(JobState.self, from: data) else { return nil }
            let keys = state.prKeys
            let ticketKey = state.intent.flatMap { tickets.keys(in: $0).first }
            let role = SessionRole.of(name: state.name, intent: state.intent)
            let cwd = state.cwd ?? ""
            guard !keys.isEmpty || ticketKey != nil || role != .other || ClaudePaths.path(cwd, isUnder: keepIn) else { return nil }
            return ClaudeJob(
                id: id, name: state.label(fallback: id), state: state.state ?? "unknown", cwd: cwd,
                prKeys: keys, updatedAt: state.updatedAt ?? .distantPast, createdAt: state.createdAt, sessionId: state.sessionId,
                ticketKey: ticketKey, startedOn: state.intent.map(ClaudeJobs.prKeys(in:)) ?? [], linked: state.linked,
                question: state.question, detail: state.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                role: role, request: role == .worker && ticketKey == nil ? state.intent.flatMap(request(in:)) : nil
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The session that carries a PR through the flow, which its presses stop and resume: the newest of those started on
    /// the PR or on its ticket; else, of those whose link scan found the PR, the earliest started, which is the one that
    /// opened it. A later session that only mentioned the PR, as one long session does with many, never takes it over.
    /// `sessions` newest first, as `scan` returns them.
    public static func carrier(of prKey: String, tickets: [String], in sessions: [ClaudeJob]) -> ClaudeJob? {
        sessions.first { $0.startedOn.contains(prKey) || $0.ticketKey.map(tickets.contains) == true }
            ?? sessions.filter { $0.linked.contains(prKey) }.min { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
    }

    /// The short id `claude --bg` prints ("backgrounded · 1a2b3c4d"), out of ANSI-coloured output. Read off the
    /// "backgrounded" line when there is one: a resume that started a copy names the original first.
    public static func startedID(in output: String) -> String? {
        let plain = output.replacing(/\u{1B}\[[0-9;]*m/, with: "")
        let line = plain.split(separator: "\n").first { $0.contains("backgrounded") }.map(String.init) ?? plain
        return line.matches(of: /\b[0-9a-f]{8}\b/).first.map { String($0.output) }
    }

    /// What the person asked a worker for, out of the prompt the master started it with:
    /// "Use the fhenix-workflow:work-on-task skill: find why X. Report to master." gives "find why X".
    public static func request(in intent: String) -> String? {
        guard let skill = intent.range(of: "work-on-task skill") else { return nil }
        var rest = intent[skill.upperBound...].drop { $0 == ":" || $0.isWhitespace }
        if let report = rest.range(of: "Report to") { rest = rest[..<report.lowerBound] }
        let text = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return text.isEmpty ? nil : text
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
        var createdAt: Date?
        /// What a blocked session waits on you for, in a line.
        var needs: String?
        /// What it is doing, in a line.
        var detail: String?

        /// `needs` while it is blocked; Claude Code may leave it behind once the session moves on.
        var question: String? {
            guard state == "blocked", let text = needs?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }

        /// Every PR link Claude Code's scan found in the session's output, the one it opened among them.
        var linked: Set<String> {
            Set((children ?? []).filter { $0.kind == "pr" }.compactMap { $0.href.flatMap(ClaudeJobs.prKey) })
        }

        /// The PRs this session is about: the ones it linked to, plus any named in the prompt it was started from —
        /// which is the only trace of a session started on a PR that it did not open.
        var prKeys: Set<String> {
            linked.union(intent.map(ClaudeJobs.prKeys(in:)) ?? [])
        }

        func label(fallback: String) -> String {
            let candidates = [name, intent?.split(separator: "\n").first.map(String.init)]
            let text = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            return text ?? fallback
        }
    }
}

/// Runs the claude CLI for the app: starts background sessions, and sends one its next instruction. What the CLI prints
/// and writes is read by `ClaudeJobs`.
public struct ClaudeCLI: Sendable {
    let path: String
    /// What runs claude: `Shell.run`, but for a test.
    let run: ShellRun

    public init(path: String, run: @escaping ShellRun = Shell.run) {
        self.path = path
        self.run = run
    }

    /// Starts a background session on `prompt` in `cwd`, with `flags` before it, and returns its short id.
    public func startBackground(_ prompt: String, cwd: String, flags: [String] = []) async throws -> String {
        let output = try await Shell.output(path, ["--bg"] + flags + [prompt], cwd: cwd, timeout: 120, run: run)
        guard let id = ClaudeJobs.startedID(in: output) else { throw DeskError.sessionNotStarted(output) }
        return id
    }

    /// Stops a background session: `claude stop <id>`. Its transcript stays; `claude attach` still opens it.
    public func stop(_ id: String) async throws {
        try await Shell.output(path, ["stop", id], timeout: 30, run: run)
    }
}

/// Whether a repository's review sessions can start: `fhenix-workflow` enabled for the repo and installed at a version
/// with a review skill, and which one they start on.
public struct ReviewSkill: Sendable, Hashable {
    public enum State: Sendable, Hashable { case ready, noSkill, notInstalled, notEnabled }

    public var state: State
    /// The installed plugin version, when there is one.
    public var version: String?
    /// The review skill the installed version lacks: `review-pr`, when it has no `review-teammate-task` either.
    public var missing: [String]
    /// Whether review sessions here can run `review-teammate-task`, which reviews any set of PRs with your notes: from
    /// the plugin folder Desk loads plugins from, when one is set, or else the installed plugin. Without it, a review is
    /// one PR on `review-pr`, as before.
    public var groupReview: Bool

    public init(state: State, version: String? = nil, missing: [String] = [], groupReview: Bool = false) {
        self.state = state
        self.version = version
        self.missing = missing
        self.groupReview = groupReview
    }

    /// The skill a review session here starts on.
    public var reviewSkill: String { groupReview ? ClaudePlugins.reviewTeammateTask : ClaudePlugins.reviewPR }

    /// A review session can start here.
    public var isReady: Bool { state == .ready }

    /// One skill there.
    public func has(_ skill: String) -> Bool { (state == .ready || state == .noSkill) && !missing.contains(skill) }

    public var text: String {
        let plugin = ClaudePlugins.plugin
        switch state {
        case .ready: return "\(plugin) \(version ?? "") · \(reviewSkill)"
        case .noSkill: return "\(plugin) \(version ?? "") has no \(missing.joined(separator: ", ")) — update the plugin"
        case .notInstalled: return "\(plugin) is enabled but not installed for your user"
        case .notEnabled: return "\(plugin) is not installed for your user"
        }
    }
}

/// Reads the plugin files Claude Code reads, never the plugins themselves.
public enum ClaudePlugins {
    public static let plugin = "fhenix-workflow"
    /// The skill a one-PR review session starts with, before fhenix-workflow 1.0.
    public static let reviewPR = "review-pr"
    /// The skill a review of any set of PRs, with your notes, starts with: fhenix-workflow 1.0 and later.
    public static let reviewTeammateTask = "review-teammate-task"

    /// The plugin as installed for your user in the Claude Code Desk runs (`home`), the same in every repo: your
    /// settings' `enabledPlugins` turns it on, and the user-wide install record says which version is there and which
    /// review skill it carries. A repo's own install doesn't count: Desk's sessions need it wherever they run.
    /// `pluginDir`, a folder of plugins Desk's sessions load in place of the installed ones, decides whether a group
    /// review can run.
    public static func reviewSkill(pluginDir: String = "", home: String = ClaudeJobs.home) -> ReviewSkill {
        let folder = (pluginDir.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        let inFolder = !folder.isEmpty && FileManager.default.fileExists(atPath: "\(folder)/\(plugin)/skills/\(reviewTeammateTask)/SKILL.md")
        guard let enabled = enabledEntry(in: "\(home)/settings.json"), enabled.on else {
            return ReviewSkill(state: .notEnabled, groupReview: inFolder)
        }
        guard let install = install(of: enabled.name, home: home) else {
            return ReviewSkill(state: .notInstalled, groupReview: inFolder)
        }
        let has = { (skill: String) in FileManager.default.fileExists(atPath: "\(install.path)/skills/\(skill)/SKILL.md") }
        let group = folder.isEmpty ? has(reviewTeammateTask) : inFolder
        let missing = group || has(reviewPR) ? [] : [reviewPR]
        return ReviewSkill(state: missing.isEmpty ? .ready : .noSkill, version: install.version, missing: missing, groupReview: group)
    }

    /// `fhenix-workflow@<marketplace>` and whether this file turns it on, or nil when the file does not name it.
    private static func enabledEntry(in path: String) -> (name: String, on: Bool)? {
        guard let plugins = object(at: path)?["enabledPlugins"] as? [String: Any],
              let entry = plugins.first(where: { $0.key.hasPrefix(plugin + "@") })
        else { return nil }
        return (entry.key, entry.value as? Bool ?? false)
    }

    /// The user-wide install.
    private static func install(of name: String, home: String) -> (path: String, version: String?)? {
        let records = (object(at: "\(home)/plugins/installed_plugins.json")?["plugins"] as? [String: Any])?[name] as? [[String: Any]] ?? []
        guard let record = records.first(where: { $0["scope"] as? String == "user" }),
              let path = record["installPath"] as? String
        else { return nil }
        return (path, record["version"] as? String)
    }

    private static func object(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
