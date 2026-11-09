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
