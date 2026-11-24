import Foundation

/// The weekly review learning pass for one repo: a Claude session Desk starts on the `fhenix-workflow:review-learning`
/// skill, which gathers the week's review numbers, sorts CodeRabbit's threads, proposes changes and records what the
/// person decided. Desk keeps each run in a folder of its own and says the pass is due until a run has finished.
public enum ReviewLearning {
    // ponytail: one repo, fixed, as the person asked; a setting when a second repo adopts the review flow.
    public static let repo = "FhenixProtocol/cofhe"
    /// The name Desk starts the session under, as `claude agents` lists it.
    public static let sessionName = "review-learning"
    /// The skill's name, which the session's prompt carries: how Desk knows the session's role.
    public static let skill = "review-learning"
    /// Due again this long after the last finished run: the script's `--days 7`.
    public static let interval: TimeInterval = 7 * 86_400

    /// `started.json`, which Desk writes into a run's folder once the session has started.
    public struct Start: Codable, Sendable, Equatable {
        public var startedAt: Date
        /// The session's short id, by which Desk tells a run whose session is still there from one left behind.
        public var jobId: String

        public init(startedAt: Date, jobId: String) {
            self.startedAt = startedAt
            self.jobId = jobId
        }
    }

    /// `finished.json`, the last file the skill writes into a run's folder, after the report and the person's
    /// decisions.
    public struct Finish: Codable, Sendable, Equatable {
        public var finishedAt: Date
        public var repo: String
        /// The days the run covered, `yyyy-MM-dd`, both inclusive, as the metrics script reports them.
        public var from: String
        public var to: String
        /// The report's file name in the run's folder.
        public var report: String

        public init(finishedAt: Date, repo: String, from: String, to: String, report: String) {
            self.finishedAt = finishedAt
            self.repo = repo
            self.from = from
            self.to = to
            self.report = report
        }
    }

    public struct Run: Sendable, Equatable {
        public var folder: URL
        public var start: Start
        /// Nil until the run has finished: see `ReviewLearningFolder.runs`.
        public var finish: Finish?

        public init(folder: URL, start: Start, finish: Finish? = nil) {
            self.folder = folder
            self.start = start
            self.finish = finish
        }

        /// The finished run's report.
        public var report: URL? { finish.map { folder.appendingPathComponent(($0.report as NSString).lastPathComponent) } }
    }

    public enum Status: Sendable, Equatable {
        /// No finished run in the last `interval`. `lastFinished` is nil before the first; `unfinishedStart` is when the
        /// newest run started, when its session is gone and it never finished.
        case due(lastFinished: Date?, unfinishedStart: Date?)
        /// The newest run has not finished and its session is still there: at work, or waiting on the person.
        case running(startedAt: Date, jobId: String)
        case upToDate(finishedAt: Date, nextDue: Date, report: URL)

        /// Whether the pass waits on the person: due, or started and not finished.
        public var needsYou: Bool {
            if case .upToDate = self { return false }
            return true
        }
    }

    /// Where the pass stands. `live` holds the ids of the sessions that are still there; a started run counts for
    /// nothing until it has finished, so one whose session is gone leaves the pass as due as it was.
    public static func status(runs: [Run], live: Set<String>, now: Date = Date()) -> Status {
        let newest = runs.max { $0.start.startedAt < $1.start.startedAt }
        if let newest, newest.finish == nil, live.contains(newest.start.jobId) {
            return .running(startedAt: newest.start.startedAt, jobId: newest.start.jobId)
        }
        let last = runs.filter { $0.finish != nil }.max { $0.finish!.finishedAt < $1.finish!.finishedAt }
        if let last, let finish = last.finish, let report = last.report, now < finish.finishedAt.addingTimeInterval(interval) {
            return .upToDate(finishedAt: finish.finishedAt, nextDue: finish.finishedAt.addingTimeInterval(interval), report: report)
        }
        return .due(lastFinished: last?.finish?.finishedAt, unfinishedStart: newest?.finish == nil ? newest?.start.startedAt : nil)
    }

    /// The session's prompt: its skill, the repo, and the run's folder, where the skill writes its files.
    public static func prompt(run: URL) -> String {
        "Use the fhenix-workflow:\(skill) skill for \(repo). Write the run's files to \(run.path)"
    }
}

/// The folder the runs are kept in, under Desk's own: `review-learning/runs/<start time>/`, each with the `started.json`
/// Desk writes and the `report.md` and `finished.json` the skill does.
public struct ReviewLearningFolder: Sendable {
    public let url: URL

    public init(support: AppSupport) { url = support.directory.appendingPathComponent("review-learning", isDirectory: true) }
    public init(url: URL) { self.url = url }

    private var runsURL: URL { url.appendingPathComponent("runs", isDirectory: true) }

    /// Makes the folder of a run starting at `now`, named by the second in UTC, and returns it.
    public func newRun(now: Date = Date()) throws -> URL {
        let name = now.formatted(.iso8601.dateSeparator(.dash).timeSeparator(.omitted)).replacingOccurrences(of: ":", with: "")
        let run = runsURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        return run
    }

    public func recordStart(_ start: ReviewLearning.Start, in run: URL) throws {
        try JSON.encoder().encode(start).write(to: run.appendingPathComponent("started.json"), options: .atomic)
    }

    /// Every run Desk started. A run is finished only when its `finished.json` reads, is not older than the start, and
    /// names a report that is there and not empty: the skill writes the marker last, so a session that stopped, failed
    /// or still waits on the person's decisions has left none. A folder with no `started.json` is a start that failed.
    public func runs() -> [ReviewLearning.Run] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: runsURL, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSON.decoder()
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("started.json")),
                  let start = try? decoder.decode(ReviewLearning.Start.self, from: data) else { return nil }
            var run = ReviewLearning.Run(folder: folder, start: start)
            if let data = try? Data(contentsOf: folder.appendingPathComponent("finished.json")),
               let finish = try? decoder.decode(ReviewLearning.Finish.self, from: data), finish.finishedAt >= start.startedAt {
                run.finish = finish
                let size = run.report.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
                if size == 0 { run.finish = nil }
            }
            return run
        }
    }
}
