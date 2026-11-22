import Foundation

/// A question the master session has open for the person, as the coordinate-tasks skill keeps them in `asks.json`.
public struct MasterAsk: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// The task it is about: a ticket key or a worker's name.
    public var task: String
    public var worker: String?
    public var text: String
    public var askedAt: Date?

    public init(id: String, task: String, worker: String? = nil, text: String, askedAt: Date? = nil) {
        self.id = id
        self.task = task
        self.worker = worker
        self.text = text
        self.askedAt = askedAt
    }
}

/// One line of `events.jsonl`: something Desk saw on GitHub, which the master routes to a worker or to the person.
/// `kind` is a `NudgeKind`'s raw value, as the skill's table names them.
public struct MasterEvent: Codable, Sendable, Equatable {
    public var kind: String
    /// `owner/name#number`.
    public var pr: String
    public var task: String?
    public var title: String
    public var at: Date

    public init(kind: String, pr: String, task: String?, title: String, at: Date) {
        self.kind = kind
        self.pr = pr
        self.task = task
        self.title = title
        self.at = at
    }
}

/// What `graph.json` holds: the tasks, their PRs and their workers, which the master routes events by.
public struct TaskGraph: Codable, Sendable, Equatable {
    public struct Worker: Codable, Sendable, Equatable {
        public var name: String
        public var id: String
        public var state: String
        public var detail: String?
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        /// `ticket`, `session` or `pullRequest`: what the task started from.
        public var from: String
        public var title: String
        /// The ticket's Jira status, for a task started from a loaded ticket.
        public var jira: String?
        /// `sprint` or `backlog`: where that ticket sits, as Desk's Jira searches found it, so the master need not ask
        /// Jira. Desk knows the active sprint by its search, not by name; nil where Desk doesn't know.
        public var placement: String?
        public var stage: String
        public var waitingOn: String
        public var prs: [String]
        public var worker: Worker?
        public var dependsOn: [String]
    }

    public struct PR: Codable, Sendable, Equatable {
        public var task: String
        public var url: String
        public var stage: String
        public var draft: Bool
        /// `red`, `pending` or `green`.
        public var checks: String
        public var base: String
        public var unresolved: Int
    }

    public var generatedAt: Date
    public var tasks: [Entry]
    /// By `owner/name#number`.
    public var prs: [String: PR]

    public init(tasks: [WorkTask], tickets: [Ticket], asked: Set<String>, now: Date = Date()) {
        generatedAt = now
        var prs: [String: PR] = [:]
        self.tasks = tasks.map { task in
            for pr in task.pullRequests {
                prs[ClaudeJobs.prKey(pr.url) ?? pr.url] = PR(
                    task: task.id, url: pr.url, stage: FlowStage.of(pr).rawValue, draft: pr.isDraft,
                    checks: pr.checks.isRed ? "red" : pr.checks.isPending ? "pending" : "green", base: pr.baseRef,
                    unresolved: pr.unresolvedThreads
                )
            }
            let ticket = task.origin == .ticket ? tickets.first { $0.key == task.id } : nil
            return Entry(
                id: task.id, from: task.origin.rawValue, title: task.title, jira: ticket?.status,
                placement: ticket.flatMap { $0.placement == .unknown ? nil : $0.placement.rawValue },
                stage: task.stage.rawValue, waitingOn: task.waitingOn(asked: asked).rawValue,
                prs: task.pullRequests.compactMap { ClaudeJobs.prKey($0.url) },
                worker: task.worker.map { Worker(name: $0.name, id: $0.id, state: $0.state, detail: $0.detail) },
                dependsOn: task.dependsOn
            )
        }
        self.prs = prs
    }
}

/// The folder the master session runs in, under Desk's own: the files Desk writes for it (`graph.json`, `events.jsonl`),
/// the ones it writes (`asks.json`, `focus.json`, and `handoff.md` before a restart), and its `.claude/settings.json`.
public struct MasterFolder: Sendable {
    public let url: URL

