import DeskCore
import Foundation
import Testing

@Suite struct ShellTests {
    @Test func returnsOutputAndStatus() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.text == "out\n")
        #expect(result.stderr == "err\n")
    }

    @Test func feedsStdin() async throws {
        let text = try await Shell.output("/bin/cat", [], stdin: Data("hello".utf8))
        #expect(text == "hello")
    }

    @Test func cancelledTaskThrowsInsteadOfCrashing() async {
        let task = Task { try await Shell.run("/bin/sleep", ["5"]) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test func timesOut() async {
        await #expect(throws: ShellError.self) { try await Shell.run("/bin/sleep", ["5"], timeout: 0.2) }
    }
}
