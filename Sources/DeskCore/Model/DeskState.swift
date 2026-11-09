import Foundation

/// One status column of the Jira screen: every open ticket of yours sitting in that status.
public struct TicketGroup: Sendable, Identifiable {
    public var id: String { status }
    public var status: String
    public var category: TicketStatusCategory
    public var tickets: [Ticket]
}

/// Which slice of the review queue to show: the ones asked of you, the open ones you have not reviewed, the ones you
/// reviewed that wait on their authors, or every open PR by someone else. `needsYou` — asked of you, or not yet
/// reviewed — is what the sidebar badge, Up Next and the menu bar count; the screen does not offer it.
public enum ReviewScope: String, CaseIterable, Sendable, Identifiable {
    case onMe, open, reviewed, all, needsYou

    /// The scopes the Reviews screen offers, in order.
    public static let offered: [ReviewScope] = [.onMe, .open, .reviewed, .all]

    public var id: ReviewScope { self }

    public var title: String {
        switch self {
        case .onMe: return "On you"
        case .open: return "Open"
        case .reviewed: return "Reviewed"
        case .all: return "All"
        case .needsYou: return "Needs you"
        }
    }
}

public enum Source: String, CaseIterable, Sendable, Codable {
    case github, git, jira

    public var title: String {
        switch self {
        case .github: return "GitHub"
        case .git: return "Git"
        case .jira: return "Jira"
        }
    }
}

/// Everything the UI shows. Raw data per source plus values derived from it.
public struct DeskState: Sendable {
    public var config: DeskConfig
    public var github: GitHubSnapshot?
    public var gitScan: GitScan?
    public var tickets: [Ticket] = []
    /// Claude Code's background sessions that mention a PR or were started on a ticket, newest first. Local files, so
    /// they ride the git poll rather than being a polled `Source` of their own.
    public var claudeJobs: [ClaudeJob] = []
    /// Your Claude plan's limits, for the sidebar. Rides the git poll as well.
    public var claudeLimits: [ClaudeLimit] = []
    /// Whether each clone's sessions can run the team review skill, by repo root. Read with the git poll.
    public var reviewSkills: [String: ReviewSkill] = [:]
    public var errors: [Source: String] = [:]
    public var lastRefresh: [Source: Date] = [:]

    public private(set) var nudges: [Nudge] = []
    public private(set) var stackParents: [String: String] = [:]
    /// Ticket keys each of my pull requests names, by PR url. Precomputed because the tables read it per
    /// row and the matcher compiles a regex.
    public private(set) var ticketKeys: [String: [String]] = [:]
    /// Tickets whose Jira status has fallen behind their pull requests, less the moves you dismissed: the moves the app
    /// suggests. None happens until you press Move.
    public private(set) var ticketDrifts: [TicketDrift] = []
    /// The suggested moves you dismissed, by `TicketDrift.moveKey`.
    public var dismissedMoves: Set<String> = []
    /// Which queued PRs wait on your review, and why.
    public private(set) var reviewNeeds: [String: ReviewNeed] = [:]

    public init(config: DeskConfig) {
        self.config = config
    }

    public var login: String { github?.login ?? "" }

    public var mine: [PullRequest] { github?.mine ?? [] }
    /// PRs that wait on the user. GitHub keeps a review request on a PR its author turns back into a
    /// draft, but the author is still working: the PR joins the queue once it is marked ready again.
    /// Bot PRs never join it; the app shows them nowhere.
    public var reviewRequests: [PullRequest] {
        (github?.reviewRequests ?? []).filter { !$0.isDraft && !$0.isAutomated(config.automation) }
    }
    /// Worktrees the user works in. A prunable one is a record git still keeps for a directory the disk no longer
    /// has — every background Claude session whose job has since been deleted leaves one behind — and it is no place
    /// to start anything.
    public var worktrees: [Worktree] { (gitScan?.worktrees ?? []).filter { !$0.isPrunable } }

    /// Open PRs nobody has put on you and you have not reviewed. Once you review one it moves to `reviewedByYou`; if
    /// the author re-requests you it comes back through `reviewRequests` instead.
    public var openForReview: [PullRequest] { notOnYou.filter { !hasYourReview($0) } }

    /// Open PRs you reviewed that nobody has put back on you: they wait on their authors.
    public var reviewedByYou: [PullRequest] { notOnYou.filter(hasYourReview) }

