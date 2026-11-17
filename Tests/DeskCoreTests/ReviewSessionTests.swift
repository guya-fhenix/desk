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

    /// A group review: the plugin folder and the other clones come before the one allowed command, the prompt names the
    /// skill and every PR, then the notes and the tickets, and comes last.
    @Test func aGroupReviewNamesTheSkillEveryPullRequestAndTheNotes() {
        let stack = Fixtures.pr(number: 120, repo: "FhenixProtocol/powershot", head: "roee/2", author: "roee")
        let other = Fixtures.pr(number: 14, repo: "FhenixProtocol/teecryptor", head: "roee/cidr", author: "roee")
        let group = ReviewGroup(pullRequests: [stack, other], notes: "  Start with #120.\n")
        var config = DeskConfig()
        config.pluginDir = "/mp/plugins"
        let arguments = DeskService.groupReviewArguments(group, tickets: ["PRO-646"], otherClones: ["/r/teecryptor"], config: config)
        #expect(Array(arguments.prefix(4)) == ["--plugin-dir", "/mp/plugins", "--add-dir", "/r/teecryptor"])
        #expect(arguments[4] == "--allowedTools")
        #expect(arguments[6] == "--append-system-prompt")
        #expect(arguments[7].contains("fhenixdesk://show/<owner>/<repo>/<number>/<side>/<line>/<path>"))
        #expect(arguments.last == """
            Review these together with the fhenix-workflow:review-teammate-task skill:
            https://github.com/FhenixProtocol/powershot/pull/120
            https://github.com/FhenixProtocol/teecryptor/pull/14

            My notes: Start with #120.

            The tickets they are for:

            PRO-646
            """)
        #expect(DeskService.groupReviewPrompt(ReviewGroup(pullRequests: [other]), tickets: []).hasSuffix("teecryptor/pull/14"))
        // The same PRs in another order are the same group.
        #expect(ReviewGroup(pullRequests: [other, stack]).id == group.id)
    }

    /// Picked in any order, a group reads repo by repo in the order picked, each stack base first.
    @Test func aGroupIsOrderedBaseFirstWithinEachRepo() {
        let one = Fixtures.pr(number: 119, repo: "FhenixProtocol/powershot", head: "roee/1", base: "ohad/x")
        let two = Fixtures.pr(number: 120, repo: "FhenixProtocol/powershot", head: "roee/2", base: "roee/1")
        let tee = Fixtures.pr(number: 14, repo: "FhenixProtocol/teecryptor", head: "roee/cidr")
        let parents = Linker.stackParents([one, two, tee])
        #expect(ReviewGroup.ordered([two, tee, one], parents: parents).map(\.number) == [119, 120, 14])
    }

    /// A group review can run when the plugin folder Desk loads has the skill, whatever is installed.
    @Test func aPluginFolderWithTheSkillAllowsAGroupReview() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let skill = folder.appendingPathComponent("fhenix-workflow/skills/review-teammate-task")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: review-teammate-task\n---\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let home = folder.appendingPathComponent("home").path
        #expect(ClaudePlugins.reviewSkill(repoRoot: "/nowhere", pluginDir: folder.path, home: home).groupReview)
        #expect(!ClaudePlugins.reviewSkill(repoRoot: "/nowhere", home: home).groupReview)
    }
}
