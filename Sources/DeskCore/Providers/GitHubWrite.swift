import Foundation

/// One review on its way to GitHub: a verdict, a body, and the comments that can be attached to a line.
public struct ReviewSubmission: Sendable, Hashable {
    public var repo: String
    public var number: Int
    /// The head the comments were written against. GitHub validates it, which is what catches a head that
    /// moved while the user was reading.
    public var commitId: String
    public var event: ReviewVerdict
    public var body: String
    public var comments: [Inline]

    public init(repo: String, number: Int, commitId: String, event: ReviewVerdict, body: String, comments: [Inline]) {
        self.repo = repo
        self.number = number
        self.commitId = commitId
        self.event = event
        self.body = body
        self.comments = comments
    }

    public struct Inline: Sendable, Hashable {
        public var path: String
        public var line: Int
        public var side: DiffSide
        public var body: String

        public init(path: String, line: Int, side: DiffSide, body: String) {
            self.path = path
            self.line = line
            self.side = side
            self.body = body
        }
    }

    /// Pure, so the payload can be asserted on without a network.
    public func jsonBody() throws -> Data {
        var object: [String: Any] = ["commit_id": commitId, "event": event.rawValue, "body": body]
        if !comments.isEmpty {
            object["comments"] = comments.map { ["path": $0.path, "line": $0.line, "side": $0.side.rawValue, "body": $0.body] }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

public struct SubmittedReview: Sendable, Hashable {
    public var id: Int
    public var url: String
    public var state: String

    public init(id: Int, url: String, state: String) {
        self.id = id
        self.url = url
        self.state = state
    }
}

public enum GitHubWriteError: Error, CustomStringConvertible, Sendable {
    /// GitHub refused a comment's position, and takes the whole review down with it.
    case unprocessable(message: String, fields: [String])
    /// `commit_id` is not the PR's head any more.
    case staleCommit(String)
    case selfReview
    case failed(status: Int32, stderr: String)

    public var description: String {
        switch self {
        case .unprocessable(let message, let fields):
            let where_ = fields.isEmpty ? "" : " (\(fields.joined(separator: ", ")))"
            return "GitHub rejected the review\(where_): \(message)"
        case .staleCommit(let message): return "the PR head moved: \(message)"
        case .selfReview: return "GitHub does not let you approve or request changes on your own PR"
        case .failed(let status, let stderr): return "gh api exited \(status): \(stderr)"
        }
    }
}

/// The app's only write to GitHub. It lives in its own file so that fact stays auditable in one place —
/// everything in `GitHubProvider.swift` reads.
extension GitHubProvider {
    public func submitReview(_ submission: ReviewSubmission) async throws -> SubmittedReview {
        let arguments = [
            "api", "--method", "POST",
            "repos/\(submission.repo)/pulls/\(submission.number)/reviews",
            "-H", "Accept: application/vnd.github+json",
            "--input", "-",
        ]
        // No cwd: `gh api` fills {owner}/{repo} from the current directory, and this call must never
        // depend on where the process happens to be standing.
        let result = try await Shell.run(ghPath, arguments, stdin: try submission.jsonBody(), timeout: 60)
        guard result.status == 0 else {
            // Deliberately no retry, not even on a 5xx. A 502 returned after the write landed would post
            // the review twice; a duplicate from a second deliberate press is the user's decision, one
            // from a silent retry is a bug. Do not "fix" this to match the read path's retry.
            throw error(stdout: result.text, stderr: result.stderr, status: result.status)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] else {
            throw GitHubWriteError.failed(status: result.status, stderr: "unreadable response")
        }
        return SubmittedReview(
            id: object["id"] as? Int ?? 0,
            url: object["html_url"] as? String ?? "",
            state: object["state"] as? String ?? ""
        )
    }

    /// `gh api` prints the error body on stdout and exits non-zero.
    private func error(stdout: String, stderr: String, status: Int32) -> GitHubWriteError {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [String: Any] else {
            return .failed(status: status, stderr: stderr.isEmpty ? stdout : stderr)
        }
        let message = object["message"] as? String ?? ""
        let details = (object["errors"] as? [[String: Any]]) ?? []
        let fields = details.compactMap { $0["field"] as? String }
        let text = ([message] + details.compactMap { $0["message"] as? String }).joined(separator: "; ")
        if message.localizedCaseInsensitiveContains("approve your own") { return .selfReview }
        if text.localizedCaseInsensitiveContains("commit") || fields.contains("commit_id") { return .staleCommit(text) }
        return .unprocessable(message: text.isEmpty ? stdout : text, fields: fields)
    }
}
