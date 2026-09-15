import DeskCore
import Foundation
import Testing

@Suite struct ReviewPlannerTests {
    let pr = Fixtures.pr(number: 5, head: "feat/x")

    @Test func cleansUpOnlyMergedOrClosedPullRequests() {
        let merged = Fixtures.pr(number: 1, head: "a", merged: Fixtures.t0)
        var closed = Fixtures.pr(number: 2, head: "b")
        closed.state = .closed
        let open = Fixtures.pr(number: 3, head: "c")
        let unknown = Fixtures.pr(number: 4, head: "d")
        let records = Dictionary(uniqueKeysWithValues: [merged, closed, open, unknown].map { ($0.url, Fixtures.record(pr: $0)) })
        let cleanups = ReviewPlanner.cleanups(records: records, closed: [merged, closed, open])
        #expect(cleanups.map(\.number) == [1, 2])
        #expect(ReviewPlanner.cleanups(records: records, closed: []).isEmpty)
    }

    @Test func worktreePathNestsRepoAndNumberUnderTheRoot() {
        #expect(ReviewPlanner.worktreePath(reviewRoot: "/r/.reviews", pr: pr) == "/r/.reviews/cofhe/pr-5")
    }
}
