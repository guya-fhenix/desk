import Foundation

public enum TicketStatusCategory: String, Codable, Sendable {
    case todo = "new"
    case inProgress = "indeterminate"
    case done = "done"
    case unknown

    /// Workflow order for grouping: what has not started, then what is underway, then the rest.
    public var rank: Int {
        switch self {
        case .todo: return 0
        case .inProgress: return 1
        case .unknown: return 2
        case .done: return 3
        }
    }

    public init(jiraKey: String) {
        self = TicketStatusCategory(rawValue: jiraKey) ?? .unknown
    }
}

/// Whether a ticket sits in the running sprint or waits in the backlog. Jira answers this through JQL
/// rather than a field, so it is decided by which search returned the ticket.
public enum TicketPlacement: String, Codable, Sendable {
    case sprint, backlog, unknown
}

public struct Ticket: Codable, Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var summary: String
    public var status: String
    public var category: TicketStatusCategory
    public var priority: String?
    public var url: String
    public var assignedToMe: Bool
    public var placement: TicketPlacement
    /// The Jira description as markdown. Jira sends it as a node tree; `JiraDescription` flattens it so
    /// the same renderer that draws a pull request body can draw this.
    public var description: String

    public init(
        key: String, summary: String, status: String, category: TicketStatusCategory,
        priority: String? = nil, url: String, assignedToMe: Bool, placement: TicketPlacement = .unknown,
        description: String = ""
    ) {
        self.key = key
        self.summary = summary
        self.status = status
        self.category = category
        self.priority = priority
        self.url = url
        self.assignedToMe = assignedToMe
        self.placement = placement
        self.description = description
    }
}
