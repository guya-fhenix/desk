import DeskCore
import Foundation
import Testing

@Suite struct ClaudeJobsTests {
    /// Writes one `~/.claude/jobs/<id>/state.json` the way Claude Code does.
    private func job(_ home: URL, id: String, body: String) throws {
        let directory = home.appendingPathComponent("jobs/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try body.write(to: directory.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    }

    @Test func scanLinksSessionsToPullRequestsByLinkAndByPrompt() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        // Claude Code's own link scan: the session worked with the PR.
        try job(home, id: "aaaaaaaa", body: """
            {"state": "done", "name": "review pro-1", "cwd": "/r/cofhe", "updatedAt": "2026-09-01T10:00:00.000Z",
             "children": [{"id": "986", "href": "https://github.com/FhenixProtocol/cofhe/pull/986", "kind": "pr"}]}
            """)
        // Started from the app: only the prompt names the PR yet.
        try job(home, id: "bbbbbbbb", body: """
            {"state": "working", "cwd": "/r/cofhe", "updatedAt": "2026-09-02T10:00:00.000Z",
             "intent": "Working on FhenixProtocol/cofhe#987\\nhttps://github.com/FhenixProtocol/cofhe/pull/987", "children": null}
            """)
        // A session about no PR at all, and a link that is not one.
        try job(home, id: "cccccccc", body: """
            {"state": "done", "name": "housekeeping", "cwd": "/r/cofhe",
             "children": [{"id": "5", "href": "https://github.com/FhenixProtocol/cofhe/issues/5", "kind": "issue"}]}
            """)

        let jobs = ClaudeJobs.scan(home: home.path)
        #expect(jobs.map(\.id) == ["bbbbbbbb", "aaaaaaaa"])
        #expect(jobs[0].prKeys == ["fhenixprotocol/cofhe#987"])
        #expect(jobs[0].isRunning)
        // No name of its own: the prompt's first line stands in for one.
        #expect(jobs[0].name == "Working on FhenixProtocol/cofhe#987")
        #expect(jobs[1].prKeys == ["fhenixprotocol/cofhe#986"])
        #expect(!jobs[1].isRunning)

        var state = DeskState(config: DeskConfig())
        state.claudeJobs = jobs
        #expect(state.claudeJobs(for: Fixtures.pr(number: 986, head: "a")).map(\.id) == ["aaaaaaaa"])
        #expect(state.claudeJobs(for: Fixtures.pr(number: 5, head: "b")).isEmpty)
    }

    @Test func scanSurvivesAMissingOrUnreadableJobsDirectory() {
        #expect(ClaudeJobs.scan(home: "/nope/not/here").isEmpty)
    }

    @Test func startedIDIsReadOutOfTheColouredLine() {
        let output = "backgrounded · \u{1B}[36mc020ac7f\u{1B}[39m\n  claude attach c020ac7f    open in this terminal\n"
        #expect(ClaudeJobs.startedID(in: output) == "c020ac7f")
        #expect(ClaudeJobs.startedID(in: "nothing here") == nil)
    }
}
