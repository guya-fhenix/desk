import DeskCore
import Foundation
import Testing

@Suite struct ReviewSessionTests {
    @Test func aThreadLandsOnItsLineOrTheNearestOne() throws {
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

    /// A review of one PR is a group of one, on review-teammate-task. The session gets no command it may run without
    /// asking and no way to move the diff: it is only told the diff is there, and the prompt goes last.
    @Test func theSessionCannotMoveTheDiffAndThePromptGoesLast() {
        let pr = Fixtures.pr(number: 1166, head: "chore/x")
        let arguments = DeskService.groupReviewArguments(ReviewGroup(pullRequests: [pr]), tickets: ["PRO-1 — Fix it"], otherClones: [], config: DeskConfig())
        #expect(arguments.count == 3)
        #expect(arguments[0] == "--append-system-prompt")
        #expect(arguments[1].contains(pr.url))
        #expect(!arguments[1].contains("://show/"))
        #expect(arguments.last == "Review these together with the fhenix-workflow:review-teammate-task skill:\nhttps://github.com/FhenixProtocol/cofhe/pull/1166\n\nThe tickets they are for:\n\nPRO-1 — Fix it")
    }

    @Test func theTicketGoesAlongWithItsTextWhenDeskHasIt() {
        let pr = Fixtures.pr(number: 1, head: "PRO-9-gate")
        #expect(DeskService.reviewTicket(for: pr, tickets: [], projectKeys: ["PRO"]) == "PRO-9")
        #expect(DeskService.reviewTicket(for: pr, tickets: [Fixtures.ticket("PRO-9")], projectKeys: ["PRO"]) == "PRO-9 — Summary PRO-9\n\nhttps://j/browse/PRO-9")
        #expect(DeskService.reviewTicket(for: Fixtures.pr(number: 2, head: "chore/x"), tickets: [], projectKeys: ["PRO"]) == nil)
    }

    /// A group review: the plugin folder and the other clones come first, the prompt names the skill and every PR, then
    /// the notes and the tickets, and comes last.
    @Test func aGroupReviewNamesTheSkillEveryPullRequestAndTheNotes() {
        let stack = Fixtures.pr(number: 120, repo: "FhenixProtocol/powershot", head: "roee/2", author: "roee")
        let other = Fixtures.pr(number: 14, repo: "FhenixProtocol/teecryptor", head: "roee/cidr", author: "roee")
        let group = ReviewGroup(pullRequests: [stack, other], notes: "  Start with #120.\n")
        var config = DeskConfig()
        config.pluginDir = "/mp/plugins"
        let arguments = DeskService.groupReviewArguments(group, tickets: ["PRO-646"], otherClones: ["/r/teecryptor"], config: config)
        #expect(Array(arguments.prefix(4)) == ["--plugin-dir", "/mp/plugins", "--add-dir", "/r/teecryptor"])
        #expect(arguments[4] == "--append-system-prompt")
        #expect(!arguments.contains("--allowedTools"))
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
        #expect(ClaudePlugins.reviewSkill(pluginDir: folder.path, home: home).groupReview)
        #expect(!ClaudePlugins.reviewSkill(home: home).groupReview)
    }
}
