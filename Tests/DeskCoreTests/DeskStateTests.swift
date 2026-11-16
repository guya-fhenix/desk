import DeskCore
import Foundation
import Testing

@Suite struct DeskStateTests {
    var state: DeskState {
        var state = DeskState(config: DeskConfig())
        state.github = GitHubSnapshot(login: "me", mine: [], reviewRequests: [], mergedRecent: [], fetchedAt: Fixtures.t0)
        return state
    }

    /// Find a PR and the PR list's search: every word has to appear in repo#number, title or branch.
    @Test func aSearchFindsAPullRequestByNumberTitleOrBranch() {
        let pr = Fixtures.pr(number: 1082, title: "[CHORE] Test CI: skip, cache scope", head: "chore/test-ci-speedup")
        for search in ["#1082", "1082", "cofhe#10", "COFHE", "cache scope", "ci-speedup", "chore ci", ""] {
            #expect(pr.matches(search: search), "\(search)")
        }
        for search in ["#1083", "cache flow", "teecryptor"] {
            #expect(!pr.matches(search: search), "\(search)")
        }
    }

    /// A merge or close this app made takes the PR out of the open lists, a merge into the merged one once, and a draft it
    /// marked ready shows ready, while GitHub's search still says otherwise.
    @Test func landedAndReadiedCorrectALaggingGitHub() {
        var state = state
        let merged = Fixtures.pr(number: 1, head: "a"), closed = Fixtures.pr(number: 2, head: "b"), draft = Fixtures.pr(number: 3, head: "c", draft: true)
        state.github?.mine = [merged, closed, draft]
        state.github?.reviewRequests = [closed]
        var ended = merged
        ended.state = .merged
        var shut = closed
        shut.state = .closed
        state.apply(landed: [ended, shut], readied: [draft.url])
        state.apply(landed: [ended, shut], readied: [draft.url])
        #expect(state.mine.map(\.number) == [3] && state.mine.first?.isDraft == false)
        #expect(state.github?.reviewRequests.isEmpty == true)
        #expect(state.github?.mergedRecent.map(\.number) == [1])
    }

    /// Up Next's badge: your PRs in every section but Waiting, and the suggested Jira moves.
    @Test func upNextCountsAllButWaitingAndTheMoves() {
        var state = state
        state.github?.mine = [Fixtures.pr(number: 1, head: "feat/pro-391-gauge", checks: .failure), Fixtures.pr(number: 2, head: "b")]
        state.tickets = [Fixtures.ticket("PRO-391")]
        state.recompute()
        #expect(state.ticketDrifts.count == 1)
        #expect(state.upNext(reviewDays: nil).map(\.section) == [.yourMove, .waiting])
        #expect(state.upNextCount(reviewDays: nil) == 2)
    }

    /// An open review thread is something to answer or fix, and a conflict something to resolve, so both put the PR in
    /// Your move: a PR with threads open sat in Waiting, as if it were on someone else.
    @Test func openThreadsAndConflictsAreYourMove() {
        var state = state
        var threads = Fixtures.pr(number: 1, head: "a")
        threads.unresolvedThreads = 2
        var conflicting = Fixtures.pr(number: 2, head: "b", merge: .blocked)
        conflicting.conflicting = true
        let waiting = Fixtures.pr(number: 3, head: "c")
        state.github?.mine = [threads, conflicting, waiting]
        state.recompute()
        let plan = state.upNext(reviewDays: nil)
        #expect(plan.first { $0.section == .yourMove }?.pullRequests.map(\.number).sorted() == [1, 2])
        #expect(plan.first { $0.section == .waiting }?.pullRequests.map(\.number) == [3])
    }

