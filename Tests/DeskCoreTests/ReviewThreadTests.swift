import DeskCore
import Foundation
import Testing

@Suite struct ReviewThreadTests {
    private func thread(_ id: String, path: String = "src/a.rs", line: Int? = 1, author: String = "alice", body: String) -> ReviewThread {
        ReviewThread(id: id, path: path, line: line, url: "https://github.com/o/r/pull/1#discussion_r\(id)", author: author, body: body)
    }

    @Test func sourceIsPrePRByMarkerThenCodeRabbitByAuthor() {
        #expect(thread("1", author: "me", body: "<!-- pre-pr:finding -->\n**Nit** · x").source == .prePR)
        #expect(thread("2", author: "coderabbitai[bot]", body: "**Minor** · x").source == .codeRabbit)
        #expect(thread("3", author: "coderabbitai", body: "**Minor** · x").source == .codeRabbit)
        #expect(thread("4", author: "alice", body: "Why?").source == .people)
    }


    /// The side card's rows: the tools first, then each person, the most first.
    @Test func countsByWhoStartedThem() {
        let threads = [
            thread("1", author: "me", body: "<!-- pre-pr:finding -->\n**Nit** · x"),
            thread("2", author: "coderabbitai[bot]", body: "**Minor** · x"),
            thread("3", author: "coderabbitai[bot]", body: "**Major** · x"),
            thread("4", author: "bob", body: "Why?"),
            thread("5", author: "alice", body: "And this?"),
            thread("6", author: "alice", body: "Here too."),
        ]
        #expect(threads.byWho.map(\.who) == ["/pre-pr", "CodeRabbit", "@alice", "@bob"])
        #expect(threads.byWho.map(\.count) == [1, 2, 2, 1])
        #expect([ReviewThread]().byWho.isEmpty)
    }
}

@Suite struct ApprovalGateTests {
    /// Every form the review gate writes, with and without the note after a semicolon.
    @Test func readsEveryDescription() {
        let cases: [(String, ApprovalGate.State, String?, Bool)] = [
            ("Draft: approvals are checked once the PR is ready", .draft, nil, false),
            ("Waiting for CodeRabbit's review of the latest commit", .waitingForCodeRabbit, nil, false),
            ("low risk: no approval needed", .counted(have: 0, needed: 0), "low", true),
            ("low risk: no approval needed; CodeRabbit could not review", .counted(have: 0, needed: 0), "low", true),
            ("medium risk: 0 of 1 approvals on the latest commit", .counted(have: 0, needed: 1), "medium", false),
            ("high risk: 2 of 2 approvals on the latest commit", .counted(have: 2, needed: 2), "high", true),
            (
                "high risk: 2 of 2 approvals on the latest commit; How to revert is not filled in the author's /pre-pr evidence comment",
                .counted(have: 2, needed: 2), "high", true
            ),
            ("high risk: 1 of 2 approvals on the latest commit; CodeRabbit could not review", .counted(have: 1, needed: 2), "high", false),
            ("Something new", .unknown, nil, false),
            ("", .unknown, nil, false),
        ]
        for (description, state, tier, met) in cases {
            let gate = ApprovalGate(description: description)
            #expect(gate.state == state, "\(description)")
            #expect(gate.tier == tier, "\(description)")
            #expect(gate.isMet == met, "\(description)")
        }
    }

    /// The queue's filter: short, waiting, unknown and no gate at all all need an approval; met does not. Your own PR
    /// falls back to GitHub's review decision where the repo has no gate.
    @Test func needsApprovalAndApprovalsMet() {
        var pr = Fixtures.pr(number: 1, head: "a", review: .approved)
        #expect(pr.needsApproval && pr.approvalsMet)
        pr.approvalStatus = "Waiting for CodeRabbit's review of the latest commit"
        #expect(pr.needsApproval && !pr.approvalsMet)
        pr.approvalStatus = "medium risk: 0 of 1 approvals on the latest commit"
        #expect(pr.needsApproval && !pr.approvalsMet)
        pr.approvalStatus = "medium risk: 1 of 1 approvals on the latest commit"
        #expect(!pr.needsApproval && pr.approvalsMet)
        pr.reviewDecision = .reviewRequired
        pr.approvalStatus = "low risk: no approval needed"
        #expect(!pr.needsApproval && pr.approvalsMet)
        #expect(pr.approvalGate?.tier == "low")
    }
}
