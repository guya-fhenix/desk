import DeskCore
import Foundation
import Testing

@Suite struct CommentMergeTests {
    @Test func aDecidedCommentKeepsItsLineThroughARerun() {
        var approved = Fixtures.comment(line: 10, body: "Claude's words", state: .approved)
        approved.editedBody = "my words"
        let existing = [approved, Fixtures.comment(line: 20, state: .rejected)]
        let incoming = [
            // The same finding, reworded by the new run.
            Fixtures.comment(line: 10, severity: .blocker, body: "reworded", run: 2),
            // The same line the user already dismissed.
            Fixtures.comment(line: 20, body: "here again", run: 2),
            Fixtures.comment(line: 30, body: "new finding", run: 2),
        ]
        let merged = CommentMerge.merge(existing: existing, incoming: incoming, run: 2, now: Fixtures.t0)
        #expect(merged.map(\.line) == [10, 20, 30])
        // The user's state, wording and id all survive; only what the run can see is refreshed.
        #expect(merged[0].id == approved.id)
        #expect(merged[0].state == .approved)
        #expect(merged[0].text == "my words")
        #expect(merged[0].body == "Claude's words")
        #expect(merged[0].severity == .blocker)
        #expect(merged[0].lastRun == 2)
        #expect(merged[0].firstRun == 1)
        // A rejected comment holds its line, so a re-run cannot resurrect it.
        #expect(merged[1].state == .rejected)
        #expect(merged[1].body == "Off by one.")
        #expect(merged[2].state == .pending)
        #expect(merged[2].firstRun == 2)
    }

    @Test func theSameLineOnEitherSideIsTwoDifferentComments() {
        let merged = CommentMerge.merge(
            existing: [Fixtures.comment(line: 5, side: .right)],
            incoming: [Fixtures.comment(line: 5, side: .left, run: 2)],
            run: 2, now: Fixtures.t0
        )
        #expect(merged.count == 2)
    }

    @Test func arefoundCommentStopsBeingOutdated() {
        let stale = Fixtures.comment(line: 7, state: .approved, outdated: true)
        let merged = CommentMerge.merge(existing: [stale], incoming: [Fixtures.comment(line: 7, run: 2)], run: 2, now: Fixtures.t0)
        #expect(!merged[0].isOutdated)
        #expect(merged[0].state == .approved)
    }

    @Test func outputIsInFileOrder() {
        let merged = CommentMerge.merge(existing: [], incoming: [
            Fixtures.comment(path: "b.swift", line: 1),
            Fixtures.comment(path: "a.swift", line: 30),
            Fixtures.comment(path: "a.swift", line: 2),
        ], run: 1, now: Fixtures.t0)
        #expect(merged.map { "\($0.path):\($0.line)" } == ["a.swift:2", "a.swift:30", "b.swift:1"])
    }
}

@Suite struct ReviewBodyTests {
    @Test func summaryAloneWhenNothingWasFolded() {
        let body = ReviewBody.compose(
            summary: "Adds a gauge.", verdict: .approve, folded: [], inlineCount: 2,
            repo: "FhenixProtocol/cofhe", sha: "4f2ab19"
        )
        #expect(body == "Adds a gauge.")
    }

    @Test func anEmptyBodyIsFilledInWhenGitHubDemandsOne() {
        // GitHub rejects a request-changes or comment review with no body at all.
        #expect(ReviewBody.compose(summary: "", verdict: .requestChanges, folded: [], inlineCount: 3, repo: "o/r", sha: "s")
            == "See the inline comments.")
        #expect(ReviewBody.compose(summary: "", verdict: .comment, folded: [], inlineCount: 0, repo: "o/r", sha: "s")
            == "No further comments.")
        // An approval may go out with nothing said.
        #expect(ReviewBody.compose(summary: "", verdict: .approve, folded: [], inlineCount: 0, repo: "o/r", sha: "s").isEmpty)
    }

    @Test func commentsThatCannotAttachAreFoldedInWithPermalinks() {
        let folded = [
            Fixtures.comment(path: "src/a.swift", line: 12, severity: .major, body: "First line\nSecond line", outdated: true),
            Fixtures.comment(path: "src/b.swift", line: 3, severity: .nit, body: "Tiny thing"),
        ]
        let body = ReviewBody.compose(
            summary: "Mostly good.", verdict: .requestChanges, folded: folded, inlineCount: 1,
            repo: "FhenixProtocol/cofhe", sha: "4f2ab19"
        )
        #expect(body.hasPrefix("Mostly good.\n\n<details>"))
        #expect(body.contains("<summary>2 notes on lines that are no longer in the diff</summary>"))
        // Pinned to the sha the comment was written against, so the link still shows the line it meant.
        #expect(body.contains("[`src/a.swift:12`](https://github.com/FhenixProtocol/cofhe/blob/4f2ab19/src/a.swift#L12)"))
        #expect(body.contains("*(outdated)*"))
        #expect(body.contains("**major**"))
        // A multi-line body stays inside its own bullet.
        #expect(body.contains("First line\n  Second line"))
        #expect(body.hasSuffix("</details>"))

        let one = ReviewBody.compose(summary: "s", verdict: .comment, folded: [folded[0]], inlineCount: 0, repo: "o/r", sha: "s")
        #expect(one.contains("<summary>1 note on a line that is no longer in the diff</summary>"))
    }

    @Test func aUserEditIsWhatGetsPosted() {
        var comment = Fixtures.comment(body: "Claude's words")
        comment.editedBody = "my words"
        let body = ReviewBody.compose(summary: "", verdict: .comment, folded: [comment], inlineCount: 0, repo: "o/r", sha: "s")
        #expect(body.contains("my words"))
        #expect(!body.contains("Claude's words"))
    }
}

