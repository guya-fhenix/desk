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
    public var flows: [Flow]
    /// Each flow session's state, by job id.
    public var sessionStates: [String: String]

    public init(
        now: Date, login: String, config: DeskConfig, mine: [PullRequest], reviewRequests: [PullRequest],
        openHeadsByRepo: [String: Set<String>], defaultBranches: [String: String], readyReviews: [ReadyReview] = [],
        flows: [Flow] = [], sessionStates: [String: String] = [:]
    ) {
        self.now = now
        self.login = login
        self.config = config
        self.mine = mine
        self.reviewRequests = reviewRequests
        self.openHeadsByRepo = openHeadsByRepo
        self.defaultBranches = defaultBranches
        self.readyReviews = readyReviews
        self.flows = flows
        self.sessionStates = sessionStates
    }
}

public enum NudgeEngine {
    public static func nudges(_ input: NudgeInput) -> [Nudge] {
        var nudges: [Nudge] = []
        // A flow that is not paused fixes red CI itself, proposes fixes for change requests and offers Merge, so those
        // three would only repeat what its own nudges say.
        let carried = Set(input.flows.filter { !$0.paused && $0.stage != .merged }.compactMap(\.prURL))

        for pr in input.mine where pr.state == .open && !pr.isDraft {
            let label = "\(pr.repoName)#\(pr.number)"
            let inFlow = carried.contains(pr.url)
            if pr.checks.isRed && !inFlow {
                nudges.append(Nudge(id: "ci:\(pr.url):\(pr.headSha)", kind: .ciFailed, severity: .urgent, title: "CI failed on \(label)", detail: pr.title, url: pr.url))
            }
            if pr.reviewDecision == .changesRequested && !inFlow {
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

    /// The flow's presses that wait on you, and the sessions that do. Keyed by stage and step, so each new wait is
    /// news once.
    private static func flowNudges(_ input: NudgeInput) -> [Nudge] {
        input.flows.filter { $0.stage != .merged }.flatMap { flow -> [Nudge] in
            let pr = flow.prURL.flatMap { url in input.mine.first { $0.url == url } }
            let label = pr.map { "\($0.repoName)#\($0.number)" } ?? flow.ticketKey ?? flow.jobId
            let detail = pr?.title ?? "Session started from \(flow.ticketKey ?? "a ticket")"
            var nudges: [Nudge] = []
            if input.sessionStates[flow.jobId] == "blocked" {
                nudges.append(Nudge(
                    id: "flow-ask:\(flow.jobId):\(flow.step)", kind: .sessionNeedsYou, severity: .warning,
                    title: "\(label): the session is asking you something", detail: detail, url: pr?.url, jobId: flow.jobId
                ))
            } else if let note = flow.note {
                nudges.append(Nudge(
                    id: "flow-note:\(flow.jobId):\(flow.step):\(flow.paused)", kind: .sessionNeedsYou, severity: .warning,
                    title: "\(label): \(flow.paused ? "the flow is paused" : "the flow needs a look")", detail: note,
                    url: pr?.url, jobId: flow.jobId
                ))
            }
            if flow.stage.waitsOnYou, flow.pending == nil, flow.awaiting == nil, let pr {
                let title: String
                switch flow.stage {
                case .draft: title = "\(label) is a draft waiting for your approval"
                case .fixesToCheck: title = "\(label): self-review done, check its fixes"
                case .fixesProposed: title = "\(label): \(flow.proposals.count) \(flow.proposals.count == 1 ? "fix" : "fixes") proposed"
                default: title = "\(label) is approved: merge it"
                }
                // A warning, not info: this is the press only you can make, so it is counted and coloured as one.
                nudges.append(Nudge(
                    id: "flow:\(flow.jobId):\(flow.stage.rawValue):\(flow.step)", kind: .flowWaiting, severity: .warning,
                    title: title, detail: pr.title, url: pr.url, jobId: flow.jobId
                ))
            }
            return nudges
        }
    }
}
