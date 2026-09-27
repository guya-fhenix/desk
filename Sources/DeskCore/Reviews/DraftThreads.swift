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

    /// The severity leads, so the draft reads as triage on GitHub, where the app's chips are not.
    public static func body(_ comment: DraftComment, onLine: Bool) -> String {
        var header = "**\(comment.severity.title)**"
        if !onLine {
            header += " · \(comment.side == .left ? "old line" : "line") \(comment.line)"
        } else if comment.isUnverified {
            header += " · line not verified"
        }
        return "\(header)\n\n\(comment.body)\n\n\(marker)"
    }
}
