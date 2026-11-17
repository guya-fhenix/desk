import Foundation

/// One piece of work: what the master session and its workers act on, and what the Tasks screen lists. It starts from a
/// Jira ticket, from a session started without one (an investigation of cloud errors, say), or from a PR with neither,
/// and is named after it. Worked out afresh on every refresh; nothing of it is stored.
public struct WorkTask: Sendable, Identifiable, Hashable {
    public enum Origin: String, Sendable, Codable {
        case ticket, session, pullRequest
    }

    /// The ticket key, the session's name, or the `owner/name#number` of the stack's root PR.
    public var id: String
    public var origin: Origin
    public var title: String
    /// Your open PRs in it, each stack contiguous and base first.
    public var pullRequests: [PullRequest]
    /// Its sessions, newest first. The first is its worker.
    public var sessions: [ClaudeJob]
    /// What its PRs sit on that is not theirs to merge: another person's open PR (`owner/name#number`), or a branch that
    /// no open PR opens and no merged PR closed (`owner/name@branch`).
    public var dependsOn: [String]

    public init(
        id: String, origin: Origin, title: String, pullRequests: [PullRequest] = [], sessions: [ClaudeJob] = [],
        dependsOn: [String] = []
    ) {
        self.id = id
        self.origin = origin
        self.title = title
        self.pullRequests = pullRequests
        self.sessions = sessions
        self.dependsOn = dependsOn
    }

    public var worker: ClaudeJob? { sessions.first }

    /// The stage of its least advanced PR; working until it has one.
    public var stage: FlowStage {
        pullRequests.map(FlowStage.of).min { FlowStage.allCases.firstIndex(of: $0)! < FlowStage.allCases.firstIndex(of: $1)! } ?? .working
    }

    /// When anything in it last moved.
    public var updatedAt: Date {
        (pullRequests.map(\.updatedAt) + sessions.map(\.updatedAt)).max() ?? .distantPast
    }

    /// Who it waits on. `asked` holds the tasks the master has a question open on.
    public func waitingOn(asked: Set<String>) -> TaskWait {
        if asked.contains(id) || sessions.contains(where: \.isAsking) { return .you }
        if sessions.contains(where: \.isRunning) { return .worker }
        // A PR of its yours to fix — a conflict, red CI, changes asked for, a thread open — is yours, whatever the stage.
        if pullRequests.contains(where: { RowState.of($0).move == .yoursToFix }) { return .you }
        switch stage {
        case .inReview: return .reviewers
        case .draft, .approved: return .you
        case .working, .merged, .closed: return .nobody
        }
    }
}

public enum TaskWait: String, Sendable, Codable {
    case you, worker, reviewers, nobody
}

extension Linker {
    /// Groups your open PRs and the sessions into tasks, most recently moved first.
    ///
    /// A PR belongs to the ticket it, or the root of its stack, names; else to the worker session that carries it and was
    /// started on no ticket; else to its stack's root PR. A session started on a ticket joins that ticket's task, with or
    /// without a PR. Any other session is a task of its own when it is a worker, or runs in `trackedRoots`, and carries
    /// none of your PRs: the master and review sessions never are, and one that has sat done for `idleDays` drops off
    /// unless `keep` names it (the master still has a question open on it).
    public static func tasks(
        mine: [PullRequest], allOpen: [PullRequest], merged: [PullRequest], ticketKeys: [String: [String]], tickets: [Ticket],
        sessions: [ClaudeJob], trackedRoots: [String] = [], keep: Set<String> = [], now: Date = Date(), idleDays: Double = 3
    ) -> [WorkTask] {
        let parents = stackParents(allOpen)
        let mineByURL = Dictionary(mine.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let openByURL = Dictionary(allOpen.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let mergedHeads = mergedHeadsByRepo(merged)
        let eligible = sessions.filter { $0.role != .master && $0.role != .review }

        func root(of pr: PullRequest) -> PullRequest {
            var current = pr
            var seen: Set<String> = [pr.url]
            while let parent = parents[current.url].flatMap({ mineByURL[$0] }), seen.insert(parent.url).inserted { current = parent }
            return current
        }

        var tasks: [String: WorkTask] = [:]
        var order: [String] = []
        func add(_ id: String, _ origin: WorkTask.Origin, _ title: @autoclosure () -> String) {
            guard tasks[id] == nil else { return }
            tasks[id] = WorkTask(id: id, origin: origin, title: title())
            order.append(id)
        }

        var carried = Set<String>()
        for pr in mine {
            let top = root(of: pr)
            let prKey = ClaudeJobs.prKey(pr.url) ?? pr.url
            let carrier = ClaudeJobs.carrier(of: prKey, tickets: ticketKeys[pr.url] ?? [], in: eligible)
            if let carrier { carried.insert(carrier.id) }
            let id: String
            if let key = ticketKeys[pr.url]?.first ?? ticketKeys[top.url]?.first {
                id = key
                add(id, .ticket, tickets.first { $0.key == key }?.summary ?? top.title)
            } else if let carrier, carrier.role == .worker, carrier.ticketKey == nil {
                id = carrier.name
                add(id, .session, carrier.request ?? carrier.name)
            } else {
                id = ClaudeJobs.prKey(top.url) ?? top.url
                add(id, .pullRequest, top.title)
            }
            tasks[id]!.pullRequests.append(pr)
            if let carrier, !tasks[id]!.sessions.contains(carrier) { tasks[id]!.sessions.append(carrier) }
        }

        for session in eligible {
            if let key = session.ticketKey {
                add(key, .ticket, tickets.first { $0.key == key }?.summary ?? session.name)
                if !tasks[key]!.sessions.contains(session) { tasks[key]!.sessions.append(session) }
                continue
            }
            guard !carried.contains(session.id), session.role == .worker || ClaudePaths.path(session.cwd, isUnder: trackedRoots)
            else { continue }
            let stale = session.isIdle && session.updatedAt < now.addingTimeInterval(-idleDays * 86_400)
            guard !stale || keep.contains(session.name) else { continue }
            add(session.name, .session, session.request ?? session.name)
            if !tasks[session.name]!.sessions.contains(session) { tasks[session.name]!.sessions.append(session) }
        }

        return order.compactMap { id -> WorkTask? in
            guard var task = tasks[id] else { return nil }
            let byNumber = [KeyPathComparator(\StackedPullRequest.pullRequest.number)]
            task.pullRequests = stacked(task.pullRequests, parents: parents, order: byNumber).map(\.pullRequest)
            task.sessions.sort { $0.updatedAt > $1.updatedAt }
            let inTask = Set(task.pullRequests.map(\.url))
            var depends: [String] = []
            for pr in task.pullRequests where pr.baseRef != pr.defaultBranch {
                if let parent = parents[pr.url] {
                    if !inTask.contains(parent), let other = openByURL[parent] { depends.append(ClaudeJobs.prKey(other.url) ?? other.url) }
                } else if mergedHeads[pr.repo]?.contains(pr.baseRef) != true {
                    depends.append("\(pr.repo.lowercased())@\(pr.baseRef)")
                }
            }
            task.dependsOn = Array(Set(depends)).sorted()
            return task
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }
}
