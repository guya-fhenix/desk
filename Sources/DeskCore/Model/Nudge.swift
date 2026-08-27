import Foundation

public enum NudgeKind: String, Codable, Sendable {
    case ciFailed, changesRequested, readyToMerge, needsRebase, stalePullRequest
    case reviewRequested, botReviews, claudeWaiting, unpushedWork
}

public enum NudgeSeverity: Int, Codable, Sendable, Comparable {
    case info = 0, warning = 1, urgent = 2

    public static func < (lhs: NudgeSeverity, rhs: NudgeSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Nudge: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: NudgeKind
    public var severity: NudgeSeverity
    public var title: String
    public var detail: String
    public var url: String?
    public var path: String?

    public init(id: String, kind: NudgeKind, severity: NudgeSeverity, title: String, detail: String, url: String? = nil, path: String? = nil) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.url = url
        self.path = path
    }
}