    /// A move or edit of this app's is laid over a Jira answer that does not show it yet, and dropped once one does.
    @Test func ticketEditsCorrectALaggingJira() {
        var state = state
        state.tickets = [Fixtures.ticket("PRO-1", status: "In Progress"), Fixtures.ticket("PRO-2")]
        let moved = TicketEdit(status: "Done", category: .done).merging(TicketEdit(summary: "Renamed"))
        #expect(state.apply(ticketEdits: ["PRO-1": moved, "PRO-9": moved]).isEmpty)
        #expect(state.ticket("PRO-1")?.status == "Done" && state.ticket("PRO-1")?.category == .done)
        #expect(state.ticket("PRO-1")?.summary == "Renamed" && state.ticket("PRO-1")?.description == "")
        #expect(state.ticket("PRO-2") == Fixtures.ticket("PRO-2"))
        // Jira caught up: the edit changes nothing, so it can go.
        #expect(state.apply(ticketEdits: ["PRO-1": moved]) == ["PRO-1"])
    }

    /// A dismissed move stays hidden; the same ticket's next one, once its PR merges, is suggested again.
    @Test func aDismissedMoveStaysHiddenUntilItsTargetChanges() {
        var state = state
        state.github?.mine = [Fixtures.pr(number: 1, head: "feat/pro-391-gauge")]
        state.tickets = [Fixtures.ticket("PRO-391")]
        state.recompute()
        #expect(state.ticketDrifts.map(\.moveKey) == ["PRO-391→👀 Review Ready"])

        state.dismissedMoves = ["PRO-391→👀 Review Ready"]
        state.recompute()
        #expect(state.ticketDrifts.isEmpty)

        state.github?.mine = []
        state.github?.mergedRecent = [Fixtures.pr(number: 1, head: "feat/pro-391-gauge", merged: Fixtures.hours(3))]
        state.recompute()
        #expect(state.ticketDrifts.map(\.target) == ["Done"])
    }

    @Test func recentlyMergedIsTheLastThirtyDaysNewestFirst() {
        var state = state
        let day: TimeInterval = 86_400
        state.github?.mergedRecent = [2, 29, 31].map { Fixtures.pr(number: Int($0), head: "b\($0)", merged: Fixtures.t0 - $0 * day) }
        #expect(state.recentlyMerged(now: Fixtures.t0).map(\.number) == [2, 29])
    }

