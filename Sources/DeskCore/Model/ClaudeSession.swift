import Foundation

public enum LiveStatus: String, Codable, Sendable {
    case idle, busy, shell, unknown
}

public enum SessionKind: String, Codable, Sendable {
    case interactive, bg, unknown
}

public struct LiveSession: Codable, Sendable, Hashable, Identifiable {
    public var id: String { sessionId }
    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    public var name: String
    public var kind: SessionKind
    public var status: LiveStatus
    public var startedAt: Date
    public var statusUpdatedAt: Date?
    public var isAlive: Bool

    public init(
        pid: Int32, sessionId: String, cwd: String, name: String, kind: SessionKind, status: LiveStatus,
        startedAt: Date, statusUpdatedAt: Date?, isAlive: Bool
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.kind = kind
        self.status = status
        self.startedAt = startedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.isAlive = isAlive
    }

    /// Idle after activity means the session finished its turn and waits for input.
    public var waitsForInput: Bool { isAlive && status == .idle }
}

public struct PullRequestRef: Codable, Sendable, Hashable {
    public var repo: String
    public var number: Int
    public var url: String

    public init(repo: String, number: Int, url: String) {
        self.repo = repo
        self.number = number
        self.url = url
    }
}

public struct SessionSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String { sessionId }
    public var sessionId: String
    public var filePath: String
    public var cwd: String?
    public var branches: [String]
    public var worktreePaths: [String]
    public var title: String?
    public var prLinks: [PullRequestRef]
    public var firstActivityAt: Date?
    public var lastActivityAt: Date?
    public var humanPrompts: Int
    public var assistantMessages: Int
    public var costUSD: Double?
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var totalDurationMs: Int?
    public var scannedBytes: Int64
    public var fileModifiedAt: Date?

    public init(sessionId: String, filePath: String) {
        self.sessionId = sessionId
        self.filePath = filePath
        self.cwd = nil
        self.branches = []
        self.worktreePaths = []
        self.title = nil
        self.prLinks = []
        self.firstActivityAt = nil
        self.lastActivityAt = nil
        self.humanPrompts = 0
        self.assistantMessages = 0
        self.costUSD = nil
        self.linesAdded = nil
        self.linesRemoved = nil
        self.totalDurationMs = nil
        self.scannedBytes = 0
        self.fileModifiedAt = nil
    }

    public var displayName: String { title ?? (cwd as NSString?)?.lastPathComponent ?? String(sessionId.prefix(8)) }
    public var paths: [String] { [cwd].compactMap { $0 } + worktreePaths }
}
