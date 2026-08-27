import Foundation

public enum TimeText {
    /// "45m", "3.5h", "2.1d". Nil reads as an en dash.
    public static func duration(_ interval: TimeInterval?) -> String {
        guard let interval else { return "–" }
        let minutes = interval / 60
        if minutes < 60 { return "\(max(Int(minutes), 0))m" }
        let hours = minutes / 60
        if hours < 48 { return String(format: "%.1fh", hours) }
        return String(format: "%.1fd", hours / 24)
    }

    public static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "–" }
        return duration(now.timeIntervalSince(date))
    }
}
