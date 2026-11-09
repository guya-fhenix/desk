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
             "createdAt": "2026-08-31T09:00:00.000Z",
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
        #expect(jobs[1].linked == ["fhenixprotocol/cofhe#986"])
        #expect(jobs[1].createdAt == ISO8601DateFormatter().date(from: "2026-08-31T09:00:00Z"))
        #expect(jobs[0].createdAt == nil)
        #expect(jobs[0].linked.isEmpty && jobs[0].startedOn == ["fhenixprotocol/cofhe#987"])

        var state = DeskState(config: DeskConfig())
        state.claudeJobs = jobs
        #expect(state.claudeJobs(for: Fixtures.pr(number: 986, head: "a")).map(\.id) == ["aaaaaaaa"])
        #expect(state.claudeJobs(for: Fixtures.pr(number: 5, head: "b")).isEmpty)
    }

    /// A ticket's session is kept before it has touched any PR, by the key in the prompt it started from, so its ticket
    /// can show it.
    @Test func scanKeepsTicketSessionsByTheKeyInTheirPrompt() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try job(home, id: "dddddddd", body: #"{"state": "working", "intent": "Plan PRO-9 — a thing", "cwd": "/r/cofhe"}"#)
        try job(home, id: "eeeeeeee", body: #"{"state": "done", "intent": "unrelated", "cwd": "/r/cofhe"}"#)
        #expect(ClaudeJobs.scan(home: home.path).isEmpty)
        let jobs = ClaudeJobs.scan(home: home.path, tickets: TicketKeyMatcher(projectKeys: ["PRO"]))
        #expect(jobs.map(\.id) == ["dddddddd"])
        #expect(jobs.first?.ticketKey == "PRO-9")
    }

    /// A session started on the PR or its ticket carries it; failing one, the earliest of those that link to it, which is the
    /// one that opened it. A later session that only mentioned it never does.
    @Test func theCarrierIsTheSessionThatBeganThePullRequest() {
        let key = "fhenixprotocol/cofhe#1160"
        func session(_ id: String, created: Double, linked: Set<String> = [], startedOn: Set<String> = [], ticket: String? = nil) -> ClaudeJob {
            ClaudeJob(
                id: id, name: id, state: "done", cwd: "/r", prKeys: linked.union(startedOn), updatedAt: Fixtures.hours(10 - created),
                createdAt: Fixtures.hours(created), ticketKey: ticket, startedOn: startedOn, linked: linked
            )
        }
        // Newest first, as the scan sorts them: the one that only mentioned the PR was active last.
        let mentioned = session("later", created: 5, linked: [key])
        let opener = session("opener", created: 1, linked: [key])
        #expect(ClaudeJobs.carrier(of: key, tickets: [], in: [mentioned, opener])?.id == "opener")
        let onTicket = session("ticket", created: 3, ticket: "PRO-7")
        #expect(ClaudeJobs.carrier(of: key, tickets: ["PRO-7"], in: [mentioned, onTicket, opener])?.id == "ticket")
        let onPR = session("pr", created: 4, startedOn: [key])
        #expect(ClaudeJobs.carrier(of: key, tickets: [], in: [mentioned, onPR, opener])?.id == "pr")
        #expect(ClaudeJobs.carrier(of: key, tickets: [], in: [session("other", created: 0, linked: ["o/r#1"])]) == nil)
    }

    @Test func scanSurvivesAMissingOrUnreadableJobsDirectory() {
        #expect(ClaudeJobs.scan(home: "/nope/not/here").isEmpty)
    }

    @Test func reviewSkillFollowsClaudeCodesSettingsOrderAndTheInstalledVersion() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let (home, repo) = (base.appendingPathComponent("home").path, base.appendingPathComponent("repo").path)
        func write(_ path: String, _ text: String) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        func skill() -> ReviewSkill.State { ClaudePlugins.reviewSkill(repoRoot: repo, home: home).state }

        #expect(skill() == .notEnabled)
        try write("\(repo)/.claude/settings.json", #"{"enabledPlugins": {"fhenix-workflow@fhenix": true}}"#)
        #expect(skill() == .notInstalled)

        let old = "\(home)/plugins/cache/fhenix/fhenix-workflow/0.4.2"
        let new = "\(home)/plugins/cache/fhenix/fhenix-workflow/0.5.0"
        try write("\(new)/skills/reviewing-code/SKILL.md", "---\nname: reviewing-code\n---\n")
        // Another repo's install of the new version does not count for this one.
        try write("\(home)/plugins/installed_plugins.json", """
            {"version": 2, "plugins": {"fhenix-workflow@fhenix": [
              {"scope": "project", "projectPath": "\(repo)", "installPath": "\(old)", "version": "0.4.2"},
              {"scope": "project", "projectPath": "/elsewhere", "installPath": "\(new)", "version": "0.5.0"}]}}
            """)
        #expect(ClaudePlugins.reviewSkill(repoRoot: repo, home: home)
            == ReviewSkill(state: .noSkill, version: "0.4.2", missing: ["reviewing-code", "review-pr"]))

        try write("\(home)/plugins/installed_plugins.json", """
            {"version": 2, "plugins": {"fhenix-workflow@fhenix": [
              {"scope": "project", "projectPath": "\(repo)/", "installPath": "\(new)", "version": "0.5.0"}]}}
            """)
        // The self-review's skill without review-pr: Approve works, Start review does not, and the note says what is missing.
        let partial = ClaudePlugins.reviewSkill(repoRoot: repo, home: home)
        #expect(partial == ReviewSkill(state: .noSkill, version: "0.5.0", missing: ["review-pr"]))
        #expect(partial.has("reviewing-code") && !partial.has("review-pr"))
        #expect(partial.text == "fhenix-workflow 0.5.0 has no review-pr — update the plugin")

        try write("\(new)/skills/review-pr/SKILL.md", "---\nname: review-pr\n---\n")
        let ready = ClaudePlugins.reviewSkill(repoRoot: repo, home: home)
        #expect(ready == ReviewSkill(state: .ready, version: "0.5.0"))
        #expect(ready.text == "fhenix-workflow 0.5.0 · reviewing-code, review-pr")
        // A repo on the review flow self-reviews with /pre-pr, which this version lacks.
        #expect(ClaudePlugins.reviewSkill(repoRoot: repo, adopted: true, home: home).missing == ["pre-pr"])

        // Local settings outrank the shared ones, the way they do in Claude Code.
        try write("\(repo)/.claude/settings.local.json", #"{"enabledPlugins": {"fhenix-workflow@fhenix": false}}"#)
        #expect(skill() == .notEnabled)
    }

    /// A send stops the session, waits until it is listed no longer and its process is gone, then resumes it under its own
    /// id. A resume that starts a copy instead stops and deletes the copy, and fails.
    @Test func sendStopsWaitsThenResumes() async throws {
        let job = ClaudeJob(id: "1a2b3c4d", name: "s", state: "done", cwd: "/r", prKeys: [], updatedAt: Fixtures.t0, sessionId: "sid")
        func claude(_ calls: Calls, resumedAs id: String) -> ClaudeCLI {
            ClaudeCLI(path: "/claude") { _, arguments, _, _, _, _ in
                let call = arguments.joined(separator: " ")
                let count = await calls.add(call)
                switch arguments.first {
                // Listed with a process no system has before the stop, still listed once after it, then gone.
                case "agents": return .ok(count < 3 ? #"[{"id":"1a2b3c4d","pid":999999}]"# : "[]")
                case "--bg": return .ok("backgrounded · \(id)\n")
                default: return .ok("")
                }
            }
        }
        let calls = Calls()
        try await claude(calls, resumedAs: "1a2b3c4d").send("go on", to: job, cwd: "/r")
        #expect(await calls.list == ["agents --json", "stop 1a2b3c4d", "agents --json", "agents --json", "--bg --resume sid go on"])

        let copied = Calls()
        await #expect(throws: DeskError.self) { try await claude(copied, resumedAs: "deadbeef").send("go on", to: job, cwd: "/r") }
        #expect(await copied.list.suffix(3) == ["--bg --resume sid go on", "stop deadbeef", "rm deadbeef"])
    }

    @Test func startedIDIsReadOutOfTheColouredLine() {
        let output = "backgrounded · \u{1B}[36mc020ac7f\u{1B}[39m\n  claude attach c020ac7f    open in this terminal\n"
        #expect(ClaudeJobs.startedID(in: output) == "c020ac7f")
        #expect(ClaudeJobs.startedID(in: "nothing here") == nil)
        let copy = "note: session fd883a8f is already running in the background, so this started a copy as 664b5899.\nbackgrounded · 664b5899\n"
        #expect(ClaudeJobs.startedID(in: copy) == "664b5899")
    }
}
