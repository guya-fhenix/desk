import Foundation

/// One of your Claude plan's usage limits, for the sidebar: how much of it is gone and when it starts over.
public struct ClaudeLimit: Sendable, Hashable, Identifiable {
    public var name: String
    public var percent: Int
    /// When the window starts over; nil once it has, until a session opens the next one.
    public var resetsAt: Date?
    public var id: String { name }

    public init(name: String, percent: Int, resetsAt: Date?) {
        self.name = name
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// The plan limits as Claude Code last handed them to the statusline. Claude Code gives them to nothing else on disk;
/// claude-meter, the statusline, keeps them in a cache — the session and week windows from the statusline's own input,
/// and the per-model weekly ones from the usage endpoint every minute. No cache, no limits: the sidebar leaves them out.
public enum ClaudeLimits {
    public static let cacheDirectory = ("~/.cache/claude-meter" as NSString).expandingTildeInPath

    public static func read(directory: String = cacheDirectory, now: Date = Date()) -> [ClaudeLimit] {
        guard let quota = fields(at: "\(directory)/quota"), quota.count >= 4,
              let session = Int(quota[0]), let week = Int(quota[1]),
              let sessionReset = TimeInterval(quota[2]), let weekReset = TimeInterval(quota[3])
        else { return [] }
        let weekEnds = Date(timeIntervalSince1970: weekReset)
        func limit(_ name: String, _ percent: Int, _ resets: Date) -> ClaudeLimit {
            // A window that ended has nothing used in it yet.
            resets > now ? .init(name: name, percent: percent, resetsAt: resets) : .init(name: name, percent: 0, resetsAt: nil)
        }
        var limits = [
            limit("Session", session, Date(timeIntervalSince1970: sessionReset)),
            limit("Week", week, weekEnds),
        ]
        // Pairs of model name and percent. Only when written this week: a fetch that has failed since leaves last week's.
        let scopedFile = "\(directory)/scoped"
        let written = (try? FileManager.default.attributesOfItem(atPath: scopedFile))?[.modificationDate] as? Date
        if let scoped = fields(at: scopedFile), let written, written >= weekEnds.addingTimeInterval(-7 * 86_400) {
            for index in stride(from: 0, to: scoped.count - 1, by: 2) where !scoped[index].isEmpty {
                if let percent = Int(scoped[index + 1]) { limits.append(limit("\(scoped[index]) week", percent, weekEnds)) }
            }
        }
        return limits
    }

    /// One cache record: fields split on the unit separator, or on `|` in claude-meter's older files.
    static func fields(at path: String) -> [String]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return line.split(separator: line.contains("\u{1F}") ? "\u{1F}" : "|", omittingEmptySubsequences: false).map(String.init)
    }
}
