import Foundation

public enum NudgeKind: String, Codable, Sendable {
    case ciFailed, changesRequested, readyToMerge, needsRebase
    case reviewRequested, reviewReady
    /// A flow stage that moves only when you press something.
    case flowWaiting
    /// A flow's session is asking you something, or the flow hit a problem it will not retry on its own.
    case sessionNeedsYou

    /// Which screen handles this one.
    public var screen: NudgeScreen {
        switch self {
        case .ciFailed, .changesRequested, .readyToMerge, .needsRebase, .flowWaiting, .sessionNeedsYou:
            return .pullRequests
        case .reviewRequested, .reviewReady: return .reviews
        }
    }
}

public enum NudgeScreen: Sendable {
    case pullRequests, reviews
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
    /// The flow's session, for a nudge about one: a session that has not opened its PR yet has no url to go by.
    public var jobId: String?

    public init(
        id: String, kind: NudgeKind, severity: NudgeSeverity, title: String, detail: String, url: String? = nil, jobId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.url = url
        self.jobId = jobId
    }
}
