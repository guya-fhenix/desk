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

    /// The master is kept by its name, workers and reviews by the skill their prompt names, and any session in a tracked clone by
    /// where it runs: a session started there with no ticket is still a task. Each brings its live status line, and a
    /// worker started on what the person asked brings the ask.
    @Test func scanKeepsDeskRolesAndSessionsInTrackedClones() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try job(home, id: "aaaaaaaa", body: """
            {"state": "working", "name": "master", "cwd": "/support/master", "intent": "Use the coordinate-tasks skill.",
             "updatedAt": "2026-11-16T09:00:00Z"}
            """)
        try job(home, id: "bbbbbbbb", body: """
            {"state": "working", "name": "testnet-decrypt-errors", "cwd": "/support/master", "updatedAt": "2026-11-16T08:00:00Z",
             "intent": "Use the fhenix-workflow:work-on-task skill: find why decrypt requests fail on testnet. Report to master.",
             "detail": "searching Cloud Logging since 06:00 "}
            """)
        try job(home, id: "cccccccc", body: """
            {"state": "done", "name": "a question", "cwd": "/r/powershot/sub", "intent": "how does X work", "updatedAt": "2026-11-16T07:00:00Z"}
            """)
        try job(home, id: "dddddddd", body: #"{"state": "done", "name": "openclaw", "cwd": "/r/openclaw", "intent": "server"}"#)
        try job(home, id: "eeeeeeee", body: #"{"state": "done", "name": "plan", "cwd": "/r", "intent": "a flow across repos"}"#)

        #expect(ClaudeJobs.scan(home: home.path, keepIn: ["/r/powershot"], roots: ["/r"]).map(\.id).contains("eeeeeeee"))
        let jobs = ClaudeJobs.scan(home: home.path, keepIn: ["/r/powershot"])
        #expect(jobs.map(\.id) == ["aaaaaaaa", "bbbbbbbb", "cccccccc"])
        #expect(jobs.map(\.role) == [.master, .worker, .other])
        #expect(jobs[1].detail == "searching Cloud Logging since 06:00")
        #expect(jobs[1].request == "find why decrypt requests fail on testnet")
        #expect(jobs[0].request == nil)
        #expect(ClaudeJobs.scan(home: home.path).map(\.id) == ["aaaaaaaa", "bbbbbbbb"])
    }

    @Test func theRequestIsWhatFollowsTheSkill() {
        #expect(ClaudeJobs.request(in: "Use the work-on-task skill: look at the logs") == "look at the logs")
        #expect(ClaudeJobs.request(in: "Use the fhenix-workflow:work-on-task skill for PRO-650. Report to master.") == "for PRO-650")
        #expect(ClaudeJobs.request(in: "Use the work-on-task skill. Report to master.") == nil)
        #expect(ClaudeJobs.request(in: "Plan PRO-9") == nil)
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

    /// powershot#115's session ended a long report with "Should I watch the PR for longer?" and Claude Code marked it
    /// blocked; attached, the line read as the report's end, not a question. Desk now says the question itself, from
    /// Claude Code's own summary of it, and says "asks you" for "blocked", which read as stuck.
    @Test func anAskingSessionSaysWhatItAsks() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let pr = #""children": [{"id": "115", "href": "https://github.com/FhenixProtocol/powershot/pull/115", "kind": "pr"}]"#
        try job(home, id: "f33ce657", body: #"{"state": "blocked", "needs": " Should I watch the PR for longer?\n", "updatedAt": "2026-11-09T16:39:49.877Z", \#(pr)}"#)
        // Left behind once the session moved on: not a question any more.
        try job(home, id: "aaaaaaaa", body: #"{"state": "done", "needs": "Merge it?", "updatedAt": "2026-11-09T10:00:00.000Z", \#(pr)}"#)
        let jobs = ClaudeJobs.scan(home: home.path)
        #expect(jobs.map(\.id) == ["f33ce657", "aaaaaaaa"])
        #expect(jobs[0].question == "Should I watch the PR for longer?")
        #expect(jobs[0].status == "asks you")
        #expect(jobs[1].question == nil && jobs[1].status == "done")
    }

    @Test func scanSurvivesAMissingOrUnreadableJobsDirectory() {
        #expect(ClaudeJobs.scan(home: "/nope/not/here").isEmpty)
    }

    /// The plugin as installed for the user: turned on in the user's settings, the user-wide install's version and skills.
    /// A repo's own install doesn't count.
    @Test func reviewSkillIsTheUsersInstall() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home").path
        func write(_ path: String, _ text: String) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        func skill() -> ReviewSkill.State { ClaudePlugins.reviewSkill(home: home).state }

        #expect(skill() == .notEnabled)
        try write("\(home)/settings.json", #"{"enabledPlugins": {"fhenix-workflow@fhenix": true}}"#)
        #expect(skill() == .notInstalled)

        let old = "\(home)/plugins/cache/fhenix/fhenix-workflow/0.7.0"
        let mid = "\(home)/plugins/cache/fhenix/fhenix-workflow/0.8.2"
        let new = "\(home)/plugins/cache/fhenix/fhenix-workflow/1.0.0"
        try write("\(mid)/skills/review-pr/SKILL.md", "---\nname: review-pr\n---\n")
        try write("\(new)/skills/review-teammate-task/SKILL.md", "---\nname: review-teammate-task\n---\n")
        func installed(_ path: String, _ version: String, scope: String = "user") throws {
            let project = scope == "user" ? "" : #", "projectPath": "/repo""#
            try write("\(home)/plugins/installed_plugins.json", """
                {"version": 2, "plugins": {"fhenix-workflow@fhenix": [
                  {"scope": "\(scope)"\(project), "installPath": "\(path)", "version": "\(version)"}]}}
                """)
        }
        // No review skill at all: Start review stays off, and the note says what to get.
        try installed(old, "0.7.0")
        let stale = ClaudePlugins.reviewSkill(home: home)
        #expect(stale == ReviewSkill(state: .noSkill, version: "0.7.0", missing: ["review-teammate-task"]))
        #expect(stale.text == "fhenix-workflow 0.7.0 has no review-teammate-task — update the plugin")
        // A repo's install is not the user's.
        try installed(new, "1.0.0", scope: "project")
        #expect(skill() == .notInstalled)
        // review-pr, the old flow's, is no review skill any more.
        try installed(mid, "0.8.2")
        #expect(ClaudePlugins.reviewSkill(home: home) == ReviewSkill(state: .noSkill, version: "0.8.2", missing: ["review-teammate-task"]))
        // review-teammate-task: one PR or any set of them.
        try installed(new, "1.0.0")
        let group = ClaudePlugins.reviewSkill(home: home)
        #expect(group == ReviewSkill(state: .ready, version: "1.0.0", groupReview: true))
        #expect(group.text == "fhenix-workflow 1.0.0 · review-teammate-task")

        // Turned off in the user's settings.
        try write("\(home)/settings.json", #"{"enabledPlugins": {"fhenix-workflow@fhenix": false}}"#)
        #expect(skill() == .notEnabled)
    }


    @Test func startedIDIsReadOutOfTheColouredLine() {
        let output = "backgrounded · \u{1B}[36mc020ac7f\u{1B}[39m\n  claude attach c020ac7f    open in this terminal\n"
        #expect(ClaudeJobs.startedID(in: output) == "c020ac7f")
        #expect(ClaudeJobs.startedID(in: "nothing here") == nil)
        let copy = "note: session fd883a8f is already running in the background, so this started a copy as 664b5899.\nbackgrounded · 664b5899\n"
        #expect(ClaudeJobs.startedID(in: copy) == "664b5899")
    }

    /// Removing a session stops it, waits until `claude agents` no longer lists it, and only then takes it off the list:
    /// a refused stop, of one already stopped, is no failure, and a refused `rm` is.
    @Test func removeStopsWaitsAndRemoves() async throws {
        let calls = Calls()
        let run: ShellRun = { _, arguments, _, _, _, _ in
            let call = arguments.joined(separator: " ")
            let nth = await calls.add(call)
            switch arguments.first {
            case "stop": return .failed("not running")
            // Still listed the first time it is asked.
            case "agents": return .ok(nth == 1 ? #"[{"id": "abc12345", "pid": 7}]"# : "[]")
            default: return .ok("removed abc12345")
            }
        }
        try await ClaudeCLI(path: "/bin/claude", run: run).remove("abc12345")
        #expect(await calls.list == ["stop abc12345", "agents --json", "agents --json", "rm abc12345"])

        let refused: ShellRun = { _, arguments, _, _, _, _ in arguments.first == "rm" ? .failed("unpushed commits") : .ok("[]") }
        await #expect(throws: (any Error).self) { try await ClaudeCLI(path: "/bin/claude", run: refused).remove("abc12345") }
    }

    /// The master is the session named `master`. A worker whose prompt mentions the master's skill is a worker, in the
    /// master folder too, and of two sessions named `master` only the one in the master folder is it.
    @Test func theMasterIsKnownByItsNameNeverByItsPrompt() throws {
        let mention = "Use the fhenix-workflow:work-on-task skill: fix how the coordinate-tasks skill starts workers. Report to master."
        #expect(SessionRole.of(name: "fix-skill", intent: mention) == .worker)
        #expect(SessionRole.of(name: "notes", intent: "what does the coordinate-tasks skill do?") == .other)
        #expect(SessionRole.of(name: "master", intent: nil) == .master)
        #expect(SessionRole.of(name: "master-detection", intent: nil) == .other)

        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        // The worker is the newest, so the first Desk would have taken while the prompt decided.
        try job(home, id: "aaaaaaaa", body: """
            {"state": "working", "name": "fix-skill", "cwd": "/support/master", "updatedAt": "2026-11-22T10:00:00Z",
             "intent": "\(mention)"}
            """)
        try job(home, id: "bbbbbbbb", body: """
            {"state": "working", "name": "master", "cwd": "/r/elsewhere", "updatedAt": "2026-11-22T09:00:00Z"}
            """)
        try job(home, id: "cccccccc", body: """
            {"state": "done", "name": "master", "cwd": "/support/master/", "updatedAt": "2026-11-22T08:00:00Z",
             "intent": "Use the fhenix-workflow:coordinate-tasks skill."}
            """)

        var state = DeskState(config: DeskConfig())
        state.claudeJobs = ClaudeJobs.scan(home: home.path, masterFolder: "/support/master")
        #expect(state.claudeJobs.map(\.role) == [.worker, .other, .master])
        #expect(state.master?.id == "cccccccc")

        // With no master in the master folder, the one named master somewhere else is it.
        state.claudeJobs = ClaudeJobs.scan(home: home.path, masterFolder: "/nowhere")
        #expect(state.master?.id == "bbbbbbbb")
        try FileManager.default.removeItem(at: home.appendingPathComponent("jobs/bbbbbbbb"))
        try FileManager.default.removeItem(at: home.appendingPathComponent("jobs/cccccccc"))
        state.claudeJobs = ClaudeJobs.scan(home: home.path, masterFolder: "/support/master")
        #expect(state.master == nil)
    }

    /// Stop master stops and removes the master Desk started, named `master` in the master folder, and nothing else:
    /// handed any other session, it throws before any `claude` command runs, since `claude rm` deletes a worker's
    /// worktree and branch.
    @Test func stopMasterOnlyEverRemovesTheMaster() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A stand-in `claude` that records what it was run with.
        let log = folder.appendingPathComponent("calls")
        let claude = folder.appendingPathComponent("claude")
        try "#!/bin/sh\necho \"$@\" >> '\(log.path)'\n[ \"$1\" = agents ] && echo '[]'\nexit 0\n"
            .write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        var config = DeskConfig()
        config.claudePath = claude.path
        let service = DeskService(config: config, support: AppSupport(directory: folder))

        let prompt = "Use the fhenix-workflow:work-on-task skill: fix the coordinate-tasks skill. Report to master."
        let worker = ClaudeJob(
            id: "w0000000", name: "fix-skill", state: "working", cwd: "/r", prKeys: [], updatedAt: Date(),
            role: SessionRole.of(name: "fix-skill", intent: prompt)
        )
        // Not by a role someone else set on it either: the name decides.
        let mislabelled = ClaudeJob(
            id: "x0000000", name: "fix-skill", state: "working", cwd: folder.appendingPathComponent("master").path, prKeys: [],
            updatedAt: Date(), role: .master
        )
        // Nor a session named master that is not Desk's own: the one that lost to the master in the master folder, one
        // started by hand somewhere else, and one whose folder nothing recorded.
        let masterFolder = MasterFolder(support: AppSupport(directory: folder))
        let named = { (id: String, cwd: String, role: SessionRole) in
            ClaudeJob(id: id, name: "master", state: "working", cwd: cwd, prKeys: [], updatedAt: Date(), role: role)
        }
        let refused = [
            worker, mislabelled, named("l0000000", masterFolder.path, .other), named("e0000000", "/r/elsewhere", .master),
            named("n0000000", "", .master),
        ]
        for session in refused {
            await #expect(throws: DeskError.self) { try await service.stopMaster(session) }
        }
        #expect(!FileManager.default.fileExists(atPath: log.path))
        // No path is no folder, not the one the process runs in.
        #expect(!masterFolder.holds(named("n0000000", "", .master)))
        #expect(!MasterFolder(url: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).holds(named("n0000000", "", .master)))

        // Desk's own master, also when its folder is reached through a symlink.
        try FileManager.default.createDirectory(at: masterFolder.url, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: masterFolder.url)
        let master = named("m0000000", link.path, .master)
        try await service.stopMaster(master)
        #expect(try String(contentsOf: log, encoding: .utf8) == "stop m0000000\nagents --json\nrm m0000000\n")
    }
}
