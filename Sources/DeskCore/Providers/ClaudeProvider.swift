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

    public init(
        id: String, name: String, state: String, cwd: String, prKeys: Set<String>, updatedAt: Date, createdAt: Date? = nil,
        sessionId: String? = nil, ticketKey: String? = nil, startedOn: Set<String> = [], linked: Set<String> = []
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
    }

    public var isRunning: Bool { state == "working" }
    /// Waiting on your answer to something it asked.
    public var isAsking: Bool { state == "blocked" }
    /// In the middle of a turn: working, or asking you something.
    public var isBusy: Bool { isRunning || isAsking }
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
                prKeys: keys, updatedAt: state.updatedAt ?? .distantPast, createdAt: state.createdAt, sessionId: state.sessionId,
                ticketKey: ticketKey, startedOn: state.intent.map(ClaudeJobs.prKeys(in:)) ?? [], linked: state.linked
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

    /// Where the session writes the result of instruction `step`: its own scratch folder, which it may always
    /// write to, and which goes when the session is deleted. The app reads nothing from it — the stage follows the
    /// session and the PR — and writing it is the instruction's last step.
    public static func resultFile(jobId: String, step: Int, home: String = ClaudeJobs.home) -> String {
        "\(home)/jobs/\(jobId)/tmp/desk-step-\(step).json"
    }

    /// The directory to resume a session from: the one whose Claude Code project folder holds its transcript. A
    /// session that entered a worktree keeps its conversation under that worktree, not where it started.
    public static func resumeDirectory(sessionId: String, candidates: [String], home: String = ClaudeJobs.home) -> String? {
        candidates.first { dir in
            let folder = dir.replacing(/[^A-Za-z0-9-]/, with: "-")
            return FileManager.default.fileExists(atPath: "\(home)/projects/\(folder)/\(sessionId).jsonl")
        }
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

    public init(path: String) {
        self.path = path
    }

    /// Starts a background session on `prompt` in `cwd`, and returns its short id.
    public func startBackground(_ prompt: String, cwd: String) async throws -> String {
        let output = try await Shell.output(path, ["--bg", prompt], cwd: cwd, timeout: 120)
        guard let id = ClaudeJobs.startedID(in: output) else { throw DeskError.sessionNotStarted(output) }
        return id
    }

    /// Sends an idle background session its next instruction, keeping its id and its conversation. A session that
    /// has finished its turn is still alive, and resuming a live one starts a copy instead, so it is stopped first
    /// and resumed only once `claude agents` no longer lists it running. Callers send only to a session that is
    /// `done`: stopping one that is working or asking something would cut it off.
    public func send(_ prompt: String, to job: ClaudeJob, cwd: String) async throws {
        guard let sessionId = job.sessionId else { throw DeskError.sessionNotResumed("no session id recorded for \(job.id) yet") }
        // Its exit status is not the test: a session that is not running may refuse the stop. Not running is the test.
        let pid = await agents()?.first { $0["id"] as? String == job.id }?["pid"] as? Int32
        _ = try await Shell.run(path, ["stop", job.id], timeout: 30)
        guard await waitUntilStopped(job.id, pid: pid) else { throw DeskError.sessionStillRunning(job.id) }
        let output = try await Shell.output(path, ["--bg", "--resume", sessionId, prompt], cwd: cwd, timeout: 120)
        guard let id = ClaudeJobs.startedID(in: output), id == job.id else {
            // A copy would run the instruction beside the real session; it goes before anything else happens.
            if let copy = ClaudeJobs.startedID(in: output) {
                _ = try? await Shell.run(path, ["stop", copy], timeout: 30)
                _ = try? await Shell.run(path, ["rm", copy], timeout: 30)
            }
            throw DeskError.sessionNotResumed(output)
        }
    }

    /// `claude agents` drops a stopped session a second or two before its process exits, and a resume in that gap
    /// starts a copy: so the process `pid` going is the test too.
    private func waitUntilStopped(_ id: String, pid: Int32?) async -> Bool {
        for _ in 0..<30 {
            guard let list = await agents() else { return false }
            let listed = list.contains { $0["id"] as? String == id && $0["pid"] != nil }
            if !listed, pid.map({ kill($0, 0) != 0 }) ?? true { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private func agents() async -> [[String: Any]]? {
        guard let output = try? await Shell.output(path, ["agents", "--json"], timeout: 30) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [[String: Any]] ?? []
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
