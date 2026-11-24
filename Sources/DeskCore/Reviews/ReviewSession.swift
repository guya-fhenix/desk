import Foundation

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

extension DeskService {
    /// What a review session is told on top of its own instructions: that the diff is beside it, and how the lines
    /// picked there reach it. Nothing in it lets the session move the diff: where the reviewer reads is theirs to choose.
    public static func groupDiffInstructions(for pullRequests: [PullRequest]) -> String {
        """
        Fhenix Desk shows the diff of the PR you are on beside you: \(pullRequests.map(\.url).joined(separator: ", ")). \
        Lines the reviewer selects in the diff arrive pasted into your input, with their PR, path and line numbers.
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

    /// The arguments of a group review's `claude`: the plugin folder and the other PRs' clones first, then the
    /// instructions and the prompt.
    public static func groupReviewArguments(_ group: ReviewGroup, tickets: [String], otherClones: [String], config: DeskConfig) -> [String] {
        config.pluginDirFlags + otherClones.flatMap { ["--add-dir", $0] } + [
            "--append-system-prompt", groupDiffInstructions(for: group.pullRequests),
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
