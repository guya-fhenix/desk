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
        let helper = DeskService.showHelper.path
        // Unquoted in the rule and the command alike, which only a path without spaces allows.
        #expect(!helper.contains(" "))
        #expect(Array(arguments.prefix(2)) == ["--allowedTools", "Bash(\(helper) *)"])
        #expect(arguments[2] == "--append-system-prompt")
        #expect(arguments[3].contains("\(helper) fhenixdesk://show/FhenixProtocol/cofhe/1166/<side>/<line>/<path>"))
        #expect(arguments.last == "/fhenix-workflow:review-pr https://github.com/FhenixProtocol/cofhe/pull/1166\n\nThe ticket it is for:\n\nPRO-1 — Fix it")
        #expect(DeskService.reviewArguments(for: pr, ticket: nil).last == "/fhenix-workflow:review-pr https://github.com/FhenixProtocol/cofhe/pull/1166")
    }

    /// The allowed helper refuses anything but one show link: an extra argument, a space, or another kind of URL never
    /// reaches `open`.
    @Test func theShowHelperOpensOneShowLinkOnly() async throws {
        try DeskService.installShowHelper()
        try DeskService.installShowHelper()
        let helper = DeskService.showHelper.path
        #expect(FileManager.default.isExecutableFile(atPath: helper))
        for arguments in [
            [],
            ["fhenixdesk://show/o/r/7/new/3/a.rs", "https://example.com"],
            ["fhenixdesk://show/o/r/7/new/3/a b.rs"],
            ["https://example.com"],
            ["/etc/passwd"],
        ] {
            #expect(try await Shell.run(helper, arguments).status == 64, "\(arguments)")
        }
    }

    /// A show link moves the diff only for an open PR Desk knows, matched by repo, any case, and number.
    @Test func aShowLinkFindsItsPullRequest() {
        var state = DeskState(config: DeskConfig())
        let pr = Fixtures.pr(number: 5, head: "h", author: "bob")
        state.github = GitHubSnapshot(login: "me", mine: [], reviewRequests: [pr], mergedRecent: [], fetchedAt: Fixtures.t0)
        func link(_ repo: String, _ number: Int) -> DeskLink { DeskLink(repo: repo, number: number, side: .right, line: 1, path: "a.rs") }
        #expect(state.pullRequest(for: link("fhenixprotocol/COFHE", 5))?.url == pr.url)
        #expect(state.pullRequest(for: link("FhenixProtocol/cofhe", 6)) == nil)
        #expect(state.pullRequest(for: link("FhenixProtocol/other", 5)) == nil)
    }

    @Test func theTicketGoesAlongWithItsTextWhenDeskHasIt() {
        let pr = Fixtures.pr(number: 1, head: "PRO-9-gate")
        #expect(DeskService.reviewTicket(for: pr, tickets: [], projectKeys: ["PRO"]) == "PRO-9")
        #expect(DeskService.reviewTicket(for: pr, tickets: [Fixtures.ticket("PRO-9")], projectKeys: ["PRO"]) == "PRO-9 — Summary PRO-9\n\nhttps://j/browse/PRO-9")
        #expect(DeskService.reviewTicket(for: Fixtures.pr(number: 2, head: "chore/x"), tickets: [], projectKeys: ["PRO"]) == nil)
    }
}
