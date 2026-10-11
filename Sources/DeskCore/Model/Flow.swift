import Foundation

/// Where a pull request stands in the app's own flow, from the ticket's session to the merge. Not Jira's status
/// and not GitHub's: a draft that you approved and that is now reviewing itself looks the same as any other
/// draft on GitHub, which is why the stage is kept here.
public enum FlowStage: String, Codable, Sendable, CaseIterable {
    case working, draft, selfReview, fixesToCheck, inReview, fixesProposed, applying, approved, merged

    public var title: String {
        switch self {
        case .working: return "Working"
        case .draft: return "Draft"
        case .selfReview: return "Self-review"
        case .fixesToCheck: return "Fixes to check"
        case .inReview: return "In review"
        case .fixesProposed: return "Fixes proposed"
        case .applying: return "Applying"
        case .approved: return "Approved"
        case .merged: return "Merged"
        }
    }

    /// The stages that move only when you press something.
    public var waitsOnYou: Bool { [.draft, .fixesToCheck, .fixesProposed, .approved].contains(self) }
}

/// One background session carried from a ticket to its merge. Saved in `flows.json`: the stage is the one thing
/// here that neither GitHub nor the session can tell the app again after it quits.
public struct Flow: Codable, Sendable, Hashable, Identifiable {
    public var id: String { jobId }
    /// The short id `claude --bg` printed, which `claude attach` takes.
    public var jobId: String
    public var ticketKey: String?
    /// The clone the session started in.
    public var repoRoot: String
    /// The pull request the session opened, once it has.
    public var prURL: String?
    public var stage: FlowStage
    public var startedAt: Date

    public init(jobId: String, ticketKey: String?, repoRoot: String, prURL: String? = nil, stage: FlowStage = .working, startedAt: Date) {
        self.jobId = jobId
        self.ticketKey = ticketKey
        self.repoRoot = repoRoot
        self.prURL = prURL
        self.stage = stage
        self.startedAt = startedAt
    }
}

/// Moves a flow along on what GitHub and the session say. Only the moves nobody has to press for happen here.
public enum FlowEngine {
    public static func advance(
        _ flow: Flow, job: ClaudeJob?, mine: [PullRequest], merged: [PullRequest], ticketKeys: [String: [String]]
    ) -> Flow {
        var flow = flow
        if flow.prURL == nil, let job, let pr = openedPR(flow, job: job, mine: mine, ticketKeys: ticketKeys) {
            flow.prURL = pr.url
            flow.stage = pr.isDraft ? .draft : .inReview
        }
        guard let url = flow.prURL else { return flow }
        if merged.contains(where: { $0.url == url }) {
            flow.stage = .merged
        } else if flow.stage == .draft, mine.first(where: { $0.url == url })?.isDraft == false {
            // Marked ready by hand on GitHub: the draft stages are behind it.
            flow.stage = .inReview
        }
        return flow
    }

    /// The PR this session opened. Claude Code's link scan lists every PR a session touched, including ones it
    /// only read, so it has to be one of yours that appeared after the session started; one that names the
    /// ticket beats one that does not, and the first opened wins.
    static func openedPR(_ flow: Flow, job: ClaudeJob, mine: [PullRequest], ticketKeys: [String: [String]]) -> PullRequest? {
        let opened = mine.filter { pr in
            pr.createdAt >= flow.startedAt && ClaudeJobs.prKey(pr.url).map(job.prKeys.contains) == true
        }
        let named = opened.filter { pr in flow.ticketKey.map { ticketKeys[pr.url]?.contains($0) == true } ?? false }
        return (named.isEmpty ? opened : named).min { $0.createdAt < $1.createdAt }
    }
}
