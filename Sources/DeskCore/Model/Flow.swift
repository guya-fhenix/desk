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
        let ready = pr.approvalsMet && pr.unresolvedThreads == 0 && !pr.checks.isRed && pr.mergeState != .dirty
        return ready ? .approved : .inReview
    }
}

/// Where /pre-pr stands on your draft: never run (no evidence comment), passed (its `local-reviewed` label), or ran and
/// left an Important finding open (evidence, no label). Run /pre-pr and Mark ready are both yours to press, in any order.
public enum PrePRStatus: Sendable, Equatable {
    case notRun, passed, importantOpen

    public static func of(_ pr: PullRequest) -> PrePRStatus {
        pr.isLocallyReviewed ? .passed : pr.evidence == nil ? .notRun : .importantOpen
    }
}

extension DeskState {
    /// Why nothing can be sent to this PR's session now, in the words beside the button that would; nil when it can.
    /// An instruction never cuts in: the session must be done with its turn. `sending` is one going out already.
    public func sendBlocker(_ pr: PullRequest, sending: Bool) -> String? {
        guard let session = session(for: pr) else { return "No session" }
        if sending { return "Sending…" }
        if session.isAsking { return "The session is asking you something" }
        if !session.isIdle || session.sessionId == nil { return "The session is busy" }
        return nil
    }

    /// Why Run /pre-pr is dead on a draft; nil when it may be pressed. Without a session it starts one, which needs a
    /// clone of the repo; `startingSession` is one starting already.
    public func prePRBlocker(_ pr: PullRequest, sending: Bool, startingSession: Bool) -> String? {
        if session(for: pr) == nil {
            if startingSession { return "Starting a session…" }
            if localRepo(for: pr) == nil { return "No clone of \(pr.repoName) here" }
        } else if let blocker = sendBlocker(pr, sending: sending) {
            return blocker
        }
        guard let skill = reviewSkill(for: pr), skill.has(skill.selfReview) else { return "Self-review skill missing" }
        return nil
    }
}
