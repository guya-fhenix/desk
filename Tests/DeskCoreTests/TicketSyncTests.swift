import DeskCore
import Foundation
import Testing

@Suite struct TicketSyncTests {
    static let branches = ["cofhe": "master"]

    func drifts(tickets: [Ticket], open: [PullRequest] = [], merged: [PullRequest] = []) -> [TicketDrift] {
        TicketSync.drifts(TicketSyncInput(
            tickets: tickets, open: open, merged: merged, defaultBranches: Self.branches,
            projectKeys: ["PRO"], reviewStatus: "👀 Review Ready", doneStatus: "Done"
        ))
    }

    @Test func readyPullRequestPutsItsTicketInReview() {
        let pr = Fixtures.pr(number: 1, head: "feat/pro-391-gauge")
        let found = drifts(tickets: [Fixtures.ticket("PRO-391")], open: [pr])
        #expect(found.map(\.ticket.key) == ["PRO-391"])
        #expect(found[0].stage == .inReview)
        #expect(found[0].target == "👀 Review Ready")
        #expect(found[0].pullRequests == [pr])
    }

    @Test func keyIsReadFromTheTitleToo() {
        let pr = Fixtures.pr(number: 2, title: "PRO-392 tighten the gauge", head: "guya/gauge")
        #expect(drifts(tickets: [Fixtures.ticket("PRO-392")], open: [pr]).count == 1)
    }

    /// The description is prose about other work; reading it would move tickets a PR only mentions.
    @Test func keyIsNotReadFromTheBody() {
        var pr = Fixtures.pr(number: 3, title: "Tighten the gauge", head: "guya/gauge")
        pr.body = "Follows PRO-393, see also PRO-394."
        #expect(drifts(tickets: [Fixtures.ticket("PRO-393")], open: [pr]).isEmpty)
    }

    @Test func mergedPullRequestFinishesItsTicket() {
        let pr = Fixtures.pr(number: 4, head: "feat/pro-394-gauge", base: "master", merged: Fixtures.hours(3))
        let found = drifts(tickets: [Fixtures.ticket("PRO-394")], merged: [pr])
        #expect(found.map(\.stage) == [.done])
        #expect(found[0].target == "Done")
    }

    /// A PR merged into the branch below it in a stack has landed nothing; the ticket waits for the one
    /// that reaches the default branch.
    @Test func mergingIntoAParentBranchDoesNotFinishIt() {
        let pr = Fixtures.pr(number: 5, head: "feat/pro-395-part-2", base: "feat/pro-395-part-1", merged: Fixtures.hours(3))
        #expect(drifts(tickets: [Fixtures.ticket("PRO-395")], merged: [pr]).isEmpty)
    }

    @Test func oneOpenPullRequestHoldsTheTicketInReview() {
        let landed = Fixtures.pr(number: 6, head: "feat/pro-396-part-1", merged: Fixtures.hours(3))
        let open = Fixtures.pr(number: 7, head: "feat/pro-396-part-2")
        let found = drifts(tickets: [Fixtures.ticket("PRO-396")], open: [open], merged: [landed])
        #expect(found.map(\.stage) == [.inReview])
        #expect(found[0].pullRequests.map(\.number) == [7, 6])
    }

    /// A draft is unfinished work: it neither opens a review nor lets the ticket close.
    @Test func aDraftIsNeitherReviewNorDone() {
        let landed = Fixtures.pr(number: 8, head: "feat/pro-397-part-1", merged: Fixtures.hours(3))
        let draft = Fixtures.pr(number: 9, head: "feat/pro-397-part-2", draft: true)
        #expect(drifts(tickets: [Fixtures.ticket("PRO-397")], open: [draft], merged: [landed]).isEmpty)
    }

    @Test func aTicketAlreadyInTheTargetStatusIsNotDrifting() {
        let pr = Fixtures.pr(number: 10, head: "feat/pro-398-gauge")
        let ticket = Fixtures.ticket("PRO-398", status: "👀 Review Ready")
        #expect(drifts(tickets: [ticket], open: [pr]).isEmpty)
    }

    /// Never backwards: reopening work is a decision, not a drift.
    @Test func aDoneTicketIsNeverMoved() {
        let pr = Fixtures.pr(number: 11, head: "feat/pro-399-gauge")
        let ticket = Fixtures.ticket("PRO-399", category: .done, status: "Done")
        #expect(drifts(tickets: [ticket], open: [pr]).isEmpty)
    }

    @Test func somebodyElsesTicketIsNeverMoved() {
        let pr = Fixtures.pr(number: 12, head: "feat/pro-400-gauge")
        let ticket = Fixtures.ticket("PRO-400", assignedToMe: false)
        #expect(drifts(tickets: [ticket], open: [pr]).isEmpty)
    }

    @Test func blockedMovesForwardToReview() {
        let pr = Fixtures.pr(number: 13, head: "feat/pro-401-gauge")
        let ticket = Fixtures.ticket("PRO-401", status: "⛔ Blocked")
        #expect(drifts(tickets: [ticket], open: [pr]).map(\.stage) == [.inReview])
    }

    @Test func anEmptyStatusTurnsThatHalfOff() {
        let open = Fixtures.pr(number: 14, head: "feat/pro-402-gauge")
        let landed = Fixtures.pr(number: 15, head: "feat/pro-403-gauge", merged: Fixtures.hours(3))
        let found = TicketSync.drifts(TicketSyncInput(
            tickets: [Fixtures.ticket("PRO-402"), Fixtures.ticket("PRO-403")], open: [open], merged: [landed],
            defaultBranches: Self.branches, projectKeys: ["PRO"], reviewStatus: "", doneStatus: "Done"
        ))
        #expect(found.map(\.ticket.key) == ["PRO-403"])
    }

    @Test func aTicketWithNoPullRequestIsNotDrifting() {
        #expect(drifts(tickets: [Fixtures.ticket("PRO-404")]).isEmpty)
    }
}
