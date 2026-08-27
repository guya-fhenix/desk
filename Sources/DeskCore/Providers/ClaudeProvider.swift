import Darwin
import Foundation

public struct ClaudeScan: Codable, Sendable {
    /// Bump when the scanner extracts different fields, so stale caches rescan from zero.
    public static let currentVersion = 2

    public var version: Int
    /// Summaries keyed by transcript file path.
    public var summaries: [String: SessionSummary]

    public init(summaries: [String: SessionSummary] = [:]) {
        self.version = Self.currentVersion
        self.summaries = summaries
    }

    public var isCurrent: Bool { version == Self.currentVersion }

    public var sessions: [SessionSummary] {
        summaries.values.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
    }

    /// Sessions with a human prompt or a PR link. Aborted or empty sessions stay out of the UI.
    public var meaningfulSessions: [SessionSummary] {
        sessions.filter { $0.humanPrompts > 0 || !$0.prLinks.isEmpty }
    }
}

public enum ClaudePaths {
    /// Claude Code names a project directory after its cwd with `/` and `.` replaced by `-`.
    public static func projectSlug(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    /// A project belongs when its cwd is a repo (or a path under it) or exactly one of the root folders.
    public static func projectDirectory(_ name: String, belongsTo repoRoots: [String], exactRoots: [String] = []) -> Bool {
        repoRoots.contains { root in
            let slug = projectSlug(root)
            return name == slug || name.hasPrefix(slug + "-")
        } || exactRoots.contains { name == projectSlug($0) }
    }

    public static func path(_ path: String, isUnder prefixes: [String], orExactly exact: [String]) -> Bool {
        prefixes.contains { path == $0 || path.hasPrefix($0 + "/") } || exact.contains(path)
    }
}

public struct ClaudeScope: Sendable {
    /// Repo roots and worktree paths. Sessions under them count.
    public var repoPaths: [String]
    /// Folders that hold repos. Sessions exactly there count too; sessions in unrelated repos below them do not.
    public var rootFolders: [String]

