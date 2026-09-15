import Foundation

public enum ReviewVerdict: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"

    public var id: Self { self }

    public var title: String {
        switch self {
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        case .comment: return "Comment only"
        }
    }

    /// GitHub requires a body on everything but an approval.
    public var needsBody: Bool { self != .approve }
}

public enum CommentSeverity: String, Codable, Sendable, Hashable, CaseIterable {
    case blocker, major, minor, nit, question

    public var title: String {
        switch self {
        case .blocker: return "Blocker"
        case .major: return "Major"
        case .minor: return "Minor"
        case .nit: return "Nit"
        case .question: return "Question"
        }
    }

    /// What makes a verdict "request changes" rather than a pile of suggestions.
    public var isBlocking: Bool { self == .blocker || self == .major }

    /// Most severe first, for sorting a list of findings.
    public var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
}

/// One finding exactly as the model reported it, before the app checks it against the diff.
public struct ProposedComment: Sendable, Hashable {
    public var path: String
    public var line: Int
    public var side: DiffSide
    /// The line the model says it is pointing at, copied verbatim. Models miscount hunk offsets, so this
    /// is what the line number is corrected against.
    public var lineText: String
    public var severity: CommentSeverity
    public var body: String

    public init(path: String, line: Int, side: DiffSide = .right, lineText: String = "", severity: CommentSeverity = .minor, body: String) {
        self.path = path
        self.line = line
        self.side = side
        self.lineText = lineText
        self.severity = severity
        self.body = body
    }
}

public struct ReviewOutput: Sendable, Hashable {
    public var verdict: ReviewVerdict
    public var summary: String
    public var comments: [ProposedComment]
    /// Nothing parsed and `summary` is the model's raw prose. The review is still shown and can still be
    /// submitted as a body: text the user paid for is never thrown away.
    public var isFallback: Bool

    public init(verdict: ReviewVerdict, summary: String, comments: [ProposedComment], isFallback: Bool = false) {
        self.verdict = verdict
        self.summary = summary
        self.comments = comments
        self.isFallback = isFallback
    }

    public static func fallback(raw: String) -> ReviewOutput {
        ReviewOutput(verdict: .comment, summary: raw.trimmingCharacters(in: .whitespacesAndNewlines), comments: [], isFallback: true)
    }
}

public enum ReviewOutputError: Error, CustomStringConvertible, Sendable {
    case noObject(String)

    public var description: String {
        switch self {
        case .noObject(let text): return "no review JSON in the model's answer: \(text)"
        }
    }
}

/// Reads the JSON object the review prompt asks for. Deliberately forgiving: the alternative to accepting
/// a near-miss is spending a second full review on a formatting problem.
public enum ReviewOutputParser {
    public static func parse(_ text: String) throws -> ReviewOutput {
        var best: ReviewOutput?
        for slice in JSON.objectSlices(in: text) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any],
                  let output = output(from: object) else { continue }
            // Models restate and refine, so more findings win outright and a later object wins a tie.
            if let best, output.comments.count < best.comments.count { continue }
            best = output
        }
        guard let best else { throw ReviewOutputError.noObject(String(text.suffix(2_000))) }
        return best
    }

    private static func output(from object: [String: Any]) -> ReviewOutput? {
        let rawVerdict = string(object, "verdict", "decision", "recommendation", "status")
        let summary = string(object, "summary", "overview", "overall", "description")
        let rawComments = objects(object, "comments", "findings", "issues", "notes")
        // Some other object entirely — a tool result, a fragment of the diff — rather than a review.
        guard rawVerdict != nil || summary != nil || rawComments != nil else { return nil }
        return ReviewOutput(
            verdict: verdict(rawVerdict),
            summary: (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            comments: (rawComments ?? []).compactMap(comment(from:))
        )
    }

    private static func comment(from object: [String: Any]) -> ProposedComment? {
        guard let path = string(object, "path", "file", "filename", "file_path")?.trimmingCharacters(in: .whitespaces),
              !path.isEmpty,
              let body = string(object, "body", "comment", "message", "text", "description")?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty,
              let line = int(object, "line", "line_number", "lineNumber", "end_line"), line > 0
        else { return nil }
        return ProposedComment(
            path: strippingPrefix(path),
            line: line,
            side: string(object, "side")?.uppercased() == "LEFT" ? .left : .right,
            lineText: string(object, "lineText", "line_text", "code", "snippet", "source") ?? "",
            severity: severity(string(object, "severity", "level", "kind", "type")),
            body: body
        )
    }

    /// `a/x` and `b/x` come from the diff header, `./x` from a model being tidy. GitHub wants neither.
    private static func strippingPrefix(_ path: String) -> String {
        for prefix in ["a/", "b/", "./"] where path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        return path
    }

    /// Public because it is the one piece of this parser worth asserting on directly.
    public static func verdict(_ raw: String?) -> ReviewVerdict {
        switch normalized(raw) {
        case "APPROVE", "APPROVED", "LGTM", "SHIP_IT": return .approve
        case "REQUEST_CHANGES", "CHANGES_REQUESTED", "REQUEST_CHANGE", "NEEDS_WORK", "REJECT", "REJECTED":
            return .requestChanges
        // Anything unrecognised lands on the verdict that asserts least.
        default: return .comment
        }
    }

    public static func severity(_ raw: String?) -> CommentSeverity {
        switch normalized(raw) {
        case "BLOCKER", "BLOCKING", "CRITICAL", "HIGH", "ERROR", "BUG": return .blocker
        case "MAJOR", "MEDIUM", "WARNING", "IMPORTANT": return .major
        case "MINOR", "LOW", "INFO", "SUGGESTION": return .minor
        case "NIT", "NITPICK", "STYLE", "TRIVIAL": return .nit
        case "QUESTION", "DISCUSSION", "ASK": return .question
        default: return .minor
        }
    }

    private static func normalized(_ raw: String?) -> String {
        (raw ?? "").uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_ ."))
    }

    private static func string(_ object: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let text = object[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    private static func objects(_ object: [String: Any], _ keys: String...) -> [[String: Any]]? {
        for key in keys {
            if let list = object[key] as? [[String: Any]] { return list }
            // An empty array decodes as [Any], which is still a legitimate "nothing to report".
            if let list = object[key] as? [Any] { return list.compactMap { $0 as? [String: Any] } }
        }
        return nil
    }

    /// Accepts `214`, `214.0`, `"214"`, `"L214"` and `"214-216"` — the last number wins, because GitHub's
    /// `line` is the last line of a range.
    private static func int(_ object: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            switch object[key] {
            case let number as Int: return number
            case let number as Double: return Int(number)
            case let text as String:
                var digits = ""
                var last: Int?
                for character in text {
                    if character.isNumber {
                        digits.append(character)
                    } else if !digits.isEmpty {
                        last = Int(digits)
                        digits = ""
                    }
                }
                if let value = Int(digits) ?? last { return value }
            default: continue
            }
        }
        return nil
    }
}
