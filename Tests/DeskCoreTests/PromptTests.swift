import DeskCore
import Foundation
import Testing

/// Prompts edited in Settings. The defaults are pinned by the session and ticket prompt tests; these cover the
/// template syntax and what an edit does.
@Suite struct PromptTests {
    /// One pass: a value is never searched for placeholders, and braces that name nothing stay as typed — the flow
    /// prompts' result format is JSON.
    @Test func fillIsOnePassAndLeavesOtherBracesAlone() {
        let filled = PromptTemplate.fill(#"{a} {b} {"x": 1} {unknown} {"#, ["a": "{b}", "b": "B"])
        #expect(filled == #"{b} B {"x": 1} {unknown} {"#)
    }

    @Test func aSectionIsKeptOnlyWhenItsConditionHolds() {
        let template = "A\n\n{#x}X1\n\nX2{/x}\n\nC"
        #expect(PromptTemplate.fill(template, [:], when: ["x": true]) == "A\n\nX1\n\nX2\n\nC")
        #expect(PromptTemplate.fill(template, [:], when: ["x": false]) == "A\n\nC")
    }

    @Test func elseGivesTheOtherCase() {
        let template = "Branch {#wt}in {path}{else}here{/wt}."
        #expect(PromptTemplate.fill(template, ["path": "/w"], when: ["wt": true]) == "Branch in /w.")
        #expect(PromptTemplate.fill(template, ["path": "/w"], when: ["wt": false]) == "Branch here.")
    }

    /// A marker that is broken or names nothing is sent as typed, so the text inside it is never lost.
    @Test func aBrokenOrUnknownSectionStaysAsTyped() {
        #expect(PromptTemplate.fill("{#x}open", [:], when: ["x": false]) == "{#x}open")
        #expect(PromptTemplate.fill("{#y}text{/y}", [:], when: ["x": false]) == "{#y}text{/y}")
    }

    /// Markers inside a value are the value's text, not the template's.
    @Test func aValueWithMarkersIsSentAsWritten() {
        let filled = PromptTemplate.fill("{#d}{d}{/d}", ["d": "{/d} {#d} {else}"], when: ["d": true])
        #expect(filled == "{/d} {#d} {else}")
    }

    @Test func anEditedPromptIsWhatTheSessionGets() {
        var config = DeskConfig()
        config.prompts[PromptID.session.rawValue] = "{url}\n\n{#conflict}Rebase onto {baseRef} and stop.{/conflict}"
        let dirty = Fixtures.pr(number: 4, head: "feat/x", base: "master", merge: .dirty)
        #expect(DeskService.sessionPrompt(for: dirty, config: config) == "\(dirty.url)\n\nRebase onto master and stop.")
        let clean = Fixtures.pr(number: 5, head: "feat/x", merge: .clean)
        #expect(DeskService.sessionPrompt(for: clean, config: config) == clean.url)
    }

    /// An edit cleared to nothing would start a session with nothing to do.
    @Test func aBlankEditIsTheDefault() {
        var config = DeskConfig()
        config.prompts[PromptID.ticketPlan.rawValue] = "  \n "
        let ticket = Fixtures.ticket("PRO-1")
        #expect(DeskService.ticketPrompt(for: ticket, config: config) == DeskService.ticketPrompt(for: ticket))
    }

    /// The Settings legend never advertises a name that does nothing: a prompt made of nothing but its
    /// legend's names comes out with every placeholder filled and every section marker gone.
    @Test func everyNameInALegendWorks() {
        var ticket = Fixtures.ticket("PRO-1")
        ticket.description = "D"
        var pr = Fixtures.pr(number: 1, head: "h", merge: .dirty)
        pr.unresolvedThreads = 2
        for id in PromptID.allCases {
            var config = DeskConfig()
            config.prompts[id.rawValue] = (id.placeholders.map { "{\($0.name)}" } + id.conditions.map { "{#\($0.name)}C{/\($0.name)}" })
                .joined(separator: " ")
            let text = switch id {
            case .ticketPlan: DeskService.ticketPrompt(for: ticket, note: "N", config: config)
            case .selfReview, .fixConflict, .fixChecks: DeskService.flowPrompt(id, pr: pr, worktree: "/w", resultFile: "/f", config: config)
            case .session: DeskService.sessionPrompt(for: pr, worktree: "/w", config: config)
            }
            #expect(!text.contains("{"), "\(id) left a marker: \(text)")
        }
    }

    /// The conflict fix rebases a draft nobody reviews yet, and merges the base into a PR reviewers are on, so their
    /// comments stay on their lines.
    @Test func theConflictFixRebasesOnlyADraft() {
        let draft = Fixtures.pr(number: 4, head: "h", draft: true)
        let ready = Fixtures.pr(number: 5, head: "h")
        #expect(DeskService.flowPrompt(.fixConflict, pr: draft, worktree: nil, resultFile: "/f").contains("--force-with-lease"))
        #expect(!DeskService.flowPrompt(.fixConflict, pr: ready, worktree: nil, resultFile: "/f").contains("--force-with-lease"))
        #expect(DeskService.flowPrompt(.fixConflict, pr: ready, worktree: nil, resultFile: "/f").contains("merge origin/"))
    }

    /// Every condition the legend lists is one the default text uses.
    @Test func everyDefaultUsesItsConditions() {
        for id in PromptID.allCases {
            for condition in id.conditions {
                #expect(id.defaultText.contains("{#\(condition.name)}"), "\(id) never uses {#\(condition.name)}")
            }
        }
    }

    @Test func editsRoundTripThroughConfigJSON() throws {
        var config = DeskConfig()
        config.prompts[PromptID.session.rawValue] = "Work on {url}."
        let decoded = try JSON.decoder().decode(DeskConfig.self, from: JSON.encoder().encode(config))
        #expect(decoded.prompts == config.prompts)
        #expect(try JSON.decoder().decode(DeskConfig.self, from: Data("{}".utf8)).prompts.isEmpty)
    }
}
