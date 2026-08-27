import DeskCore
import Foundation
import Testing

@Suite struct TranscriptScannerTests {
    private func write(_ lines: [String], to url: URL, append: Bool = false, trailingNewline: Bool = true) throws {
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        if append {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    private let human = #"{"parentUuid":null,"type":"user","message":{"role":"user","content":"hi"},"origin":{"kind":"human"},"timestamp":"2026-08-23T11:54:57.327Z","cwd":"/r/cofhe","gitBranch":"feat/pro-492-engine-alerts","sessionId":"s"}"#
    private let toolResult = #"{"parentUuid":"x","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"big"}]},"timestamp":"2026-08-23T11:55:00.000Z","cwd":"/r/cofhe","gitBranch":"master","sessionId":"s"}"#
    private let assistant = #"{"parentUuid":"y","type":"assistant","message":{"role":"assistant","model":"m","content":[]},"timestamp":"2026-08-23T11:55:01.000Z","sessionId":"s"}"#
    private let prLink = #"{"type":"pr-link","sessionId":"s","prNumber":64,"prUrl":"https://github.com/FhenixProtocol/teecryptor/pull/64","prRepository":"FhenixProtocol/teecryptor","timestamp":"2026-08-23T14:58:39.483Z"}"#
    private let title = #"{"type":"ai-title","aiTitle":"pro-495 pro-496 tickets","sessionId":"s"}"#
    private let cost = #"{"type":"cost-state","sessionId":"s","totalCostUSD":108.42,"totalDuration":20231646,"totalLinesAdded":12,"totalLinesRemoved":3}"#
    private let relocated = #"{"type":"relocated","sessionId":"s","relocatedCwd":"/r/cofhe/.claude/worktrees/pro-495"}"#

    @Test func extractsSummaryFields() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString).jsonl")
        try write([human, toolResult, assistant, prLink, title, cost, relocated], to: url)
        var summary = SessionSummary(sessionId: "s", filePath: url.path)
        try TranscriptScanner.scan(fileURL: url, into: &summary)

        #expect(summary.humanPrompts == 1)
        #expect(summary.assistantMessages == 1)
        #expect(summary.cwd == "/r/cofhe")
        #expect(summary.branches == ["feat/pro-492-engine-alerts"])
        #expect(summary.prLinks.map(\.number) == [64])
        #expect(summary.title == "pro-495 pro-496 tickets")
        #expect(summary.costUSD == 108.42)
        #expect(summary.linesAdded == 12)
        #expect(summary.totalDurationMs == 20_231_646)
        #expect(summary.worktreePaths == ["/r/cofhe/.claude/worktrees/pro-495"])
        #expect(summary.firstActivityAt == JSON.parseISO8601("2026-08-23T11:54:57.327Z"))
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int64
        #expect(summary.scannedBytes == size)
    }

    @Test func resumesFromOffsetAndKeepsPartialLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString).jsonl")
        try write([human], to: url)
        var summary = SessionSummary(sessionId: "s", filePath: url.path)
        try TranscriptScanner.scan(fileURL: url, into: &summary)
        let firstSize = summary.scannedBytes
        #expect(summary.humanPrompts == 1)

        try write([human, String(prLink.prefix(40))], to: url, append: true, trailingNewline: false)
        try TranscriptScanner.scan(fileURL: url, into: &summary)
        #expect(summary.humanPrompts == 2)
        #expect(summary.prLinks.isEmpty)
        #expect(summary.scannedBytes == firstSize + Int64(human.utf8.count) + 1)

        try write([String(prLink.dropFirst(40))], to: url, append: true)
        try TranscriptScanner.scan(fileURL: url, into: &summary)
        #expect(summary.prLinks.count == 1)
    }

    @Test func projectDirectoryMatchesRepoAndItsWorktrees() {
        let roots = ["/Users/me/Repos/cofhe", "/Users/me/Repos/teecryptor"]
        #expect(ClaudePaths.projectDirectory("-Users-me-Repos-cofhe", belongsTo: roots))
        #expect(ClaudePaths.projectDirectory("-Users-me-Repos-cofhe--claude-worktrees-pro-391", belongsTo: roots))
        #expect(ClaudePaths.projectDirectory("-Users-me-Repos-teecryptor-worktrees-pro-401", belongsTo: roots))
        #expect(!ClaudePaths.projectDirectory("-Users-me-Repos-cofhejs", belongsTo: roots))
        #expect(!ClaudePaths.projectDirectory("-Users-me-Repos", belongsTo: roots))
    }
}
