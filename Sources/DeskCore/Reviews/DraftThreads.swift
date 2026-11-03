import Foundation

/// Turns checked findings into the threads a draft review takes. Pure, so what gets posted is tested
/// without a network.
public enum DraftThreads {
    /// Put at the end of every comment the app posts. An HTML comment, so GitHub does not render it, and
    /// it is how a pending review is read back as Claude's rather than yours without the app keeping any
    /// record of what it posted.
    public static let marker = "<!-- fhenix-desk -->"

    /// A finding on a line of the diff goes on that line. One whose line is outside the diff, in a file the
    /// PR does change, becomes a comment on the file that names the line — GitHub would reject the whole
    /// draft over it otherwise. One about a file the PR does not touch has nowhere to go and is counted.
    public static func threads(_ comments: [DraftComment], in diff: PullRequestDiff) -> (threads: [DraftThread], unplaced: Int) {
        var threads: [DraftThread] = []
        var unplaced = 0
        for comment in comments {
            if diff.isCommentable(path: comment.path, line: comment.line, side: comment.side) {
                threads.append(DraftThread(path: comment.path, line: comment.line, side: comment.side, body: body(comment, onLine: true)))
            } else if diff.file(comment.path) != nil {
                threads.append(DraftThread(path: comment.path, line: nil, body: body(comment, onLine: false)))
            } else {
                unplaced += 1
            }
        }
        return (threads, unplaced)
    }

    /// The severity leads, so the draft reads as triage on GitHub, where the app's chips are not — on the comment's
    /// first line rather than one of its own, which keeps a comment to the three lines it is asked to fit.
    public static func body(_ comment: DraftComment, onLine: Bool) -> String {
        var header = "**\(comment.severity.title)**"
        if !onLine {
            header += " · \(comment.side == .left ? "old line" : "line") \(comment.line)"
        } else if comment.isUnverified {
            header += " · line not verified"
        }
        return "\(header) · \(comment.body)\n\n\(marker)"
    }

    /// A draft comment read back: the severity it leads with, if it leads with one, and the rest of what it says,
    /// without the marker. Reads the comments of earlier versions too, whose severity stood on a line of its own.
    public static func read(_ body: String) -> (severity: CommentSeverity?, text: String, isClaude: Bool) {
        let isClaude = body.contains(marker)
        var text = body.replacingOccurrences(of: marker, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.firstMatch(of: /^\*\*([\w-]+)\*\*/), let severity = CommentSeverity(title: String(match.output.1))
        else { return (nil, text, isClaude) }
        text = String(text[match.range.upperBound...])
        // " · body", or the older "\n\nbody"; a header note ("line 900") stays at the front of the text.
        if text.hasPrefix(" · ") { text = String(text.dropFirst(3)) }
        return (severity, text.trimmingCharacters(in: .whitespacesAndNewlines), isClaude)
    }
}

/// One comment of your pending review, read back from GitHub for the review page: where it sits, what it says, and
/// whether it is one Claude wrote.
public struct DraftReviewComment: Sendable, Hashable, Identifiable {
    public var id: String
    public var path: String
    /// Nil for a comment on the file as a whole.
    public var line: Int?
    public var severity: CommentSeverity?
    public var text: String
    public var isClaude: Bool

    public init(id: String, path: String, line: Int?, severity: CommentSeverity?, text: String, isClaude: Bool) {
        self.id = id
        self.path = path
        self.line = line
        self.severity = severity
        self.text = text
        self.isClaude = isClaude
    }
}
