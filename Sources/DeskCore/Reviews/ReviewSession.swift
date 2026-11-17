import Foundation

/// `fhenixdesk://show/<owner>/<repo>/<number>/<new|old>/<line>/<path>`: a review session opens one, through
/// `DeskService.showHelper`, to move the diff beside it to a line. A path rather than a query, so it needs no quoting in a shell, where `?` and `&`
/// would.
public struct DeskLink: Equatable, Sendable {
    public static let scheme = "fhenixdesk"

    /// owner/name
    public var repo: String
    public var number: Int
    public var side: DiffSide
    public var line: Int
    public var path: String

    public init(repo: String, number: Int, side: DiffSide, line: Int, path: String) {
        self.repo = repo
        self.number = number
        self.side = side
        self.line = line
        self.path = path
    }

    /// Nil for anything that is not a well-formed show link. Any app can open one, so a link only ever moves the
    /// diff: it never acts.
    public init?(_ url: URL) {
        guard url.scheme == Self.scheme, url.host == "show" else { return nil }
        let parts = url.path.split(separator: "/", maxSplits: 5).map(String.init)
        guard parts.count == 6, let number = Int(parts[2]), let line = Int(parts[4]),
              let side = ["new": DiffSide.right, "old": .left][parts[3]]
        else { return nil }
        self.init(repo: "\(parts[0])/\(parts[1])", number: number, side: side, line: line, path: parts[5])
    }

    /// `owner/name#number`, as `ClaudeJobs.prKey` writes a PR's url.
    public var prKey: String { "\(repo.lowercased())#\(number)" }
}

/// PRs reviewed together in one session, any repos and authors — a stack, a ticket's PRs, or ones picked by hand — with
/// what the reviewer wants looked at.
public struct ReviewGroup: Sendable, Equatable, Identifiable {
    public var pullRequests: [PullRequest]
    public var notes: String

    public init(pullRequests: [PullRequest], notes: String = "") {
        self.pullRequests = pullRequests
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same PRs are the same group, whatever order they were picked in.
    public var id: String { pullRequests.map(\.url).sorted().joined(separator: " ") }

    public func contains(_ url: String) -> Bool { pullRequests.contains { $0.url == url } }

    /// The group's PRs base first within each repo's stacks, the repos in the order their first PR was picked.
    public static func ordered(_ pullRequests: [PullRequest], parents: [String: String]) -> [PullRequest] {
        var repos: [String] = []
        for pr in pullRequests where !repos.contains(pr.repo) { repos.append(pr.repo) }
        let byNumber = [KeyPathComparator(\StackedPullRequest.pullRequest.number)]
        return repos.flatMap { repo in
            Linker.stacked(pullRequests.filter { $0.repo == repo }, parents: parents, order: byNumber).map(\.pullRequest)
        }
    }
}

extension DeskState {
    /// The open PR a show link names, out of every search; nil for one Desk does not know.
    public func pullRequest(for link: DeskLink) -> PullRequest? {
        (reviewRequests + openForReview + (github?.allOpen ?? [])).first { ClaudeJobs.prKey($0.url) == link.prKey }
    }
}

extension DeskService {
    /// The one command a review session may run without asking. It opens a single show link and nothing else, where an
    /// allowed `open` also opened any URL or file added after the link. In the per-user temporary folder, whose path
    /// has no spaces: Claude Code matches a rule against the command's text, and a quoted path would not match.
    public static let showHelper = FileManager.default.temporaryDirectory.appending(path: "fhenix-desk/desk-show")

