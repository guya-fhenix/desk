import DeskCore
import Foundation

enum Format {
    static func age(_ date: Date?, now: Date = Date()) -> String { TimeText.age(date, now: now) }

    /// The exact moment an age stands for, for its tooltip.
    static func date(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .shortened) ?? "–" }

    static func usd(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value < 10 ? String(format: "$%.2f", value) : String(format: "$%.0f", value)
    }

    static func sizeBucket(_ lines: Int) -> String {
        switch lines {
        case ..<20: return "XS"
        case ..<100: return "S"
        case ..<300: return "M"
        case ..<800: return "L"
        default: return "XL"
        }
    }
}
