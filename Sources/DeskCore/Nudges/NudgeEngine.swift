import Foundation

public struct NudgeInput: Sendable {
    public var now: Date
    public var login: String
    public var config: DeskConfig
    public var mine: [PullRequest]
    public var reviewRequests: [PullRequest]
    public var worktrees: [Worktree]
    public var liveSessions: [LiveSession]
    public var openHeadsByRepo: [String: Set<String>]
    public var defaultBranches: [String: String]

    public init(now: Date, login: String, config: DeskConfig, mine: [PullRequest], reviewRequests: [PullRequest], worktrees: [Worktree], liveSessions: [LiveSession], openHeadsByRepo: [String: Set<String>], defaultBranches: [String: String]) {
        self.now = now
        self.login = login
        self.config = config
        self.mine = mine
        self.reviewRequests = reviewRequests
        self.worktrees = worktrees
        self.liveSessions = liveSessions
        self.openHeadsByRepo = openHeadsByRepo
        self.defaultBranches = defaultBranches
    }
}

public enum NudgeEngine {
    public static func nudges(_ input: NudgeInput) -> [Nudge] {
        var nudges: [Nudge] = []
        let automation = input.config.automation
        let staleAfter = TimeInterval(input.config.stalePullRequestDays) * 86_400

        for pr in input.mine where pr.state == .open && !pr.isDraft {
            let label = "\(pr.repoName)#\(pr.number)"
            if pr.checks.isRed {
                nudges.append(Nudge(id: "ci:\(pr.url):\(pr.headSha)", kind: .ciFailed, severity: .urgent, title: "CI failed on \(label)", detail: pr.title, url: pr.url))
            }
            if pr.reviewDecision == .changesRequested {
                let latest = pr.reviews.filter { $0.state == "CHANGES_REQUESTED" }.map(\.submittedAt).max() ?? pr.updatedAt
                nudges.append(Nudge(id: "changes:\(pr.url):\(latest.timeIntervalSince1970)", kind: .changesRequested, severity: .warning, title: "Changes requested on \(label)", detail: pr.title, url: pr.url))
            }
            let openHeads = input.openHeadsByRepo[pr.repoName] ?? []
            let defaultBranch = input.defaultBranches[pr.repoName] ?? "main"
            if let reason = Linker.rebaseReason(pr, openHeads: openHeads, defaultBranch: defaultBranch) {
                nudges.append(Nudge(id: "rebase:\(pr.url):\(reason.rawValue):\(pr.headSha)", kind: .needsRebase, severity: .warning, title: "\(label) needs a rebase", detail: "\(reason.text): \(pr.baseRef)", url: pr.url))
            }
            if pr.reviewDecision == .approved && pr.mergeState == .clean && !pr.checks.isRed && !pr.checks.isPending {
                nudges.append(Nudge(id: "ready:\(pr.url):\(pr.headSha)", kind: .readyToMerge, severity: .info, title: "\(label) is approved and green", detail: "Merge it.", url: pr.url))
            }
            if input.now.timeIntervalSince(pr.updatedAt) > staleAfter && pr.reviewDecision != .approved {
                let days = Int(input.now.timeIntervalSince(pr.updatedAt) / 86_400)
                nudges.append(Nudge(id: "stale:\(pr.url)", kind: .stalePullRequest, severity: .info, title: "\(label) is quiet for \(days) days", detail: "Ping a reviewer or close it.", url: pr.url))
            }
        }

        let botReviews = input.reviewRequests.filter { $0.isAutomated(automation) }
        for pr in input.reviewRequests where !pr.isAutomated(automation) {
            let waiting = input.now.timeIntervalSince(pr.createdAt)
            nudges.append(Nudge(id: "review:\(pr.url)", kind: .reviewRequested, severity: waiting > 86_400 ? .warning : .info, title: "Review waits: \(pr.repoName)#\(pr.number)", detail: "\(pr.title) · \(pr.author) · \(TimeText.duration(waiting))", url: pr.url))
        }
        if !botReviews.isEmpty {
            let ids = botReviews.map(\.url).sorted().joined(separator: ",")
            nudges.append(Nudge(id: "bots:\(ids.hashValue)", kind: .botReviews, severity: .info, title: "\(botReviews.count) bot PRs wait for approval", detail: botReviews.map { "\($0.repoName)#\($0.number)" }.joined(separator: ", ")))
        }

        let waitingAfter = TimeInterval(input.config.claudeWaitingMinutes) * 60
        for session in input.liveSessions where session.waitsForInput {
            guard let since = session.statusUpdatedAt, input.now.timeIntervalSince(since) > waitingAfter else { continue }
            nudges.append(Nudge(id: "claude:\(session.sessionId):\(since.timeIntervalSince1970)", kind: .claudeWaiting, severity: .warning, title: "Claude waits for you: \(session.name)", detail: "\((session.cwd as NSString).lastPathComponent) · idle \(TimeText.age(since, now: input.now))", path: session.cwd))
        }

        let unpushedAfter = TimeInterval(input.config.unpushedWorkDays) * 86_400
        let liveCwds = input.liveSessions.filter(\.isAlive).map(\.cwd)
        for worktree in input.worktrees where worktree.hasLocalWork && !worktree.isPrunable {
            guard let lastCommit = worktree.lastCommitAt, input.now.timeIntervalSince(lastCommit) > unpushedAfter else { continue }
            guard !liveCwds.contains(where: { $0 == worktree.path || $0.hasPrefix(worktree.path + "/") }) else { continue }
            let parts = [worktree.dirtyFiles > 0 ? "\(worktree.dirtyFiles) dirty files" : nil, worktree.ahead > 0 ? "\(worktree.ahead) unpushed commits" : nil, worktree.hasUpstream ? nil : "no upstream"].compactMap { $0 }
            nudges.append(Nudge(id: "unpushed:\(worktree.path):\(worktree.headSha):\(worktree.dirtyFiles)", kind: .unpushedWork, severity: .info, title: "Local work sits in \(worktree.repoName)/\(worktree.name)", detail: parts.joined(separator: ", "), path: worktree.path))
        }

        return nudges.sorted { ($0.severity, $0.title) > ($1.severity, $1.title) }
    }
}
