import DeskCore
import Foundation
import Testing

@Suite struct ReviewLearningTests {
    private func folder() -> ReviewLearningFolder {
        ReviewLearningFolder(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
    }

    private let day: TimeInterval = 86_400

    private func finish(_ run: URL, at: String, report: String? = "# Report") throws {
        if let report { try report.write(to: run.appendingPathComponent("report.md"), atomically: true, encoding: .utf8) }
        try #"{"finishedAt": "\#(at)", "repo": "FhenixProtocol/cofhe", "from": "2026-11-14", "to": "2026-11-20", "report": "report.md"}"#
            .write(to: run.appendingPathComponent("finished.json"), atomically: true, encoding: .utf8)
    }

    /// Started is not finished: the run counts only once the skill's marker is there, not older than the start, with a
    /// report that has something in it.
    @Test func aRunIsFinishedOnlyByItsMarkerAndReport() throws {
        let runs = folder()
        defer { try? FileManager.default.removeItem(at: runs.url) }
        let start = JSON.parseISO8601("2026-11-21T14:02:00Z")!
        let run = try runs.newRun(now: start)
        #expect(runs.runs().isEmpty, "a folder with no started.json is a start that failed")
        try runs.recordStart(.init(startedAt: start, jobId: "abc"), in: run)
        #expect(runs.runs().map(\.finish) == [nil])

        try finish(run, at: "2026-11-21T15:00:00Z", report: nil)
        #expect(runs.runs().first?.finish == nil, "no report")
        try finish(run, at: "2026-11-21T15:00:00Z", report: "")
        #expect(runs.runs().first?.finish == nil, "an empty report")
        try finish(run, at: "2026-11-20T15:00:00Z")
        #expect(runs.runs().first?.finish == nil, "a marker older than the start")
        try "{".write(to: run.appendingPathComponent("finished.json"), atomically: true, encoding: .utf8)
        #expect(runs.runs().first?.finish == nil, "a half-written marker")
        // A name that resolves to a folder is no report: a folder's size is never zero.
        for name in ["", ".", "..", "/"] {
            try #"{"finishedAt": "2026-11-21T15:00:00Z", "report": "\#(name)"}"#
                .write(to: run.appendingPathComponent("finished.json"), atomically: true, encoding: .utf8)
            #expect(runs.runs().first?.finish == nil, "report named '\(name)'")
        }
        // Only the time and the report are needed. A time later than the marker was written counts as when it was
        // written, which does not move: eight days on, the pass is due again.
        try #"{"finishedAt": "2099-01-01T00:00:00Z", "report": "report.md"}"#
            .write(to: run.appendingPathComponent("finished.json"), atomically: true, encoding: .utf8)
        let written = Date()
        let capped = try #require(runs.runs().first?.finish?.finishedAt)
        #expect(abs(capped.timeIntervalSince(written)) < 60)
        #expect(ReviewLearning.status(runs: runs.runs(), live: [], now: written + 8 * day) == .due(lastFinished: capped, unfinishedStart: nil))

        try finish(run, at: "2026-11-21T15:00:00Z")
        let finished = try #require(runs.runs().first)
        #expect(finished.finish?.to == "2026-11-20")
        #expect(finished.report?.lastPathComponent == "report.md")
    }

    @Test func statusFollowsTheLastFinishedRun() {
        let t0 = Fixtures.t0
        let url = URL(fileURLWithPath: "/runs/a")
        func run(_ id: String, started: Date, finished: Date? = nil) -> ReviewLearning.Run {
            ReviewLearning.Run(folder: url, start: .init(startedAt: started, jobId: id), finish: finished.map {
                .init(finishedAt: $0, repo: ReviewLearning.repo, from: "2026-11-14", to: "2026-11-20", report: "report.md")
            })
        }
        let status = { (runs: [ReviewLearning.Run], live: Set<String>, now: Date) in ReviewLearning.status(runs: runs, live: live, now: now) }

        // Never run.
        #expect(status([], [], t0) == .due(lastFinished: nil, unfinishedStart: nil))
        // Started, its session still there: not finished, whatever the session's state.
        #expect(status([run("a", started: t0)], ["a"], t0 + 600) == .running(startedAt: t0, jobId: "a"))
        // Just started, its session not in a scan yet: running, not abandoned.
        #expect(status([run("a", started: t0)], [], t0 + 30) == .running(startedAt: t0, jobId: "a"))
        // Its session gone before it finished: still due, and it says the start did not finish.
        #expect(status([run("a", started: t0)], [], t0 + 600) == .due(lastFinished: nil, unfinishedStart: t0))

        let done = run("a", started: t0, finished: t0 + 3_600)
        let report = url.appendingPathComponent("report.md")
        #expect(status([done], ["a"], t0 + 2 * day) == .upToDate(finishedAt: t0 + 3_600, nextDue: t0 + 3_600 + 7 * day, report: report))
        // Seven days after it finished, due again.
        #expect(status([done], [], t0 + 3_600 + 7 * day) == .due(lastFinished: t0 + 3_600, unfinishedStart: nil))
        // A later run that never finished does not move the last finished one.
        let abandoned = run("b", started: t0 + 8 * day)
        #expect(status([done, abandoned], [], t0 + 9 * day) == .due(lastFinished: t0 + 3_600, unfinishedStart: t0 + 8 * day))
        #expect(status([done, abandoned], ["b"], t0 + 9 * day) == .running(startedAt: t0 + 8 * day, jobId: "b"))
        // Started again before it was due, and left: the finished run still stands.
        #expect(status([done, run("b", started: t0 + day)], [], t0 + 2 * day).needsYou == false)
    }

    @Test func theSessionIsKnownByItsPromptAndIsNoTask() {
        let prompt = ReviewLearning.prompt(run: URL(fileURLWithPath: "/tmp/Fhenix Desk/review-learning/runs/x"))
        #expect(prompt.contains("FhenixProtocol/cofhe") && prompt.hasSuffix("/runs/x"))
        #expect(SessionRole.of(name: ReviewLearning.sessionName, intent: prompt) == .learning)
        #expect(SessionRole.of(name: "PRO-1", intent: "Use the fhenix-workflow:work-on-task skill: fix review-learning") == .worker)
    }
}