    public init(repoPaths: [String], rootFolders: [String]) {
        self.repoPaths = repoPaths
        self.rootFolders = rootFolders
    }
}

public actor ClaudeProvider {
    private let home: String

    public init(home: String) {
        self.home = home
    }

    public func liveSessions(scope: ClaudeScope) throws -> [LiveSession] {
        let directory = (home as NSString).appendingPathComponent("sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let decoder = JSONDecoder()
        var sessions: [LiveSession] = []
        for name in names where name.hasSuffix(".json") {
            let url = URL(fileURLWithPath: (directory as NSString).appendingPathComponent(name))
            guard let data = try? Data(contentsOf: url), let file = try? decoder.decode(LiveFile.self, from: data) else { continue }
            guard ClaudePaths.path(file.cwd, isUnder: scope.repoPaths, orExactly: scope.rootFolders) else { continue }
            sessions.append(LiveSession(
                pid: file.pid,
                sessionId: file.sessionId,
                cwd: file.cwd,
                name: file.name ?? String(file.sessionId.prefix(8)),
                kind: file.kind.flatMap(SessionKind.init) ?? .unknown,
                status: file.status.flatMap(LiveStatus.init) ?? .unknown,
                startedAt: Date(timeIntervalSince1970: file.startedAt / 1000),
                statusUpdatedAt: file.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                isAlive: Self.isProcessAlive(file.pid)
            ))
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// Scans transcripts for the given repos. Re-reads only bytes appended since the previous scan.
    public func scanTranscripts(scope: ClaudeScope, previous: ClaudeScan) throws -> ClaudeScan {
        let projects = (home as NSString).appendingPathComponent("projects")
        let fileManager = FileManager.default
        guard let projectNames = try? fileManager.contentsOfDirectory(atPath: projects) else { return previous }
        var scan = ClaudeScan()
        for project in projectNames where ClaudePaths.projectDirectory(project, belongsTo: scope.repoPaths, exactRoots: scope.rootFolders) {
            let projectPath = (projects as NSString).appendingPathComponent(project)
            guard let files = try? fileManager.contentsOfDirectory(atPath: projectPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = (projectPath as NSString).appendingPathComponent(file)
                guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                      let size = (attributes[.size] as? NSNumber)?.int64Value,
                      let modified = attributes[.modificationDate] as? Date else { continue }
                var summary = previous.summaries[path] ?? SessionSummary(sessionId: String(file.dropLast(".jsonl".count)), filePath: path)
                if summary.scannedBytes == size, summary.fileModifiedAt == modified {
                    scan.summaries[path] = summary
                    continue
                }
                if size < summary.scannedBytes {
                    summary = SessionSummary(sessionId: summary.sessionId, filePath: path)
                }
                try TranscriptScanner.scan(fileURL: URL(fileURLWithPath: path), into: &summary)
                summary.fileModifiedAt = modified
                summary.lastActivityAt = modified
                if summary.firstActivityAt == nil { summary.firstActivityAt = attributes[.creationDate] as? Date }
                scan.summaries[path] = summary
            }
        }
        return scan
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private struct LiveFile: Decodable {
        var pid: Int32
        var sessionId: String
        var cwd: String
        var name: String?
        var kind: String?
        var status: String?
        var startedAt: Double
        var statusUpdatedAt: Double?
    }
}

public enum TranscriptScanner {
    private static let chunkSize = 1 << 20
    private static let newline = Data("\n".utf8)
    private static let recordPrefix = Data("{\"parentUuid\"".utf8)
    private static let typePrefix = Data("{\"type\":\"".utf8)
    private static let humanMarker = Data("\"kind\":\"human\"".utf8)
    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)
    private static let prLinkPrefix = Data("{\"type\":\"pr-link\"".utf8)
    private static let titlePrefix = Data("{\"type\":\"ai-title\"".utf8)
    private static let costPrefix = Data("{\"type\":\"cost-state\"".utf8)
    private static let relocatedPrefix = Data("{\"type\":\"relocated\"".utf8)
    private static let worktreePrefix = Data("{\"type\":\"worktree-state\"".utf8)

    public static func scan(fileURL: URL, into summary: inout SessionSummary) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(summary.scannedBytes))
        let decoder = JSON.decoder()
        var buffer = Data()
        var consumed = summary.scannedBytes
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newlineRange = buffer.range(of: newline, in: start..<buffer.endIndex) {
                let line = buffer[start..<newlineRange.lowerBound]
                consume(line, into: &summary, decoder: decoder)
                consumed += Int64(newlineRange.upperBound - start)
                start = newlineRange.upperBound
            }
            buffer = Data(buffer[start...])
        }
        summary.scannedBytes = consumed
    }

    private static func consume(_ line: Data, into summary: inout SessionSummary, decoder: JSONDecoder) {
        if line.starts(with: recordPrefix) {
            if line.range(of: humanMarker) != nil, let record = try? decoder.decode(UserRecord.self, from: line) {
                summary.humanPrompts += 1
                if summary.cwd == nil { summary.cwd = record.cwd }
                if let branch = record.gitBranch, !branch.isEmpty, branch != "HEAD", !summary.branches.contains(branch) { summary.branches.append(branch) }
                if let timestamp = record.timestamp {
                    if summary.firstActivityAt.map({ timestamp < $0 }) ?? true { summary.firstActivityAt = timestamp }
                }
            } else if line.range(of: assistantMarker) != nil {
                summary.assistantMessages += 1
            }
            return
        }
        guard line.starts(with: typePrefix) else { return }
        if line.starts(with: prLinkPrefix), let record = try? decoder.decode(PRLinkRecord.self, from: line) {
            let ref = PullRequestRef(repo: record.prRepository, number: record.prNumber, url: record.prUrl)
            if !summary.prLinks.contains(ref) { summary.prLinks.append(ref) }
        } else if line.starts(with: titlePrefix), let record = try? decoder.decode(TitleRecord.self, from: line) {
            summary.title = record.aiTitle
        } else if line.starts(with: costPrefix), let record = try? decoder.decode(CostRecord.self, from: line) {
            summary.costUSD = record.totalCostUSD
            summary.linesAdded = record.totalLinesAdded
            summary.linesRemoved = record.totalLinesRemoved
            summary.totalDurationMs = record.totalDuration
        } else if line.starts(with: relocatedPrefix), let record = try? decoder.decode(RelocatedRecord.self, from: line) {
            addPath(record.relocatedCwd, to: &summary)
        } else if line.starts(with: worktreePrefix), let record = try? decoder.decode(WorktreeRecord.self, from: line) {
            addPath(record.worktreeSession?.worktreePath, to: &summary)
        }
    }

    private static func addPath(_ path: String?, to summary: inout SessionSummary) {
        guard let path, !path.isEmpty, !summary.worktreePaths.contains(path) else { return }
        summary.worktreePaths.append(path)
    }

    private struct UserRecord: Decodable {
        var timestamp: Date?
        var gitBranch: String?
        var cwd: String?
    }

    private struct PRLinkRecord: Decodable {
        var prNumber: Int
        var prUrl: String
        var prRepository: String
    }

    private struct TitleRecord: Decodable { var aiTitle: String }

    private struct CostRecord: Decodable {
        var totalCostUSD: Double?
        var totalLinesAdded: Int?
        var totalLinesRemoved: Int?
        var totalDuration: Int?
    }

    private struct RelocatedRecord: Decodable { var relocatedCwd: String? }

    private struct WorktreeRecord: Decodable {
        var worktreeSession: WorktreeSession?
        struct WorktreeSession: Decodable { var worktreePath: String? }
    }
}
