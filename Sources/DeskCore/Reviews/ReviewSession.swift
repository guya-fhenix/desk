import Foundation

/// `fhenixdesk://show/<owner>/<repo>/<number>/<new|old>/<line>/<path>`: a review session runs `open` on one to move
/// the diff beside it to a line. A path rather than a query, so it needs no quoting in a shell, where `?` and `&`
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

extension DeskService {
    /// What a review session is told on top of its own instructions: how to move the diff beside it. Fixed, not a
    /// Settings prompt, because the app parses what comes back.
    public static func reviewLinkInstructions(for pr: PullRequest) -> String {
        """
        Fhenix Desk shows the diff of \(pr.url) beside you, and that is how the reviewer moves through the code. \
        Whenever you point at a specific line of that diff, also move their view there by running exactly this \
        command, without quotes: open \(DeskLink.scheme)://show/\(pr.repo)/\(pr.number)/<side>/<line>/<path> — \
        <side> is new for an added or unchanged line (its number in the new file) and old for a removed line (its \
        number in the old file); <path> is the file's path as the diff shows it. Lines the reviewer selects in the \
        diff arrive pasted into your input, with their path and line numbers.
        """
    }

    /// The arguments of the regular `claude` a review runs in the terminal panel. The allowed `open` is what lets
    /// the session move the diff without asking each time; the prompt goes last, because `--allowedTools` takes
    /// every argument after it up to the next option.
    public static func reviewArguments(for pr: PullRequest, ticket: String?, config: DeskConfig = DeskConfig()) -> [String] {
        let prompt = config.prompt(
            .review,
            ["repo": pr.repo, "number": "\(pr.number)", "title": pr.title, "url": pr.url, "baseRef": pr.baseRef, "ticket": ticket ?? ""],
            when: ["ticket": ticket != nil]
        )
        return [
            "--allowedTools", "Bash(open \(DeskLink.scheme)://*)",
            "--append-system-prompt", reviewLinkInstructions(for: pr),
            prompt,
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
