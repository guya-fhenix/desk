import Foundation

public struct NudgeInput: Sendable {
    public var now: Date
    public var login: String
    public var config: DeskConfig
    public var mine: [PullRequest]
    public var reviewRequests: [PullRequest]
    /// Your merged PRs' head branches, by repo `owner/name`: a PR based on one needs a rebase.
    public var mergedHeadsByRepo: [String: Set<String>]
    /// The background sessions, newest first: one on a PR of yours puts it in the flow.
    public var sessions: [ClaudeJob]
    /// The Jira keys each PR of yours names, by PR url: a ticket's session carries its PRs.
    public var ticketKeys: [String: [String]]

    public init(
        now: Date, login: String, config: DeskConfig, mine: [PullRequest], reviewRequests: [PullRequest],
        mergedHeadsByRepo: [String: Set<String>], sessions: [ClaudeJob] = [], ticketKeys: [String: [String]] = [:]
    ) {
        self.now = now
        self.login = login
        self.config = config
        self.mine = mine
        self.reviewRequests = reviewRequests
        self.mergedHeadsByRepo = mergedHeadsByRepo
        self.sessions = sessions
        self.ticketKeys = ticketKeys
    }

    /// The session carrying this PR through the flow, as `ClaudeJobs.carrier` picks it.
    func session(for pr: PullRequest) -> ClaudeJob? {
        guard let key = ClaudeJobs.prKey(pr.url) else { return nil }
        return ClaudeJobs.carrier(of: key, tickets: ticketKeys[pr.url] ?? [], in: sessions)
    }
}

public enum NudgeEngine {
    public static func nudges(_ input: NudgeInput) -> [Nudge] {
        var nudges: [Nudge] = []

        for pr in input.mine where pr.state == .open && !pr.isDraft {
            let label = "\(pr.repoName)#\(pr.number)"
            // A PR in the flow says Merge on its own nudge.
            let inFlow = input.session(for: pr) != nil
            if pr.checks.isRed {
                nudges.append(Nudge(id: "ci:\(pr.url):\(pr.headSha)", kind: .ciFailed, severity: .urgent, title: "CI failed on \(label)", detail: pr.title, url: pr.url))
            }
            if pr.reviewDecision == .changesRequested {
                let latest = pr.reviews.filter { $0.state == .changesRequested }.map(\.submittedAt).max() ?? pr.updatedAt
                nudges.append(Nudge(id: "changes:\(pr.url):\(latest.timeIntervalSince1970)", kind: .changesRequested, severity: .warning, title: "Changes requested on \(label)", detail: pr.title, url: pr.url))
            }
            if let reason = Linker.rebaseReason(pr, mergedHeads: input.mergedHeadsByRepo[pr.repo] ?? []) {
                nudges.append(Nudge(id: "rebase:\(pr.url):\(reason.rawValue):\(pr.headSha)", kind: .needsRebase, severity: .warning, title: "\(label) needs a rebase", detail: "\(reason.text): \(pr.baseRef)", url: pr.url))
            }
            // Ready by the stage's rule, and GitHub would take the merge now: nothing left to wait for.
            if FlowStage.of(pr) == .approved && pr.mergeState == .clean && !pr.checks.isPending && !inFlow {
                nudges.append(Nudge(id: "ready:\(pr.url):\(pr.headSha)", kind: .readyToMerge, severity: .info, title: "\(label) is ready to merge", detail: "Merge it.", url: pr.url))
            }
        }

        for pr in input.reviewRequests {
            let waiting = input.now.timeIntervalSince(pr.createdAt)
            // Keyed by your last review too, so a request that comes back after you answered is news again.
            let answered = ReviewStatus.lastSubmitted(pr, by: input.login)?.submittedAt.timeIntervalSince1970 ?? 0
            nudges.append(Nudge(id: "review:\(pr.url):\(answered)", kind: .reviewRequested, severity: waiting > 86_400 ? .warning : .info, title: "Needs review: \(pr.repoName)#\(pr.number)", detail: "\(pr.title) · \(pr.author) · \(TimeText.duration(waiting))", url: pr.url))
        }

        nudges += flowNudges(input)
        return nudges.sorted { ($0.severity, $0.title) > ($1.severity, $1.title) }
    }

    /// The flow's presses that wait on you, and the sessions that do: a session on one of your PRs, or one started on a
    /// ticket. A stage's nudge is keyed by the PR head and an ask by when the session last moved, so each new wait is news
    /// once.
    private static func flowNudges(_ input: NudgeInput) -> [Nudge] {
        var nudges: [Nudge] = []
        for session in input.sessions where session.isAsking {
            let pr = input.mine.first { ClaudeJobs.prKey($0.url).map(session.prKeys.contains) == true }
            // A session on a teammate's PR, opened from Reviews, is not in the flow.
            guard let label = pr.map({ "\($0.repoName)#\($0.number)" }) ?? session.ticketKey else { continue }
            nudges.append(Nudge(
                id: "flow-ask:\(session.id):\(session.updatedAt.timeIntervalSince1970)", kind: .sessionNeedsYou, severity: .warning,
                title: "\(label): the session is asking you something", detail: pr?.title ?? "Session started from \(label)",
                url: pr?.url, jobId: session.id
            ))
        }
        for pr in input.mine where pr.state == .open {
            // A session at work leaves nothing to press; one asking something is nudged above.
            guard let session = input.session(for: pr), !session.isBusy else { continue }
            let stage = FlowStage.of(pr)
            let label = "\(pr.repoName)#\(pr.number)"
            let threads = pr.unresolvedThreads
            let open = "\(threads) open \(threads == 1 ? "thread" : "threads")"
            let title: String
            switch stage {
            case .draft:
                switch PrePRStatus.of(pr) {
                case .notRun: title = "\(label) is a draft: run /pre-pr, or mark it ready"
                case .passed: title = "\(label) passed /pre-pr: mark it ready" + (threads > 0 ? ", \(open) left" : "")
                case .importantOpen: title = "\(label): /pre-pr left an Important finding open"
                }
            case .approved: title = "\(label) is ready: merge it"
            default:
                // Open threads wait on you at any stage; a stage that waits on you already says so.
                guard threads > 0 else { continue }
                title = "\(label): \(open) to review"
            }
            // A warning, not info: this is the press only you can make, so it is counted and coloured as one.
            nudges.append(Nudge(
                id: "flow:\(pr.url):\(stage.rawValue):\(pr.headSha)", kind: .flowWaiting, severity: .warning,
                title: title, detail: pr.title, url: pr.url, jobId: session.id
            ))
        }
        return nudges
    }
}