@Suite struct ReviewSubmissionTests {
    @Test func payloadCarriesTheCommitAndTheInlineComments() throws {
        let submission = ReviewSubmission(
            repo: "FhenixProtocol/cofhe", number: 928, commitId: "4f2ab19", event: .requestChanges, body: "Body.",
            comments: [
                ReviewSubmission.Inline(path: "src/a.swift", line: 12, side: .right, body: "one"),
                ReviewSubmission.Inline(path: "src/b.swift", line: 3, side: .left, body: "two"),
            ]
        )
        let object = try #require(JSONSerialization.jsonObject(with: try submission.jsonBody()) as? [String: Any])
        #expect(object["commit_id"] as? String == "4f2ab19")
        #expect(object["event"] as? String == "REQUEST_CHANGES")
        #expect(object["body"] as? String == "Body.")
        let comments = try #require(object["comments"] as? [[String: Any]])
        #expect(comments.count == 2)
        #expect(comments[0]["path"] as? String == "src/a.swift")
        #expect(comments[0]["line"] as? Int == 12)
        #expect(comments[0]["side"] as? String == "RIGHT")
        #expect(comments[1]["side"] as? String == "LEFT")
    }

    @Test func aBodyOnlyReviewSendsNoCommentsKey() throws {
        let submission = ReviewSubmission(
            repo: "o/r", number: 1, commitId: "s", event: .approve, body: "Looks good.", comments: []
        )
        let object = try #require(JSONSerialization.jsonObject(with: try submission.jsonBody()) as? [String: Any])
        #expect(object["comments"] == nil)
        #expect(object["event"] as? String == "APPROVE")
    }
}

@Suite struct DiffDocumentTests {
    var document: DiffDocument {
        DiffDocument(PullRequestDiff(files: DiffParser.parse(#"""
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         keep
        -old
        +new
        diff --git a/b.txt b/b.txt
        --- a/b.txt
        +++ b/b.txt
        @@ -5,1 +5,2 @@
         there
        +added
        """#), headSha: "sha9"))
    }

    @Test func flattensToRowsWithFileRanges() {
        let document = document
        #expect(document.files.map(\.path) == ["a.txt", "b.txt"])
        // Each file's rows are its hunk header plus its lines.
        #expect(document.files[0].rowRange.count == 4)
        #expect(document.files[1].rowRange.count == 3)
        #expect(document.rows.count == 7)
        // Ids are sequential Ints, so ForEach's id pass costs nothing.
        #expect(document.rows.map(\.id) == Array(0..<7))
        #expect(document.rows[0].hunkHeader == "@@ -1,2 +1,2 @@")
        #expect(document.rows[1].line?.text == "keep")
    }

    @Test func knowsEveryLineACommentCanSitOn() {
        let keys = document.commentableKeys
        #expect(keys.contains(CommentKey(path: "a.txt", line: 2, side: .right)))
        #expect(keys.contains(CommentKey(path: "a.txt", line: 2, side: .left)))
        // A context line exists on both sides.
        #expect(keys.contains(CommentKey(path: "a.txt", line: 1, side: .right)))
        #expect(keys.contains(CommentKey(path: "a.txt", line: 1, side: .left)))
        #expect(!keys.contains(CommentKey(path: "a.txt", line: 99, side: .right)))
        #expect(!keys.contains(CommentKey(path: "nowhere.txt", line: 1, side: .right)))
    }

    @Test func tabsAreExpandedSoColumnsLineUp() {
        let document = DiffDocument(PullRequestDiff(files: DiffParser.parse(
            "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-x\n+\tif a {\n"
        ), headSha: "s"))
        #expect(document.rows.last?.line?.text == "    if a {")
    }
}
