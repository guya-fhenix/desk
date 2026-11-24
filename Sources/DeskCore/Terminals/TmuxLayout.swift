import Foundation

/// A session Desk shows in the `desk` tmux session: a background session to attach to, by the id `claude attach` takes;
/// `claude agents`, keyed `agents`; or a review session that runs where it shows, keyed `review:<group>`.
public struct PaneSpec: Equatable, Sendable {
    public var key: String
    public var name: String
    public var isMaster: Bool

    public init(key: String, name: String, isMaster: Bool = false) {
        self.key = key
        self.name = name
        self.isMaster = isMaster
    }

    /// `claude agents`, the right half of the `desk` window.
    public static let agentsKey = "agents"
    public static let agents = PaneSpec(key: agentsKey, name: "claude agents")

    /// A review session's key: its window is Desk's to open, and the session's to close when it ends.
    public static func reviewKey(_ group: String) -> String { "review:\(group)" }
    public var isReview: Bool { key.hasPrefix("review:") }
}

/// A pane of the `desk` session as tmux lists it: its window's name, the key Desk tagged it with, empty for a pane Desk
/// did not make, and for `claude agents`' pane, the session it shows in its place, if any.
public struct TmuxPane: Equatable, Sendable {
    public var paneId: String
    public var index: Int
    public var key: String
    public var window: String
    public var showing: String

    public init(paneId: String, index: Int, key: String, window: String = TmuxLayout.window, showing: String = "") {
        self.paneId = paneId
        self.index = index
        self.key = key
        self.window = window
        self.showing = showing
    }
}

/// The `desk` tmux session. Its first window, `agents`, is always the master in its left half and `claude agents` in its
/// right — every background session, to open one or start one from. A background session you show takes `claude
/// agents`' place in the right half until you leave it, when `claude agents` comes back; a review session, which isn't
/// one to attach to, runs in a window of its own. iTerm2 shows it through tmux's control mode (`tmux -CC attach`): each
/// pane a native split, each window a tab or window of iTerm's, and closing iTerm leaves every session running.
public enum TmuxLayout {
    public static let session = "desk"
    public static let window = "agents"
    public static var target: String { "\(session):\(window)" }
    /// The pane option that says which session a pane is.
    public static let option = "@desk-session"
    /// The pane option that says which session `claude agents`' pane shows in its place.
    public static let showingOption = "@desk-showing"
    /// Split on `|`, not a tab: tmux 3.7 prints a control character in a format as `_`, which left every line unread, so
    /// Desk saw no panes and opened the two again at each sync. The window's name is last, the one field that may hold a
    /// `|`: a session's name, where an id and a PR's URL never do.
    public static let listFormat = "#{pane_id}|#{pane_index}|#{\(option)}|#{\(showingOption)}|#{window_name}"

    /// The `desk` window's two panes: the master's, while one runs, and `claude agents`.
    public static func panes(master: ClaudeJob?) -> [PaneSpec] {
        (master.map { [PaneSpec(key: $0.id, name: "master", isMaster: true)] } ?? []) + [.agents]
    }

