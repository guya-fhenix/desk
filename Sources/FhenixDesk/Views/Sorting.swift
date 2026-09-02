import Foundation

/// Sorts an optional column such as a detached worktree's branch or a missing median. Absent values come first
/// ascending, so the rows that lack the value stay together rather than being dropped from the order.
struct OptionalComparator<Value: Comparable>: SortComparator {
    var order: SortOrder = .forward

    func compare(_ lhs: Value?, _ rhs: Value?) -> ComparisonResult {
        let result: ComparisonResult
        switch (lhs, rhs) {
        case (nil, nil): result = .orderedSame
        case (nil, _): result = .orderedAscending
        case (_, nil): result = .orderedDescending
        case let (lhs?, rhs?): result = lhs < rhs ? .orderedAscending : lhs == rhs ? .orderedSame : .orderedDescending
        }
        return order == .forward ? result : result.reversed
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
