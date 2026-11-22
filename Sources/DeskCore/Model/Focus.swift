import Foundation

/// How large the Focus page draws an item, which is all the page says about how much it matters: act now, soon, can
/// wait, background. An item only grows or shrinks between them.
public enum FocusLevel: Int, Sendable, Comparable, CaseIterable {
    case background = 0, canWait, next, now

    public static func < (lhs: FocusLevel, rhs: FocusLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .now: return "Now"
        case .next: return "Next"
        case .canWait: return "Can wait"
        case .background: return "Background"
        }
    }
}

/// What a Focus item is, as its chip says it.
public enum FocusKind: Sendable, Equatable {
    // Your own PRs.
    case ciFailed, conflicts, changesRequested, needsRebase, openThreads(Int), readyToMerge, draftReviewed, draft, waitingOnReview
    // Other people's PRs: asked of you by name, asked of a team of yours, open to anyone, and one you started a review
    // on and have not sent.
    case reviewAsked, reviewTeam, reviewOpen, reviewDraft
    // Tickets: Jira behind its PRs, one in progress with no PR yet, one nothing has started.
    case jiraMove, inProgress, toStart
    case merged

    public var title: String {
        switch self {
        case .ciFailed: return "CI failed"
        case .conflicts: return "Conflicts"
        case .changesRequested: return "Changes requested"
        case .needsRebase: return "Needs rebase"
        case .openThreads(let count): return count == 1 ? "1 open thread" : "\(count) open threads"
        case .readyToMerge: return "Ready to merge"
        case .draftReviewed: return "Draft, self-reviewed"
        case .draft: return "Draft"
        case .waitingOnReview: return "Waiting on review"
        case .reviewAsked: return "Review asked"
        case .reviewTeam: return "Review asked of team"
        case .reviewOpen: return "Open to review"
        case .reviewDraft: return "Review to submit"
        case .jiraMove: return "Jira move"
        case .inProgress: return "In progress"
        case .toStart: return "Ready to start"
        case .merged: return "Merged today"
        }
    }

    /// The level Desk gives it on its own, with no ranking from the master, and the one it lifts an item to when GitHub
    /// changes after the master last ranked.
    public var level: FocusLevel {
        switch self {
        case .ciFailed, .conflicts, .changesRequested, .readyToMerge: return .now
        case .needsRebase, .openThreads, .draftReviewed, .reviewAsked, .reviewDraft, .inProgress: return .next
        case .draft, .reviewTeam, .reviewOpen, .jiraMove, .toStart: return .canWait
        case .waitingOnReview, .merged: return .background
        }
    }
}

/// One item of the Focus page: a PR, a suggested Jira move or a ticket, with what it is and how large it shows.
public struct FocusItem: Sendable, Identifiable {
    public enum Subject: Sendable {
        case pullRequest(PullRequest)
        case move(TicketDrift)
        case ticket(Ticket)
    }

    public var subject: Subject
    public var kind: FocusKind
    public var level: FocusLevel
    /// Since when it has been as it is, for the waiting time; nil for what waits on nothing (a ticket to start or in
    /// progress, a PR merged today).
    public var since: Date?
    /// Desk raised it on its own after the master last ranked, because GitHub changed: the page marks it New until the
    /// master ranks again.
    public var lifted = false

    /// A PR's url or a ticket's key.
    public var id: String {
        switch subject {
        case .pullRequest(let pr): return pr.url
        case .move(let drift): return drift.ticket.key
        case .ticket(let ticket): return ticket.key
        }
    }

    /// What `focus.json` names it by: `owner/name#number`, lowercased, or the ticket's key.
    public var rankKey: String {
        if case .pullRequest(let pr) = subject { return ClaudeJobs.prKey(pr.url) ?? pr.url }
        return id.lowercased()
    }
}

/// The master's ranking, as the coordinate-tasks skill writes `focus.json`: the items in its order, each with its level
/// (3 now, 2 next, 1 can wait, 0 background), and when it ranked them. Rewritten whole with each ranking.
public struct FocusRanking: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// `owner/name#number` or a ticket key, in any case.
        public var id: String
        public var level: Int

        public init(id: String, level: Int) {
            self.id = id
            self.level = level
        }
    }

    public var rankedAt: Date
    public var items: [Entry]

    public init(rankedAt: Date, items: [Entry]) {
        self.rankedAt = rankedAt
        self.items = items
    }
}

extension DeskState {
    /// Your sprint's to-do tickets that nothing has started yet: no PR of yours names them, open or merged, and no session
    /// was started on them, in Jira's order. One whose PR merged is finished work Jira is behind on, which a Jira move
    /// suggests, not new work.
    public var ticketsToStart: [Ticket] {
        let named = Set(ticketKeys.values.joined())
        return openTickets.filter { ticket in
            ticket.placement == .sprint && ticket.category == .todo && !named.contains(ticket.key) && sessions(forTicket: ticket.key).isEmpty
        }
    }

    /// How many reviews nobody asked of you by name the page lists, oldest first: the rest are on Reviews.
    public static let focusOtherReviews = 3

    /// What the Focus badge and the menu bar count: the items at Now and Next.
    public func focusCount(reviewDays: Int?, hiding: Set<String> = [], needingApproval: Bool = false, now: Date = Date()) -> Int {
        focus(reviewDays: reviewDays, hiding: hiding, needingApproval: needingApproval, now: now).filter { $0.level >= .next }.count
    }

