import Foundation

/// Finds Jira keys like PRO-391 in branch names, titles, and paths.
/// `Regex` is immutable after compilation, so sharing it across threads is safe.
public struct TicketKeyMatcher: @unchecked Sendable {
    private let regex: Regex<(Substring, Substring, Substring)>

    public init(projectKeys: [String]) {
        let alternatives = projectKeys
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // Not `\b`, which counts `_` as part of a word: `PRO-123_add_gauge` is a branch name people write.
        let pattern = alternatives.isEmpty ? "(?!x)x()()" : "(?i)(?:^|[^A-Za-z0-9])(\(alternatives))-(\\d{1,6})(?![A-Za-z0-9])"
        // Every alternative is regex-escaped, so the pattern always compiles.
        regex = try! Regex(pattern, as: (Substring, Substring, Substring).self)
    }

    /// Returns unique keys, uppercased, in order of appearance.
    public func keys(in text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for match in text.matches(of: regex) {
            let key = "\(match.output.1.uppercased())-\(match.output.2)"
            if seen.insert(key).inserted { result.append(key) }
        }
        return result
    }

    public func keys(in texts: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for text in texts {
            for key in keys(in: text) where seen.insert(key).inserted { result.append(key) }
        }
        return result
    }
}
