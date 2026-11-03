import DeskCore
import Foundation
import Testing

@Suite struct ClaudePrintTests {
    @Test func readsTheResultEnvelope() throws {
        let stdout = #"""
        {"type":"result","subtype":"success","is_error":false,"duration_ms":91234,"num_turns":12,
         "result":"{\"verdict\":\"APPROVE\"}","session_id":"abcd1234-0000-4000-8000-000000000000",
         "total_cost_usd":1.2345,"permission_denials":[{"tool_name":"Bash","tool_use_id":"x"}]}
        """#
        let result = try ClaudePrint.result(stdout)
        #expect(result.subtype == "success")
        #expect(!result.isError)
        #expect(result.result == #"{"verdict":"APPROVE"}"#)
        #expect(result.costUSD == 1.2345)
        #expect(result.numTurns == 12)
        #expect(result.sessionId == "abcd1234-0000-4000-8000-000000000000")
        #expect(result.permissionDenials == ["Bash"])
    }

    @Test func skipsAnythingPrintedBeforeTheEnvelope() throws {
        // A hook or a version notice writes to the same stdout.
        let stdout = """
        {"hook":"PreToolUse","decision":"allow"}
        some plain text
        {"type":"result","subtype":"success","result":"ok","total_cost_usd":0.5}
        """
        let result = try ClaudePrint.result(stdout)
        #expect(result.result == "ok")
        #expect(result.costUSD == 0.5)
    }

    @Test func missingFieldsFallBackRatherThanFailing() throws {
        let result = try ClaudePrint.result(#"{"type":"result","result":"text"}"#)
        #expect(result.subtype == "unknown")
        #expect(result.costUSD == 0)
        #expect(result.permissionDenials.isEmpty)

        // An unexpected shape on one field must not cost us the rest of the envelope.
        let odd = try ClaudePrint.result(#"{"type":"result","result":"text","permission_denials":"lots","total_cost_usd":2}"#)
        #expect(odd.result == "text")
        #expect(odd.costUSD == 2)
    }

    @Test func noResultObjectThrowsWithTheOutput() {
        #expect(throws: ClaudePrintError.self) { try ClaudePrint.result("", stderr: "claude: command failed") }
        #expect(throws: ClaudePrintError.self) { try ClaudePrint.result(#"{"type":"assistant","message":{}}"#) }
    }
}

@Suite struct ReviewOutputParserTests {
    static let clean = #"""
    {
      "verdict": "REQUEST_CHANGES",
      "summary": "Adds a gauge metric. One real bug in the retry loop.",
      "comments": [
        {"path": "src/gauge.rs", "side": "RIGHT", "line": 42, "lineText": "        let mut n = 0;",
         "severity": "blocker", "body": "Off by one: `n` starts at 0 but the cap is 3."},
        {"path": "b/src/retry.rs", "side": "LEFT", "line": 7, "severity": "nit", "body": "Stale comment."}
      ]
    }
    """#

    @Test func readsTheContract() throws {
        let output = try ReviewOutputParser.parse(Self.clean)
        #expect(output.verdict == .requestChanges)
        #expect(output.summary == "Adds a gauge metric. One real bug in the retry loop.")
        #expect(!output.isFallback)
        #expect(output.comments.count == 2)
        #expect(output.comments[0].path == "src/gauge.rs")
        #expect(output.comments[0].line == 42)
        #expect(output.comments[0].side == .right)
        #expect(output.comments[0].severity == .important)
        #expect(output.comments[0].lineText == "        let mut n = 0;")
        // A model that quotes the diff header prefix must not send `b/…` to GitHub.
        #expect(output.comments[1].path == "src/retry.rs")
        #expect(output.comments[1].side == .left)
        #expect(output.comments[1].severity == .nit)
    }

    @Test func survivesFencesAndSurroundingProse() throws {
        let fenced = "Here is my review.\n\n```json\n\(Self.clean)\n```\n\nHappy to discuss.\n"
        #expect(try ReviewOutputParser.parse(fenced).comments.count == 2)
        let bare = "Looks mostly fine.\n\(Self.clean)\nThat is everything."
        #expect(try ReviewOutputParser.parse(bare).verdict == .requestChanges)
    }

    @Test func picksTheRichestObjectAndThenTheLast() throws {
        let restated = """
        {"verdict":"APPROVE","summary":"first pass","comments":[]}
        {"verdict":"COMMENT","summary":"second pass","comments":[
          {"path":"a.swift","line":1,"body":"one"},{"path":"a.swift","line":2,"body":"two"}]}
        """
        #expect(try ReviewOutputParser.parse(restated).summary == "second pass")

        let tied = """
        {"verdict":"APPROVE","summary":"earlier","comments":[{"path":"a.swift","line":1,"body":"one"}]}
        {"verdict":"APPROVE","summary":"later","comments":[{"path":"a.swift","line":1,"body":"one"}]}
        """
        #expect(try ReviewOutputParser.parse(tied).summary == "later")
    }

    @Test func normalizesVerdictsAndSeverities() {
        #expect(ReviewOutputParser.verdict("REQUEST CHANGES") == .requestChanges)
        #expect(ReviewOutputParser.verdict("changes_requested") == .requestChanges)
        #expect(ReviewOutputParser.verdict("LGTM") == .approve)
        #expect(ReviewOutputParser.verdict("Approved") == .approve)
        // Anything unrecognised, nil included, lands on the verdict that asserts least.
        #expect(ReviewOutputParser.verdict("NEEDS DISCUSSION") == .comment)
        #expect(ReviewOutputParser.verdict(nil) == .comment)

        #expect(ReviewOutputParser.severity("critical") == .important)
        #expect(ReviewOutputParser.severity("Warning") == .important)
        #expect(ReviewOutputParser.severity("nitpick") == .nit)
        #expect(ReviewOutputParser.severity(nil) == .nit)
        #expect(ReviewOutputParser.severity("Important") == .important)
        #expect(ReviewOutputParser.severity("pre-existing") == .preExisting)
        #expect(ReviewOutputParser.severity("blocker") == .important)
    }

    @Test func acceptsTheLineNumberInEveryShapeAModelWrites() throws {
        let json = """
        {"comments":[
          {"path":"a.swift","line":"214","body":"a"},
          {"path":"b.swift","line":"L37","body":"b"},
          {"path":"c.swift","line":"100-104","body":"c"},
          {"path":"d.swift","line":9.0,"body":"d"},
          {"file":"e.swift","line_number":5,"message":"e"}]}
        """
        let comments = try ReviewOutputParser.parse(json).comments
        #expect(comments.map(\.line) == [214, 37, 104, 9, 5])
        #expect(comments.map(\.path) == ["a.swift", "b.swift", "c.swift", "d.swift", "e.swift"])
        #expect(comments[4].body == "e")
    }

    @Test func dropsCommentsThatCouldNeverBePosted() throws {
        let json = """
        {"summary":"s","comments":[
          {"path":"a.swift","line":1,"body":"keep"},
          {"path":"","line":2,"body":"no path"},
          {"path":"b.swift","body":"no line"},
          {"path":"c.swift","line":0,"body":"line zero"},
          {"path":"d.swift","line":4,"body":"   "}]}
        """
        let comments = try ReviewOutputParser.parse(json).comments
        #expect(comments.map(\.body) == ["keep"])
    }

    @Test func noReviewObjectThrows() {
        #expect(throws: ReviewOutputError.self) { try ReviewOutputParser.parse("I could not review this.") }
        // An object, but not a review one.
        #expect(throws: ReviewOutputError.self) { try ReviewOutputParser.parse(#"{"tool":"Read","ok":true}"#) }
    }

    @Test func fallbackKeepsTheProse() {
        let output = ReviewOutput.fallback(raw: "\n## Verdict\nAPPROVE, looks good.\n")
        #expect(output.isFallback)
        #expect(output.verdict == .comment)
        #expect(output.summary == "## Verdict\nAPPROVE, looks good.")
        #expect(output.comments.isEmpty)
    }

    @Test func zeroFindingsIsAValidReview() throws {
        let output = try ReviewOutputParser.parse(#"{"verdict":"APPROVE","summary":"Clean.","comments":[]}"#)
        #expect(output.verdict == .approve)
        #expect(output.comments.isEmpty)
        #expect(!output.isFallback)
    }
}