    public init(support: AppSupport) { url = support.directory.appendingPathComponent("master", isDirectory: true) }
    public init(url: URL) { self.url = url }

    public var path: String { url.path }
    private func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    private static func encoder() -> JSONEncoder {
        let encoder = JSON.encoder()
        encoder.outputFormatting.insert(.withoutEscapingSlashes)
        return encoder
    }

    public func write(_ graph: TaskGraph) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let encoder = Self.encoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        try encoder.encode(graph).write(to: file("graph.json"), options: .atomic)
    }

    /// One compact line per event, so the master's `tail -F` wakes once per event.
    public func append(_ events: [MasterEvent]) throws {
        guard !events.isEmpty else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let encoder = Self.encoder()
        var lines = Data()
        for event in events {
            lines.append(try encoder.encode(event))
            lines.append(0x0A)
        }
        let target = file("events.jsonl")
        guard let handle = try? FileHandle(forWritingTo: target) else {
            try lines.write(to: target, options: .atomic)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: lines)
    }

    /// Keeps the last `keeping` events. The master reads only new lines, so older ones only grow the file.
    public func trimEvents(keeping: Int = 500) throws {
        let target = file("events.jsonl")
        guard let text = try? String(contentsOf: target, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > keeping else { return }
        try (lines.suffix(keeping).joined(separator: "\n") + "\n").write(to: target, atomically: true, encoding: .utf8)
    }

    /// The last `limit` events Desk told the master, newest first. A line that doesn't read is skipped.
    public func events(limit: Int = 20) -> [MasterEvent] {
        guard let text = try? String(contentsOf: file("events.jsonl"), encoding: .utf8) else { return [] }
        let decoder = JSON.decoder()
        return text.split(separator: "\n").suffix(limit * 2).compactMap { try? decoder.decode(MasterEvent.self, from: Data($0.utf8)) }
            .suffix(limit).reversed()
    }

    /// The master's open questions. A file it has not written yet, or one it is halfway through writing, reads as none.
    public func asks() -> [MasterAsk] {
        struct File: Decodable { var asks: [MasterAsk] }
        guard let data = try? Data(contentsOf: file("asks.json")) else { return [] }
        return (try? JSON.decoder().decode(File.self, from: data))?.asks ?? []
    }

    /// The master's ranking of the Focus page. With no file, none, and Desk ranks on its own. A file that does not read,
    /// such as one the master is halfway through writing, keeps `last`, the ranking read before it: dropping it for one
    /// scan would resize the whole page and back.
    public func focusRanking(keeping last: FocusRanking? = nil) -> FocusRanking? {
        guard let data = try? Data(contentsOf: file("focus.json")) else { return nil }
        return (try? JSON.decoder().decode(FocusRanking.self, from: data)) ?? last
    }

    /// What Desk types to the master before it restarts it: the skill's own handoff, asked for by name.
    public static let handoffRequest = "Write handoff.md now, as your skill says. Fhenix Desk restarts you as soon as the file is there."

    /// Whether the master wrote `handoff.md` at or after `since`: one left from an earlier restart doesn't count.
    public func handoffWritten(since: Date) -> Bool {
        let written = (try? FileManager.default.attributesOfItem(atPath: file("handoff.md").path))?[.modificationDate] as? Date
        return written.map { $0 >= since } ?? false
    }

    /// Lets the master see `directories` (the person's repo roots and whatever else they list), by writing them as
    /// `permissions.additionalDirectories` into the folder's `.claude/settings.json`, the settings form of `--add-dir`.
    /// Every other key in the file is kept, so a rule the person added by hand survives.
    public func writeSettings(additionalDirectories directories: [String]) throws {
        let folder = url.appendingPathComponent(".claude", isDirectory: true)
        let target = folder.appendingPathComponent("settings.json")
        var settings = (try? Data(contentsOf: target)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        permissions["additionalDirectories"] = directories.map { ($0 as NSString).expandingTildeInPath }
        settings["permissions"] = permissions
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: target, options: .atomic)
    }
}