    /// `list-panes -s -F listFormat` output, every window's. A line that doesn't parse is skipped.
    public static func parse(_ output: String) -> [TmuxPane] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5, parts[0].hasPrefix("%"), let index = Int(parts[1]) else { return nil }
            return TmuxPane(paneId: parts[0], index: index, key: parts[2], window: parts[4], showing: parts[3])
        }
    }

    /// `claude agents`, quoted for the shell tmux runs a pane's command in.
    public static func agentsCommand(claude: String) -> String { "\(quote(claude)) agents" }

    /// A background session in `claude agents`' place: attached until you detach or it ends, then the pane forgets it and
    /// is `claude agents` again.
    public static func showCommand(claude: String, tmux: String, id: String) -> String {
        "\(attachCommand(claude: claude, id: id)); \(quote(tmux)) set-option -p -u \(quote(showingOption)); exec \(agentsCommand(claude: claude))"
    }

    /// `claude attach <id>`, quoted for the shell tmux runs a pane's command in.
    public static func attachCommand(claude: String, id: String) -> String { "\(quote(claude)) attach \(quote(id))" }

    /// A review session's command: its own `claude` with the review's arguments, in the clone it reads.
    public static func reviewCommand(claude: String, arguments: [String], directory: String) -> String {
        "cd \(quote(directory)) && exec \(([claude] + arguments).map(quote).joined(separator: " "))"
    }

    public static func quote(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Drives tmux: one call per command, through `Shell` so a test can stand in for it. `socket` is tmux's `-L`, which a
/// test sets to a server of its own; Desk leaves it nil and uses your default server, where only the `desk` session is
/// Desk's.
public struct Tmux: Sendable {
    public var path: String
    public var socket: String?
    public var run: ShellRun

    public init(path: String, socket: String? = nil, run: @escaping ShellRun = Shell.run) {
        self.path = path
        self.socket = socket
        self.run = run
    }

    @discardableResult
    func call(_ arguments: [String]) async throws -> String {
        try await Shell.output(path, (socket.map { ["-L", $0] } ?? []) + arguments, timeout: 10, run: run)
    }

    public func hasSession() async -> Bool { (try? await call(["has-session", "-t", TmuxLayout.session])) != nil }

    /// Every pane of the session, each window's.
    public func panes() async throws -> [TmuxPane] {
        TmuxLayout.parse(try await call(["list-panes", "-s", "-t", TmuxLayout.session, "-F", TmuxLayout.listFormat]))
    }

    /// How many terminals are attached to the session: none means a terminal has to be opened on it.
    public func clients() async -> Int {
        ((try? await call(["list-clients", "-t", TmuxLayout.session, "-F", "#{client_name}"])) ?? "")
            .split(separator: "\n").count
    }

    /// The session, its `agents` window's first pane running `command`. Wide and tall, since iTerm resizes it to its
    /// window anyway.
    public func create(_ spec: PaneSpec, command: String) async throws {
        try await call(["new-session", "-d", "-s", TmuxLayout.session, "-n", TmuxLayout.window, "-x", "240", "-y", "64", command])
        let first = try await panes().first?.paneId ?? "\(TmuxLayout.target).0"
        try await tag(first, spec)
    }

    /// A pane in the `agents` window: the master's before the others, so it is the left half; any other after them. The
    /// window again, first, if it was closed.
    @discardableResult
    public func open(_ spec: PaneSpec, command: String) async throws -> String {
        let window = try await panes().filter { $0.window == TmuxLayout.window }
        guard let first = window.first, let last = window.last else {
            let pane = try await call(["new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "\(TmuxLayout.session):", "-n", TmuxLayout.window, command])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try await tag(pane, spec)
            return pane
        }
        let place = spec.isMaster ? ["-b", "-t", first.paneId] : ["-t", last.paneId]
        let pane = try await call(["split-window", "-d", "-h", "-P", "-F", "#{pane_id}"] + place + [command])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await tag(pane, spec)
        return pane
    }

    /// `pane` running `command` in place of what it ran, which is ended, and saying it shows `key`.
    public func show(_ key: String, in pane: String, command: String) async throws {
        try await call(["respawn-pane", "-k", "-t", pane, command])
        try await call(["set-option", "-p", "-t", pane, TmuxLayout.showingOption, key])
    }

    /// A window of its own for `spec`, named after it, beside the `agents` window.
    @discardableResult
    public func openWindow(_ spec: PaneSpec, command: String) async throws -> String {
        let pane = try await call(["new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "\(TmuxLayout.session):", "-n", spec.name, command])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await tag(pane, spec)
        return pane
    }

    private func tag(_ pane: String, _ spec: PaneSpec) async throws {
        try await call(["set-option", "-p", "-t", pane, TmuxLayout.option, spec.key])
        try await call(["select-pane", "-t", pane, "-T", spec.name])
    }

    /// Types `text` into `key`'s pane and presses Return, as you would: the one way Desk says anything to a session.
    /// False when the pane isn't there.
    public func type(_ text: String, into key: String) async throws -> Bool {
        guard let pane = try await panes().first(where: { $0.key == key }) else { return false }
        // `-l` sends the text as it is, so a word of it is never read as a key's name.
        try await call(["send-keys", "-t", pane.paneId, "-l", text])
        try await call(["send-keys", "-t", pane.paneId, "Enter"])
        return true
    }

    public func close(_ pane: String) async throws { try await call(["kill-pane", "-t", pane]) }

    /// The `agents` window in two halves, side by side.
    public func arrange() async throws {
        try await call(["select-layout", "-t", TmuxLayout.target, "even-horizontal"])
    }

    /// Makes `key`'s pane the active one, in whichever window it is, which iTerm follows.
    public func focus(_ key: String) async throws -> Bool {
        guard let pane = try await panes().first(where: { $0.key == key }) else { return false }
        try await call(["select-window", "-t", pane.paneId])
        try await call(["select-pane", "-t", pane.paneId])
        return true
    }

    public func killSession() async throws { try await call(["kill-session", "-t", TmuxLayout.session]) }
}
