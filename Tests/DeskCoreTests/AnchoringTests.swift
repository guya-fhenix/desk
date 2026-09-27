import DeskCore
import Foundation
import Testing

/// What reaches the draft: every finding on the line it is really about, and nothing GitHub would reject
/// the whole draft over.
@Suite struct AnchoringTests {
    let diff = PullRequestDiff(files: DiffParser.parse(#"""
    diff --git a/src/gauge.rs b/src/gauge.rs
    --- a/src/gauge.rs
    +++ b/src/gauge.rs
    @@ -40,3 +40,4 @@
         fn poll(&self) {
    +        let mut n = 0;
             report(n);
    diff --git a/a.txt b/a.txt
    --- a/a.txt
    +++ b/a.txt
    @@ -1,2 +1,1 @@
     keep
    -drop
    """#), headSha: "sha9")

    @Test func resolveCorrectsTheModelsLineFromTheQuotedText() {
        let proposed = [
            // Right line, right quote: nothing to correct.
            ProposedComment(path: "src/gauge.rs", line: 41, lineText: "        let mut n = 0;", body: "a"),
            // Wrong line, right quote: the quote wins.
            ProposedComment(path: "src/gauge.rs", line: 47, lineText: "        let mut n = 0;", body: "b"),
            // No quote at all: the number is taken on trust and flagged.
            ProposedComment(path: "src/gauge.rs", line: 41, lineText: "", body: "c"),
            // A line the diff has never heard of.
            ProposedComment(path: "src/gauge.rs", line: 900, lineText: "nowhere", body: "d"),
        ]
        let resolved = Anchoring.resolve(proposed, in: diff)
        #expect(resolved.map(\.line) == [41, 41, 41, 900])
        #expect(resolved.map(\.isUnverified) == [false, false, true, true])
    }

    @Test func aLeftSideCommentKeepsItsSide() {
        let resolved = Anchoring.resolve(
            [ProposedComment(path: "a.txt", line: 2, side: .left, lineText: "drop", body: "why?")], in: diff
        )
        #expect(resolved[0].line == 2)
        #expect(resolved[0].side == .left)
        #expect(!resolved[0].isUnverified)
    }

    /// A line in the diff takes the comment; a line outside it, in a file the PR changes, turns into a
    /// comment on the file that names the line; a file the PR does not touch has nowhere to go.
    @Test func eachFindingLandsWhereGitHubWillTakeIt() {
        let placed = DraftThreads.threads([
            Fixtures.comment(path: "src/gauge.rs", line: 41),
            Fixtures.comment(path: "src/gauge.rs", line: 900, severity: .nit),
            Fixtures.comment(path: "a.txt", line: 2, side: .left),
            Fixtures.comment(path: "src/elsewhere.rs", line: 3),
        ], in: diff)
        #expect(placed.threads.map(\.path) == ["src/gauge.rs", "src/gauge.rs", "a.txt"])
        #expect(placed.threads.map(\.line) == [41, nil, 2])
        #expect(placed.threads[2].side == .left)
        #expect(placed.threads[1].body.hasPrefix("**Nit** · line 900\n\n"))
        #expect(placed.unplaced == 1)
    }

    /// The severity leads, since on GitHub there is nothing else to triage by.
    @Test func theBodyStartsWithItsSeverity() {
        #expect(DraftThreads.body(Fixtures.comment(severity: .blocker, body: "Off by one."), onLine: true) == "**Blocker**\n\nOff by one.")
        #expect(DraftThreads.body(Fixtures.comment(body: "x", unverified: true), onLine: true) == "**Major** · line not verified\n\nx")
        #expect(DraftThreads.body(Fixtures.comment(line: 7, side: .left, body: "x"), onLine: false) == "**Major** · old line 7\n\nx")
    }
}
