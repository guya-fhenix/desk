import DeskCore
import Foundation
import Testing

@Suite struct FocusTests {
    /// PRO, with its statuses picked for the three moves, as Setup leaves them.
    var state: DeskState {
        var config = DeskConfig()
        config.jiraProjectKey = "PRO"
        (config.jiraInProgressStatus, config.jiraReviewStatus, config.jiraDoneStatus) = ("In Progress", "👀 Review Ready", "Done")
        var state = DeskState(config: config)
        state.github = GitHubSnapshot(login: "me", mine: [], reviewRequests: [], mergedRecent: [], fetchedAt: Fixtures.t0)
        state.gitScan = GitScan(repos: [Fixtures.repo()], worktrees: [])
        return state
    }

    private func numbers(_ items: [FocusItem], _ level: FocusLevel) -> [Int] {
        items.filter { $0.level == level }.compactMap { if case .pullRequest(let pr) = $0.subject { pr.number } else { nil } }
    }

    /// With no ranking from the master, each of your PRs sits at the level of its own state on GitHub, and the reviews on
    /// you join them inside the day filter; the badge counts Now and Next.
    @Test func yourPullRequestsAndReviewsTakeTheirOwnLevels() {
        var state = state
        let failing = Fixtures.pr(number: 1, head: "a", checks: .failure)
        let ready = Fixtures.pr(number: 2, head: "b", updated: Fixtures.t0 - 10, review: .approved, merge: .clean)
        let inReview = Fixtures.pr(number: 3, head: "c")
        var threads = Fixtures.pr(number: 4, head: "d")
        threads.unresolvedThreads = 2
        let draft = Fixtures.pr(number: 5, head: "e", draft: true)
        var reviewed = Fixtures.pr(number: 6, head: "f", draft: true)
        reviewed.labels = [SelfReview.reviewedLabel]
        state.github?.mine = [failing, ready, inReview, threads, draft, reviewed]
        var asked = Fixtures.pr(number: 10, head: "x", author: "alice", created: Fixtures.t0 - 2 * 86_400, events: [Fixtures.event(at: Fixtures.t0 - 3_600)])
        asked.requestedReviewers = ["me"]
        // Asked of a team of yours, not of you by name.
        let old = Fixtures.pr(number: 11, head: "y", author: "alice", created: Fixtures.t0 - 30 * 86_400)
        // Its draft not submitted yet: outside the day filter, still listed, since you started it.
        var drafted = Fixtures.pr(number: 12, head: "z", author: "alice", created: Fixtures.t0 - 40 * 86_400)
        drafted.pendingReview = Fixtures.pending()
        state.github?.reviewRequests = [asked, old, drafted]
        state.github?.openForReview = [Fixtures.pr(number: 20, head: "o", author: "bob")]
        state.recompute(now: Fixtures.t0)

        let items = state.focus(reviewDays: 14, now: Fixtures.t0)
        #expect(numbers(items, .now) == [1, 2])
        #expect(numbers(items, .next) == [4, 6, 12, 10])
        #expect(numbers(items, .canWait) == [5, 20])
        #expect(items.filter { $0.kind == .reviewOpen }.count == 1 && items.filter { $0.kind == .reviewTeam }.isEmpty)
        #expect(numbers(items, .background) == [3])
        #expect(state.focusCount(reviewDays: 14, now: Fixtures.t0) == 6)
        #expect(items.filter(\.lifted).isEmpty)
        // Asked an hour ago, whenever the PR opened.
        #expect(items.first { $0.kind == .reviewAsked }?.since == Fixtures.t0 - 3_600)
        // All time takes the old request in; a hidden author's PRs leave, yours stay.
        #expect(state.focus(reviewDays: nil, now: Fixtures.t0).first { $0.kind == .reviewTeam }?.id == old.url)
        #expect(numbers(state.focus(reviewDays: nil, hiding: ["alice"], now: Fixtures.t0), .next) == [4, 6])
    }