    /// The PR page's Reviewers card: a decision outweighs a later comment, a re-request is pending again, the author's
    /// replies are no review, and anyone asked who has not answered is pending.
    @Test func reviewersStandWhereTheirLastDecisionLeftThem() {
        var pr = Fixtures.pr(number: 5, head: "x", author: "me", reviews: [
            Review(state: .commented, submittedAt: Fixtures.t0, author: "ann"),
            Review(state: .approved, submittedAt: Fixtures.t0 + 60, author: "ann"),
            Review(state: .commented, submittedAt: Fixtures.t0 + 120, author: "ann"),
            Review(state: .changesRequested, submittedAt: Fixtures.t0 + 30, author: "bob"),
            Review(state: .commented, submittedAt: Fixtures.t0 + 40, author: "cy"),
            Review(state: .commented, submittedAt: Fixtures.t0 + 50, author: "me"),
        ])
        pr.requestedReviewers = ["bob", "Protocol Team"]
        #expect(pr.reviewerStatuses == [
            ReviewerStatus(name: "ann", state: .approved), ReviewerStatus(name: "cy", state: .commented),
            ReviewerStatus(name: "bob", state: .pending), ReviewerStatus(name: "Protocol Team", state: .pending),
        ])
    }

    @Test func mergeIsRefusedWithAReason() {
        #expect(Fixtures.pr(number: 1, head: "x", merge: .clean).mergeBlocker == nil)
        #expect(Fixtures.pr(number: 1, head: "x", merge: .unstable).mergeBlocker == nil)
        #expect(Fixtures.pr(number: 1, head: "x", merge: .clean, draft: true).mergeBlocker?.hasPrefix("A draft") == true)
        #expect(Fixtures.pr(number: 1, head: "x", base: "main", merge: .dirty).mergeBlocker == "Conflicts with main")
        #expect(Fixtures.pr(number: 1, head: "x", review: .reviewRequired, merge: .blocked).mergeBlocker == "Needs an approving review")
        #expect(Fixtures.pr(number: 1, head: "x", checks: .failure, review: .approved, merge: .blocked).mergeBlocker == "Required checks are failing")
    }

    @Test func reviewStatusComesFromThePullRequest() {
        var state = state
        var pr = Fixtures.pr(number: 9, head: "y")
        pr.pendingReview = Fixtures.pending(comments: 4, commit: "older")
        state.github?.reviewRequests = [pr]
        let status = state.reviewStatus(for: pr)
        #expect(status.headMoved)
        #expect(status.draft == .pending(comments: 4))
    }

    @Test func draftsAndBotPullRequestsStayOutOfTheReviewQueue() {
        var state = state
        let ready = Fixtures.pr(number: 1, head: "a", author: "alice")
        let draft = Fixtures.pr(number: 2, head: "b", author: "alice", draft: true)
        let bot = Fixtures.pr(number: 3, head: "c", author: "github-actions[bot]")
        let workflow = Fixtures.pr(number: 4, title: "Update Submodule from cofhe-contracts", head: "d", author: "liorbond")
        state.github?.reviewRequests = [ready, draft, bot, workflow]
        state.recompute(now: Fixtures.t0)
        #expect(state.reviewRequests.map(\.number) == [1])
        #expect(state.nudges.filter { $0.kind == .reviewRequested }.map(\.url) == [ready.url])
    }

    /// Up Next sorts your PRs by what they wait for and adds the reviews that wait on you, inside the day filter.
    @Test func upNextSortsYourPullRequestsAndTheReviewsOnYou() {
        var state = state
        state.gitScan = GitScan(repos: [Fixtures.repo()], worktrees: [])
        let failing = Fixtures.pr(number: 1, head: "a", checks: .failure)
        let ready = Fixtures.pr(number: 2, head: "b", review: .approved, merge: .clean)
        let inReview = Fixtures.pr(number: 3, head: "c")
        // A draft gets no nudge, but red is still yours to fix.
        let redDraft = Fixtures.pr(number: 4, head: "d", updated: Fixtures.t0 - 60, checks: .failure, draft: true)
        state.github?.mine = [failing, ready, inReview, redDraft]
        let recent = Fixtures.pr(number: 10, head: "x", author: "alice", created: Fixtures.t0 - 2 * 86_400)
        let old = Fixtures.pr(number: 11, head: "y", author: "alice", created: Fixtures.t0 - 30 * 86_400)
        // Reviewed, and its draft not submitted yet: outside the day filter, still listed, since you started it.
        var drafted = Fixtures.pr(number: 12, head: "z", author: "alice", created: Fixtures.t0 - 40 * 86_400)
        drafted.pendingReview = Fixtures.pending()
        state.github?.reviewRequests = [recent, old, drafted]
        state.recompute(now: Fixtures.t0)
        let plan = state.upNext(reviewDays: 14, now: Fixtures.t0)
        #expect(plan.map(\.section) == [.readyToMerge, .yourMove, .draftsToSubmit, .toReview, .waiting])
        #expect(plan.map { $0.pullRequests.map(\.number) } == [[2], [1, 4], [12], [10], [3]])
        // All time takes the old one in too.
        #expect(state.upNext(reviewDays: nil, now: Fixtures.t0).first { $0.section == .toReview }?.pullRequests.count == 2)
        // A hidden author's PRs leave the review sections, drafts included; your own PRs stay.
        let hidden = state.upNext(reviewDays: nil, hiding: ["alice"], now: Fixtures.t0)
        #expect(hidden.map(\.section) == [.readyToMerge, .yourMove, .waiting])
    }

    /// Up Next offers your sprint's to-do tickets that nothing has started yet.
    @Test func upNextOffersTheTicketsNothingHasStarted() {
        var config = DeskConfig()
        config.jiraProjectKeys = ["PRO"]
        var state = DeskState(config: config)
        state.github = GitHubSnapshot(
            login: "me", mine: [Fixtures.pr(number: 1, title: "PRO-2 the fix", head: "x")], reviewRequests: [],
            mergedRecent: [Fixtures.pr(number: 2, title: "PRO-6 done already", head: "y", merged: Fixtures.t0)], fetchedAt: Fixtures.t0
        )
        state.tickets = [
            Fixtures.ticket("PRO-1", category: .todo, status: "To Do"),
            Fixtures.ticket("PRO-2", category: .todo, status: "To Do"),
            Fixtures.ticket("PRO-3", category: .inProgress),
            Fixtures.ticket("PRO-4", category: .todo, status: "To Do", placement: .backlog),
            Fixtures.ticket("PRO-5", category: .todo, status: "To Do", assignedToMe: false),
            Fixtures.ticket("PRO-6", category: .todo, status: "To Do"),
        ]
        state.recompute(now: Fixtures.t0)
        // PRO-2 has a PR, PRO-3 is underway, PRO-4 waits in the backlog, PRO-5 is someone else's, PRO-6's PR merged.
        #expect(state.ticketsToStart.map(\.key) == ["PRO-1"])
    }

    @Test func stateMarksWhichPullRequestsWaitOnYourReview() {
        var state = state
        let fresh = Fixtures.pr(number: 1, head: "a", author: "alice")
        var reRequested = Fixtures.pr(number: 2, head: "b", author: "alice")
        reRequested.reviews = [Fixtures.review(at: Fixtures.t0)]
        reRequested.reviewRequestEvents = [Fixtures.event(at: Fixtures.hours(1))]
        var done = Fixtures.pr(number: 3, head: "c", author: "alice")
        done.reviews = [Fixtures.review(at: Fixtures.t0)]
        state.github?.reviewRequests = [fresh, reRequested, done]
        state.recompute(now: Fixtures.hours(2))
        #expect(state.reviewNeed(for: fresh) == .notReviewed)
        #expect(state.reviewNeed(for: reRequested) == .reRequested)
        #expect(state.reviewNeed(for: done) == nil)
        // Oldest first, so the one waiting longest is at the top.
        #expect(state.reviewsToDo.map(\.number) == [1, 2])
    }
}

