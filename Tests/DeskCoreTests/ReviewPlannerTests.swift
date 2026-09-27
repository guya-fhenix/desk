import DeskCore
import Foundation
import Testing

/// A review worktree's path is the only record of which PR it belongs to.
@Suite struct ReviewPlannerTests {
    @Test func theWorktreePathNamesThePullRequest() {
        let pr = Fixtures.pr(number: 45, repo: "FhenixProtocol/gitops", head: "a")
        let path = ReviewPlanner.worktreePath(reviewRoot: "/r/.reviews", pr: pr)
        #expect(path == "/r/.reviews/gitops/pr-45")
        let found = ReviewPlanner.pullRequest(ofWorktree: path, reviewRoot: "/r/.reviews", repoSlug: "fhenixprotocol/gitops")
        #expect(found?.url == "https://github.com/fhenixprotocol/gitops/pull/45")
        #expect(found?.number == 45)
    }

    @Test func anythingElseUnderTheRootIsNotAReview() {
        for path in ["/r/.reviews/gitops", "/r/.reviews/gitops/pr-x", "/r/.reviews/gitops/pr-45/sub", "/r/gitops/pr-45", "/r/.reviewsX/gitops/pr-4"] {
            #expect(ReviewPlanner.pullRequest(ofWorktree: path, reviewRoot: "/r/.reviews", repoSlug: "o/gitops") == nil)
        }
        // Without the repo's slug there is no PR to name.
        #expect(ReviewPlanner.pullRequest(ofWorktree: "/r/.reviews/gitops/pr-45", reviewRoot: "/r/.reviews", repoSlug: "") == nil)
    }
}
