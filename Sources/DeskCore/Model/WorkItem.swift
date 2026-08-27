import Foundation

public struct WorkItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var ticketKey: String?
    public var ticket: Ticket?
    public var pullRequests: [PullRequest]
    public var worktrees: [Worktree]
    public var sessions: [SessionSummary]
    public var liveSessions: [LiveSession]

    public init(
        id: String, ticketKey: String? = nil, ticket: Ticket? = nil, pullRequests: [PullRequest] = [],
        worktrees: [Worktree] = [], sessions: [SessionSummary] = [], liveSessions: [LiveSession] = []
    ) {
        self.id = id
        self.ticketKey = ticketKey
        self.ticket = ticket
        self.pullRequests = pullRequests
        self.worktrees = worktrees
        self.sessions = sessions
        self.liveSessions = liveSessions
    }

    public var title: String {
        if let ticket { return "\(ticket.key) \(ticket.summary)" }
        if let ticketKey { return ticketKey }
        return pullRequests.first?.title ?? id
    }

    public var claudeCostUSD: Double { sessions.compactMap(\.costUSD).reduce(0, +) }
    public var claudeDuration: TimeInterval { Double(sessions.compactMap(\.totalDurationMs).reduce(0, +)) / 1000 }
    public var linesAdded: Int { sessions.compactMap(\.linesAdded).reduce(0, +) }
    public var linesRemoved: Int { sessions.compactMap(\.linesRemoved).reduce(0, +) }
    public var lastActivityAt: Date? {
        (pullRequests.map(\.updatedAt) + sessions.compactMap(\.lastActivityAt) + worktrees.compactMap(\.lastCommitAt)).max()
    }
}
