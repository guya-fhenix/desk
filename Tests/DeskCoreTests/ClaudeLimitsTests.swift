import DeskCore
import Foundation
import Testing

@Suite struct ClaudeLimitsTests {
    private func temporary() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func limitsStartOverOnceTheirWindowEnds() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let sessionEnded = Int(now.timeIntervalSince1970) - 60
        let weekEnds = Int(now.timeIntervalSince1970) + 86_400
        try "4\u{1F}32\u{1F}\(sessionEnded)\u{1F}\(weekEnds)\n".write(toFile: directory.path + "/quota", atomically: true, encoding: .utf8)
        try "Fable\u{1F}12\n".write(toFile: directory.path + "/scoped", atomically: true, encoding: .utf8)

        let limits = ClaudeLimits.read(directory: directory.path, now: now)
        #expect(limits.map(\.name) == ["Session", "Week", "Fable week"])
        #expect(limits.map(\.percent) == [0, 32, 12])
        #expect(limits[0].resetsAt == nil)
        #expect(limits[1].resetsAt == Date(timeIntervalSince1970: TimeInterval(weekEnds)))

        // A per-model figure written before this week began is last week's: left out rather than shown as current.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: directory.path + "/scoped")
        #expect(ClaudeLimits.read(directory: directory.path, now: now).map(\.name) == ["Session", "Week"])
    }
}
