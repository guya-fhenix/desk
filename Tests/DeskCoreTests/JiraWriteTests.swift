import DeskCore
import Foundation
import Testing

/// acli exits 0 on a refused transition and says so only in its output, so reading that output correctly
/// is the whole safety of the one button that writes to Jira.
@Suite struct JiraWriteTests {
    @Test func readsTheRefusalMessage() {
        let text = """
        {
          "results": [
            { "status": "FAILURE", "message": "No allowed transitions found for given status", "id": "PRO-413" }
          ],
          "totalCount": 1,
          "successCount": 0
        }
        """
        #expect(JiraDecoding.transitionFailure(in: text) == "No allowed transitions found for given status")
    }

    @Test func acceptsASuccessCount() {
        let text = #"{"results": [{"status": "SUCCESS", "id": "PRO-413"}], "totalCount": 1, "successCount": 1}"#
        #expect(JiraDecoding.transitionFailure(in: text) == nil)
    }

    /// A build that stops reporting the count still reports the entry.
    @Test func acceptsASuccessfulEntryWithoutACount() {
        #expect(JiraDecoding.transitionFailure(in: #"{"results": [{"status": "SUCCESS", "id": "PRO-413"}]}"#) == nil)
    }

    /// Without `--json`, or from a build that changes its mind about the shape, the printed line is still
    /// the best message there is — and it is never read as success.
    @Test func fallsBackToThePrintedLine() {
        let text = "✗ Failure: PRO-999 can't be transitioned: Issue does not exist"
        #expect(JiraDecoding.transitionFailure(in: text) == text)
    }

    @Test func sayingNothingIsNotConfirmation() {
        #expect(JiraDecoding.transitionFailure(in: "   \n") == "acli did not confirm the transition")
        #expect(JiraDecoding.transitionFailure(in: #"{"totalCount": 1, "successCount": 0}"#) == "acli did not confirm the transition")
    }

    /// An edit is read the same way: acli says FAILURE in a body it exits 0 with.
    @Test func aRefusedEditIsAFailure() {
        let text = #"{"results":[{"status":"FAILURE","message":"Issue does not exist or you do not have permission to see it.","id":"PRO-1"}],"totalCount":1,"successCount":0}"#
        #expect(JiraDecoding.writeFailure(in: text, unconfirmed: "x") == "Issue does not exist or you do not have permission to see it.")
        #expect(JiraDecoding.writeFailure(in: #"{"results":[{"status":"SUCCESS","id":"PRO-1"}],"successCount":1}"#, unconfirmed: "x") == nil)
    }

    /// A workflow with no way from To Do straight to Review Ready refuses the move; it then goes through In Progress,
    /// and only for that refusal: one acli could not confirm may have landed, so it is not tried again.
    @Test func aMoveWithNoWayThereGoesThroughInProgress() async throws {
        let noWay = ShellResult.ok(#"{"results":[{"status":"FAILURE","message":"No allowed transitions found for given status","id":"PRO-1"}]}"#)
        let moved = ShellResult.ok(#"{"results":[{"status":"SUCCESS","id":"PRO-1"}]}"#)
        /// acli's answers in the order they are asked for, each move after them answered as made.
        actor Script {
            var answers: [ShellResult]
            let otherwise: ShellResult
            var statuses: [String] = []
            init(_ answers: [ShellResult], otherwise: ShellResult) { (self.answers, self.otherwise) = (answers, otherwise) }
            func answer(_ status: String) -> ShellResult {
                statuses.append(status)
                return answers.isEmpty ? otherwise : answers.removeFirst()
            }
        }
        func moves(_ answers: [ShellResult], via: String?) async -> (statuses: [String], error: String?) {
            let script = Script(answers, otherwise: moved)
            let jira = JiraProvider(acliPath: "/acli") { _, arguments, _, _, _, _ in
                await script.answer(arguments[arguments.firstIndex(of: "--status")! + 1])
            }
            do { try await jira.transition(key: "PRO-1", to: "👀 Review Ready", via: via) } catch {
                return (await script.statuses, "\(error)")
            }
            return (await script.statuses, nil)
        }

        let through = await moves([noWay], via: "In Progress")
        #expect(through.statuses == ["👀 Review Ready", "In Progress", "👀 Review Ready"])
        #expect(through.error == nil)

        let direct = await moves([], via: "In Progress")
        #expect(direct.statuses == ["👀 Review Ready"], "a workflow that allows the move makes one transition")

        let unconfirmed = await moves([.ok("   ")], via: "In Progress")
        #expect(unconfirmed.statuses == ["👀 Review Ready"], "an unconfirmed move may have landed: not tried again")

        let noVia = await moves([noWay], via: nil)
        #expect(noVia.statuses == ["👀 Review Ready"])
        #expect(noVia.error?.contains("No allowed transitions") == true)

        // In Progress done but Review Ready still refused: the ticket moved, and the error says where it stands.
        let halfway = await moves([noWay, moved, noWay], via: "In Progress")
        #expect(halfway.statuses == ["👀 Review Ready", "In Progress", "👀 Review Ready"])
        #expect(halfway.error?.contains("moved to “In Progress”") == true)
    }

    /// What acli's failures come to, for a move, an edit and a read alike. nil answers as if acli were not installed.
    @Test func acliFailuresSayWhatWentWrong() async {
        func jira(_ answer: ShellResult?) -> JiraProvider {
            JiraProvider(acliPath: "/acli") { executable, _, _, _, _, _ in
                guard let answer else { throw ShellError.executableNotFound(executable) }
                return answer
            }
        }
        func move(_ answer: ShellResult?) async -> String {
            do { try await jira(answer).transition(key: "PRO-1", to: "Done") } catch { return "\(error)" }
            return "moved"
        }
        func edit(_ answer: ShellResult?) async -> String {
            do { try await jira(answer).edit(key: "PRO-1", summary: "s") } catch { return "\(error)" }
            return "saved"
        }
        func read(_ answer: ShellResult?) async -> String {
            do { _ = try await jira(answer).projectKeys() } catch { return "\(error)" }
            return "read"
        }
        let signedOut = ShellResult.failed("Error: unauthorized: run acli jira auth login")
        let refused = ShellResult.failed("  No transition to Done  \n")
        for result in [await move(signedOut), await edit(signedOut), await read(signedOut)] {
            #expect(result == JiraError.notAuthenticated.description)
        }
        for result in [await move(nil), await edit(nil), await read(nil)] {
            #expect(result == JiraError.acliNotFound.description)
        }
        #expect(await move(refused) == JiraError.transitionRefused(key: "PRO-1", status: "Done", detail: "No transition to Done").description)
        #expect(await edit(refused) == JiraError.editRefused(key: "PRO-1", detail: "No transition to Done").description)
        // A read has nothing to refuse: acli's own failure goes on as it came.
        #expect(await read(refused).hasPrefix("/acli jira project list"))
        #expect(await move(.ok(#"{"results":[{"status":"FAILURE","message":"nope"}]}"#)).hasSuffix("— nope"))
        #expect(await move(.ok(#"{"results":[{"status":"SUCCESS"}],"successCount":1}"#)) == "moved")
    }
}
