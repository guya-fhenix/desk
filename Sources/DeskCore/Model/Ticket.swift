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
    /// Who it is assigned to, by Jira display name; nil when nobody is.
    public var assignee: String?
    /// The assignee's Jira picture, a public URL.
    public var assigneeAvatar: String?
    /// Who opened the ticket: Jira's reporter, by display name.
    public var reporter: String?
    public var placement: TicketPlacement
    /// The Jira description as markdown. Jira sends it as a node tree; `JiraDescription` flattens it so
    /// the same renderer that draws a pull request body can draw this.
    public var description: String
    /// Whether `description` holds everything Jira's does, so editing it here and saving loses nothing. False for one
    /// with mentions, images, panels and the like, which is then edited in Jira.
    public var descriptionEditable: Bool

    public init(
        key: String, summary: String, status: String, category: TicketStatusCategory,
        priority: String? = nil, url: String, assignedToMe: Bool, assignee: String? = nil, assigneeAvatar: String? = nil,
        reporter: String? = nil, placement: TicketPlacement = .unknown,
        description: String = "", descriptionEditable: Bool = true
    ) {
        self.key = key
        self.summary = summary
        self.status = status
        self.category = category
        self.priority = priority
        self.url = url
        self.assignedToMe = assignedToMe
        self.assignee = assignee
        self.assigneeAvatar = assigneeAvatar
        self.reporter = reporter
        self.placement = placement
        self.description = description
        self.descriptionEditable = descriptionEditable
    }
}

/// What this app last wrote to a ticket, as it expects Jira to show it; a field left nil was not written.
public struct TicketEdit: Sendable, Equatable {
    public var status: String?
    public var category: TicketStatusCategory?
    public var summary: String?
    public var description: String?

    public init(status: String? = nil, category: TicketStatusCategory? = nil, summary: String? = nil, description: String? = nil) {
        self.status = status
        self.category = category
        self.summary = summary
        self.description = description
    }

    /// This edit with a later one's fields over it, so a move and then an edit are both kept.
    public func merging(_ later: TicketEdit) -> TicketEdit {
        TicketEdit(
            status: later.status ?? status, category: later.category ?? category, summary: later.summary ?? summary,
            description: later.description ?? description
        )
    }
}

/// Someone with Jira tickets, as the assignee filter shows them.
public struct TicketPerson: Hashable, Sendable, Identifiable {
    public var name: String
    public var avatar: String?
    public var id: String { name }

    public init(name: String, avatar: String? = nil) {
        self.name = name
        self.avatar = avatar
    }
}

/// One choice in the Jira screen's assignee filter: you, nobody, or someone by Jira display name. The raw value is
/// what the screen remembers.
public enum TicketAssignee: Hashable, Sendable, RawRepresentable {
    case me, unassigned, person(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "me": self = .me
        case "unassigned": self = .unassigned
        case let raw where raw.hasPrefix("person:"): self = .person(String(raw.dropFirst("person:".count)))
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .me: return "me"
        case .unassigned: return "unassigned"
        case .person(let name): return "person:\(name)"
        }
    }

    public func matches(_ ticket: Ticket) -> Bool {
        switch self {
        case .me: return ticket.assignedToMe
        case .unassigned: return !ticket.assignedToMe && ticket.assignee == nil
        case .person(let name): return !ticket.assignedToMe && ticket.assignee == name
        }
    }
}
