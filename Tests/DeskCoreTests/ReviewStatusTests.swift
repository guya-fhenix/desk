import DeskCore
import Foundation
import Testing

@Suite struct ReviewStatusTests {
    let pr = Fixtures.pr(number: 9, head: "y", author: "alice")

    @Test func phaseComesStraightFromTheRecord() {
        // There is no session file to read it back out of, so the record is the only authority.
        for phase in [ReviewPhase.queued, .preparing, .running, .ready, .submitting, .submitted] {
            let record = Fixtures.record(pr: pr, phase: phase)
            #expect(ReviewStatus.derive(record: record, pr: pr, login: "me").phase == phase)
        }
        #expect(ReviewStatus.derive(record: Fixtures.record(pr: pr, error: "git fetch failed"), pr: pr, login: "me").phase == .failed)
    }

    @Test func busyCoversEverythingWithWorkInFlight() {
        #expect(ReviewPhase.queued.isBusy)
        #expect(ReviewPhase.preparing.isBusy)
        #expect(ReviewPhase.running.isBusy)
        #expect(ReviewPhase.submitting.isBusy)
        #expect(!ReviewPhase.ready.isBusy)
        #expect(!ReviewPhase.failed.isBusy)
        #expect(!ReviewPhase.submitted.isBusy)
    }

    @Test func headMovedComparesTheRecordedSha() {
        #expect(ReviewStatus.derive(record: Fixtures.record(pr: pr, head: "old"), pr: pr, login: "me").headMoved)
        #expect(!ReviewStatus.derive(record: Fixtures.record(pr: pr), pr: pr, login: "me").headMoved)
        // An empty sha on either side is unknown, not moved.
        var headless = pr
        headless.headSha = ""
        #expect(!ReviewStatus.derive(record: Fixtures.record(pr: pr, head: "old"), pr: headless, login: "me").headMoved)
        #expect(!ReviewStatus.derive(record: Fixtures.record(pr: pr, head: ""), pr: pr, login: "me").headMoved)
    }

    @Test func reRequestedNeedsARequestForMeAfterTheLastRun() {
        let record = Fixtures.record(pr: pr, lastRun: Fixtures.t0)
        func status(_ events: [ReviewRequestEvent]) -> ReviewStatus {
            var pr = pr
            pr.reviewRequestEvents = events
            return ReviewStatus.derive(record: record, pr: pr, login: "me")
        }
        #expect(status([Fixtures.event(at: Fixtures.hours(1))]).reRequested)
        #expect(!status([Fixtures.event(at: Fixtures.hours(-1))]).reRequested)
        #expect(!status([Fixtures.event(reviewer: "someone-else", at: Fixtures.hours(1))]).reRequested)
        // A team request is not a request of me.
        #expect(!status([Fixtures.event(reviewer: "me", at: Fixtures.hours(1), team: true)]).reRequested)
    }

    @Test func countsSplitCommentsByStateAndSeverity() {
        let record = Fixtures.record(pr: pr, comments: [
            Fixtures.comment(line: 1, severity: .blocker, state: .approved),
            Fixtures.comment(line: 2, severity: .major, state: .pending, outdated: true),
            Fixtures.comment(line: 3, severity: .nit, state: .rejected),
            // A rejected blocker is not blocking anything: it is not going anywhere.
            Fixtures.comment(line: 4, severity: .blocker, state: .rejected),
        ])
        let counts = ReviewStatus.derive(record: record, pr: pr, login: "me").counts
        #expect(counts.approved == 1)
        #expect(counts.pending == 1)
        #expect(counts.rejected == 2)
        #expect(counts.outdated == 1)
        #expect(counts.blocking == 2)
        #expect(counts.total == 4)
    }

    @Test func verdictPrefersTheUsersChoice() {
        var record = Fixtures.record(pr: pr)
        #expect(record.effectiveVerdict == .comment)
        record.verdict = .approve
        #expect(record.effectiveVerdict == .approve)
        record.chosenVerdict = .requestChanges
        #expect(record.effectiveVerdict == .requestChanges)
    }

    @Test func editedCommentPostsTheUsersWords() {
        var comment = Fixtures.comment(body: "Claude wrote this")
        #expect(comment.text == "Claude wrote this")
        #expect(!comment.isUserEdited)
        comment.editedBody = "I wrote this"
        #expect(comment.text == "I wrote this")
        #expect(comment.isUserEdited)
        // Claude's original survives, so "edited" stays visible.
        #expect(comment.body == "Claude wrote this")
    }

    @Test func ledgerKeepsAWeekOfSpend() {
        var ledger = ReviewLedger()
        ledger.record(cost: 2, prUrl: "a", now: Fixtures.t0)
        ledger.record(cost: 3, prUrl: "b", now: Fixtures.t0)
        #expect(ledger.spent(since: Fixtures.hours(-24)) == 5)
        #expect(ledger.spent(since: Fixtures.hours(1)) == 0)
        // A zero-cost run is not worth a row.
        ledger.record(cost: 0, prUrl: "c", now: Fixtures.t0)
        #expect(ledger.spend.count == 2)
        // Anything past the retention window is dropped on the next write.
        ledger.record(cost: 1, prUrl: "d", now: Fixtures.t0.addingTimeInterval(8 * 86_400))
        #expect(ledger.spend.count == 1)
    }
}