@Suite struct ReviewScopeTests {
    var state: DeskState {
        var state = DeskState(config: DeskConfig())
        state.github = GitHubSnapshot(login: "me", mine: [], reviewRequests: [], mergedRecent: [], fetchedAt: Fixtures.t0)
        return state
    }

    @Test func openForReviewDropsWhatIsAlreadyOnYouOrAlreadyReviewed() {
        var state = state
        let onMe = Fixtures.pr(number: 1, head: "a", author: "alice")
        let fresh = Fixtures.pr(number: 2, head: "b", author: "alice")
        let mineAlready = Fixtures.pr(
            number: 3, head: "c", author: "alice",
            reviews: [Review(state: .approved, submittedAt: Fixtures.t0, author: "me")]
        )
        let draft = Fixtures.pr(number: 4, head: "d", author: "alice", draft: true)
        let bot = Fixtures.pr(number: 5, head: "e", author: "dependabot")
        state.github?.reviewRequests = [onMe]
        state.github?.openForReview = [onMe, fresh, mineAlready, draft, bot]

        #expect(state.openForReview.map(\.number) == [2])
        #expect(state.reviewQueue(.onMe).map(\.number) == [1])
        // Reviewed by you and not asked again: it waits on its author, so only All and Reviewed list it.
        #expect(state.reviewQueue(.reviewed).map(\.number) == [3])
        #expect(state.reviewQueue(.needsYou).map(\.number) == [1, 2])
        #expect(state.reviewQueue(.all).map(\.number) == [1, 2, 3])
    }

    /// Needs you leads, as the screen's default; Open is gone, so a scope saved as "open" reads as none and the screen
    /// falls back to Needs you.
    @Test func needsYouLeadsAndASavedOpenFallsBack() {
        #expect(ReviewScope.offered == [.needsYou, .onMe, .reviewed, .all])
        #expect(ReviewScope(rawValue: "open") == nil)
    }

