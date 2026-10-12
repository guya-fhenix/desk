import Foundation

public enum TimeText {
    /// "45m", "3h", "2d", "3w", "5mo": whole numbers in the coarsest unit that still says something, since "161.4d"
    /// asks for arithmetic. Nil reads as an en dash.
    public static func duration(_ interval: TimeInterval?) -> String {
        guard let interval else { return "–" }
        let minutes = Int(max(interval, 0) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h" }
        let days = hours / 24
        if days < 14 { return "\(days)d" }
        if days < 60 { return "\(days / 7)w" }
        return "\(days / 30)mo"
    }

    public static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "–" }
        return duration(now.timeIntervalSince(date))
    }
}
