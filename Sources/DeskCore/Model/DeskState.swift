import Foundation

/// One status column of the Tickets screen: every open ticket of yours sitting in that status.
public struct TicketGroup: Sendable, Identifiable {
    public var id: String { status }
    public var status: String
    public var category: TicketStatusCategory
    public var tickets: [Ticket]
}

/// Which slice of the review queue to show: the ones asked of you, the ones nobody asked you about, or both.
public enum ReviewScope: String, CaseIterable, Sendable, Identifiable {
    case onMe, open, all

    public var id: ReviewScope { self }

    public var title: String {
        switch self {
        case .onMe: return "On me"
        case .open: return "Open"
        case .all: return "All"
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
    /// Claude review runs this session, by PR url. Where each review stands is read off the PR itself.
    public var reviewRuns: [String: ReviewRun] = [:]
    public var tickets: [Ticket] = []
    /// Claude Code's background sessions that mention a PR. Local files, so they ride the git poll
    /// rather than being a polled `Source` of their own.
    public var claudeJobs: [ClaudeJob] = []
    public var errors: [Source: String] = [:]
    /// The last review failure. Reviews are not a polled source, so they do not belong in `errors`.
    public var reviewError: String?
    public var lastRefresh: [Source: Date] = [:]

    public private(set) var nudges: [Nudge] = []
    public private(set) var stackParents: [String: String] = [:]
    /// Ticket keys each of my pull requests names, by PR url. Precomputed because the tables read it per
    /// row and the matcher compiles a regex.
    public private(set) var ticketKeys: [String: [String]] = [:]
    /// Tickets whose Jira status has fallen behind their pull requests. Nothing acts on this: the Tickets
    /// screen shows it and the move happens on a press.
    public private(set) var ticketDrifts: [TicketDrift] = []
    public private(set) var defaultBranches: [String: String] = [:]
    /// Which queued PRs are waiting for you to run a review, and why. Nothing acts on this: it is what
    /// the Reviews tab shows so the press is an informed one.
    public private(set) var reviewNeeds: [String: ReviewNeed] = [:]

    public init(config: DeskConfig) {
        self.config = config
    }

    public var login: String { github?.login ?? "" }

    /// What waits on you on one screen. The sidebar badge is this number; Today lists the nudges themselves.
    public func waiting(on screen: NudgeScreen) -> Int {
        nudges.count { $0.kind.screen == screen }
    }
    public var mine: [PullRequest] { github?.mine ?? [] }
    /// PRs that wait on the user. GitHub keeps a review request on a PR its author turns back into a
    /// draft, but the author is still working: the PR joins the queue once it is marked ready again.
    /// Bot PRs never join it; the app shows them nowhere.
    public var reviewRequests: [PullRequest] {
        (github?.reviewRequests ?? []).filter { !$0.isDraft && !$0.isAutomated(config.automation) }
    }
    /// Worktrees the user works in. Review worktrees are detached PR heads the app owns; they would
    /// otherwise read as local work and raise "unpushed work" nudges. A prunable one is a record git
    /// still keeps for a directory the disk no longer has — every background Claude session whose job
    /// has since been deleted leaves one behind — and it is no place to start anything.
    public var worktrees: [Worktree] {
        (gitScan?.worktrees ?? []).filter { !isReviewWorktree($0.path) && !$0.isPrunable }
    }
    public var reviewWorktrees: [Worktree] { (gitScan?.worktrees ?? []).filter { isReviewWorktree($0.path) } }

    /// Open PRs nobody has put on you and you have not reviewed. Once you review one it drops out of
    /// here; if the author re-requests you it comes back through `reviewRequests` instead.
    public var openForReview: [PullRequest] {
        let queued = Set(reviewRequests.map(\.url))
        return (github?.openForReview ?? [])
            .filter { !$0.isDraft && !$0.isAutomated(config.automation) }
            .filter { !queued.contains($0.url) }
            .filter { pr in !pr.reviews.contains { $0.author == login } }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// How far back the queue looks by default. Older PRs are still there, behind the toggle.
    public static let recentWindow: TimeInterval = 14 * 86_400

    /// Everything the Reviews queue can show, in the order the scopes are offered. `recentOnly` keeps
    /// the last two weeks by creation date, which is what the Waiting column measures.
    public func reviewQueue(_ scope: ReviewScope, recentOnly: Bool = false, now: Date = Date()) -> [PullRequest] {
        let rows: [PullRequest]
        switch scope {
        case .onMe: rows = reviewRequests
        case .open: rows = openForReview
        case .all: rows = reviewRequests + openForReview
        }
        guard recentOnly else { return rows }
        let cutoff = now.addingTimeInterval(-Self.recentWindow)
        return rows.filter { $0.createdAt > cutoff }
    }

    /// Your unfinished tickets. Done is not work, so it never counts here.
    public var openTickets: [Ticket] {
        tickets.filter { $0.assignedToMe && $0.category != .done }
    }

    /// Your unfinished tickets in one placement, grouped by status. Statuses come out in workflow order —
    /// to do, then in progress, then anything Jira does not categorise — and done never appears.
    public func ticketGroups(_ placement: TicketPlacement) -> [TicketGroup] {
        let rows = openTickets.filter { $0.placement == placement }
        return Dictionary(grouping: rows, by: \.status)
            .map { TicketGroup(status: $0.key, category: $0.value[0].category, tickets: $0.value.sorted { $0.key < $1.key }) }
            .sorted { ($0.category.rank, $0.status) < ($1.category.rank, $1.status) }
    }

    public func ticket(_ key: String) -> Ticket? { tickets.first { $0.key == key } }

    /// My open pull requests that name this ticket in their branch or title.
    public func pullRequests(forTicket key: String) -> [PullRequest] {
        mine.filter { ticketKeys[$0.url]?.contains(key) == true }
    }

    /// Where this ticket should move, or nil when Jira already agrees with GitHub.
    public func drift(forKey key: String) -> TicketDrift? { ticketDrifts.first { $0.ticket.key == key } }

    public func isReviewWorktree(_ path: String) -> Bool { ClaudePaths.path(path, isUnder: [config.expandedReviewRoot]) }

    /// Ticket keys seen in PRs and worktrees. Jira fetches them even when they are assigned to someone else.
    public var referencedTicketKeys: [String] {
        let matcher = TicketKeyMatcher(projectKeys: config.jiraProjectKeys)
        let texts = mine.flatMap(TicketSync.texts(of:)) + worktrees.compactMap(\.branch) + worktrees.map(\.name)
        return matcher.keys(in: texts)
    }

    public mutating func recompute(now: Date = Date()) {
        let openAll = github?.allOpen ?? []
        stackParents = Linker.stackParents(openAll)
        let merged = github?.mergedRecent ?? []
        defaultBranches = Linker.defaultBranches(worktrees: worktrees, pullRequests: openAll + merged)
        reviewNeeds = ReviewReadiness.needs(ReviewReadinessInput(
            login: login, queue: reviewRequests + openForReview, runs: reviewRuns, repos: gitScan?.repos ?? []
        ))
        let matcher = TicketKeyMatcher(projectKeys: config.jiraProjectKeys)
        ticketKeys = Dictionary(uniqueKeysWithValues: mine.map { ($0.url, TicketSync.keys(for: $0, matcher: matcher)) })
        ticketDrifts = TicketSync.drifts(TicketSyncInput(
            tickets: tickets, open: mine, merged: merged, defaultBranches: defaultBranches,
            projectKeys: config.jiraProjectKeys, reviewStatus: config.jiraReviewStatus, doneStatus: config.jiraDoneStatus
        ))
        nudges = NudgeEngine.nudges(NudgeInput(
            now: now, login: login, config: config, mine: mine, reviewRequests: reviewRequests,
            openHeadsByRepo: Linker.openHeadsByRepo(openAll), defaultBranches: defaultBranches, readyReviews: readyReviews
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

    public func rebaseReason(_ pr: PullRequest) -> RebaseReason? {
        let openHeads = Linker.openHeadsByRepo(github?.allOpen ?? [])[pr.repoName] ?? []
        return Linker.rebaseReason(pr, openHeads: openHeads, defaultBranch: defaultBranches[pr.repoName] ?? "main")
    }

    // MARK: Reviews

    public func localRepo(for pr: PullRequest) -> RepoRef? {
        gitScan.flatMap { Linker.repo(for: pr, in: $0.repos) }
    }

    public func reviewRun(for pr: PullRequest) -> ReviewRun? { reviewRuns[pr.url] }

    /// Why this PR wants a review run on it, or nil when it does not.
    public func reviewNeed(for pr: PullRequest) -> ReviewNeed? { reviewNeeds[pr.url] }

    /// PRs waiting for you to press Review, oldest first.
    public var reviewsToRun: [PullRequest] {
        reviewRequests.filter { reviewNeeds[$0.url] != nil }.sorted { $0.createdAt < $1.createdAt }
    }

    public func reviewStatus(for pr: PullRequest) -> ReviewStatus {
        ReviewStatus.derive(pr: pr, run: reviewRuns[pr.url], login: login)
    }

    /// Drafts with Claude's comments that still wait on you, for the nudge that says so.
    private var readyReviews: [ReadyReview] {
        reviewRequests.compactMap { pr in
            guard let pending = pr.pendingReview, pending.claudeComments > 0 else { return nil }
            return ReadyReview(pr: pr, comments: pending.comments, draftId: pending.id)
        }
    }
}
