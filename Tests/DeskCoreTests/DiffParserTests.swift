import DeskCore
import Foundation
import Testing

@Suite struct DiffParserTests {
    @Test func numbersLinesFromTheHunkHeader() throws {
        let diff = #"""
        diff --git a/src/gauge.rs b/src/gauge.rs
        index 9127faf..acf6374 100644
        --- a/src/gauge.rs
        +++ b/src/gauge.rs
        @@ -40,4 +40,5 @@ impl Gauge {
             fn poll(&self) {
        -        let n = 0;
        +        let mut n = 0;
        +        loop {
                 report(n);
        """#
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.path == "src/gauge.rs")
        #expect(file.status == .modified)
        #expect(file.additions == 2)
        #expect(file.deletions == 1)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.heading == "impl Gauge {")
        #expect(hunk.lines.map(\.kind) == [.context, .removed, .added, .added, .context])
        #expect(hunk.lines.map(\.oldLine) == [40, 41, nil, nil, 42])
        #expect(hunk.lines.map(\.newLine) == [40, nil, 41, 42, 43])
        #expect(hunk.lines.map(\.position) == [1, 2, 3, 4, 5])
        #expect(file.line(41, on: .right)?.text == "        let mut n = 0;")
        #expect(file.line(41, on: .left)?.text == "        let n = 0;")
    }

    @Test func laterHunkHeadersTakeAPositionOfTheirOwn() throws {
        let diff = #"""
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,4 @@
         a
        +b
         c
         d
        @@ -10,2 +11,2 @@
         e
        -f
        +g
        """#
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.hunks.count == 2)
        #expect(file.hunks[0].lines.map(\.position) == [1, 2, 3, 4])
        #expect(file.hunks[1].lines.map(\.position) == [6, 7, 8])
        #expect(file.hunks[1].lines.map(\.oldLine) == [10, 11, nil])
        #expect(file.hunks[1].lines.map(\.newLine) == [11, nil, 12])
    }

    @Test func readsAddedRemovedRenamedAndBinaryFiles() throws {
        let diff = #"""
        diff --git a/new.json b/new.json
        new file mode 100644
        index 0000000..031d5f3
        --- /dev/null
        +++ b/new.json
        @@ -0,0 +1,2 @@
        +{
        +}
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 031d5f3..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/old/name.swift b/new/name.swift
        similarity index 95%
        rename from old/name.swift
        rename to new/name.swift
        index aaa..bbb 100644
        --- a/old/name.swift
        +++ b/new/name.swift
        @@ -1 +1 @@
        -let a = 1
        +let a = 2
        diff --git a/logo.png b/logo.png
        index aaa..bbb 100644
        Binary files a/logo.png and b/logo.png differ
        """#
        let files = DiffParser.parse(diff)
        #expect(files.map(\.path) == ["new.json", "gone.txt", "new/name.swift", "logo.png"])
        #expect(files.map(\.status) == [.added, .removed, .renamed, .modified])

        #expect(files[0].additions == 2)
        #expect(files[0].hunks[0].lines.map(\.newLine) == [1, 2])
        #expect(files[0].hunks[0].lines.allSatisfy { $0.oldLine == nil })

        #expect(files[1].deletions == 1)
        #expect(files[1].hunks[0].lines.map(\.oldLine) == [1])

        #expect(files[2].previousPath == "old/name.swift")
        // A missing count in `@@ -1 +1 @@` means one line, not zero.
        #expect(files[2].hunks[0].oldCount == 1)
        #expect(files[2].hunks[0].lines.count == 2)

        #expect(files[3].isBinary)
        #expect(files[3].hunks.isEmpty)
    }

    @Test func noNewlineMarkerDoesNotConsumeALineNumber() throws {
        let diff = #"""
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         first
        -second
        \ No newline at end of file
        +second!
        \ No newline at end of file
        """#
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.hunks[0].lines.map(\.text) == ["first", "second", "second!"])
        #expect(file.hunks[0].lines.map(\.newLine) == [1, nil, 2])
        #expect(file.additions == 1)
        #expect(file.deletions == 1)
    }

    @Test func contextLineStrippedOfItsLeadingSpaceStillCounts() throws {
        // Trailing whitespace is easy to lose in transit; an empty line inside a hunk is a context line.
        let diff = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,3 +1,3 @@\n one\n\n-two\n+three\n"
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.hunks[0].lines.map(\.kind) == [.context, .context, .removed, .added])
        #expect(file.hunks[0].lines.map(\.text) == ["one", "", "two", "three"])
        #expect(file.hunks[0].lines.map(\.newLine) == [1, 2, nil, 3])
    }

    @Test func modeOnlyChangeFallsBackToTheGitHeader() throws {
        let diff = #"""
        diff --git a/scripts/bundle.sh b/scripts/bundle.sh
        old mode 100644
        new mode 100755
        """#
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.path == "scripts/bundle.sh")
        #expect(file.hunks.isEmpty)
        #expect(file.additions == 0)
    }

    @Test func quotedPathsAreUnquoted() {
        #expect(GitParsing.unquotePath(#""a/pa\tth.txt""#) == "a/pa\tth.txt")
        #expect(GitParsing.unquotePath("plain/path.txt") == "plain/path.txt")
        #expect(GitParsing.unquotePath(#""na\303\257ve.txt""#) == "naïve.txt")
        #expect(GitParsing.unquotePath(#""quote\"inside.txt""#) == "quote\"inside.txt")

        let diff = "diff --git \"a/na\\303\\257ve.txt\" \"b/na\\303\\257ve.txt\"\n--- \"a/na\\303\\257ve.txt\"\n+++ \"b/na\\303\\257ve.txt\"\n@@ -1 +1 @@\n-a\n+b\n"
        #expect(DiffParser.parse(diff).first?.path == "naïve.txt")
    }

    @Test func garbageBetweenFilesDoesNotSwallowTheNextOne() {
        let diff = #"""
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -a
        +b
        this line belongs to nothing
        diff --git a/b.txt b/b.txt
        --- a/b.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -c
        +d
        """#
        #expect(DiffParser.parse(diff).map(\.path) == ["a.txt", "b.txt"])
    }

    @Test func emptyInputIsNoFiles() {
        #expect(DiffParser.parse("").isEmpty)
        #expect(DiffParser.parse("not a diff at all\n").isEmpty)
    }
}

@Suite struct PullRequestDiffTests {
    var diff: PullRequestDiff {
        let text = #"""
        diff --git a/src/gauge.rs b/src/gauge.rs
        --- a/src/gauge.rs
        +++ b/src/gauge.rs
        @@ -40,4 +40,5 @@
             fn poll(&self) {
        -        let n = 0;
        +        let mut n = 0;
        +        loop {
                 report(n);
        diff --git a/logo.png b/logo.png
        Binary files a/logo.png and b/logo.png differ
        """#
        return PullRequestDiff(files: DiffParser.parse(text), headSha: "sha1", fetchedAt: Fixtures.t0)
    }

    @Test func commentableOnlyInsideTheDiff() {
        #expect(diff.isCommentable(path: "src/gauge.rs", line: 41, side: .right))
        #expect(diff.isCommentable(path: "src/gauge.rs", line: 40, side: .right))
        #expect(!diff.isCommentable(path: "src/gauge.rs", line: 500, side: .right))
        // Line 41 on the left is the line the PR deleted, so it takes a comment too.
        #expect(diff.isCommentable(path: "src/gauge.rs", line: 41, side: .left))
        #expect(!diff.isCommentable(path: "nowhere.rs", line: 1, side: .right))
        // A binary file has no lines, so nothing can be attached to it.
        #expect(!diff.isCommentable(path: "logo.png", line: 1, side: .right))
    }

    @Test func snapCorrectsALineNumberFromTheQuotedText() {
        #expect(diff.snap(path: "src/gauge.rs", near: 44, side: .right, matching: "        let mut n = 0;") == 41)
        // Leading whitespace the model dropped must not stop the match.
        #expect(diff.snap(path: "src/gauge.rs", near: 41, side: .right, matching: "let mut n = 0;") == 41)
        // Outside the window is no match at all rather than a wrong one.
        #expect(diff.snap(path: "src/gauge.rs", near: 900, side: .right, matching: "        loop {", window: 5) == nil)
        #expect(diff.snap(path: "src/gauge.rs", near: 41, side: .right, matching: "not in the file") == nil)
    }

}
