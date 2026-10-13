import DeskCore
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
}