    /// A PR's own state decides, whatever its session is doing: a session asking you something moves nothing.
    @Test func sessionsHaveNoSay() {
        var state = state
        let inReview = Fixtures.pr(number: 2, head: "b")
        state.github?.mine = [inReview]
        let key = ClaudeJobs.prKey(inReview.url)!
        state.claudeJobs = [ClaudeJob(id: "job", name: "w", state: "blocked", cwd: "/r/cofhe", prKeys: [key], updatedAt: Fixtures.t0, startedOn: [key], role: .worker)]
        state.recompute(now: Fixtures.t0)
        #expect(state.focus(reviewDays: nil, now: Fixtures.t0).map(\.kind) == [.waitingOnReview])
    }

    /// Tickets: a suggested move, one in progress with no PR yet, the sprint's to-do nothing started; and a PR merged
    /// today, which waits on nothing.
    @Test func ticketsAndTodaysMergesAreItems() {
        var state = state
        state.github?.mine = [Fixtures.pr(number: 1, head: "feat/pro-391-gauge")]
        state.github?.mergedRecent = [
            Fixtures.pr(number: 7, head: "m", merged: Fixtures.t0 - 60), Fixtures.pr(number: 8, head: "n", merged: Fixtures.t0 - 3 * 86_400),
        ]
        state.tickets = [
            Fixtures.ticket("PRO-391"), Fixtures.ticket("PRO-400"), Fixtures.ticket("PRO-401", category: .todo, status: "To Do"),
        ]
        state.recompute(now: Fixtures.t0)
        let items = state.focus(reviewDays: nil, now: Fixtures.t0)
        #expect(items.map(\.id) == ["PRO-400", "PRO-391", "PRO-401", "https://github.com/FhenixProtocol/cofhe/pull/1", "https://github.com/FhenixProtocol/cofhe/pull/7"])
        #expect(items.map(\.kind) == [.inProgress, .jiraMove, .toStart, .waitingOnReview, .merged])
        #expect(items.last?.since == nil)
    }

    /// Only the first three reviews not asked of you by name are listed, oldest first, and any the master ranked.
    @Test func otherReviewsAreCappedUnlessTheMasterRankedThem() {
        var state = state
        state.github?.reviewRequests = (1...5).map { Fixtures.pr(number: $0, head: "h\($0)", author: "alice", created: Fixtures.t0 - Double(10 - $0) * 86_400) }
        state.recompute(now: Fixtures.t0)
        #expect(numbers(state.focus(reviewDays: nil, now: Fixtures.t0), .canWait) == [1, 2, 3])
        state.focusRanking = FocusRanking(rankedAt: Fixtures.t0, items: [.init(id: "FhenixProtocol/cofhe#5", level: 2)])
        let items = state.focus(reviewDays: nil, now: Fixtures.t0)
        #expect(numbers(items, .next) == [5] && numbers(items, .canWait) == [1, 2, 3])
    }

    /// The master's ranking sets the level and the order of what it names, a level out of range held to the nearest;
    /// the rest keep Desk's. What has become something Desk puts higher since Desk first read the ranking is lifted to
    /// Desk's level, first, and marked, whatever its times say: a PR gone red, one that became ready to merge on an
    /// approval older than the ranking. So is a review asked since. A push to a PR that was red already lifts nothing.
    @Test func theMastersRankingOrdersAndDeskLiftsWhatBecameSomethingElse() {
        var state = state
        let old = Fixtures.t0 - 7_200
        state.github?.mine = [
            Fixtures.pr(number: 1, head: "a", updated: old), Fixtures.pr(number: 2, head: "b", updated: old, checks: .failure),
            Fixtures.pr(number: 3, head: "c", updated: old), Fixtures.pr(number: 4, head: "d", updated: old),
        ]
        let seen = Fixtures.pr(number: 11, head: "y", author: "alice", created: Fixtures.t0 - 86_400)
        state.github?.reviewRequests = [seen]
        state.focusRanking = FocusRanking(rankedAt: Fixtures.t0 - 3_600, items: [
            .init(id: "FhenixProtocol/cofhe#3", level: 9), .init(id: "fhenixprotocol/cofhe#11", level: 3),
            .init(id: "FhenixProtocol/cofhe#2", level: 1), .init(id: "FhenixProtocol/cofhe#1", level: 0),
            .init(id: "FhenixProtocol/cofhe#4", level: 0),
        ])
        state.recompute(now: Fixtures.t0)
        state.focusSeen = state.focusKinds(now: Fixtures.t0)
        #expect(state.focus(reviewDays: nil, now: Fixtures.t0).filter(\.lifted).isEmpty)

        let failing = Fixtures.pr(number: 1, head: "a", updated: Fixtures.t0, checks: .failure)
        let pushed = Fixtures.pr(number: 2, head: "b", updated: Fixtures.t0, checks: .failure)
        let ready = Fixtures.pr(number: 4, head: "d", updated: old, review: .approved, merge: .clean, reviews: [Fixtures.review(.approved, at: old, by: "alice")])
        state.github?.mine = [failing, pushed, Fixtures.pr(number: 3, head: "c", updated: old), ready]
        var fresh = Fixtures.pr(number: 10, head: "x", author: "alice", events: [Fixtures.event(at: Fixtures.t0)])
        fresh.requestedReviewers = ["me"]
        state.github?.reviewRequests = [fresh, seen]
        state.recompute(now: Fixtures.t0)
        let items = state.focus(reviewDays: nil, now: Fixtures.t0)
        #expect(numbers(items, .now) == [1, 4, 3, 11])
        #expect(numbers(items, .next) == [10])
        #expect(numbers(items, .canWait) == [2])
        #expect(Set(items.filter(\.lifted).map(\.id)) == [failing.url, ready.url, fresh.url])

        // Until Desk has remembered what a ranking saw, the ranking alone decides.
        state.focusSeen = nil
        let unseen = state.focus(reviewDays: nil, now: Fixtures.t0)
        #expect(unseen.filter(\.lifted).isEmpty && numbers(unseen, .background) == [1, 4])
    }