    /// Open PRs by others, drafts and bots aside, that are not asked of you; oldest first.
    private var notOnYou: [PullRequest] {
        let queued = Set(reviewRequests.map(\.url))
        return (github?.openForReview ?? [])
            .filter { !$0.isDraft && !$0.isAutomated(config.automation) && !queued.contains($0.url) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func hasYourReview(_ pr: PullRequest) -> Bool { pr.reviews.contains { $0.author == login } }

    /// Everything the Reviews queue can show, in the order the scopes are offered. `days` keeps the PRs
    /// opened within that many days, which is what the Waiting column measures; nil keeps them all.
    /// `hiding` leaves out the PRs of authors you filtered out. `needingApproval` keeps the PRs the review gate says still
    /// need an approval, or has not decided on, and every PR of a repo without the gate.
    public func reviewQueue(
        _ scope: ReviewScope, days: Int? = nil, hiding: Set<String> = [], needingApproval: Bool = false, now: Date = Date()
    ) -> [PullRequest] {
        var rows: [PullRequest]
        switch scope {
        case .onMe: rows = reviewRequests
        case .open: rows = openForReview
        case .reviewed: rows = reviewedByYou
        case .all: rows = reviewRequests + openForReview + reviewedByYou
        case .needsYou: rows = reviewRequests + openForReview
        }
        if !hiding.isEmpty { rows.removeAll { hiding.contains($0.author) } }
        if needingApproval { rows.removeAll { !$0.needsApproval } }
        guard let days else { return rows.needsHumanFirst }
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        return rows.filter { $0.createdAt > cutoff }.needsHumanFirst
    }

    /// Your unfinished tickets. Done is not work, so it never counts here.
    public var openTickets: [Ticket] {
        tickets.filter { $0.assignedToMe && $0.category != .done }
    }

    /// Unfinished tickets in one placement whose assignee is among `assignees`, grouped by status; an empty set
    /// is everyone's. Statuses come out in workflow order — to do, then in progress, then anything Jira does not
    /// categorise — and done never appears.
    public func ticketGroups(_ placement: TicketPlacement, assignees: Set<TicketAssignee> = [.me]) -> [TicketGroup] {
        let rows = tickets.filter { ticket in
            ticket.placement == placement && ticket.category != .done
                && (assignees.isEmpty || assignees.contains { $0.matches(ticket) })
        }
        return Dictionary(grouping: rows, by: \.status)
            .map { TicketGroup(status: $0.key, category: $0.value[0].category, tickets: $0.value.sorted { $0.key < $1.key }) }
            .sorted { ($0.category.rank, $0.status) < ($1.category.rank, $1.status) }
    }

    public func ticket(_ key: String) -> Ticket? { tickets.first { $0.key == key } }

    /// Lays this app's own writes, by ticket key, over the tickets Jira returned, and returns the keys whose ticket shows
    /// its write already. Jira's search lags a write, so until it agrees a refresh brings back what was there before.
    @discardableResult
    public mutating func apply(ticketEdits edits: [String: TicketEdit]) -> Set<String> {
        var agreed = Set<String>()
        for index in tickets.indices {
            guard let edit = edits[tickets[index].key] else { continue }
            let before = tickets[index]
            if let status = edit.status { tickets[index].status = status }
            if let category = edit.category { tickets[index].category = category }
            if let summary = edit.summary { tickets[index].summary = summary }
            if let description = edit.description { tickets[index].description = description }
            if tickets[index] == before { agreed.insert(before.key) }
        }
        return agreed
    }

    /// Everyone but you with an unfinished ticket in the sprint or the backlog, by name: the assignee filter's list.
    public var ticketAssignees: [TicketPerson] {
        let open = tickets.filter { !$0.assignedToMe && $0.placement != .unknown && $0.category != .done }
        let people = Dictionary(open.compactMap { t in t.assignee.map { ($0, t.assigneeAvatar) } }, uniquingKeysWith: { first, _ in first })
        return people.map { TicketPerson(name: $0.key, avatar: $0.value) }.sorted { $0.name < $1.name }
    }

    /// You as Jira has you, read off one of your tickets; nil when you have none.
    public var ticketSelf: TicketPerson? {
        tickets.first { $0.assignedToMe && $0.assignee != nil }.map { TicketPerson(name: $0.assignee!, avatar: $0.assigneeAvatar) }
    }

    /// My open pull requests that name this ticket in their branch or title.
    public func pullRequests(forTicket key: String) -> [PullRequest] {
        mine.filter { ticketKeys[$0.url]?.contains(key) == true }
    }

    /// Your pull requests merged in the last 30 days, newest first: the Pull Requests screen's second tab. The
    /// merged search reaches further back, for Jira's sake; the screen shows only this month.
    public func recentlyMerged(now: Date = Date()) -> [PullRequest] {
        let since = now.addingTimeInterval(-30 * 86_400)
        return (github?.mergedRecent ?? [])
            .filter { ($0.mergedAt ?? .distantPast) >= since }
            .sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }
    }

    /// Where this ticket should move, or nil when Jira already agrees with GitHub.
    public func drift(forKey key: String) -> TicketDrift? { ticketDrifts.first { $0.ticket.key == key } }

    /// Ticket keys seen in PRs and worktrees. Jira fetches them even when they are assigned to someone else.
    public var referencedTicketKeys: [String] {
        let matcher = TicketKeyMatcher(projectKeys: config.jiraProjectKeys)
        let texts = mine.flatMap(TicketSync.texts(of:)) + worktrees.compactMap(\.branch) + worktrees.map(\.name)
        return matcher.keys(in: texts)
    }

    public mutating func recompute(now: Date = Date()) {
        let openAll = github?.allOpen ?? []
        let merged = github?.mergedRecent ?? []
        stackParents = Linker.stackParents(openAll)
        reviewNeeds = ReviewReadiness.needs(login: login, queue: reviewRequests + openForReview)
        let matcher = TicketKeyMatcher(projectKeys: config.jiraProjectKeys)
        // The merged ones too, so their rows name the ticket they closed.
        ticketKeys = Dictionary((mine + merged).map { ($0.url, TicketSync.keys(for: $0, matcher: matcher)) }, uniquingKeysWith: { first, _ in first })
        ticketDrifts = TicketSync.drifts(TicketSyncInput(
            tickets: tickets, open: mine, merged: merged, projectKeys: config.jiraProjectKeys,
            inProgressStatus: config.jiraInProgressStatus, reviewStatus: config.jiraReviewStatus, doneStatus: config.jiraDoneStatus
        )).filter { !dismissedMoves.contains($0.moveKey) }
        nudges = NudgeEngine.nudges(NudgeInput(
            now: now, login: login, config: config, mine: mine, reviewRequests: reviewRequests,
            mergedHeadsByRepo: Linker.mergedHeadsByRepo(merged), sessions: claudeJobs, ticketKeys: ticketKeys
        ))
    }

    /// My open PRs with each stack contiguous, children beneath their root; `order` sorts the stacks by their roots.
    public func stackedMine(order: [KeyPathComparator<StackedPullRequest>]) -> [StackedPullRequest] {
        Linker.stacked(mine, parents: stackParents, order: order)
    }

    public func stackParent(of pr: PullRequest) -> PullRequest? {
        guard let url = stackParents[pr.url] else { return nil }
        return github?.allOpen.first { $0.url == url }
    }

    /// Background Claude sessions that worked on this PR, newest first. Interactive sessions are not
    /// here: only a background one can be attached to from outside the terminal that started it.
    public func claudeJobs(for pr: PullRequest) -> [ClaudeJob] {
        guard let key = ClaudeJobs.prKey(pr.url) else { return [] }
        return claudeJobs.filter { $0.prKeys.contains(key) }
    }

    /// The session that carries this PR through the flow, as `ClaudeJobs.carrier` picks it. A PR with one is in the flow.
    public func session(for pr: PullRequest) -> ClaudeJob? {
        guard let key = ClaudeJobs.prKey(pr.url) else { return nil }
        return ClaudeJobs.carrier(of: key, tickets: ticketKeys[pr.url] ?? [], in: claudeJobs)
    }

    /// Where this PR of yours stands in the flow; nil while no session works on it.
    public func stage(for pr: PullRequest) -> FlowStage? { session(for: pr).map { _ in FlowStage.of(pr) } }

    /// The sessions started on this ticket, newest first.
    public func sessions(forTicket key: String) -> [ClaudeJob] { claudeJobs.filter { $0.ticketKey == key } }

    /// The PR of yours, open or merged, that a ticket's session works on: one that names the ticket first.
    public func pullRequest(of session: ClaudeJob) -> PullRequest? {
        let linked = (mine + (github?.mergedRecent ?? [])).filter { ClaudeJobs.prKey($0.url).map(session.prKeys.contains) == true }
        return linked.first { pr in session.ticketKey.map { ticketKeys[pr.url]?.contains($0) == true } ?? false } ?? linked.first
    }

    /// A ticket session's stage: its PR's, or Working until it has one.
    public func stage(of session: ClaudeJob) -> FlowStage {
        pullRequest(of: session).map(FlowStage.of) ?? .working
    }

    public func rebaseReason(_ pr: PullRequest) -> RebaseReason? {
        Linker.rebaseReason(pr, mergedHeads: Linker.mergedHeadsByRepo(github?.mergedRecent ?? [])[pr.repo] ?? [])
    }

    // MARK: Reviews

    public func localRepo(for pr: PullRequest) -> RepoRef? {
        gitScan.flatMap { Linker.repo(for: pr, in: $0.repos) }
    }

    /// Whether a session on this PR's clone can run the team review skill; nil without a clone.
    public func reviewSkill(for pr: PullRequest) -> ReviewSkill? { localRepo(for: pr).flatMap { reviewSkills[$0.root] } }

    /// The same, for a tracked `owner/name`.
    public func reviewSkill(forSlug slug: String) -> ReviewSkill? {
        let repo = gitScan?.repos.first { GitParsing.repoSlug(fromRemote: $0.remote) == slug.lowercased() }
        return repo.flatMap { reviewSkills[$0.root] }
    }

    /// Why this PR waits on your review, or nil when it does not.
    public func reviewNeed(for pr: PullRequest) -> ReviewNeed? { reviewNeeds[pr.url] }

    /// PRs asked of you that wait on your review, oldest first.
    public var reviewsToDo: [PullRequest] {
        reviewRequests.filter { reviewNeeds[$0.url] != nil }.sorted { $0.createdAt < $1.createdAt }
    }

    public func reviewStatus(for pr: PullRequest) -> ReviewStatus { ReviewStatus.derive(pr: pr, login: login) }
}

/// Up Next's sections, in the order the screen lists them: what you can finish now, what is yours to fix, the reviews
/// waiting on you, and your PRs that wait on someone else.
public enum UpNextSection: Int, CaseIterable, Sendable, Hashable {
    case readyToMerge, yourMove, draftsToSubmit, toReview, waiting

