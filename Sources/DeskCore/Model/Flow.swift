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

/// One instruction the app sends a flow's session. Each ends with the session writing a result file, which is
/// how the app knows it has finished: a session reports `done` between the rounds of a `/goal` too.
public enum FlowPrompt: String, Codable, Sendable {
    case selfReview, proposeFixes, applyFixes, fixConflict, fixChecks

    public var title: String {
        switch self {
        case .selfReview: return "Self-review"
        case .proposeFixes: return "Proposing fixes"
        case .applyFixes: return "Applying fixes"
        case .fixConflict: return "Fixing the conflict"
        case .fixChecks: return "Fixing CI"
        }
    }

    /// Sent without a press of yours, so it also waits for the session to have sat idle a while.
    public var isAutomatic: Bool { [.proposeFixes, .fixConflict, .fixChecks].contains(self) }
}

/// One finding of the self-review, as the session reports it.
public struct Finding: Codable, Sendable, Hashable {
    public var severity: String
    public var file: String
    public var line: Int?
    public var problem: String
    /// What the session changed, or why it left it.
    public var fix: String
    public var round: Int?
    public var fixed: Bool?

    public init(severity: String, file: String, line: Int? = nil, problem: String, fix: String, round: Int? = nil, fixed: Bool? = nil) {
        self.severity = severity
        self.file = file
        self.line = line
        self.problem = problem
        self.fix = fix
        self.round = round
        self.fixed = fixed
    }
}

/// The self-review's result file.
public struct SelfReview: Codable, Sendable, Hashable {
    public var rounds: Int?
    /// Whether the last review found no High or Medium.
    public var clean: Bool?
    public var findings: [Finding]

    public init(rounds: Int? = nil, clean: Bool? = nil, findings: [Finding] = []) {
        self.rounds = rounds
        self.clean = clean
        self.findings = findings
    }
}

/// One fix the session proposes for a reviewer's comment. Nothing happens to it until you decide.
public struct Proposal: Codable, Sendable, Hashable {
    /// The review thread's node id, which resolving it takes.
    public var thread: String?
    public var reviewer: String?
    public var file: String?
    public var line: Int?
    /// What the reviewer asks for.
    public var comment: String
    /// What the session would change.
    public var fix: String
    public var diff: String?
    /// Resolve the thread once the fix is in: the session's call on whether it is simple, yours to flip.
    public var resolve: Bool
    /// Apply it, skip it, or nil while you have not decided.
    public var apply: Bool?

    public init(
        thread: String? = nil, reviewer: String? = nil, file: String? = nil, line: Int? = nil, comment: String, fix: String,
        diff: String? = nil, resolve: Bool = false, apply: Bool? = nil
    ) {
        self.thread = thread
        self.reviewer = reviewer
        self.file = file
        self.line = line
        self.comment = comment
        self.fix = fix
        self.diff = diff
        self.resolve = resolve
        self.apply = apply
    }

    private enum CodingKeys: String, CodingKey { case thread, reviewer, file, line, comment, fix, diff, resolve, apply }

    /// Lenient: the session writes these, and a field it leaves out must not cost the rest of the file.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thread = try c.decodeIfPresent(String.self, forKey: .thread)
        reviewer = try c.decodeIfPresent(String.self, forKey: .reviewer)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        line = try? c.decodeIfPresent(Int.self, forKey: .line)
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        fix = try c.decodeIfPresent(String.self, forKey: .fix) ?? ""
        diff = try c.decodeIfPresent(String.self, forKey: .diff)
        resolve = try c.decodeIfPresent(Bool.self, forKey: .resolve) ?? false
        apply = try c.decodeIfPresent(Bool.self, forKey: .apply)
    }

    /// `file:line`, or whichever of them there is.
    public var place: String {
        [file, line.map(String.init)].compactMap { $0 }.joined(separator: ":")
    }
}

private struct ProposalsFile: Decodable {
    var proposals: [Proposal]
}

/// What an automatic fix reports.
private struct FixFile: Decodable {
    var fixed: Bool?
    var summary: String?
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
    /// While on, the app sends the session nothing: you are driving it yourself.
    public var paused = false
    /// An instruction waiting for the session to be free.
    public var pending: FlowPrompt?
    /// The instruction the session is on, until its result file appears.
    public var awaiting: FlowPrompt?
    /// Numbers the result files, so a file from an earlier instruction is never read as this one's.
    public var step = 0
    /// When the awaited instruction went out.
    public var sentAt: Date?
    /// The PR head when self-review started: where its changes begin.
    public var baseSha: String?
    public var selfReview: SelfReview?
    /// The session's proposed fixes for the latest reviews, with your decisions.
    public var proposals: [Proposal] = []
    /// Reviews submitted after this start a round of proposed fixes.
    public var reviewsSince: Date?
    /// The PR head each automatic fix was last tried on, by instruction: one try per head, so a fix that did not
    /// take is left to you instead of being sent again on every poll.
    public var autoFixes: [String: String] = [:]
    /// What last went wrong, shown until the next instruction goes out.
    public var note: String?

