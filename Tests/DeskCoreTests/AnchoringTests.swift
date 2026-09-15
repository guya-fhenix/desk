import DeskCore
import Foundation
import Testing

@Suite struct AnchoringTests {
    let file = [
        "import Foundation",
        "",
        "func poll() {",
        "    let mut n = 0",
        "    loop {",
        "        report(n)",
        "    }",
        "}",
    ]

    func anchor(_ text: String, before: [String] = [], after: [String] = [], sha: String = "old") -> CommentAnchor {
        CommentAnchor(text: text, before: before, after: after, sha: sha)
    }

    @Test func anUnchangedLineStaysWhereItIs() {
        #expect(Anchoring.locate(anchor("    let mut n = 0"), at: 4, in: file) == 4)
    }

    @Test func aLineThatOnlyMovedKeepsItsComment() {
        // Three lines inserted at the top: same line, new number.
        let shifted = ["// a", "// b", "// c"] + file
        #expect(Anchoring.locate(anchor("    let mut n = 0"), at: 4, in: shifted) == 7)
    }

    @Test func aChangedLineIsNotFound() {
        var edited = file
        edited[3] = "    let mut n = 1"
        #expect(Anchoring.locate(anchor("    let mut n = 0"), at: 4, in: edited) == nil)
        // Nor is one whose file lost it entirely.
        #expect(Anchoring.locate(anchor("    let mut n = 0"), at: 4, in: ["nothing here"]) == nil)
    }

    @Test func aLineThatStillSaysWhatItSaidIsNeverSearchedFor() {
        // The recorded line matching is the answer, whatever else the file contains. Anything else would
        // move a comment off a line that did not change.
        let braces = ["func a() {", "    work()", "}", "", "func b() {", "    work()", "}"]
        #expect(Anchoring.locate(anchor("}"), at: 3, in: braces) == 3)
        #expect(Anchoring.locate(anchor("}"), at: 7, in: braces) == 7)
    }

    @Test func aTrivialLineNeedsANeighbourToAgree() {
        let braces = ["func a() {", "    work()", "    more()", "}", "", "func b() {", "    work()", "}"]
        // The comment sat on a `}` at line 3, which now says something else. `}` matches twice more, and
        // with nothing to tell them apart, moving the comment would be a guess.
        #expect(Anchoring.locate(anchor("}"), at: 3, in: braces) == nil)
        // One neighbour agreeing is enough, and it picks the far match over the near one.
        #expect(Anchoring.locate(anchor("}", before: ["    work()"]), at: 3, in: braces) == 8)
    }

    @Test func contextBeatsDistanceBetweenIdenticalLines() {
        let twice = [
            "func a() {", "    value = compute()", "}", "",
            "func b() {", "    value = compute()", "}", "// tail",
        ]
        // Recorded at line 7, which now reads `}`. Line 6 is the nearer match but sits in the wrong
        // function; line 2 is farther and has both neighbours right.
        let inA = anchor("    value = compute()", before: ["func a() {"], after: ["}"])
        #expect(Anchoring.locate(inA, at: 7, in: twice) == 2)
    }

    @Test func aDistinctiveLineIsFoundEvenFarAway() {
        let moved = Array(repeating: "// filler", count: 400) + file
        #expect(Anchoring.locate(anchor("    let mut n = 0"), at: 4, in: moved) == 404)
    }

    @Test func reindentationCountsAsTheSameLineOnlyWhenNothingElseMatches() {
        var reindented = file
        reindented[3] = "        let mut n = 0"
        #expect(Anchoring.locate(anchor("    let mut n = 0"), at: 4, in: reindented) == 4)
    }

    @Test func reanchoringMarksWhatItCannotPlace() {
        var edited = file
        edited[3] = "    let mut n = 1"
        let comments = [
            Fixtures.comment(path: "a.swift", line: 4, anchorText: "    let mut n = 0"),
            Fixtures.comment(path: "a.swift", line: 6, anchorText: "        report(n)"),
            Fixtures.comment(path: "gone.swift", line: 1, anchorText: "whatever"),
        ]
        let updated = Anchoring.reanchored(comments, contents: ["a.swift": edited], sha: "new", side: .right)
        #expect(updated[0].isOutdated)
        #expect(updated[0].line == 4)
        #expect(!updated[1].isOutdated)
        #expect(updated[1].line == 6)
        // The file is not in the new commit at all, so whatever it pointed at certainly changed.
        #expect(updated[2].isOutdated)
        #expect(updated.allSatisfy { $0.anchor.sha == "new" })
    }

    @Test func reanchoringSkipsTheOtherSideAndWorkAlreadyDone() {
        let right = Fixtures.comment(side: .right, anchorText: "x", sha: "new")
        let left = Fixtures.comment(side: .left, anchorText: "x", sha: "old")
        let updated = Anchoring.reanchored([right, left], contents: [:], sha: "new", side: .right)
        // Already at that sha, and the left-side comment is not this pass's business.
        #expect(!updated[0].isOutdated)
        #expect(!updated[1].isOutdated)
        #expect(updated[1].anchor.sha == "old")
    }

    @Test func resolveCorrectsTheModelsLineFromTheQuotedText() {
        let diff = PullRequestDiff(files: DiffParser.parse(#"""
        diff --git a/src/gauge.rs b/src/gauge.rs
        --- a/src/gauge.rs
        +++ b/src/gauge.rs
        @@ -40,3 +40,4 @@
             fn poll(&self) {
        +        let mut n = 0;
                 report(n);
        """#), headSha: "sha9")

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
        let resolved = Anchoring.resolve(proposed, in: diff, baseSha: "base", run: 1)
        #expect(resolved.map(\.line) == [41, 41, 41, 900])
        #expect(resolved.map(\.isUnverified) == [false, false, true, true])
        // The anchor text comes from the diff, not from the model, whenever the diff has the line.
        #expect(resolved[0].anchor.text == "        let mut n = 0;")
        #expect(resolved[0].anchor.before == ["    fn poll(&self) {"])
        #expect(resolved[3].anchor.text == "nowhere")
        #expect(resolved.allSatisfy { $0.anchor.sha == "sha9" })
    }

    @Test func leftSideCommentsAnchorAgainstTheMergeBase() {
        let diff = PullRequestDiff(files: DiffParser.parse(
            "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,1 @@\n keep\n-drop\n"
        ), headSha: "sha9")
        let resolved = Anchoring.resolve(
            [ProposedComment(path: "a.txt", line: 2, side: .left, lineText: "drop", body: "why?")],
            in: diff, baseSha: "base1", run: 1
        )
        #expect(resolved[0].line == 2)
        #expect(resolved[0].anchor.sha == "base1")
        #expect(!resolved[0].isUnverified)
    }
}
