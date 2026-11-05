import DeskCore
import Foundation
import Testing

@Suite struct ReviewThreadTests {
    private func thread(_ id: String, path: String = "src/a.rs", line: Int? = 1, author: String = "alice", body: String) -> ReviewThread {
        ReviewThread(id: id, path: path, line: line, url: "https://github.com/o/r/pull/1#discussion_r\(id)", author: author, body: body)
    }

    /// /pre-pr leads with its own word under its marker; CodeRabbit with its scale, in either of its two styles.
    @Test func severityReadsPrePRAndBothCodeRabbitStyles() {
        let cases: [(String, CommentSeverity?)] = [
            ("<!-- pre-pr:finding -->\n**Important** · R3 · Unchecked unwrap\n\nWhy.\n\n**Fix:** check it.", .important),
            ("<!-- pre-pr:finding -->\n**Nit** · Rename it", .nit),
            ("**Minor** · **Security & Privacy** · **Quick win**\n\n**Leaks the token.**", .nit),
            ("**Major** · **Correctness**\n\nOff by one.", .important),
            ("**Critical** · **Security**", .important),
            ("**Trivial** · **Style**", .nit),
            ("_⚠️ Potential issue_ | _🟠 Major_\n\n**Null deref.**", .important),
            ("_🛠️ Refactor suggestion_ | _🟡 Minor_", .nit),
            ("_🧹 Nitpick_\n\nSpacing.", .nit),
            ("_⚠️ Potential issue_\n\nSomething.", nil),
            ("Could you rename `my_var_name`? It reads as **important** further down.", nil),
            ("", nil),
        ]
        for (body, expected) in cases {
            #expect(ReviewThread.severity(of: body) == expected, "\(body)")
        }
    }

    @Test func sourceIsPrePRByMarkerThenCodeRabbitByAuthor() {
        #expect(thread("1", author: "me", body: "<!-- pre-pr:finding -->\n**Nit** · x").source == .prePR)
        #expect(thread("2", author: "coderabbitai[bot]", body: "**Minor** · x").source == .codeRabbit)
        #expect(thread("3", author: "coderabbitai", body: "**Minor** · x").source == .codeRabbit)
        #expect(thread("4", author: "alice", body: "Why?").source == .people)
    }

    /// By source, then Important, Nit and the rest, then file and line.
    @Test func orderGroupsBySourceThenSeverityThenPlace() {
        let threads = [
            thread("people", author: "alice", body: "Why?"),
            thread("crNit", path: "b.rs", author: "coderabbitai[bot]", body: "**Minor** · x"),
            thread("crNone", path: "a.rs", author: "coderabbitai[bot]", body: "Hmm"),
            thread("crBig", path: "z.rs", author: "coderabbitai[bot]", body: "**Major** · x"),
            thread("preNit", author: "me", body: "<!-- pre-pr:finding -->\n**Nit** · x"),
            thread("preBig2", path: "b.rs", line: 9, author: "me", body: "<!-- pre-pr:finding -->\n**Important** · x"),
            thread("preBig1", path: "b.rs", line: 3, author: "me", body: "<!-- pre-pr:finding -->\n**Important** · x"),
        ]
        #expect(threads.ordered.map(\.id) == ["preBig1", "preBig2", "preNit", "crBig", "crNit", "crNone", "people"])
    }

    @Test func previewDropsTheMarkerAndJoinsTheLines() {
        let finding = thread("1", body: "<!-- pre-pr:finding -->\n**Important** · Unchecked unwrap\n\nIt panics.\n")
        #expect(finding.preview == "**Important** · Unchecked unwrap It panics.")
        #expect(finding.place == "src/a.rs:1")
        #expect(thread("2", line: nil, body: "x").place == "src/a.rs")
    }

    /// The evidence comment as /pre-pr writes it: the page keeps Testing, Risk and How to revert, and the tier line.
    @Test func evidenceKeepsTestingRiskAndRevert() {
        let body = """
            <!-- pre-pr:start -->
            ## Testing
            - cargo test: passed

            ## Risk
            - Tier: medium. Needs a person: no. Expected approvals: 1.
            - Why: touches the gateway <!-- tier.sh -->

            ## How to revert
            Revert the squash commit.

            ## Local review
            | Step | Important |
            |---|---|
            <!-- pre-pr:end -->
            """
        let evidence = PrePR.evidence(body)
        #expect(evidence.sections.map(\.title) == ["Testing", "Risk", "How to revert"])
        #expect(evidence.sections[0].text == "- cargo test: passed")
        #expect(evidence.sections[1].text == "- Tier: medium. Needs a person: no. Expected approvals: 1.\n- Why: touches the gateway")
        #expect(evidence.sections[2].text == "Revert the squash commit.")
        #expect(evidence.tier == "Tier: medium. Needs a person: no. Expected approvals: 1.")
        #expect(PrePR.evidence("<!-- pre-pr:start -->\nnothing").sections.isEmpty)
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
