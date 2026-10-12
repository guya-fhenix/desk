import Foundation

/// How well a typed query matches a line of text, for Search (⌘K): loosely, so a half-remembered title still finds
/// its PR, and ranked, so the closest match comes first.
public enum FuzzyMatch {
    /// Higher is better; nil is no match. A prefix beats a word start, which beats a substring, which beats every
    /// word appearing somewhere, which beats the letters merely appearing in order — the last only for three letters
    /// or more, since two letters appear in order in nearly every title.
    public static func score(_ text: String, _ query: String) -> Int? {
        let text = text.lowercased()
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        if text.hasPrefix(query) { return 400 }
        if text.range(of: query) != nil {
            let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return words.contains { $0.hasPrefix(query) } ? 300 : 200
        }
        let words = query.split(whereSeparator: \.isWhitespace)
        if words.count > 1, words.allSatisfy({ text.contains($0) }) { return 100 }
        let letters = query.filter { !$0.isWhitespace }
        guard letters.count >= 3 else { return nil }
        var rest = text[...]
        for letter in letters {
            guard let found = rest.firstIndex(of: letter) else { return nil }
            rest = rest[rest.index(after: found)...]
        }
        return 10
    }
}
