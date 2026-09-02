import Foundation

public enum Source: String, CaseIterable, Sendable, Codable {
    case github, git, claude, jira

    public var title: String {
        switch self {
        case .github: return "GitHub"
        case .git: return "Git"
        case .claude: return "Claude"
        case .jira: return "Jira"
        }
    }
}

/// Everything the UI shows. Raw data per source plus values derived from it.
public struct DeskState: Sendable {
    public var config: DeskConfig
    public var github: GitHubSnapshot?
    public var gitScan: GitScan?
    public var liveSessions: [LiveSession] = []
    public var claudeScan = ClaudeScan()
    public var tickets: [Ticket] = []
    public var errors: [Source: String] = [:]
    public var lastRefresh: [Source: Date] = [:]

    public private(set) var workItems: [WorkItem] = []
    public private(set) var nudges: [Nudge] = []
    public private(set) var cycles: [PullRequestCycle] = []
    public private(set) var weekly: [WeeklyCycle] = []
    public private(set) var reviewLatencies: [ReviewLatency] = []
    public private(set) var stackParents: [String: String] = [:]
    public private(set) var defaultBranches: [String: String] = [:]

    public init(config: DeskConfig) {
        self.config = config
    }

    public var login: String { github?.login ?? "" }
    public var mine: [PullRequest] { github?.mine ?? [] }
    public var reviewRequests: [PullRequest] { github?.reviewRequests ?? [] }
    public var worktrees: [Worktree] { gitScan?.worktrees ?? [] }
    public var sessions: [SessionSummary] { claudeScan.meaningfulSessions }
    public var humanReviewRequests: [PullRequest] { reviewRequests.filter { !$0.isAutomated(config.automation) } }
    public var botReviewRequests: [PullRequest] { reviewRequests.filter { $0.isAutomated(config.automation) } }
    public var aliveSessions: [LiveSession] { liveSessions.filter(\.isAlive) }

    /// Ticket keys seen in PRs and worktrees. Jira fetches them even when they are assigned to someone else.
    public var referencedTicketKeys: [String] {
        let matcher = TicketKeyMatcher(projectKeys: config.jiraProjectKeys)
        let texts = mine.flatMap { [$0.headRef, $0.title] } + worktrees.compactMap(\.branch) + worktrees.map(\.name)
        return matcher.keys(in: texts)
    }

    public mutating func recompute(now: Date = Date()) {
        let matcher = TicketKeyMatcher(projectKeys: config.jiraProjectKeys)
        let openAll = github?.allOpen ?? []
        workItems = Linker.workItems(LinkerInput(
            pullRequests: mine, worktrees: worktrees, sessions: sessions, liveSessions: liveSessions, tickets: tickets, matcher: matcher
        ))
        stackParents = Linker.stackParents(openAll)
        defaultBranches = Linker.defaultBranches(worktrees: worktrees, pullRequests: openAll)
        cycles = CycleTime.cycles(github?.mergedRecent ?? [], botLogins: config.botLoginSet)
        weekly = CycleTime.weekly(cycles, weeks: config.metricsWeeks, now: now)
        reviewLatencies = CycleTime.reviewLatencies(github?.reviewedByMe ?? [], login: login)
        nudges = NudgeEngine.nudges(NudgeInput(
            now: now, login: login, config: config, mine: mine, reviewRequests: reviewRequests, worktrees: worktrees,
            liveSessions: liveSessions, openHeadsByRepo: Linker.openHeadsByRepo(openAll), defaultBranches: defaultBranches
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

    public func rebaseReason(_ pr: PullRequest) -> RebaseReason? {
        let openHeads = Linker.openHeadsByRepo(github?.allOpen ?? [])[pr.repoName] ?? []
        return Linker.rebaseReason(pr, openHeads: openHeads, defaultBranch: defaultBranches[pr.repoName] ?? "main")
    }

    public func liveSession(for worktree: Worktree) -> LiveSession? {
        aliveSessions.first { $0.cwd == worktree.path || $0.cwd.hasPrefix(worktree.path + "/") }
    }

    public func summary(for live: LiveSession) -> SessionSummary? {
        sessions.first { $0.sessionId == live.sessionId }
    }
}