    public init(
        jobId: String, ticketKey: String?, repoRoot: String, prURL: String? = nil, stage: FlowStage = .working,
        startedAt: Date, reviewsSince: Date? = nil
    ) {
        self.jobId = jobId
        self.ticketKey = ticketKey
        self.repoRoot = repoRoot
        self.prURL = prURL
        self.stage = stage
        self.startedAt = startedAt
        self.reviewsSince = reviewsSince
    }

    private enum CodingKeys: String, CodingKey {
        case jobId, ticketKey, repoRoot, prURL, stage, startedAt, paused, pending, awaiting, step, sentAt, baseSha, selfReview
        case proposals, reviewsSince, autoFixes, note
    }

    /// Every field after the first few is optional on the way in, so a flows.json written before it existed loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try c.decode(String.self, forKey: .jobId)
        ticketKey = try c.decodeIfPresent(String.self, forKey: .ticketKey)
        repoRoot = try c.decode(String.self, forKey: .repoRoot)
        prURL = try c.decodeIfPresent(String.self, forKey: .prURL)
        stage = try c.decode(FlowStage.self, forKey: .stage)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        pending = try c.decodeIfPresent(FlowPrompt.self, forKey: .pending)
        awaiting = try c.decodeIfPresent(FlowPrompt.self, forKey: .awaiting)
        step = try c.decodeIfPresent(Int.self, forKey: .step) ?? 0
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt)
        baseSha = try c.decodeIfPresent(String.self, forKey: .baseSha)
        selfReview = try c.decodeIfPresent(SelfReview.self, forKey: .selfReview)
        proposals = try c.decodeIfPresent([Proposal].self, forKey: .proposals) ?? []
        reviewsSince = try c.decodeIfPresent(Date.self, forKey: .reviewsSince)
        autoFixes = try c.decodeIfPresent([String: String].self, forKey: .autoFixes) ?? [:]
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

/// What the polls said about one flow.
public struct FlowInput: Sendable {
    public var job: ClaudeJob?
    public var mine: [PullRequest]
    public var merged: [PullRequest]
    public var ticketKeys: [String: [String]]
    /// The awaited instruction's result file, once the session has written it.
    public var result: Data?
    /// You, whose own reviews start nothing.
    public var login: String
    /// Accounts whose reviews start nothing either: the bot list in Settings.
    public var bots: Set<String>
    public var now: Date

    public init(
        job: ClaudeJob?, mine: [PullRequest], merged: [PullRequest], ticketKeys: [String: [String]] = [:], result: Data? = nil,
        login: String = "", bots: Set<String> = [], now: Date = Date()
    ) {
        self.job = job
        self.mine = mine
        self.merged = merged
        self.ticketKeys = ticketKeys
        self.result = result
        self.login = login
        self.bots = bots
        self.now = now
    }
}

/// What the app has to do for a flow after it moved.
public enum FlowEffect: Sendable, Equatable {
    /// Stop the idle session and resume it with this instruction.
    case send(FlowPrompt)
    /// Ask the review team again: fixes went in and the PR is still not approved.
    case requestTeam
}

/// Moves a flow along on what GitHub and the session say. Only the moves nobody has to press for happen here;
/// a press changes the flow first and lets this send what it queued.
public enum FlowEngine {
    /// How long a session sits idle before an automatic instruction may interrupt it.
    /// ponytail: one fixed wait for every session; a per-flow setting if 10 minutes turns out wrong.
    public static let idleBeforeAutomatic: TimeInterval = 600

    public static func advance(_ flow: Flow, _ input: FlowInput) -> (flow: Flow, effects: [FlowEffect]) {
        var flow = flow
        if flow.prURL == nil, let job = input.job, let pr = openedPR(flow, job: job, mine: input.mine, ticketKeys: input.ticketKeys) {
            flow.prURL = pr.url
            flow.stage = pr.isDraft ? .draft : .inReview
            if !pr.isDraft { flow.reviewsSince = input.now }
        }
        guard let url = flow.prURL else { return (flow, []) }
        if input.merged.contains(where: { $0.url == url }) {
            flow.stage = .merged
            flow.pending = nil
            flow.awaiting = nil
            return (flow, [])
        }
        let pr = input.mine.first { $0.url == url }
        if flow.stage == .draft, pr?.isDraft == false {
            // Marked ready by hand on GitHub: the draft stages are behind it.
            flow.stage = .inReview
            flow.reviewsSince = input.now
        }
        var effects: [FlowEffect] = []
        if let awaiting = flow.awaiting, let result = input.result {
            effects += finish(&flow, awaiting, result: result, pr: pr)
        }
        if let pr, flow.pending == nil, flow.awaiting == nil { effects += review(&flow, pr, input) }
        if let pr, flow.pending == nil, flow.awaiting == nil { autoFix(&flow, pr) }
        guard let pending = flow.pending, flow.awaiting == nil, !flow.paused, let job = input.job,
              canSend(job, automatic: pending.isAutomatic, now: input.now)
        else { return (flow, effects) }
        flow.pending = nil
        flow.awaiting = pending
        flow.step += 1
        flow.sentAt = input.now
        flow.note = nil
        return (flow, effects + [.send(pending)])
    }

