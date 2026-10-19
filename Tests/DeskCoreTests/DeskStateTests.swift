import DeskCore
import Foundation
import Testing

@Suite struct DeskStateTests {
    var state: DeskState {
        var config = DeskConfig()
        config.reviewRoot = "/r/.reviews"
        var state = DeskState(config: config)
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
            Review(state: "COMMENTED", submittedAt: Fixtures.t0, author: "ann"),
            Review(state: "APPROVED", submittedAt: Fixtures.t0 + 60, author: "ann"),
            Review(state: "COMMENTED", submittedAt: Fixtures.t0 + 120, author: "ann"),
            Review(state: "CHANGES_REQUESTED", submittedAt: Fixtures.t0 + 30, author: "bob"),
            Review(state: "COMMENTED", submittedAt: Fixtures.t0 + 40, author: "cy"),
            Review(state: "COMMENTED", submittedAt: Fixtures.t0 + 50, author: "me"),
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

    @Test func reviewWorktreesAreKeptApartFromWorkingOnes() {
        var state = state
        let main = Fixtures.worktree(path: "/r/cofhe", branch: "master", isMain: true)
        let review = Fixtures.worktree(path: "/r/.reviews/cofhe/pr-9", branch: nil)
        state.gitScan = GitScan(repos: [Fixtures.repo()], worktrees: [main, review])
        #expect(state.worktrees.map(\.path) == ["/r/cofhe"])
        #expect(state.reviewWorktrees.map(\.path) == ["/r/.reviews/cofhe/pr-9"])
    }

    @Test func reviewStatusComesFromThePullRequestAndThisSessionsRun() {
        var state = state
        var pr = Fixtures.pr(number: 9, head: "y")
        pr.pendingReview = Fixtures.pending(comments: 4, claude: 3, commit: "older")
        state.github?.reviewRequests = [pr]
        state.reviewRuns[pr.url] = ReviewRun(phase: .posted, posted: 3)
        let status = state.reviewStatus(for: pr)
        #expect(status.run?.phase == .posted)
        #expect(status.headMoved)
        #expect(status.draft == .pending(comments: 4, claude: 3))
    }

    /// The "Claude reviewed" nudge is for a draft with Claude's comments that is still waiting.
    @Test func aPendingDraftIsWhatNudges() {
        var state = state
        var waiting = Fixtures.pr(number: 1, head: "a", author: "alice")
        waiting.pendingReview = Fixtures.pending(comments: 3, claude: 2)
        var yours = Fixtures.pr(number: 2, head: "b", author: "alice")
        yours.pendingReview = Fixtures.pending(comments: 1, claude: 0)
        let sent = Fixtures.pr(number: 3, head: "c", author: "alice")
        state.github?.reviewRequests = [waiting, yours, sent]
        state.recompute(now: Fixtures.t0)
        let ready = state.nudges.filter { $0.kind == .reviewReady }
        #expect(ready.map(\.url) == ["\(waiting.url)/files"])
        #expect(ready.first?.detail == "3 comments waiting in your draft review")
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

    @Test func stateMarksWhichPullRequestsAreReadyToRun() {
        var state = state
        state.gitScan = GitScan(repos: [Fixtures.repo()], worktrees: [])
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
        // Oldest first, so the row worth pressing first is at the top.
        #expect(state.reviewsToRun.map(\.number) == [1, 2])
    }


}

@Suite struct ReviewScopeTests {
    var state: DeskState {
        var config = DeskConfig()
        config.reviewRoot = "/r/.reviews"
        var state = DeskState(config: config)
        state.github = GitHubSnapshot(login: "me", mine: [], reviewRequests: [], mergedRecent: [], fetchedAt: Fixtures.t0)
        return state
    }

    @Test func openForReviewDropsWhatIsAlreadyOnYouOrAlreadyReviewed() {
        var state = state
        let onMe = Fixtures.pr(number: 1, head: "a", author: "alice")
        let fresh = Fixtures.pr(number: 2, head: "b", author: "alice")
        let mineAlready = Fixtures.pr(
            number: 3, head: "c", author: "alice",
            reviews: [Review(state: "APPROVED", submittedAt: Fixtures.t0, author: "me")]
        )
        let draft = Fixtures.pr(number: 4, head: "d", author: "alice", draft: true)
        let bot = Fixtures.pr(number: 5, head: "e", author: "dependabot")
        state.github?.reviewRequests = [onMe]
        state.github?.openForReview = [onMe, fresh, mineAlready, draft, bot]

        #expect(state.openForReview.map(\.number) == [2])
        #expect(state.reviewQueue(.onMe).map(\.number) == [1])
        #expect(state.reviewQueue(.all).map(\.number) == [1, 2])
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