    /// A change in how many threads are open is the same kind of thing, and lifts nothing. What the master did not name
    /// is lifted when it grew, and when it is new at Next or above; a new item at Can wait is not marked.
    @Test func aThreadCountIsNoChangeAndUnrankedItemsLiftWhenTheyGrow() {
        var state = state
        var threads = Fixtures.pr(number: 1, head: "a")
        threads.unresolvedThreads = 2
        state.github?.mine = [threads, Fixtures.pr(number: 2, head: "b")]
        state.focusRanking = FocusRanking(rankedAt: Fixtures.t0, items: [.init(id: "FhenixProtocol/cofhe#1", level: 0)])
        state.recompute(now: Fixtures.t0)
        state.focusSeen = state.focusKinds(now: Fixtures.t0)

        threads.unresolvedThreads = 1
        let draft = Fixtures.pr(number: 3, head: "c", draft: true)
        state.github?.mine = [threads, Fixtures.pr(number: 2, head: "b", checks: .failure), draft]
        state.recompute(now: Fixtures.t0)
        let items = state.focus(reviewDays: nil, now: Fixtures.t0)
        #expect(numbers(items, .background) == [1] && numbers(items, .canWait) == [3] && numbers(items, .now) == [2])
        #expect(items.filter(\.lifted).map(\.id) == ["https://github.com/FhenixProtocol/cofhe/pull/2"])
    }

    /// The page says how many reviews it left to the Reviews screen: those past the cap, whatever else it lists.
    @Test func thePageCountsTheReviewsItLeftOut() {
        var state = state
        var drafted = Fixtures.pr(number: 9, head: "z", author: "alice")
        drafted.pendingReview = Fixtures.pending()
        state.github?.reviewRequests = (1...4).map { Fixtures.pr(number: $0, head: "h\($0)", author: "alice", created: Fixtures.t0 - Double(10 - $0) * 86_400) } + [drafted]
        state.recompute(now: Fixtures.t0)
        let page = state.focusPage(reviewDays: nil, now: Fixtures.t0)
        #expect(page.reviewsLeftOut == 1)
        #expect(page.items.map(\.kind) == [.reviewDraft, .reviewTeam, .reviewTeam, .reviewTeam])
    }

    /// A PR that merged between GitHub's two searches is in both lists, and on the page once.
    @Test func aPullRequestInTwoListsIsListedOnce() {
        var state = state
        state.github?.mine = [Fixtures.pr(number: 1, head: "a")]
        state.github?.mergedRecent = [Fixtures.pr(number: 1, head: "a", merged: Fixtures.t0)]
        state.recompute(now: Fixtures.t0)
        #expect(state.focus(reviewDays: nil, now: Fixtures.t0).count == 1)
    }
}
