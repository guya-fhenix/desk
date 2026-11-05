import Foundation

/// A draft review with Claude's comments in it, waiting on you.
public struct ReadyReview: Sendable, Hashable {
    public var pr: PullRequest
    /// Every comment in the draft, yours included.
    public var comments: Int
    public var draftId: String

    public init(pr: PullRequest, comments: Int, draftId: String) {
        self.pr = pr
        self.comments = comments
        self.draftId = draftId
    }
}

public struct NudgeInput: Sendable {
    public var now: Date
    public var login: String
    public var config: DeskConfig
    public var mine: [PullRequest]
    public var reviewRequests: [PullRequest]
    public var openHeadsByRepo: [String: Set<String>]
    public var defaultBranches: [String: String]
    public var readyReviews: [ReadyReview]
    /// The background sessions, newest first: one on a PR of yours puts it in the flow.
    public var sessions: [ClaudeJob]

    public init(
        now: Date, login: String, config: DeskConfig, mine: [PullRequest], reviewRequests: [PullRequest],
        openHeadsByRepo: [String: Set<String>], defaultBranches: [String: String], readyReviews: [ReadyReview] = [],
        sessions: [ClaudeJob] = []
    ) {
        self.now = now
        self.login = login
        self.config = config
        self.mine = mine
        self.reviewRequests = reviewRequests
        self.openHeadsByRepo = openHeadsByRepo
        self.defaultBranches = defaultBranches
        self.readyReviews = readyReviews
        self.sessions = sessions
    }

    /// The session carrying this PR through the flow, as `DeskState.session(for:)` picks it.
    func session(for pr: PullRequest) -> ClaudeJob? {
        guard let key = ClaudeJobs.prKey(pr.url) else { return nil }
        return sessions.first { $0.prKeys.contains(key) }
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
                let latest = pr.reviews.filter { $0.state == "CHANGES_REQUESTED" }.map(\.submittedAt).max() ?? pr.updatedAt
                nudges.append(Nudge(id: "changes:\(pr.url):\(latest.timeIntervalSince1970)", kind: .changesRequested, severity: .warning, title: "Changes requested on \(label)", detail: pr.title, url: pr.url))
            }
            let openHeads = input.openHeadsByRepo[pr.repoName] ?? []
            let defaultBranch = input.defaultBranches[pr.repoName] ?? "main"
            if let reason = Linker.rebaseReason(pr, openHeads: openHeads, defaultBranch: defaultBranch) {
                nudges.append(Nudge(id: "rebase:\(pr.url):\(reason.rawValue):\(pr.headSha)", kind: .needsRebase, severity: .warning, title: "\(label) needs a rebase", detail: "\(reason.text): \(pr.baseRef)", url: pr.url))
            }
            if pr.reviewDecision == .approved && pr.mergeState == .clean && !pr.checks.isRed && !pr.checks.isPending && !inFlow {
                nudges.append(Nudge(id: "ready:\(pr.url):\(pr.headSha)", kind: .readyToMerge, severity: .info, title: "\(label) is approved and green", detail: "Merge it.", url: pr.url))
            }
        }

        for pr in input.reviewRequests {
            let waiting = input.now.timeIntervalSince(pr.createdAt)
            nudges.append(Nudge(id: "review:\(pr.url)", kind: .reviewRequested, severity: waiting > 86_400 ? .warning : .info, title: "Needs review: \(pr.repoName)#\(pr.number)", detail: "\(pr.title) · \(pr.author) · \(TimeText.duration(waiting))", url: pr.url))
        }

        for review in input.readyReviews {
            let pr = review.pr
            // The Files tab, which is where a pending review's comments are read and finished. Keyed by
            // the draft, so a new draft on the same PR is news again.
            nudges.append(Nudge(
                id: "prereview:\(review.draftId)", kind: .reviewReady, severity: .info,
                title: "Claude reviewed \(pr.repoName)#\(pr.number)",
                detail: "\(review.comments) \(review.comments == 1 ? "comment" : "comments") waiting in your draft review",
                url: "\(pr.url)/files"
            ))
        }

        nudges += flowNudges(input)
        return nudges.sorted { ($0.severity, $0.title) > ($1.severity, $1.title) }
    }

    /// The flow's presses that wait on you, and the sessions that do: a session on one of your PRs, or one started on a
    /// ticket. A stage's nudge is keyed by the PR head and an ask by when the session last moved, so each new wait is news
    /// once.
    private static func flowNudges(_ input: NudgeInput) -> [Nudge] {
        var nudges: [Nudge] = []
        for session in input.sessions where session.state == "blocked" {
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
            guard let session = input.session(for: pr) else { continue }
            let stage = FlowStage.of(pr, session: session)
            let label = "\(pr.repoName)#\(pr.number)"
            let title: String
            switch stage {
            case .draft: title = "\(label) is a draft waiting for your approval"
            case .fixesToCheck: title = "\(label): self-review done, check its fixes"
            case .threadsToReview: title = "\(label): \(pr.unresolvedThreads) open \(pr.unresolvedThreads == 1 ? "thread" : "threads") to review"
            case .approved: title = "\(label) is approved: merge it"
            default: continue
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
