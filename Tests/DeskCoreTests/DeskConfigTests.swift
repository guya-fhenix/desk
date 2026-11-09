import DeskCore
import Foundation
import Testing

@Suite struct DeskConfigTests {
    /// A source that keeps failing is asked half as often each time, up to every 30 minutes, which lets a throttle on
    /// the account lift; one success puts it back on its own interval.
    @Test func aFailingPollBacksOffToThirtyMinutes() {
        #expect(PollBackoff.seconds(interval: 300, failures: 0) == 300)
        #expect(PollBackoff.seconds(interval: 300, failures: 1) == 600)
        #expect(PollBackoff.seconds(interval: 300, failures: 2) == 1_200)
        #expect(PollBackoff.seconds(interval: 300, failures: 3) == 1_800)
        #expect(PollBackoff.seconds(interval: 300, failures: 50) == 1_800, "capped, and no overflow however long it fails")
        #expect(PollBackoff.seconds(interval: 60, failures: 1) == 120)
        #expect(PollBackoff.seconds(interval: 3_600, failures: 2) == 3_600, "an interval set above the cap is kept")
    }

    /// A config.json from before a setting went away still loads: the key it names is ignored.
    @Test func missingKeysFallBackToDefaults() throws {
        let json = #"{"githubOrg":"Other","reviewTimeoutMinutes":45,"reviewRoot":"~/x","stalePullRequestDays":3}"#
        let config = try JSON.decoder().decode(DeskConfig.self, from: Data(json.utf8))
        #expect(config.githubOrg == "Other")
        #expect(config.repoRoots == DeskConfig().repoRoots)
    }

    /// A value of the wrong type, as a hand edit leaves one, costs that key alone.
    @Test func aWrongTypedValueFallsBackAlone() throws {
        let json = #"{"githubPollSeconds":"120","trackedRepos":["FhenixProtocol/cofhe"]}"#
        let config = try JSON.decoder().decode(DeskConfig.self, from: Data(json.utf8))
        #expect(config.trackedRepos == ["FhenixProtocol/cofhe"])
        #expect(config.githubPollSeconds == DeskConfig().githubPollSeconds)
    }

    /// A file that is not JSON at all is kept as config.json.bad and left alone, and the error says so; no file is no error.
    @Test func anUnreadableFileIsKeptAside() throws {
        let support = AppSupport(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: support.directory) }
        let none = DeskService.loadConfig(support: support)
        #expect(none.config == DeskConfig() && none.error == nil)

        try FileManager.default.createDirectory(at: support.directory, withIntermediateDirectories: true)
        let broken = #"{"trackedRepos":["FhenixProtocol/cofhe"]"#
        try broken.write(to: support.url("config.json"), atomically: true, encoding: .utf8)
        let loaded = DeskService.loadConfig(support: support)
        #expect(loaded.config == DeskConfig())
        #expect(loaded.error?.contains("config.json.bad") == true)
        #expect(try String(contentsOf: support.url("config.json.bad"), encoding: .utf8) == broken)
        #expect(try String(contentsOf: support.url("config.json"), encoding: .utf8) == broken)
    }

    @Test func roundTripsThroughJSON() throws {
        var config = DeskConfig()
        config.claudePath = "/opt/claude"
        config.notificationsEnabled = false
        let data = try JSON.encoder().encode(config)
        let decoded = try JSON.decoder().decode(DeskConfig.self, from: data)
        #expect(decoded == config)
    }

}
