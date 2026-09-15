import Foundation

/// A finished Claude pre-review of a PR that still waits on the user.
public struct ReadyReview: Sendable, Hashable {
    public var pr: PullRequest
    public var summary: String
    public var comments: Int
    public var runs: Int

    public init(pr: PullRequest, summary: String, comments: Int, runs: Int) {
        self.pr = pr
        self.summary = summary
        self.comments = comments
        self.runs = runs
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

    public init(
        now: Date, login: String, config: DeskConfig, mine: [PullRequest], reviewRequests: [PullRequest],
        openHeadsByRepo: [String: Set<String>], defaultBranches: [String: String], readyReviews: [ReadyReview] = []
    ) {
        self.now = now
        self.login = login
        self.config = config
        self.mine = mine
        self.reviewRequests = reviewRequests
        self.openHeadsByRepo = openHeadsByRepo
        self.defaultBranches = defaultBranches
        self.readyReviews = readyReviews
    }
}

public enum NudgeEngine {
    public static func nudges(_ input: NudgeInput) -> [Nudge] {
        var nudges: [Nudge] = []
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

        for pr in input.reviewRequests {
            let waiting = input.now.timeIntervalSince(pr.createdAt)
            nudges.append(Nudge(id: "review:\(pr.url)", kind: .reviewRequested, severity: waiting > 86_400 ? .warning : .info, title: "Review waits: \(pr.repoName)#\(pr.number)", detail: "\(pr.title) · \(pr.author) · \(TimeText.duration(waiting))", url: pr.url))
        }

        for review in input.readyReviews {
            let pr = review.pr
            let detail = review.comments > 0
                ? "\(review.comments) comments to look over"
                : (review.summary.isEmpty ? pr.title : review.summary)
            nudges.append(Nudge(
                id: "prereview:\(pr.url):\(review.runs)", kind: .reviewReady, severity: .info,
                title: "Claude reviewed \(pr.repoName)#\(pr.number)", detail: detail, url: pr.url
            ))
        }

        return nudges.sorted { ($0.severity, $0.title) > ($1.severity, $1.title) }
    }
}
