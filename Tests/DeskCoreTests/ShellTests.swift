import DeskCore
import Foundation
import Testing

/// Serialized: the descriptor count and the concurrency timing are process-wide observations.
@Suite(.serialized) struct ShellTests {
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

    @Test func environmentOverridesSetAndUnsetVariables() async throws {
        let script = "echo ${DESK_TEST_SET:-unset} ${DESK_TEST_UNSET:-unset}"
        setenv("DESK_TEST_UNSET", "inherited", 1)
        defer { unsetenv("DESK_TEST_UNSET") }
        let text = try await Shell.output("/bin/sh", ["-c", script], environment: ["DESK_TEST_SET": "yes", "DESK_TEST_UNSET": nil])
        #expect(text == "yes unset\n")
        let inherited = try await Shell.output("/bin/sh", ["-c", script])
        #expect(inherited == "unset inherited\n")
    }

    @Test func toolPathPutsTheLoginShellsFirstAndKeepsEachDirectoryOnce() {
        let path = Shell.toolPath(login: "/Users/me/.nvm/bin:/opt/homebrew/bin", inherited: "/usr/bin:/sbin")
        let expected = ["/Users/me/.nvm/bin", "/opt/homebrew/bin"] + Shell.toolDirectories.filter { $0 != "/opt/homebrew/bin" } + ["/sbin"]
        #expect(path == expected.joined(separator: ":"))
        #expect(Shell.toolPath(login: nil, inherited: nil) == Shell.toolDirectories.joined(separator: ":"))
    }

    @Test func cancelledTaskThrowsInsteadOfCrashing() async {
        let task = Task { try await Shell.run("/bin/sleep", ["5"]) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test func timesOut() async {
        await #expect(throws: ShellError.self) { try await Shell.run("/bin/sleep", ["5"], timeout: 0.2) }
    }

    /// Every run opens pipes; a retain cycle once kept them open for the life of the process.
    @Test func releasesDescriptorsAfterEachRun() async throws {
        _ = try await Shell.run("/bin/sh", ["-c", "echo warm"])
        let before = openDescriptors()
        for _ in 0..<25 {
            _ = try await Shell.run("/bin/sh", ["-c", "echo out; echo err 1>&2"], stdin: Data("in".utf8))
        }
        await #expect(throws: ShellError.self) { try await Shell.run("/bin/sleep", ["5"], timeout: 0.1) }
        #expect(openDescriptors() <= before + 2)
    }

    /// Twice the cap plus one takes at least three rounds; an uncapped run finishes in one.
    @Test func capsConcurrentProcesses() async throws {
        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<(Shell.maxConcurrentProcesses * 2 + 1) {
                group.addTask { _ = try await Shell.run("/bin/sleep", ["0.2"]) }
            }
            try await group.waitForAll()
        }
        #expect(Date().timeIntervalSince(start) >= 0.6)
    }

    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }
}
