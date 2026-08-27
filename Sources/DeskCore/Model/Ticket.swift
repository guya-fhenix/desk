import Foundation

public enum TicketStatusCategory: String, Codable, Sendable {
    case todo = "new"
    case inProgress = "indeterminate"
    case done = "done"
    case unknown

    public init(jiraKey: String) {
        self = TicketStatusCategory(rawValue: jiraKey) ?? .unknown
    }
}

public struct Ticket: Codable, Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var summary: String
    public var status: String
    public var category: TicketStatusCategory
    public var priority: String?
    public var url: String
    public var updatedAt: Date
    public var assignedToMe: Bool

    public init(
        key: String, summary: String, status: String, category: TicketStatusCategory,
        priority: String? = nil, url: String, updatedAt: Date, assignedToMe: Bool
    ) {
        self.key = key
        self.summary = summary
        self.status = status
        self.category = category
        self.priority = priority
        self.url = url
        self.updatedAt = updatedAt
        self.assignedToMe = assignedToMe
    }
}
