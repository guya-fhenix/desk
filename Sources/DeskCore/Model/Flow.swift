import Foundation

/// Where one of your pull requests stands in the app's flow, from the ticket's session to the merge. Read afresh on
/// every refresh from GitHub alone: nothing of it is saved. What the PR's session is doing, and the PR's open threads,
/// are shown beside the stage, at any stage.
public enum FlowStage: String, Sendable, CaseIterable {
    case working, draft, inReview, approved, merged, closed

    public var title: String {
        switch self {
        case .working: return "Working"
        case .draft: return "Draft"
        case .inReview: return "In review"
        // Not "Approved": that word is GitHub's review decision, shown in the same row.
        case .approved: return "Ready to merge"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    /// The stages that move only when you press something, once the session is not at work.
    public var waitsOnYou: Bool { [.draft, .approved].contains(self) }

    /// A PR's stage: a draft is a draft, whatever /pre-pr has done on it (`PrePRStatus` says that); a ready PR with the
    /// approvals it needs, nothing open, CI not red and no conflicts is ready to merge, and in review until then. The one
    /// definition of ready: the stage, the ready-to-merge nudge and Up Next all go by it.
    public static func of(_ pr: PullRequest) -> FlowStage {
        switch pr.state {
        case .merged: return .merged
        case .closed: return .closed
        case .open: break
        }
        if pr.isDraft { return .draft }
        let ready = pr.approvalsMet && pr.unresolvedThreads == 0 && !pr.checks.isRed && !pr.hasConflicts
        return ready ? .approved : .inReview
    }
}

/// What one of your open PRs waits on, as its row's one pill says it: the first of these that holds, in this order, so a
/// row says one thing rather than three chips and a stage. Ready to merge is the flow's own definition.
public enum RowState: Sendable, Equatable {
    case conflicts, ciFailed, changesRequested, readyToMerge, draft(PrePRStatus), openThreads(Int), waitingOnReview

    /// Whose move it is, which colours the pill: yours to fix, yours to merge, someone else's, or a draft's, which is
    /// yours but not yet asked of anyone.
    public enum Move: Sendable { case yoursToFix, yoursToMerge, others, draft }

    /// A draft keeps its own pill with threads open: /pre-pr's findings are threads, and "finding open" says so.
    public static func of(_ pr: PullRequest) -> RowState {
        if pr.hasConflicts { return .conflicts }
        if pr.checks.isRed { return .ciFailed }
        if pr.reviewDecision == .changesRequested { return .changesRequested }
        if FlowStage.of(pr) == .approved { return .readyToMerge }
        if pr.isDraft { return .draft(PrePRStatus.of(pr)) }
        if pr.unresolvedThreads > 0 { return .openThreads(pr.unresolvedThreads) }
        return .waitingOnReview
    }

    /// A draft's names its next press, as its page's Flow card does.
    public var title: String {
        switch self {
        case .conflicts: return "Conflicts"
        case .ciFailed: return "CI failed"
        case .changesRequested: return "Changes requested"
        case .readyToMerge: return "Ready to merge"
        case .draft(.notRun): return "Draft · not self-reviewed"
        case .draft(.passed): return "Draft · self-reviewed"
        case .openThreads(let count): return count == 1 ? "1 open thread" : "\(count) open threads"
        case .waitingOnReview: return "Waiting on review"
        }
    }

    public var move: Move {
        switch self {
        case .conflicts, .ciFailed, .changesRequested, .openThreads: return .yoursToFix
        case .readyToMerge: return .yoursToMerge
        case .draft: return .draft
        case .waitingOnReview: return .others
        }
    }
}

/// Whether the self-review passed on a PR: its `local-reviewed` label, the one thing it leaves on GitHub. Its findings
/// stay in the worker's session.
public enum PrePRStatus: Sendable, Equatable {
    case notRun, passed

    public static func of(_ pr: PullRequest) -> PrePRStatus { pr.isLocallyReviewed ? .passed : .notRun }
}
