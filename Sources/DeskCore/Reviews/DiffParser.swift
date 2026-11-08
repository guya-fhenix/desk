import Foundation

/// Parses the unified diff `gh pr diff` prints. Pure, because every line number the review screen shows,
/// and every line a session's link lands on, comes out of here.
public enum DiffParser {
    public static func parse(_ text: String) -> [DiffFile] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        var files: [DiffFile] = []
        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("diff --git ") else {
                index += 1
                continue
            }
            let parsed = file(lines, from: index)
            if let file = parsed.file { files.append(file) }
            index = parsed.next
        }
        return files
    }

    /// One `diff --git` block. Returns where the next one starts, so a block this cannot make sense of
    /// costs only itself.
    private static func file(_ lines: [String], from start: Int) -> (file: DiffFile?, next: Int) {
        var index = start
        let fallback = headerPaths(lines[index])
        index += 1
        var oldPath: String?
        var newPath: String?
        var previousPath: String?
        var status: DiffFileStatus?
        var isBinary = false

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git ") || line.hasPrefix("@@") { break }
            if line.hasPrefix("new file mode") {
                status = .added
            } else if line.hasPrefix("deleted file mode") {
                status = .removed
            } else if line.hasPrefix("rename from ") {
                previousPath = GitParsing.unquotePath(String(line.dropFirst("rename from ".count)))
                status = .renamed
            } else if line.hasPrefix("rename to ") {
                newPath = GitParsing.unquotePath(String(line.dropFirst("rename to ".count)))
                status = .renamed
            } else if line.hasPrefix("copy from ") {
                previousPath = GitParsing.unquotePath(String(line.dropFirst("copy from ".count)))
            } else if line.hasPrefix("copy to ") {
                newPath = GitParsing.unquotePath(String(line.dropFirst("copy to ".count)))
                status = status ?? .added
            } else if line.hasPrefix("--- ") {
                oldPath = path(fromMarker: line)
            } else if line.hasPrefix("+++ ") {
                newPath = path(fromMarker: line)
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                isBinary = true
            }
            index += 1
        }

        var hunks: [DiffHunk] = []
        var additions = 0
        var deletions = 0

        while index < lines.count, lines[index].hasPrefix("@@") {
            guard let head = hunkHeader(lines[index]) else { break }
            index += 1
            var remainingOld = head.oldCount
            var remainingNew = head.newCount
            var oldNumber = head.oldStart
            var newNumber = head.newStart
            var body: [DiffLine] = []
            while index < lines.count, remainingOld > 0 || remainingNew > 0 {
                let raw = lines[index]
                // "\ No newline at end of file" annotates the line above and is not a line of its own.
                if raw.hasPrefix("\\") {
                    index += 1
                    continue
                }
                guard let kind = lineKind(raw) else { break }
                // A context line git wrote as " " may reach us as "" if something stripped the trailing space.
                let text = raw.isEmpty ? "" : String(raw.dropFirst())
                switch kind {
                case .added:
                    body.append(DiffLine(kind: .added, oldLine: nil, newLine: newNumber, text: text))
                    newNumber += 1
                    remainingNew -= 1
                    additions += 1
                case .removed:
                    body.append(DiffLine(kind: .removed, oldLine: oldNumber, newLine: nil, text: text))
                    oldNumber += 1
                    remainingOld -= 1
                    deletions += 1
                case .context:
                    body.append(DiffLine(kind: .context, oldLine: oldNumber, newLine: newNumber, text: text))
                    oldNumber += 1
                    newNumber += 1
                    remainingOld -= 1
                    remainingNew -= 1
                }
                index += 1
            }
            hunks.append(DiffHunk(
                oldStart: head.oldStart, oldCount: head.oldCount, newStart: head.newStart, newCount: head.newCount,
                heading: head.heading, lines: body
            ))
        }

        // Skip anything trailing that is neither a hunk nor a new file, such as a binary patch payload.
        while index < lines.count, !lines[index].hasPrefix("diff --git ") { index += 1 }

        let resolvedOld = oldPath ?? fallback.old
        let resolvedNew = newPath ?? fallback.new
        // `--- /dev/null` and `+++ /dev/null` say added and deleted as clearly as the mode lines do.
        let resolvedStatus = status ?? (oldPath == nil && newPath != nil ? .added
            : newPath == nil && oldPath != nil ? .removed : .modified)
        guard let path = resolvedStatus == .removed ? resolvedOld : (resolvedNew ?? resolvedOld) else {
            return (nil, index)
        }
        return (DiffFile(
            path: path, previousPath: previousPath ?? (resolvedStatus == .renamed ? resolvedOld : nil),
            status: resolvedStatus, isBinary: isBinary, hunks: hunks, additions: additions, deletions: deletions
        ), index)
    }

    private static func lineKind(_ raw: String) -> DiffLineKind? {
        switch raw.first {
        case "+": return .added
        case "-": return .removed
        case " ", nil: return .context
        default: return nil
        }
    }

    /// `@@ -1,2 +3,4 @@ heading`. A missing count means 1; a zero count means the hunk sits between lines.
    static func hunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String)? {
        guard line.hasPrefix("@@") else { return nil }
        let rest = line.dropFirst(2)
        guard let close = rest.range(of: "@@") else { return nil }
        let heading = String(rest[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        let parts = rest[..<close.lowerBound].split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("-"), parts[1].hasPrefix("+") else { return nil }
        guard let old = range(parts[0].dropFirst()), let new = range(parts[1].dropFirst()) else { return nil }
        return (old.start, old.count, new.start, new.count, heading)
    }

    private static func range(_ text: Substring) -> (start: Int, count: Int)? {
        let parts = text.split(separator: ",")
        guard let start = Int(parts.first ?? "") else { return nil }
        guard parts.count > 1 else { return (start, 1) }
        guard let count = Int(parts[1]) else { return nil }
        return (start, count)
    }

    /// The path from a `--- a/x` or `+++ b/x` line, or nil for `/dev/null`.
    private static func path(fromMarker line: String) -> String? {
        var value = String(line.dropFirst(4))
        if value.hasPrefix("\"") {
            value = GitParsing.unquotePath(value)
        } else if let tab = value.firstIndex(of: "\t") {
            // Some diff producers append a timestamp after a tab; git does not, but the cost of this is nil.
            value = String(value[..<tab])
        }
        guard value != "/dev/null" else { return nil }
        if value.hasPrefix("a/") || value.hasPrefix("b/") { return String(value.dropFirst(2)) }
        return value
    }

    /// Paths from the `diff --git a/x b/y` line itself, used when a change carries no `---`/`+++` pair
    /// because it only touched the file mode.
    private static func headerPaths(_ line: String) -> (old: String?, new: String?) {
        let rest = String(line.dropFirst("diff --git ".count))
        guard let split = rest.range(of: " b/", options: .backwards) else { return (nil, nil) }
        var old = String(rest[..<split.lowerBound])
        if old.hasPrefix("a/") { old.removeFirst(2) }
        let new = String(rest[split.upperBound...])
        return (GitParsing.unquotePath(old), GitParsing.unquotePath(new))
    }
}
