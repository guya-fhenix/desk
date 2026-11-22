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
        let asked = Fixtures.pr(number: 10, head: "x", author: "alice", created: Fixtures.t0 - 2 * 86_400, events: [Fixtures.event(at: Fixtures.t0 - 3_600)])
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
        #expect(numbers(items, .background) == [3])
        #expect(state.focusCount(reviewDays: 14, now: Fixtures.t0) == 6)
        #expect(items.filter(\.lifted).isEmpty)
        // Asked an hour ago, whenever the PR opened.
        #expect(items.first { $0.kind == .reviewAsked }?.since == Fixtures.t0 - 3_600)
        // All time takes the old request in; a hidden author's PRs leave, yours stay.
        #expect(numbers(state.focus(reviewDays: nil, now: Fixtures.t0), .next).contains(11))
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

    /// The master's ranking sets the level and the order of what it names; the rest keep Desk's. What changed on GitHub
    /// after it ranked, to something Desk puts higher, is lifted to Desk's level, first, and marked; so is a review asked
    /// since, which the master has not seen. Nothing older is marked.
    @Test func theMastersRankingOrdersAndDeskLiftsWhatChangedSince() {
        var state = state
        let failing = Fixtures.pr(number: 1, head: "a", updated: Fixtures.t0, checks: .failure)
        let quiet = Fixtures.pr(number: 2, head: "b", updated: Fixtures.t0 - 7_200, checks: .failure)
        let waiting = Fixtures.pr(number: 3, head: "c", updated: Fixtures.t0 - 7_200)
        state.github?.mine = [failing, quiet, waiting]
        let fresh = Fixtures.pr(number: 10, head: "x", author: "alice", events: [Fixtures.event(at: Fixtures.t0)])
        let seen = Fixtures.pr(number: 11, head: "y", author: "alice", created: Fixtures.t0 - 86_400)
        state.github?.reviewRequests = [fresh, seen]
        state.focusRanking = FocusRanking(rankedAt: Fixtures.t0 - 3_600, items: [
            .init(id: "FhenixProtocol/cofhe#3", level: 3), .init(id: "fhenixprotocol/cofhe#11", level: 3),
            .init(id: "FhenixProtocol/cofhe#2", level: 1), .init(id: "FhenixProtocol/cofhe#1", level: 0),
            .init(id: "FhenixProtocol/cofhe#99", level: 9),
        ])
        state.recompute(now: Fixtures.t0)
        let items = state.focus(reviewDays: nil, now: Fixtures.t0)
        // #1 went red after the ranking: lifted over the master's two. #2 was red when the master put it at Can wait.
        #expect(numbers(items, .now) == [1, 3, 11])
        #expect(numbers(items, .next) == [10])
        #expect(numbers(items, .canWait) == [2])
        #expect(Set(items.filter(\.lifted).map(\.id)) == [failing.url, fresh.url])
    }
}