    @Test func reviewIsOfferedOnPullRequestsNobodyAssignedYou() {
        var state = state
        let other = Fixtures.pr(number: 8, head: "h", author: "alice")
        state.gitScan = GitScan(repos: [Fixtures.repo()], worktrees: [])
        state.github?.openForReview = [other]
        state.recompute(now: Fixtures.t0)
        // Without this the Review button never appears for a PR outside your own queue.
        #expect(state.reviewNeed(for: other) == .notReviewed)
    }
}

@Suite struct ReviewWindowTests {
    @Test func aDayLimitKeepsOnlyRecentPullRequests() {
        var state = DeskState(config: DeskConfig())
        let fresh = Fixtures.pr(number: 1, head: "a", author: "alice", created: Fixtures.hours(-24))
        let old = Fixtures.pr(number: 2, head: "b", author: "alice", created: Fixtures.hours(-24 * 30))
        state.github = GitHubSnapshot(
            login: "me", mine: [], reviewRequests: [fresh, old], mergedRecent: [], fetchedAt: Fixtures.t0
        )
        #expect(state.reviewQueue(.onMe, days: 14, now: Fixtures.t0).map(\.number) == [1])
        #expect(state.reviewQueue(.onMe, days: 31, now: Fixtures.t0).map(\.number) == [1, 2])
        #expect(state.reviewQueue(.onMe, now: Fixtures.t0).map(\.number) == [1, 2])
        #expect(state.reviewQueue(.onMe, hiding: ["alice"], now: Fixtures.t0).isEmpty)
    }

    /// CodeRabbit's needs-human label puts a PR first, the rest keep their order; its risk label reads as the tier.
    @Test func prsThatNeedAPersonComeFirst() {
        var state = DeskState(config: DeskConfig())
        let plain = Fixtures.pr(number: 1, head: "a", author: "alice")
        let other = Fixtures.pr(number: 2, head: "b", author: "alice")
        var risky = Fixtures.pr(number: 3, head: "c", author: "alice")
        risky.labels = ["risk:high", "needs-human", "area:onchain"]
        state.github = GitHubSnapshot(
            login: "me", mine: [], reviewRequests: [plain, risky, other], mergedRecent: [], fetchedAt: Fixtures.t0
        )
        #expect(state.reviewQueue(.onMe, now: Fixtures.t0).map(\.number) == [3, 1, 2])
        #expect(risky.risk == "high" && risky.needsHuman && plain.risk == nil && !plain.needsHuman)
    }

    /// Needs approval keeps what the review gate has not passed — short of approvals, waiting for CodeRabbit, words it
    /// does not know, or no gate at all — and drops what it has; needs-human still comes first, and Up Next follows it.
    @Test func needsApprovalKeepsWhatTheGateHasNotPassed() {
        var state = DeskState(config: DeskConfig())
        func pr(_ number: Int, _ gate: String?) -> PullRequest {
            var pr = Fixtures.pr(number: number, head: "h\(number)", author: "alice")
            pr.approvalStatus = gate
            return pr
        }
        var human = pr(6, "high risk: 0 of 2 approvals on the latest commit; CodeRabbit could not review")
        human.labels = ["needs-human"]
        let queue = [
            pr(1, "medium risk: 0 of 1 approvals on the latest commit"),
            pr(2, "medium risk: 1 of 1 approvals on the latest commit"),
            pr(3, "low risk: no approval needed"),
            pr(4, "Waiting for CodeRabbit's review of the latest commit"),
            pr(5, nil),
            human,
            pr(7, "high risk: 2 of 2 approvals on the latest commit; How to revert is not filled in the author's /pre-pr evidence comment"),
        ]
        state.github = GitHubSnapshot(login: "me", mine: [], reviewRequests: queue, mergedRecent: [], fetchedAt: Fixtures.t0)
        #expect(state.reviewQueue(.all, needingApproval: true, now: Fixtures.t0).map(\.number) == [6, 1, 4, 5])
        #expect(state.reviewQueue(.all, now: Fixtures.t0).map(\.number) == [6, 1, 2, 3, 4, 5, 7])

        state.gitScan = GitScan(repos: [Fixtures.repo()], worktrees: [])
        state.recompute(now: Fixtures.t0)
        let toReview = { (needing: Bool) in
            state.upNext(reviewDays: nil, needingApproval: needing, now: Fixtures.t0).first { $0.section == .toReview }?.pullRequests.map(\.number)
        }
        #expect(toReview(true) == [6, 1, 4, 5])
        #expect(toReview(false) == [6, 1, 2, 3, 4, 5, 7])
    }
}

