import Foundation

/// Where one of your pull requests stands in the app's flow, from the ticket's session to the merge. Read afresh on
/// every refresh from GitHub alone: nothing of it is saved. What the PR's session is doing, and the PR's open threads,
/// are shown beside the stage, at any stage.
public enum FlowStage: String, Sendable, CaseIterable {
    case working, draft, selfReviewed, inReview, approved, merged, closed

    public var title: String {
        switch self {
        case .working: return "Working"
        case .draft: return "Draft"
        case .selfReviewed: return "Self-reviewed"
        case .inReview: return "In review"
        // Not "Approved": that word is GitHub's review decision, shown in the same row.
        case .approved: return "Ready to merge"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    /// The stages that move only when you press something, once the session is not at work.
    public var waitsOnYou: Bool { [.draft, .selfReviewed, .approved].contains(self) }

    /// A PR's stage: a draft without /pre-pr's evidence is a draft, one with it is self-reviewed; a ready PR with the
    /// approvals it needs and nothing open is ready to merge, and in review until then.
    public static func of(_ pr: PullRequest) -> FlowStage {
        switch pr.state {
        case .merged: return .merged
        case .closed: return .closed
        case .open: break
        }
        if pr.isDraft { return pr.evidence == nil ? .draft : .selfReviewed }
        return pr.approvalsMet && pr.unresolvedThreads == 0 ? .approved : .inReview
    }
}