    /// Writes `showHelper` before a review session starts, when it is missing or differs: the system clears the
    /// temporary folder now and then.
    public static func installShowHelper() throws {
        let script = """
        #!/bin/sh
        [ $# -eq 1 ] || exit 64
        case "$1" in *[[:space:]]*) exit 64;; \(DeskLink.scheme)://show/*) exec /usr/bin/open -u "$1";; esac
        exit 64

        """
        try FileManager.default.createDirectory(at: showHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? String(contentsOf: showHelper, encoding: .utf8)) != script {
            try Data(script.utf8).write(to: showHelper, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: showHelper.path)
    }

    /// What a review session is told on top of its own instructions: how to move the diff beside it. Fixed, not a
    /// Settings prompt, because the app parses what comes back.
    public static func reviewLinkInstructions(for pr: PullRequest) -> String {
        """
        Fhenix Desk shows the diff of \(pr.url) beside you, and that is how the reviewer moves through the code. \
        Whenever you point at a specific line of that diff, also move their view there by running exactly this \
        command, without quotes: \(showHelper.path) \(DeskLink.scheme)://show/\(pr.repo)/\(pr.number)/<side>/<line>/<path> — \
        <side> is new for an added or unchanged line (its number in the new file) and old for a removed line (its \
        number in the old file); <path> is the file's path as the diff shows it. Lines the reviewer selects in the \
        diff arrive pasted into your input, with their path and line numbers.
        """
    }

    /// The arguments of the regular `claude` a review runs in its own pane in iTerm. The allowed `showHelper` is what
    /// lets the session move the diff without asking each time; the prompt goes last, because `--allowedTools` takes
    /// every argument after it up to the next option.
    /// For a clone whose sessions have no `review-teammate-task` yet: one PR on `review-pr`, and the ticket it is for.
    public static func reviewArguments(for pr: PullRequest, ticket: String?) -> [String] {
        let prompt = "/fhenix-workflow:\(ClaudePlugins.reviewPR) \(pr.url)" + (ticket.map { "\n\nThe ticket it is for:\n\n\($0)" } ?? "")
        return [
            "--allowedTools", "Bash(\(showHelper.path) *)",
            "--append-system-prompt", reviewLinkInstructions(for: pr),
            prompt,
        ]
    }

    /// How a session reviewing several PRs moves the diff: the same link, naming the PR the line belongs to.
    public static func groupLinkInstructions(for pullRequests: [PullRequest]) -> String {
        """
        Fhenix Desk shows the diff of the PR you are on beside you: \(pullRequests.map(\.url).joined(separator: ", ")). \
        That is how the reviewer moves through the code. Whenever you point at a specific line, also move their view \
        there by running exactly this command, without quotes: \(showHelper.path) \
        \(DeskLink.scheme)://show/<owner>/<repo>/<number>/<side>/<line>/<path> — <owner>/<repo>/<number> names the PR \
        the line belongs to; <side> is new for an added or unchanged line (its number in the new file) and old for a \
        removed line (its number in the old file); <path> is the file's path as the diff shows it. Lines the reviewer \
        selects in the diff arrive pasted into your input, with their PR, path and line numbers.
        """
    }

    /// What a group review starts on: the skill, every PR's link, then the reviewer's notes and the tickets, each
    /// only when there is one.
    public static func groupReviewPrompt(_ group: ReviewGroup, tickets: [String]) -> String {
        var parts = ["Review these together with the fhenix-workflow:\(ClaudePlugins.reviewTeammateTask) skill:\n"
            + group.pullRequests.map(\.url).joined(separator: "\n")]
        if !group.notes.isEmpty { parts.append("My notes: \(group.notes)") }
        if !tickets.isEmpty { parts.append("The tickets they are for:\n\n" + tickets.joined(separator: "\n\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// The arguments of a group review's `claude`: the plugin folder and the other PRs' clones first, then the one allowed
    /// command and the instructions, and the prompt last, because `--allowedTools` takes every argument after it up to
    /// the next option.
    public static func groupReviewArguments(_ group: ReviewGroup, tickets: [String], otherClones: [String], config: DeskConfig) -> [String] {
        config.pluginDirFlags + otherClones.flatMap { ["--add-dir", $0] } + [
            "--allowedTools", "Bash(\(showHelper.path) *)",
            "--append-system-prompt", groupLinkInstructions(for: group.pullRequests),
            groupReviewPrompt(group, tickets: tickets),
        ]
    }

    /// The ticket a review session is told about: its key from the PR's branch or title, with the text when Desk
    /// has the ticket loaded. A teammate's ticket usually is not, and then the skill reads it from Jira.
    public static func reviewTicket(for pr: PullRequest, tickets: [Ticket], projectKeys: [String]) -> String? {
        guard let key = TicketSync.keys(for: pr, matcher: TicketKeyMatcher(projectKeys: projectKeys)).first else { return nil }
        guard let ticket = tickets.first(where: { $0.key == key }) else { return key }
        return [ticket.key + " — " + ticket.summary, ticket.url, ticket.description].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
