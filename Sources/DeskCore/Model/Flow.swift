import Foundation

/// Where one of your pull requests stands in the app's flow, from the ticket's session to the merge. Worked out afresh
/// on every refresh from what GitHub says of the PR and whether its session is running: nothing of it is saved.
public enum FlowStage: String, Sendable, CaseIterable {
    case working, draft, selfReview, fixesToCheck, inReview, threadsToReview, fixing, approved, merged, closed

    public var title: String {
        switch self {
        case .working: return "Working"
        case .draft: return "Draft"
        case .selfReview: return "Self-review"
        case .fixesToCheck: return "Fixes to check"
        case .inReview: return "In review"
        case .threadsToReview: return "Threads to review"
        case .fixing: return "Fixing"
        // Not "Approved": that word is GitHub's review decision, shown in the same row.
        case .approved: return "Ready to merge"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    /// The stages that move only when you press something.
    public var waitsOnYou: Bool { [.draft, .fixesToCheck, .threadsToReview, .approved].contains(self) }

    /// A PR's stage. A running session is the self-review on a draft and fixing on a ready PR; an idle one, or none,
    /// leaves it to the PR: a draft with /pre-pr's evidence has fixes to check, a ready one with an open thread has
    /// threads to review, and one with the approvals it needs and nothing open is ready to merge.
    public static func of(_ pr: PullRequest, session: ClaudeJob?) -> FlowStage {
        switch pr.state {
        case .merged: return .merged
        case .closed: return .closed
        case .open: break
        }
        let running = session?.isBusy == true
        if pr.isDraft { return running ? .selfReview : pr.evidence == nil ? .draft : .fixesToCheck }
        if running { return .fixing }
        if pr.unresolvedThreads > 0 { return .threadsToReview }
        return pr.approvalsMet ? .approved : .inReview
    }
}
