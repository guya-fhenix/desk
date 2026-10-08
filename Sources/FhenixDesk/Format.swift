import DeskCore
import Foundation

enum Format {
    static func age(_ date: Date?, now: Date = Date()) -> String { TimeText.age(date, now: now) }

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
