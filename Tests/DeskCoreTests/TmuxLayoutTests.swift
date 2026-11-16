import DeskCore
import Foundation
import Testing

struct TmuxLayoutTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func job(_ id: String, _ name: String, _ state: String, minutesAgo: Double = 0, role: SessionRole = .worker) -> ClaudeJob {
        ClaudeJob(id: id, name: name, state: state, cwd: "/r", prKeys: [], updatedAt: now.addingTimeInterval(-minutesAgo * 60), role: role)
    }

    /// The master first; then each session that works, waits for you, or worked in the last ten minutes, once each.
    @Test func desiredPanes() {
        let master = job("m1", "master", "blocked", role: .master)
        let sessions = [
            job("w1", "cofhe-1154", "working"),
            job("w2", "pro-650", "done", minutesAgo: 30),
            job("w3", "marketplace-17", "done", minutesAgo: 4),
            job("w4", "teecryptor", "blocked", minutesAgo: 90),
            job("w1", "cofhe-1154", "working"),
            master,
        ]
        let specs = TmuxLayout.desired(master: master, sessions: sessions, now: now)
        #expect(specs.map(\.key) == ["m1", "w1", "w3", "w4"])
        #expect(specs[0] == PaneSpec(key: "m1", name: "master", isMaster: true))
        #expect(TmuxLayout.desired(master: nil, sessions: [], now: now).isEmpty)
    }

    @Test func parsesPanes() {
        let output = "%1\t0\tm1\n%4\t1\tw1\n%7\t2\t\nnot a pane\n"
        #expect(TmuxLayout.parse(output) == [
            TmuxPane(paneId: "%1", index: 0, key: "m1"), TmuxPane(paneId: "%4", index: 1, key: "w1"),
            TmuxPane(paneId: "%7", index: 2, key: ""),
        ])
    }

    /// Closes what is no longer wanted, never a review's pane or one Desk did not make; opens what is missing; and a
    /// pane closed by hand stays closed.
    @Test func changeBetweenLayouts() {
        let current = [
            TmuxPane(paneId: "%1", index: 0, key: "m1"), TmuxPane(paneId: "%2", index: 1, key: "old"),
            TmuxPane(paneId: "%3", index: 2, key: "review:g1"), TmuxPane(paneId: "%4", index: 3, key: ""),
        ]
        let desired = [PaneSpec(key: "m1", name: "master", isMaster: true), PaneSpec(key: "w1", name: "a"), PaneSpec(key: "w2", name: "b")]
        let change = TmuxLayout.change(current: current, desired: desired, made: ["m1", "old", "w2"], dismissed: [])
        #expect(change.close == ["%2"])
        #expect(change.open.map(\.key) == ["w1"])
        #expect(change.dismissed == ["w2"])
        // Dismissed stays dismissed while wanted, and is forgotten once not.
        let later = TmuxLayout.change(current: current, desired: [desired[0]], made: ["m1"], dismissed: ["w2"])
        #expect(later.dismissed.isEmpty && later.open.isEmpty)
    }

    @Test func commandsAreQuoted() {
        #expect(TmuxLayout.attachCommand(claude: "/Users/a b/claude", id: "abc") == "'/Users/a b/claude' attach 'abc'")
        #expect(TmuxLayout.reviewCommand(claude: "/bin/claude", arguments: ["-p", "it's"], directory: "/r")
            == "cd '/r' && exec '/bin/claude' '-p' 'it'\\''s'")
        #expect(PaneSpec(key: PaneSpec.reviewKey("g1"), name: "r").isReview)
    }

    @Test func attachScripts() {
        #expect(TerminalOpener.script(app: .iTerm, tmux: "/opt/homebrew/bin/tmux").hasSuffix(
            "exec '/opt/homebrew/bin/tmux' -CC attach -t desk\n"))
        #expect(TerminalOpener.script(app: .terminal, tmux: "/t", socket: "x").hasSuffix("exec '/t' -L 'x' attach -t desk\n"))
        #expect(TerminalOpener.openArguments(app: .iTerm, script: URL(filePath: "/s.command")) == ["-a", "iTerm", "/s.command"])
        #expect(TerminalOpener.openArguments(app: .terminal, script: nil) == ["-a", "Terminal"])
    }

    /// Against real tmux, on a server of the test's own: the layout is made, panes come and go, the master goes to the
    /// left, and focus finds a pane by its session.
    @Test(.enabled(if: Shell.which("tmux") != nil)) func realTmux() async throws {
        let tmux = Tmux(path: Shell.which("tmux")!, socket: "desk-test-\(ProcessInfo.processInfo.processIdentifier)")
        defer { Task { _ = try? await Shell.output(tmux.path, ["-L", tmux.socket!, "kill-server"]) } }
        #expect(await !tmux.hasSession())
        try await tmux.create(PaneSpec(key: "w1", name: "a"), command: "sleep 600")
        try await tmux.open(PaneSpec(key: "w2", name: "b"), command: "sleep 600")
        try await tmux.open(PaneSpec(key: "m1", name: "master", isMaster: true), command: "sleep 600")
        try await tmux.arrange()
        var panes = try await tmux.panes()
        #expect(panes.map(\.key) == ["m1", "w1", "w2"])
        let change = TmuxLayout.change(current: panes, desired: [PaneSpec(key: "m1", name: "master", isMaster: true), PaneSpec(key: "w1", name: "a")],
                                       made: ["m1", "w1", "w2"], dismissed: [])
        for pane in change.close { try await tmux.close(pane) }
        panes = try await tmux.panes()
        #expect(panes.map(\.key) == ["m1", "w1"])
        #expect(try await tmux.focus("w1"))
        #expect(try await !tmux.focus("gone"))
        #expect(await tmux.clients() == 0)
        try await tmux.killSession()
        #expect(await !tmux.hasSession())
    }
}
