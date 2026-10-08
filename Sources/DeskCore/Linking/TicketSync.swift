import Foundation

/// Where a ticket belongs given the pull requests that name it.
public enum TicketStage: String, Sendable {
    case inReview, done
}

/// A ticket whose Jira status has fallen behind its pull requests, and where it should go.
public struct TicketDrift: Sendable, Hashable, Identifiable {
    public var id: String { ticket.key }
    public var ticket: Ticket
    public var stage: TicketStage
    /// The Jira status name to move to, as configured.
    public var target: String
    /// The pull requests that put it there, highest number first. The badge names these: a move nobody
    /// can explain is one nobody should make.
    public var pullRequests: [PullRequest]

    public init(ticket: Ticket, stage: TicketStage, target: String, pullRequests: [PullRequest]) {
        self.ticket = ticket
        self.stage = stage
        self.target = target
        self.pullRequests = pullRequests
    }
}

public struct TicketSyncInput: Sendable {
    public var tickets: [Ticket]
    /// Your open pull requests.
    public var open: [PullRequest]
    /// Your recently merged ones.
    public var merged: [PullRequest]
    public var defaultBranches: [String: String]
    public var projectKeys: [String]
    /// The status a ticket takes while a pull request of its waits for review, and the one it takes once
    /// they have all landed. Empty turns that half of the sync off.
    public var reviewStatus: String
    public var doneStatus: String

    public init(
        tickets: [Ticket], open: [PullRequest], merged: [PullRequest], defaultBranches: [String: String],
        projectKeys: [String], reviewStatus: String, doneStatus: String
    ) {
        self.tickets = tickets
        self.open = open
        self.merged = merged
        self.defaultBranches = defaultBranches
        self.projectKeys = projectKeys
        self.reviewStatus = reviewStatus
        self.doneStatus = doneStatus
    }
}

/// Keeps Jira in step with GitHub: which tickets a pull request is about, and where their status has
/// fallen behind. Pure — the transition itself lives in `JiraWrite`.
public enum TicketSync {
    /// The texts a ticket key may be read out of. The branch and the title are things you chose for this
    /// pull request; the description is prose that mentions other tickets, so it is not read — a "see also
    /// PRO-100" line must never move PRO-100 to done.
    public static func texts(of pr: PullRequest) -> [String] { [pr.headRef, pr.title] }

    public static func keys(for pr: PullRequest, matcher: TicketKeyMatcher) -> [String] {
        matcher.keys(in: texts(of: pr))
    }

    public static func drifts(_ input: TicketSyncInput) -> [TicketDrift] {
        let matcher = TicketKeyMatcher(projectKeys: input.projectKeys)
        var byKey: [String: [PullRequest]] = [:]
        for pr in input.open + input.merged {
            for key in keys(for: pr, matcher: matcher) { byKey[key, default: []].append(pr) }
        }
        return input.tickets.compactMap { ticket in
            // Never someone else's ticket, and never backwards: one Jira already calls done stays done,
            // whatever happens to its pull requests afterwards.
            guard ticket.assignedToMe, ticket.category != .done else { return nil }
            guard let prs = byKey[ticket.key], let stage = stage(prs, defaultBranches: input.defaultBranches) else { return nil }
            let target = stage == .done ? input.doneStatus : input.reviewStatus
            guard !target.isEmpty, ticket.status != target else { return nil }
            return TicketDrift(ticket: ticket, stage: stage, target: target, pullRequests: prs.sorted { $0.number > $1.number })
        }
    }

    /// One open pull request marked ready puts the ticket in review. Done wants every one of them merged
    /// and at least one landed on the repository's default branch: a pull request merged into the branch
    /// below it in a stack has finished nothing anybody would call finished. A draft blocks done for the
    /// same reason and opens no review, so a ticket with only drafts left is neither.
    private static func stage(_ prs: [PullRequest], defaultBranches: [String: String]) -> TicketStage? {
        if prs.contains(where: { $0.state == .open && !$0.isDraft }) { return .inReview }
        guard !prs.isEmpty, prs.allSatisfy({ $0.state == .merged }) else { return nil }
        guard prs.contains(where: { $0.baseRef == defaultBranches[$0.repoName] ?? "main" }) else { return nil }
        return .done
    }
}