    /// The Focus page: everything of yours in one list, largest first. Each of your open PRs by its own state on GitHub
    /// (its session has no say); the reviews you started and have not sent, whatever the day filter; the reviews asked of
    /// you by name, and the first few asked of a team of yours or open to anyone, inside the Reviews screen's filters (`reviewDays`, `hiding`,
    /// `needingApproval`); the Jira moves Desk suggests; your tickets in progress with no PR yet; the sprint's tickets
    /// nothing has started; and your PRs merged today.
    ///
    /// The level is the kind's own (`FocusKind.level`) unless the master's ranking names the item: then it is the
    /// master's, in the master's order. What changed after the master ranked, to something Desk puts higher than the
    /// master did, or that the master has not seen at all, takes Desk's level and leads it, marked `lifted`.
    public func focus(reviewDays: Int?, hiding: Set<String> = [], needingApproval: Bool = false, now: Date = Date()) -> [FocusItem] {
        var items: [FocusItem] = []
        func add(_ subject: FocusItem.Subject, _ kind: FocusKind, since: Date?) {
            items.append(FocusItem(subject: subject, kind: kind, level: kind.level, since: since))
        }

        for pr in mine.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let (kind, since) = focusKind(of: pr)
            add(.pullRequest(pr), kind, since: since)
        }
        for pr in reviewQueue(.all, hiding: hiding) where pr.pendingReview != nil {
            add(.pullRequest(pr), .reviewDraft, since: nil)
        }
        let onYou = Set(reviewRequests.map(\.url))
        // A review the master ranked is listed whatever the cap: the master chose it.
        let ranked = Set((focusRanking?.items ?? []).map { $0.id.lowercased() })
        var others = 0
        for pr in reviewQueue(.needsYou, days: reviewDays, hiding: hiding, needingApproval: needingApproval, now: now)
        where pr.pendingReview == nil && reviewNeed(for: pr) != nil {
            if pr.requestedReviewers.contains(login) {
                // Since you were last asked; only the latest request events are fetched, so failing one, since it opened.
                let asked = pr.reviewRequestEvents.filter { !$0.isTeam && $0.reviewer == login }.map(\.createdAt).max()
                add(.pullRequest(pr), .reviewAsked, since: asked ?? pr.createdAt)
            } else if ClaudeJobs.prKey(pr.url).map(ranked.contains) == true {
                add(.pullRequest(pr), onYou.contains(pr.url) ? .reviewTeam : .reviewOpen, since: pr.createdAt)
            } else if others < Self.focusOtherReviews {
                others += 1
                add(.pullRequest(pr), onYou.contains(pr.url) ? .reviewTeam : .reviewOpen, since: pr.createdAt)
            }
        }
        for drift in ticketDrifts {
            add(.move(drift), .jiraMove, since: drift.pullRequests.map { $0.mergedAt ?? $0.updatedAt }.max())
        }
        let named = Set(ticketKeys.values.joined())
        for ticket in openTickets where ticket.category == .inProgress && !named.contains(ticket.key) {
            add(.ticket(ticket), .inProgress, since: nil)
        }
        for ticket in ticketsToStart { add(.ticket(ticket), .toStart, since: nil) }
        for pr in github?.mergedRecent ?? [] {
            guard let mergedAt = pr.mergedAt, Calendar.current.isDate(mergedAt, inSameDayAs: now) else { continue }
            add(.pullRequest(pr), .merged, since: nil)
        }

        var order: [String: Int] = [:]
        if let ranking = focusRanking {
            let ranked = Dictionary(ranking.items.enumerated().map { ($1.id.lowercased(), ($0, $1.level)) }, uniquingKeysWith: { first, _ in first })
            for index in items.indices {
                let item = items[index]
                let changed = item.since.map { $0 > ranking.rankedAt } ?? false
                if let (position, level) = ranked[item.rankKey] {
                    let level = FocusLevel(rawValue: min(max(level, 0), 3)) ?? .background
                    if changed, item.kind.level > level {
                        items[index].lifted = true
                        order[item.id] = -1
                    } else {
                        items[index].level = level
                        order[item.id] = position
                    }
                } else if changed, item.level > .background {
                    items[index].lifted = true
                    order[item.id] = -1
                }
            }
        }
        // Largest first; within a level what Desk lifted, then the master's order, then Desk's own.
        return items.enumerated().sorted { a, b in
            (-a.element.level.rawValue, order[a.element.id] ?? Int.max, a.offset) < (-b.element.level.rawValue, order[b.element.id] ?? Int.max, b.offset)
        }
        .map(\.element)
    }

    /// What one of your open PRs is on the page, and since when. GitHub gives no time for a check's failure, a conflict or
    /// a draft, so those go by when the PR last moved.
    private func focusKind(of pr: PullRequest) -> (FocusKind, Date) {
        switch RowState.of(pr) {
        case .conflicts: return (.conflicts, pr.updatedAt)
        case .ciFailed: return (.ciFailed, pr.updatedAt)
        case .changesRequested:
            return (.changesRequested, pr.reviews.filter { $0.state == .changesRequested }.map(\.submittedAt).max() ?? pr.updatedAt)
        case .openThreads(let count):
            return (.openThreads(count), pr.threads.compactMap(\.lastAt).max() ?? pr.updatedAt)
        case .draft(let review):
            if rebaseReason(pr) != nil { return (.needsRebase, pr.updatedAt) }
            return (review == .passed ? .draftReviewed : .draft, pr.updatedAt)
        case .readyToMerge, .waitingOnReview:
            if rebaseReason(pr) != nil { return (.needsRebase, pr.updatedAt) }
            // Ready by the stage's rule, and GitHub would take the merge now; until then it still waits.
            if FlowStage.of(pr) == .approved, pr.mergeState == .clean, !pr.checks.isPending {
                return (.readyToMerge, pr.reviews.filter { $0.state == .approved }.map(\.submittedAt).max() ?? pr.updatedAt)
            }
            return (.waitingOnReview, pr.reviewRequestEvents.map(\.createdAt).max() ?? pr.updatedAt)
        }
    }
}
