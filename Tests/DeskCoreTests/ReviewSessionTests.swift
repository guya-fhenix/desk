import DeskCore
import Foundation
import Testing

@Suite struct ReviewSessionTests {
    @Test func readsAShowLink() throws {
        let url = try #require(URL(string: "fhenixdesk://show/FhenixProtocol/cofhe/1166/new/193/.github/review/review-gate.mts"))
        let link = try #require(DeskLink(url))
        #expect(link == DeskLink(repo: "FhenixProtocol/cofhe", number: 1166, side: .right, line: 193, path: ".github/review/review-gate.mts"))
        // The same key a PR's url gives, which is how the link finds its PR.
        #expect(link.prKey == ClaudeJobs.prKey("https://github.com/FhenixProtocol/cofhe/pull/1166"))
        #expect(DeskLink(try #require(URL(string: "fhenixdesk://show/o/r/7/old/3/a.rs")))?.side == .left)
    }

    @Test func refusesAnythingElse() {
        for text in [
            "fhenixdesk://show/o/r/7/new/3", // no path
            "fhenixdesk://show/o/r/x/new/3/a.rs", // no number
            "fhenixdesk://show/o/r/7/both/3/a.rs", // no side
            "fhenixdesk://run/o/r/7/new/3/a.rs", // not show
            "https://show/o/r/7/new/3/a.rs",
        ] {
            #expect(URL(string: text).flatMap(DeskLink.init) == nil, "\(text)")
        }
    }

    @Test func aLinkLandsOnTheLineOrTheNearestOne() throws {
        let file = try #require(DiffParser.parse(#"""
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -10,3 +10,3 @@
         a
        -b
        +c
         d
        """#).first)
        // Rows: the hunk header, then a, b, c, d.
        #expect(file.row(nearest: 11, on: .right) == 3)
        #expect(file.row(nearest: 11, on: .left) == 2)
        #expect(file.row(nearest: 400, on: .right) == 4)
        #expect(file.row(nearest: 1, on: .right) == 1)
    }

    @Test func theSessionIsToldHowToMoveTheDiffAndThePromptGoesLast() {
        let pr = Fixtures.pr(number: 1166, head: "chore/x")
        let arguments = DeskService.reviewArguments(for: pr, ticket: "PRO-1 — Fix it")
        #expect(Array(arguments.prefix(2)) == ["--allowedTools", "Bash(open fhenixdesk://*)"])
        #expect(arguments[2] == "--append-system-prompt")
        #expect(arguments[3].contains("open fhenixdesk://show/FhenixProtocol/cofhe/1166/<side>/<line>/<path>"))
        #expect(arguments.last == "/fhenix-workflow:review-pr https://github.com/FhenixProtocol/cofhe/pull/1166\n\nThe ticket it is for:\n\nPRO-1 — Fix it")
        #expect(DeskService.reviewArguments(for: pr, ticket: nil).last == "/fhenix-workflow:review-pr https://github.com/FhenixProtocol/cofhe/pull/1166")
    }

    @Test func theTicketGoesAlongWithItsTextWhenDeskHasIt() {
        let pr = Fixtures.pr(number: 1, head: "PRO-9-gate")
        #expect(DeskService.reviewTicket(for: pr, tickets: [], projectKeys: ["PRO"]) == "PRO-9")
        #expect(DeskService.reviewTicket(for: pr, tickets: [Fixtures.ticket("PRO-9")], projectKeys: ["PRO"]) == "PRO-9 — Summary PRO-9\n\nhttps://j/browse/PRO-9")
        #expect(DeskService.reviewTicket(for: Fixtures.pr(number: 2, head: "chore/x"), tickets: [], projectKeys: ["PRO"]) == nil)
    }
}
