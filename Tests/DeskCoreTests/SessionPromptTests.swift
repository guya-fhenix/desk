import DeskCore
import Foundation
import Testing

/// The prompt is the whole of what a background session is told, and nothing later corrects it, so the
/// paragraphs that only belong on some PRs have to be absent from the rest.
@Suite struct SessionPromptTests {
    @Test func aCleanPullRequestIsToldOnlyWhereItIs() {
        let prompt = DeskService.sessionPrompt(for: Fixtures.pr(number: 1, head: "feat/x", merge: .clean))
        #expect(prompt.contains("FhenixProtocol/cofhe#1"))
        #expect(prompt.contains("https://github.com/FhenixProtocol/cofhe/pull/1"))
        #expect(prompt.contains("Its branch feat/x is checked out here"))
        #expect(!prompt.contains("unresolved"))
        #expect(!prompt.contains("conflicts with"))
    }

    @Test func unresolvedThreadsAskForAProposedFix() {
        var pr = Fixtures.pr(number: 2, head: "feat/x", merge: .clean)
        pr.unresolvedThreads = 3
        let prompt = DeskService.sessionPrompt(for: pr)
        #expect(prompt.contains("3 review threads are still unresolved"))
        #expect(prompt.contains("nobody has replied to"))
        #expect(prompt.contains("show the change rather than making it"))
    }

    @Test func oneThreadReadsAsOne() {
        var pr = Fixtures.pr(number: 3, head: "feat/x", merge: .clean)
        pr.unresolvedThreads = 1
        #expect(DeskService.sessionPrompt(for: pr).contains("1 review thread is still unresolved"))
    }

    @Test func conflictsNameTheBaseAndAskToLeaveTheBranchAlone() {
        let pr = Fixtures.pr(number: 4, head: "feat/x", base: "master", merge: .dirty)
        let prompt = DeskService.sessionPrompt(for: pr)
        #expect(prompt.contains("It conflicts with master"))
        #expect(prompt.contains("leave the branch as it is"))
    }

    /// Behind is not dirty: a PR that only needs a rebase has nothing to resolve, and saying otherwise
    /// would send the session hunting for conflicts that are not there.
    @Test func beingBehindIsNotAConflict() {
        let pr = Fixtures.pr(number: 5, head: "feat/x", merge: .behind)
        #expect(!DeskService.sessionPrompt(for: pr).contains("conflicts with"))
    }

    @Test func bothProblemsBothParagraphs() {
        var pr = Fixtures.pr(number: 6, head: "feat/x", base: "master", merge: .dirty)
        pr.unresolvedThreads = 2
        let prompt = DeskService.sessionPrompt(for: pr)
        #expect(prompt.contains("2 review threads are still unresolved"))
        #expect(prompt.contains("It conflicts with master"))
        // Paragraphs, not a wall: the session reads this as four separate asks.
        #expect(prompt.components(separatedBy: "\n\n").count == 4)
    }
}

/// What a planning session is told. It carries the description because the session has no Jira
/// credentials of its own, and asks for a plan rather than a change.
@Suite struct TicketPromptTests {
    @Test func namesTheTicketAndAsksForAPlan() {
        var ticket = Fixtures.ticket("PRO-577")
        ticket.description = "The three listeners hold events from 44+ days ago."
        let prompt = DeskService.ticketPrompt(for: ticket)
        #expect(prompt.contains("Plan PRO-577 — Summary PRO-577"))
        #expect(prompt.contains("https://j/browse/PRO-577"))
        #expect(prompt.contains("The ticket says:"))
        #expect(prompt.contains("44+ days ago"))
        #expect(prompt.contains("do not change anything yet"))
    }

    /// A ticket with no description says so by omission rather than with an empty heading.
    @Test func anEmptyDescriptionIsLeftOut() {
        let prompt = DeskService.ticketPrompt(for: Fixtures.ticket("PRO-578"))
        #expect(!prompt.contains("The ticket says:"))
        #expect(prompt.components(separatedBy: "\n\n").count == 2)
    }

    /// What you typed on the way in, sitting between the ticket and the instruction.
    @Test func theNoteIsCarriedAndComesLast() {
        var ticket = Fixtures.ticket("PRO-579")
        ticket.description = "Some background."
        let prompt = DeskService.ticketPrompt(for: ticket, note: "Keep it to the migration; ignore the UI.")
        #expect(prompt.contains("What I want from the plan:"))
        #expect(prompt.contains("Keep it to the migration; ignore the UI."))
        let note = try! #require(prompt.range(of: "Keep it to the migration"))
        let ticketSays = try! #require(prompt.range(of: "Some background."))
        let instruction = try! #require(prompt.range(of: "Write the plan and wait"))
        #expect(ticketSays.lowerBound < note.lowerBound)
        #expect(note.lowerBound < instruction.lowerBound)
    }

    /// Pressing Plan without typing must read exactly as it did before there was a box to type in.
    @Test func aBlankNoteChangesNothing() {
        let ticket = Fixtures.ticket("PRO-580")
        #expect(DeskService.ticketPrompt(for: ticket, note: "   \n  ") == DeskService.ticketPrompt(for: ticket))
        #expect(!DeskService.ticketPrompt(for: ticket, note: "").contains("What I want"))
    }
}
