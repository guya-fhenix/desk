import Foundation

public enum RebaseReason: String, Sendable {
    case conflicts
    case behindBase
    case baseMerged

    public var text: String {
        switch self {
        case .conflicts: return "merge conflicts"
        case .behindBase: return "behind its base"
        case .baseMerged: return "base branch has no open PR"
        }
    }
}

public struct LinkerInput: Sendable {
    public var pullRequests: [PullRequest]
    public var worktrees: [Worktree]
    public var sessions: [SessionSummary]
    public var liveSessions: [LiveSession]
    public var tickets: [Ticket]
    public var matcher: TicketKeyMatcher

    public init(pullRequests: [PullRequest], worktrees: [Worktree], sessions: [SessionSummary], liveSessions: [LiveSession], tickets: [Ticket], matcher: TicketKeyMatcher) {
        self.pullRequests = pullRequests
        self.worktrees = worktrees
        self.sessions = sessions
        self.liveSessions = liveSessions
        self.tickets = tickets
        self.matcher = matcher
    }
}

public enum Linker {
    /// Joins tickets, PRs, worktrees, and Claude sessions into work items keyed by ticket, else by PR, else by worktree.
    public static func workItems(_ input: LinkerInput) -> [WorkItem] {
        var items: [String: WorkItem] = [:]
        var order: [String] = []
        func ensure(_ id: String, ticketKey: String?) {
            if items[id] == nil {
                items[id] = WorkItem(id: id, ticketKey: ticketKey)
                order.append(id)
            }
        }

        for ticket in input.tickets {
            ensure(ticket.key, ticketKey: ticket.key)
            items[ticket.key]?.ticket = ticket
        }

        var itemIdsByPullRequest: [String: [String]] = [:]
        for pr in input.pullRequests {
            let keys = input.matcher.keys(in: [pr.headRef, pr.title])
            let ids = keys.isEmpty ? [pr.url] : keys
            for id in ids {
                ensure(id, ticketKey: keys.isEmpty ? nil : id)
                items[id]?.pullRequests.append(pr)
            }
            itemIdsByPullRequest[pr.url] = ids
        }

        var itemIdsByWorktree: [String: [String]] = [:]
        for worktree in input.worktrees where !(worktree.isMain && worktree.isOnDefaultBranch) && !worktree.isPrunable {
            let keys = input.matcher.keys(in: [worktree.branch ?? "", worktree.name])
            var ids = keys
            if ids.isEmpty, let branch = worktree.branch {
                ids = input.pullRequests
                    .filter { $0.repoName == worktree.repoName && $0.headRef == branch }
                    .flatMap { itemIdsByPullRequest[$0.url] ?? [] }
            }
            if ids.isEmpty { ids = [worktree.path] }
            for id in ids {
                ensure(id, ticketKey: keys.contains(id) ? id : nil)
                items[id]?.worktrees.append(worktree)
            }
            itemIdsByWorktree[worktree.path] = ids
        }

        var itemIdsBySession: [String: Set<String>] = [:]
        for session in input.sessions {
            let repo = session.cwd.flatMap { repoName(forPath: $0, worktrees: input.worktrees) }
            var ids = Set(input.matcher.keys(in: session.branches + [session.title ?? ""] + session.paths.map { ($0 as NSString).lastPathComponent }))
            for link in session.prLinks {
                ids.formUnion(itemIdsByPullRequest[link.url] ?? [])
            }
            for pr in input.pullRequests where session.branches.contains(pr.headRef) && (repo == nil || pr.repoName == repo) {
                ids.formUnion(itemIdsByPullRequest[pr.url] ?? [])
            }
            for path in session.paths {
                for (worktreePath, worktreeIds) in itemIdsByWorktree where path == worktreePath || path.hasPrefix(worktreePath + "/") {
                    ids.formUnion(worktreeIds)
                }
            }
            let existing = ids.filter { items[$0] != nil }
            for id in existing { items[id]?.sessions.append(session) }
            itemIdsBySession[session.sessionId] = existing
        }

        for live in input.liveSessions where live.isAlive {
            var ids = itemIdsBySession[live.sessionId] ?? []
            for (worktreePath, worktreeIds) in itemIdsByWorktree where live.cwd == worktreePath || live.cwd.hasPrefix(worktreePath + "/") {
                ids.formUnion(worktreeIds)
            }
            for id in ids where items[id] != nil { items[id]?.liveSessions.append(live) }
        }

        return order.compactMap { items[$0] }.map(sorted).sorted(by: rank)
    }

    private static func sorted(_ item: WorkItem) -> WorkItem {
        var item = item
        item.pullRequests.sort { $0.updatedAt > $1.updatedAt }
        item.sessions.sort { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
        item.worktrees.sort { $0.path < $1.path }
        return item
    }

    private static func rank(_ lhs: WorkItem, _ rhs: WorkItem) -> Bool {
        func score(_ item: WorkItem) -> Int {
            var score = 0
            if !item.liveSessions.isEmpty { score += 8 }
            if item.ticket?.category == .inProgress { score += 4 }
            if !item.pullRequests.isEmpty { score += 2 }
            if !item.worktrees.isEmpty { score += 1 }
            return score
        }
        let (l, r) = (score(lhs), score(rhs))
        if l != r { return l > r }
        return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
    }

    /// Longest worktree path that contains `path` decides the repo.
    public static func repoName(forPath path: String, worktrees: [Worktree]) -> String? {
        worktrees
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }?
            .repoName
    }

    /// Maps each PR url to the url of the PR it is stacked on.
    public static func stackParents(_ pullRequests: [PullRequest]) -> [String: String] {
        var headsByRepo: [String: [String: String]] = [:]
        for pr in pullRequests { headsByRepo[pr.repo, default: [:]][pr.headRef] = pr.url }
        var parents: [String: String] = [:]
        for pr in pullRequests {
            if let parent = headsByRepo[pr.repo]?[pr.baseRef], parent != pr.url { parents[pr.url] = parent }
        }
        return parents
    }

    public static func stackDepth(_ url: String, parents: [String: String]) -> Int {
        var depth = 0
        var current = url
        var visited = Set<String>()
        while let parent = parents[current], visited.insert(parent).inserted {
            depth += 1
            current = parent
        }
        return depth
    }

    public static func defaultBranches(worktrees: [Worktree], pullRequests: [PullRequest]) -> [String: String] {
        var result: [String: String] = [:]
        for worktree in worktrees where worktree.isMain { result[worktree.repoName] = worktree.defaultBranch }
        for pr in pullRequests where result[pr.repoName] == nil {
            let bases = pullRequests.filter { $0.repoName == pr.repoName }.map(\.baseRef)
            result[pr.repoName] = bases.contains("master") && !bases.contains("main") ? "master" : "main"
        }
        return result
    }

    public static func rebaseReason(_ pr: PullRequest, openHeads: Set<String>, defaultBranch: String) -> RebaseReason? {
        if pr.mergeState == .dirty { return .conflicts }
        if pr.mergeState == .behind { return .behindBase }
        if pr.baseRef != defaultBranch && !openHeads.contains(pr.baseRef) { return .baseMerged }
        return nil
    }

    public static func openHeadsByRepo(_ pullRequests: [PullRequest]) -> [String: Set<String>] {
        var heads: [String: Set<String>] = [:]
        for pr in pullRequests where pr.state == .open { heads[pr.repoName, default: []].insert(pr.headRef) }
        return heads
    }
}
