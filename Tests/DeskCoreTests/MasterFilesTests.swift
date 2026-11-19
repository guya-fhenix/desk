import DeskCore
import Foundation
import Testing

@Suite struct MasterFilesTests {
    private func folder() -> MasterFolder {
        MasterFolder(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
    }

    private func text(_ folder: MasterFolder, _ name: String) throws -> String {
        try String(contentsOf: folder.url.appendingPathComponent(name), encoding: .utf8)
    }

    /// One compact JSON object per line, appended, so the master's `tail -F` wakes once per event; the oldest are trimmed.
    @Test func eventsAreOneLineEachAndTrimmed() throws {
        let master = folder()
        defer { try? FileManager.default.removeItem(at: master.url) }
        let event = { (n: Int) in MasterEvent(kind: "ciFailed", pr: "fhenixprotocol/cofhe#\(n)", task: "PRO-1", title: "CI failed", at: Fixtures.t0) }
        try master.append([event(1), event(2)])
        try master.append([event(3)])
        let lines = try text(master, "events.jsonl").split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains(#""pr":"fhenixprotocol/cofhe#1""#))
        #expect(try JSON.decoder().decode(MasterEvent.self, from: Data(lines[2].utf8)) == event(3))
        try master.trimEvents(keeping: 2)
        #expect(try text(master, "events.jsonl").split(separator: "\n").map { $0.contains("#2") || $0.contains("#3") } == [true, true])
    }

    /// The asks the skill writes; a missing or half-written file is no asks.
    @Test func asksReadWhatTheSkillWrites() throws {
        let master = folder()
        defer { try? FileManager.default.removeItem(at: master.url) }
        #expect(master.asks().isEmpty)
        try FileManager.default.createDirectory(at: master.url, withIntermediateDirectories: true)
        try #"{"asks": [{"id": "PRO-650-3", "task": "PRO-650", "worker": "PRO-650", "text": "mark ready?", "askedAt": "2026-11-16T09:12:00Z"}]}"#
            .write(to: master.url.appendingPathComponent("asks.json"), atomically: true, encoding: .utf8)
        #expect(master.asks() == [MasterAsk(id: "PRO-650-3", task: "PRO-650", worker: "PRO-650", text: "mark ready?", askedAt: JSON.parseISO8601("2026-11-16T09:12:00Z"))])
        try #"{"asks": [{"id": "#.write(to: master.url.appendingPathComponent("asks.json"), atomically: true, encoding: .utf8)
        #expect(master.asks().isEmpty)
    }

    /// The folders go in as `additionalDirectories`, tildes expanded; whatever else the person put in the file stays.
    @Test func settingsKeepTheirOtherKeys() throws {
        let master = folder()
        defer { try? FileManager.default.removeItem(at: master.url) }
        let settings = master.url.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"model": "opus", "permissions": {"allow": ["Bash(gh pr view:*)"], "additionalDirectories": ["/old"]}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        try master.writeSettings(additionalDirectories: ["~/Repos", "/work"])
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        let permissions = written["permissions"] as! [String: Any]
        #expect(written["model"] as? String == "opus")
        #expect(permissions["allow"] as? [String] == ["Bash(gh pr view:*)"])
        #expect(permissions["additionalDirectories"] as? [String] == [("~/Repos" as NSString).expandingTildeInPath, "/work"])
    }

    /// What the master routes by: each PR's task and each task's worker.
    @Test func graphNamesEachPullRequestsTaskAndEachTasksWorker() throws {
        let pr = Fixtures.pr(number: 117, repo: "FhenixProtocol/powershot", title: "PRO-650: signer", head: "a", checks: .failure)
        let worker = ClaudeJob(
            id: "e359bf00", name: "PRO-650", state: "done", cwd: "/r", prKeys: [], updatedAt: Fixtures.t0, detail: "ran the self-review"
        )
        let task = WorkTask(id: "PRO-650", origin: .ticket, title: "Signer spike", pullRequests: [pr], sessions: [worker])
        let graph = TaskGraph(tasks: [task], tickets: [Fixtures.ticket("PRO-650", status: "👀 Review Ready")], asked: ["PRO-650"], now: Fixtures.t0)
        #expect(graph.tasks[0].jira == "👀 Review Ready")
        #expect(graph.tasks[0].waitingOn == "you")
        #expect(graph.tasks[0].prs == ["fhenixprotocol/powershot#117"])
        #expect(graph.tasks[0].worker?.name == "PRO-650")
        #expect(graph.tasks[0].worker?.detail == "ran the self-review")
        #expect(graph.prs["fhenixprotocol/powershot#117"]?.task == "PRO-650")
        #expect(graph.prs["fhenixprotocol/powershot#117"]?.checks == "red")

        let master = folder()
        defer { try? FileManager.default.removeItem(at: master.url) }
        try master.write(graph)
        #expect(try JSON.decoder().decode(TaskGraph.self, from: Data(contentsOf: master.url.appendingPathComponent("graph.json"))) == graph)
    }

    /// A ticket task says whether its ticket is in the active sprint or the backlog, as Desk's searches found it; nothing
    /// where Desk doesn't know (a ticket only referenced, a ticket not loaded, a task that is no ticket).
    @Test func graphPlacesEachTicketTaskInTheSprintOrTheBacklog() {
        let tasks = ["PRO-650", "PRO-595", "PRO-700", "PRO-701"].map { WorkTask(id: $0, origin: .ticket, title: $0, pullRequests: []) }
            + [WorkTask(id: "testnet-decrypt", origin: .session, title: "decrypt errors", pullRequests: [])]
        let tickets = [
            Fixtures.ticket("PRO-650", placement: .sprint), Fixtures.ticket("PRO-595", placement: .backlog),
            Fixtures.ticket("PRO-700", placement: .unknown, assignedToMe: false),
        ]
        let graph = TaskGraph(tasks: tasks, tickets: tickets, asked: [], now: Fixtures.t0)
        #expect(graph.tasks.map(\.placement) == ["sprint", "backlog", nil, nil, nil])
    }
}
