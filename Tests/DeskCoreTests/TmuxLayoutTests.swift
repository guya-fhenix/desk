import DeskCore
import Foundation
import Testing

struct TmuxLayoutTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func job(_ id: String, _ name: String, _ state: String, minutesAgo: Double = 0, role: SessionRole = .worker) -> ClaudeJob {
        ClaudeJob(id: id, name: name, state: state, cwd: "/r", prKeys: [], updatedAt: now.addingTimeInterval(-minutesAgo * 60), role: role)
    }

    /// The master on the left, `claude agents` on the right; agents alone while no master runs.
    @Test func theWindowsTwoPanes() {
        let master = job("m1", "master", "blocked", role: .master)
        #expect(TmuxLayout.panes(master: master) == [PaneSpec(key: "m1", name: "master", isMaster: true), .agents])
        #expect(TmuxLayout.panes(master: nil) == [.agents])
        #expect(TmuxLayout.agentsCommand(claude: "/a b/claude") == "'/a b/claude' agents")
        #expect(TerminalOpener.iTermBuryArguments == ["write", "com.googlecode.iterm2", "AutoHideTmuxClientSession", "-bool", "true"])
        // A session in claude agents' place: attached, then forgotten and claude agents again.
        #expect(TmuxLayout.showCommand(claude: "/c", tmux: "/t", id: "w1")
            == "'/c' attach 'w1'; '/t' set-option -p -u '@desk-showing'; exec '/c' agents")
    }

    @Test func parsesPanes() {
        let output = "%1\t0\tm1\tagents\t\n%4\t1\tagents\tagents\tw2\n%7\t0\tw1\tcofhe-1154\n%9\t2\t\nnot a pane\n"
        #expect(TmuxLayout.parse(output) == [
            TmuxPane(paneId: "%1", index: 0, key: "m1"), TmuxPane(paneId: "%4", index: 1, key: "agents", showing: "w2"),
            TmuxPane(paneId: "%7", index: 0, key: "w1", window: "cofhe-1154"), TmuxPane(paneId: "%9", index: 2, key: ""),
        ])
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
        // iTerm2 is driven by AppleScript: a window on tmux's control mode, quotes in the path escaped.
        #expect(TerminalOpener.iTermScript(tmux: "/opt/homebrew/bin/tmux") ==
            "tell application \"iTerm\"\nactivate\ncreate window with default profile command \"/opt/homebrew/bin/tmux -CC attach -t desk\"\nend tell")
        #expect(TerminalOpener.iTermScript(tmux: "/a \"b\"/tmux").contains("command \"/a \\\"b\\\"/tmux -CC attach -t desk\""))
    }

    /// Against real tmux, on a server of the test's own: `agents` first, the master to its left, a worker in a window of
    /// its own, focus across windows, and the window back when it was closed.
    @Test(.enabled(if: Shell.which("tmux") != nil)) func realTmux() async throws {
        let tmux = Tmux(path: Shell.which("tmux")!, socket: "desk-test-\(ProcessInfo.processInfo.processIdentifier)")
        defer { Task { _ = try? await Shell.output(tmux.path, ["-L", tmux.socket!, "kill-server"]) } }
        #expect(await !tmux.hasSession())
        try await tmux.create(.agents, command: "sleep 600")
        try await tmux.open(PaneSpec(key: "m1", name: "master", isMaster: true), command: "sleep 600")
        try await tmux.arrange()
        try await tmux.openWindow(PaneSpec(key: "w1", name: "cofhe-1154"), command: "sleep 600")
        var panes = try await tmux.panes()
        #expect(panes.filter { $0.window == TmuxLayout.window }.map(\.key) == ["m1", "agents"])
        #expect(panes.first { $0.key == "w1" }?.window == "cofhe-1154")
        #expect(try await tmux.focus("w1"))
        #expect(try await !tmux.focus("gone"))
        // What Desk types into a pane arrives as one line, as typed, and nothing is typed into a pane that isn't there.
        let typed = FileManager.default.temporaryDirectory.appendingPathComponent("desk-typed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: typed) }
        try await tmux.openWindow(PaneSpec(key: "t1", name: "typed"), command: "head -n 1 > \(TmuxLayout.quote(typed.path)); sleep 600")
        #expect(try await tmux.type("Write handoff.md now, as your skill says.", into: "t1"))
        #expect(try await !tmux.type("anything", into: "gone"))
        var line = ""
        for _ in 0..<40 where line.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            line = (try? String(contentsOf: typed, encoding: .utf8)) ?? ""
        }
        #expect(line == "Write handoff.md now, as your skill says.\n")
        // A session in claude agents' place: the pane keeps its key and says what it shows.
        let agents = try #require(panes.first { $0.key == PaneSpec.agentsKey })
        try await tmux.show("w2", in: agents.paneId, command: "sleep 600")
        #expect(try await tmux.panes().first { $0.key == PaneSpec.agentsKey }?.showing == "w2")
        panes = try await tmux.panes()
        // The window closed: opening a pane makes it again.
        for pane in panes where pane.window == TmuxLayout.window { try await tmux.close(pane.paneId) }
        try await tmux.open(.agents, command: "sleep 600")
        panes = try await tmux.panes()
        #expect(panes.filter { $0.window == TmuxLayout.window }.map(\.key) == ["agents"])
        #expect(await tmux.clients() == 0)
        try await tmux.killSession()
        #expect(await !tmux.hasSession())
    }
}
