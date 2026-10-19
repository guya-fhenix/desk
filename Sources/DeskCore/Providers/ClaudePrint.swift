import Foundation

/// What one `claude -p --output-format json` run reports about itself.
public struct ClaudeResult: Sendable, Hashable {
    /// "success", or an error kind such as "error_during_execution".
    public var subtype: String
    public var isError: Bool
    /// The model's final message: the JSON object a review is asked for.
    public var result: String
    public var costUSD: Double
    public var numTurns: Int
    public var durationMs: Int
    public var sessionId: String
    /// Tools a permission rule refused. The first thing to look at when a review comes back thin.
    public var permissionDenials: [String]

    public init(
        subtype: String, isError: Bool, result: String, costUSD: Double,
        numTurns: Int = 0, durationMs: Int = 0, sessionId: String = "", permissionDenials: [String] = []
    ) {
        self.subtype = subtype
        self.isError = isError
        self.result = result
        self.costUSD = costUSD
        self.numTurns = numTurns
        self.durationMs = durationMs
        self.sessionId = sessionId
        self.permissionDenials = permissionDenials
    }
}

public enum ClaudePrintError: Error, CustomStringConvertible, Sendable {
    case noResult(String)

    public var description: String {
        switch self {
        case .noResult(let output): return "claude printed no result object: \(output)"
        }
    }
}

/// Reads the envelope `claude -p --output-format json` ends with.
public enum ClaudePrint {
    /// The last top-level object whose `type` is `result`. Tolerant of anything printed before it, because
    /// a hook or a version notice writes to the same stdout.
    public static func result(_ stdout: String, stderr: String = "") throws -> ClaudeResult {
        for slice in JSON.objectSlices(in: stdout).reversed() {
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(slice.utf8)),
                  envelope.type == "result" else { continue }
            return ClaudeResult(
                subtype: envelope.subtype ?? "unknown",
                isError: envelope.isError ?? false,
                result: envelope.result ?? "",
                costUSD: envelope.costUSD ?? 0,
                numTurns: envelope.numTurns ?? 0,
                durationMs: envelope.durationMs ?? 0,
                sessionId: envelope.sessionId ?? "",
                permissionDenials: (envelope.denials ?? []).compactMap(\.toolName)
            )
        }
        let output = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        throw ClaudePrintError.noResult(String(output.suffix(2_000)))
    }

    /// Every field is optional and decoded defensively: one unexpected shape must not cost us the cost
    /// figure and the review text sitting next to it.
    private struct Envelope: Decodable {
        var type: String?
        var subtype: String?
        var isError: Bool?
        var result: String?
        var costUSD: Double?
        var numTurns: Int?
        var durationMs: Int?
        var sessionId: String?
        var denials: [Denial]?

        enum CodingKeys: String, CodingKey {
            case type, subtype, result
            case isError = "is_error"
            case costUSD = "total_cost_usd"
            case numTurns = "num_turns"
            case durationMs = "duration_ms"
            case sessionId = "session_id"
            case denials = "permission_denials"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func value<T: Decodable>(_ key: CodingKeys) -> T? {
                (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
            }
            type = value(.type)
            subtype = value(.subtype)
            isError = value(.isError)
            result = value(.result)
            costUSD = value(.costUSD)
            numTurns = value(.numTurns)
            durationMs = value(.durationMs)
            sessionId = value(.sessionId)
            denials = value(.denials)
        }

        struct Denial: Decodable {
            var toolName: String?
            enum CodingKeys: String, CodingKey { case toolName = "tool_name" }
        }
    }
}