    /// While the PR is out for review: an approval with nothing left open moves it to Approved, and a teammate's
    /// new review asks the session for proposed fixes. Your own reviews and the bots' start nothing.
    ///
    /// An approval that goes away with no new review behind it was dismissed by a push — an automatic fix's, say —
    /// so the review team is asked again. One that a teammate's change request replaced goes the way of any other
    /// review: proposed fixes first, and the team asked again once they are in.
    private static func review(_ flow: inout Flow, _ pr: PullRequest, _ input: FlowInput) -> [FlowEffect] {
        let lostApproval = flow.stage == .approved && pr.reviewDecision != .approved
        if lostApproval { flow.stage = .inReview }
        guard flow.stage == .inReview else { return [] }
        let since = flow.reviewsSince ?? .distantPast
        let fresh = pr.reviews.filter { review in
            review.submittedAt > since && review.author != input.login && !input.bots.contains(review.author)
                && !review.author.hasSuffix("[bot]")
        }
        if let latest = fresh.map(\.submittedAt).max() { flow.reviewsSince = latest }
        if pr.reviewDecision == .approved, pr.unresolvedThreads == 0 {
            flow.stage = .approved
        } else if !fresh.isEmpty {
            flow.pending = .proposeFixes
        } else if lostApproval {
            return [.requestTeam]
        }
        return []
    }

    /// The session went quiet on the awaited instruction without writing its result: idle for two minutes after
    /// the instruction went out. Between the rounds of a `/goal` it is idle for seconds, not minutes.
    public static func isStalled(_ flow: Flow, job: ClaudeJob?, now: Date = Date()) -> Bool {
        guard flow.awaiting != nil, let job, job.state == "done", let sentAt = flow.sentAt else { return false }
        return job.updatedAt > sentAt && now.timeIntervalSince(job.updatedAt) > 120
    }

    /// The session rules: never while it works, never while it is asking you something, and an automatic
    /// instruction only once it has sat idle a while, so it does not cut in right after you were talking to it.
    public static func canSend(_ job: ClaudeJob, automatic: Bool, now: Date) -> Bool {
        guard job.state == "done" else { return false }
        return !automatic || now.timeIntervalSince(job.updatedAt) >= idleBeforeAutomatic
    }

    /// A conflict with the base, then red CI, is fixed without asking — at any stage once the session has its PR.
    private static func autoFix(_ flow: inout Flow, _ pr: PullRequest) {
        guard flow.stage != .working, flow.stage != .merged else { return }
        let fix: FlowPrompt? = pr.mergeState == .dirty ? .fixConflict : pr.checks.isRed ? .fixChecks : nil
        guard let fix, flow.autoFixes[fix.rawValue] != pr.headSha else { return }
        flow.autoFixes[fix.rawValue] = pr.headSha
        flow.pending = fix
    }

    /// Takes in what the awaited instruction left behind. `result` nil is a result you chose to go on without.
    public static func finish(_ flow: inout Flow, _ prompt: FlowPrompt, result: Data?, pr: PullRequest?) -> [FlowEffect] {
        flow.awaiting = nil
        switch prompt {
        case .selfReview:
            flow.selfReview = result.flatMap { try? JSON.decoder().decode(SelfReview.self, from: $0) }
            if result != nil, flow.selfReview == nil { flow.note = "The self-review's summary did not read; the changes are still there to look at." }
            flow.stage = .fixesToCheck
        case .proposeFixes:
            let proposals = result.flatMap { try? JSON.decoder().decode(ProposalsFile.self, from: $0) }?.proposals
            flow.proposals = proposals ?? []
            if flow.proposals.isEmpty {
                flow.stage = .inReview
                flow.note = proposals == nil
                    ? "The session's proposals did not read. Attach to ask it again."
                    : "The session found nothing to fix in the new review."
            } else {
                flow.stage = .fixesProposed
            }
        case .applyFixes:
            flow.proposals = []
            if pr?.reviewDecision == .approved {
                flow.stage = .approved
            } else {
                flow.stage = .inReview
                return [.requestTeam]
            }
        case .fixConflict, .fixChecks:
            let report = result.flatMap { try? JSON.decoder().decode(FixFile.self, from: $0) }
            if report?.fixed == false {
                flow.note = "\(prompt.title) did not work out: \(report?.summary ?? "the session gave no reason"). Attach to take it from here."
            }
        }
        return []
    }

    /// The fixes you approved, as the apply instruction lists them.
    public static func approvedFixes(_ proposals: [Proposal]) -> String {
        proposals.filter { $0.apply == true }.enumerated().map { index, proposal in
            let place = proposal.place.isEmpty ? "" : "\(proposal.place): "
            let thread = proposal.thread.map { " (thread \($0): \(proposal.resolve ? "resolve it" : "leave it open"))" } ?? ""
            return "\(index + 1). \(place)\(proposal.fix)\(thread)"
        }
        .joined(separator: "\n")
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