    public var title: String {
        switch self {
        case .readyToMerge: return "Ready to merge"
        case .yourMove: return "Your move"
        case .draftsToSubmit: return "Drafts to submit"
        case .toReview: return "To review"
        case .waiting: return "Waiting"
        }
    }
}

extension DeskState {
    /// Up Next's new work: your tickets in the open sprint that are still to do, with no PR of yours naming them, open or
    /// merged, and no session started on them, in Jira's order, most recently updated first. One whose PR merged is
    /// finished work Jira is behind on, which Jira moves suggests, not new work.
    public var ticketsToStart: [Ticket] {
        let named = Set(ticketKeys.values.joined())
        return openTickets.filter { ticket in
            ticket.placement == .sprint && ticket.category == .todo && !named.contains(ticket.key) && sessions(forTicket: ticket.key).isEmpty
        }
    }
}

/// One section of Up Next and its PRs.
public struct UpNextGroup: Sendable, Identifiable {
    public var section: UpNextSection
    public var pullRequests: [PullRequest]
    public var id: UpNextSection { section }
}

extension DeskState {
    /// Up Next: every PR of yours under one section — your move when it is red, conflicts, has changes requested,
    /// needs a rebase or a flow or session waits on you; ready to merge when its nudge says so; otherwise waiting on
    /// others — most recently updated first; then the reviews you have a draft on that is not submitted yet, whatever
    /// the day filter, since you started them; then the review queue's PRs that need your review, inside the Reviews
    /// screen's day and approval filters (`reviewDays`, nil for all time; `needingApproval`), oldest first as the queue
    /// lists them. Both leave out the authors the Reviews screen hides (`hiding`). Empty sections are
    /// left out. The PR's own state decides a fix, not its nudge: drafts get no nudges, and a red draft is still yours.
    public func upNext(reviewDays: Int?, hiding: Set<String> = [], needingApproval: Bool = false, now: Date = Date()) -> [UpNextGroup] {
        let yours: Set<NudgeKind> = [.sessionNeedsYou, .flowWaiting]
        var kinds: [String: Set<NudgeKind>] = [:]
        for nudge in nudges { if let url = nudge.url { kinds[url, default: []].insert(nudge.kind) } }
        var sections: [UpNextSection: [PullRequest]] = [:]
        for pr in mine.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let found = kinds[pr.url] ?? []
            let fix = pr.checks.isRed || pr.mergeState == .dirty || pr.reviewDecision == .changesRequested || rebaseReason(pr) != nil
            let section: UpNextSection = fix || !found.isDisjoint(with: yours) ? .yourMove
                : found.contains(.readyToMerge) ? .readyToMerge : .waiting
            sections[section, default: []].append(pr)
        }
        sections[.draftsToSubmit] = reviewQueue(.all, hiding: hiding).filter { $0.pendingReview != nil }
        sections[.toReview] = reviewQueue(.needsYou, days: reviewDays, hiding: hiding, needingApproval: needingApproval, now: now)
            .filter { $0.pendingReview == nil && reviewNeed(for: $0) != nil }
        return UpNextSection.allCases.compactMap { section in
            guard let prs = sections[section], !prs.isEmpty else { return nil }
            return UpNextGroup(section: section, pullRequests: prs)
        }
    }
}
