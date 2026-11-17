import Foundation

/// A status of a Jira project, with the category Jira files it under: to do, in progress, or done.
public struct JiraStatus: Sendable, Hashable {
    public enum Category: Int, Sendable, Comparable, CaseIterable {
        case todo, inProgress, done

        /// From Jira's `statusCategory.key`: `new`, `indeterminate`, `done`. Anything else is to do.
        public init(key: String) {
            switch key {
            case "indeterminate": self = .inProgress
            case "done": self = .done
            default: self = .todo
            }
        }

        public var title: String {
            switch self {
            case .todo: return "To do"
            case .inProgress: return "In progress"
            case .done: return "Done"
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The three moves Desk makes on a ticket, each to a status of the project's.
    public enum Role: Sendable, CaseIterable {
        case inProgress, review, done
    }

    public var name: String
    public var category: Category

    public init(name: String, category: Category) {
        self.name = name
        self.category = category
    }

    /// By category, to do first; in the order found inside one.
    public static func ordered(_ statuses: [JiraStatus]) -> [JiraStatus] {
        statuses.enumerated().sorted { ($0.element.category, $0.offset) < ($1.element.category, $1.offset) }.map(\.element)
    }

    /// What Desk suggests for a move before you pick, from the names and categories alone: in progress, an in-progress
    /// status named for progress, else the first not about review; review, an in-progress status named for review;
    /// done, a done status named Done, else the first. Nil where nothing fits: you pick.
    public static func suggested(_ role: Role, in statuses: [JiraStatus]) -> String? {
        let working = statuses.filter { $0.category == .inProgress }
        let review = { (status: JiraStatus) in status.name.localizedCaseInsensitiveContains("review") }
        switch role {
        case .inProgress:
            return (working.first { $0.name.localizedCaseInsensitiveContains("progress") } ?? working.first { !review($0) })?.name
        case .review:
            return working.first(where: review)?.name
        case .done:
            let done = statuses.filter { $0.category == .done }
            return (done.first { $0.name.caseInsensitiveCompare("Done") == .orderedSame } ?? done.first)?.name
        }
    }
}