@Suite struct TicketGroupingTests {
    @Test func groupsOpenTicketsByStatusInWorkflowOrderAndDropsDone() {
        var state = DeskState(config: DeskConfig())
        state.tickets = [
            Fixtures.ticket("PRO-3", category: .inProgress, status: "Review Ready", placement: .sprint),
            Fixtures.ticket("PRO-1", category: .todo, status: "To Do", placement: .sprint),
            Fixtures.ticket("PRO-2", category: .inProgress, status: "Review Ready", placement: .sprint),
            Fixtures.ticket("PRO-9", category: .done, status: "Done", placement: .sprint),
            Fixtures.ticket("PRO-7", category: .todo, status: "To Do", placement: .backlog),
        ]
        let sprint = state.ticketGroups(.sprint)
        #expect(sprint.map(\.status) == ["To Do", "Review Ready"])
        #expect(sprint.map(\.tickets.count) == [1, 2])
        // Done is not work left to do, so it never reaches the screen.
        #expect(!sprint.contains { $0.category == .done })
        #expect(state.ticketGroups(.backlog).map(\.status) == ["To Do"])
        #expect(state.openTickets.count == 4)
    }

    /// The Jira screen's assignee filter: any mix of you, nobody and named people; nothing picked is everyone.
    @Test func ticketGroupsFilterByAssignee() {
        var state = DeskState(config: DeskConfig())
        state.tickets = [
            Fixtures.ticket("PRO-1", assignee: "Guy"),
            Fixtures.ticket("PRO-2", assignedToMe: false),
            Fixtures.ticket("PRO-3", assignedToMe: false, assignee: "Roee"),
            Fixtures.ticket("PRO-4", assignedToMe: false, assignee: "Dana"),
            Fixtures.ticket("PRO-5", category: .done, status: "Done", assignedToMe: false, assignee: "Eli"),
            Fixtures.ticket("PRO-6", placement: .unknown, assignedToMe: false, assignee: "Noa"),
        ]
        let keys = { (assignees: Set<TicketAssignee>) in state.ticketGroups(.sprint, assignees: assignees).flatMap(\.tickets).map(\.key).sorted() }
        #expect(keys([.me]) == ["PRO-1"])
        #expect(keys([.me, .unassigned]) == ["PRO-1", "PRO-2"])
        #expect(keys([.person("Roee"), .unassigned]) == ["PRO-2", "PRO-3"])
        #expect(keys([]) == ["PRO-1", "PRO-2", "PRO-3", "PRO-4"])
        // Only people with open, placed tickets are offered, and you are "Me", not your name.
        #expect(state.ticketAssignees.map(\.name) == ["Dana", "Roee"])
        #expect(state.ticketSelf?.name == "Guy")
        #expect(TicketAssignee(rawValue: TicketAssignee.person("Roee Z").rawValue) == .person("Roee Z"))
    }
}

@Suite struct SourceTests {
    /// The sidebar offers Settings for a missing CLI or a sign-in, which Settings fixes, and not for an outage.
    @Test func aSignInProblemIsOneSettingsFixes() {
        #expect(Source.isSignInProblem(DeskError.jiraSignedOut.description))
        #expect(Source.isSignInProblem(DeskError.jiraNotConfigured.description))
        #expect(Source.isSignInProblem(DeskError.ghNotFound.description))
        #expect(Source.isSignInProblem("gh: HTTP 401: Bad credentials (https://api.github.com/graphql)"))
        #expect(!Source.isSignInProblem("gh: HTTP 502 from api.github.com"))
    }
}
