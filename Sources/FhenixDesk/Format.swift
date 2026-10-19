import DeskCore
import Foundation

enum Format {
    static func age(_ date: Date?, now: Date = Date()) -> String { TimeText.age(date, now: now) }

    /// The exact moment an age stands for, for its tooltip.
    static func date(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .shortened) ?? "–" }

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
