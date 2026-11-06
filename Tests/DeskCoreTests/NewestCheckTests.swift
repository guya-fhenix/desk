import DeskCore
import Foundation
import Testing

/// A commit is judged by the newest run of each check, as GitHub's merge box does, not by GitHub's rollup, which counts a
/// cancel a newer run caused as a failure.
@Suite struct NewestCheckTests {
    private func run(_ name: String, _ outcome: PullRequestCheck.Outcome, at minute: Int, workflow: String? = "Merge Gatekeeper") -> PullRequestCheck {
        PullRequestCheck(name: name, workflow: workflow, outcome: outcome, startedAt: Date(timeIntervalSince1970: Double(minute) * 60))
    }

    /// cofhe#1157: merge-gatekeeper ran four times on one commit, and the third was cancelled by the fourth.
    @Test func aCancelANewerRunSupersededIsGone() {
        let checks = [
            run("merge-gatekeeper", .passed, at: 1),
            run("merge-gatekeeper", .passed, at: 34),
            run("merge-gatekeeper", .cancelled, at: 35),
            run("merge-gatekeeper", .passed, at: 38),
            run("check-changelog", .passed, at: 37, workflow: "Changelog Check"),
            run("check-changelog", .skipped, at: 2, workflow: "Changelog Check"),
        ]
        let newest = PullRequestCheck.newest(checks)
        #expect(newest.count == 2)
        #expect(newest.allSatisfy { $0.outcome == .passed })
        #expect(CheckState(newest: newest) == .success)
    }

    /// The same job name in two workflows is two checks: one's failure is not hidden by the other's newer pass.
    @Test func aCheckIsItsWorkflowAndItsName() {
        let newest = PullRequestCheck.newest([
            run("build", .failed, at: 1, workflow: "A"),
            run("build", .passed, at: 2, workflow: "B"),
        ])
        #expect(newest.count == 2)
        #expect(CheckState(newest: newest) == .failure)
    }

    @Test func theNewestRunDecides() {
        #expect(CheckState(newest: PullRequestCheck.newest([run("x", .passed, at: 1), run("x", .cancelled, at: 2)])) == .failure)
        #expect(CheckState(newest: PullRequestCheck.newest([run("x", .failed, at: 1), run("x", .running, at: 2)])) == .pending)
        #expect(CheckState(newest: PullRequestCheck.newest([run("x", .failed, at: 1), run("x", .passed, at: 2)])) == .success)
        #expect(CheckState(newest: []) == .none)
    }
}
