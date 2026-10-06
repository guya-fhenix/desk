import DeskCore
import Foundation
import Testing

/// Prompts edited in Settings. The defaults are pinned by the session, ticket and review prompt tests;
/// these cover what an edit does.
@Suite struct PromptTests {
    /// One pass: a value is never searched for placeholders, and braces that name nothing stay as typed —
    /// the output format is JSON.
    @Test func fillIsOnePassAndLeavesOtherBracesAlone() {
        let filled = PromptTemplate.fill(#"{a} {b} {"x": 1} {unknown} {"#, ["a": "{b}", "b": "B"])
        #expect(filled == #"{b} B {"x": 1} {unknown} {"#)
    }

    @Test func aParagraphThatFillsToNothingIsDropped() {
        #expect(PromptTemplate.fill("A\n\n{block}\n\nC", ["block": ""]) == "A\n\nC")
        #expect(PromptTemplate.fill("A\n\n{block}\n\nC", ["block": "B\n\nB2"]) == "A\n\nB\n\nB2\n\nC")
    }

    @Test func anEditedBlockIsWhatTheSessionGets() {
        var config = DeskConfig()
        config.prompts[PromptID.sessionConflict.rawValue] = "Rebase onto {baseRef} and stop."
        let pr = Fixtures.pr(number: 4, head: "feat/x", base: "master", merge: .dirty)
        let prompt = DeskService.sessionPrompt(for: pr, config: config)
        #expect(prompt.hasSuffix("\n\nRebase onto master and stop."))
        #expect(!prompt.contains("It conflicts with"))
    }

    /// Taking the placeholder out of the parent is how a block is turned off.
    @Test func aParentWithoutThePlaceholderDropsTheBlock() {
        var config = DeskConfig()
        config.prompts[PromptID.session.rawValue] = "Look at {url}."
        var pr = Fixtures.pr(number: 4, head: "feat/x", merge: .dirty)
        pr.unresolvedThreads = 2
        #expect(DeskService.sessionPrompt(for: pr, config: config) == "Look at https://github.com/FhenixProtocol/cofhe/pull/4.")
    }

    /// An edit cleared to nothing would start a session with nothing to do.
    @Test func aBlankEditIsTheDefault() {
        var config = DeskConfig()
        config.prompts[PromptID.ticketPlan.rawValue] = "  \n "
        let ticket = Fixtures.ticket("PRO-1")
        #expect(DeskService.ticketPrompt(for: ticket, config: config) == DeskService.ticketPrompt(for: ticket))
    }

    @Test func reviewEditsReachTheArguments() {
        var config = DeskConfig()
        config.prompts[PromptID.reviewSystem.rawValue] = "Be brief."
        config.prompts[PromptID.reviewOutputFormat.rawValue] = "Answer as {\"comments\": []}."
        config.prompts[PromptID.reviewReformat.rawValue] = "Fix the JSON."
        let pr = Fixtures.pr(number: 928, head: "feat/gauge")
        let arguments = ReviewCommand.reviewArguments(pr: pr, otherRepos: [], config: config)
        let system = try! #require(arguments.firstIndex(of: "--append-system-prompt"))
        #expect(arguments[system + 1] == "Be brief.")
        #expect(arguments[0].contains("Answer as {\"comments\": []}."))
        #expect(!arguments[0].contains("Rules for comments"))
        #expect(ReviewCommand.reformatArguments(config: config)[0] == "Fix the JSON.")
    }

    /// The Settings legend never advertises a name that fills nothing: a prompt made of nothing but its
    /// legend's names comes out with every one of them filled.
    @Test func everyNameInALegendFills() {
        var ticket = Fixtures.ticket("PRO-1")
        ticket.description = "D"
        var pr = Fixtures.pr(number: 1, head: "h", merge: .dirty)
        pr.unresolvedThreads = 2
        let repos = [OtherRepo(name: "a", root: "/r/a", ref: "origin/main", fetched: true)]
        for id in PromptID.allCases where !id.placeholders.isEmpty {
            var config = DeskConfig()
            config.prompts[id.rawValue] = id.placeholders.map { "{\($0.name)}" }.joined(separator: " ")
            let text = switch id {
            case .ticketPlan, .ticketDescription, .ticketNote: DeskService.ticketPrompt(for: ticket, note: "N", config: config)
            case .review, .reviewOtherRepos: ReviewCommand.prompt(pr, otherRepos: repos, config: config)
            default: DeskService.sessionPrompt(for: pr, worktree: "/w", config: config)
            }
            for placeholder in id.placeholders {
                #expect(!text.contains("{\(placeholder.name)}"), "\(id) leaves {\(placeholder.name)} unfilled")
            }
        }
    }

    @Test func editsRoundTripThroughConfigJSON() throws {
        var config = DeskConfig()
        config.prompts[PromptID.review.rawValue] = "Review {url}."
        let decoded = try JSON.decoder().decode(DeskConfig.self, from: JSON.encoder().encode(config))
        #expect(decoded.prompts == config.prompts)
        #expect(try JSON.decoder().decode(DeskConfig.self, from: Data("{}".utf8)).prompts.isEmpty)
    }
}
