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

    /// The one a search can never show: reviewed here, never submitted, then merged. `cleanups` cannot
    /// see it go, so it has to be asked about by name instead.
    @Test func listsRecordsNoSearchMentions() {
        let open = Fixtures.pr(number: 3, head: "c")
        let vanished = Fixtures.pr(number: 4, head: "d")
        let records = Dictionary(uniqueKeysWithValues: [open, vanished].map { ($0.url, Fixtures.record(pr: $0)) })
        #expect(ReviewPlanner.unresolved(records: records, seen: [open]).map(\.number) == [4])
        #expect(ReviewPlanner.unresolved(records: records, seen: [open, vanished]).isEmpty)
    }

    /// An empty snapshot is a failed poll, not a mass closure — every record comes back unresolved so each
    /// is asked about, and none is swept.
    @Test func anEmptySnapshotResolvesNothingByItself() {
        let records = Dictionary(uniqueKeysWithValues: [pr].map { ($0.url, Fixtures.record(pr: $0)) })
        #expect(ReviewPlanner.unresolved(records: records, seen: []).map(\.number) == [5])
        #expect(ReviewPlanner.cleanups(records: records, closed: []).isEmpty)
    }

    @Test func worktreePathNestsRepoAndNumberUnderTheRoot() {
        #expect(ReviewPlanner.worktreePath(reviewRoot: "/r/.reviews", pr: pr) == "/r/.reviews/cofhe/pr-5")
    }
}
