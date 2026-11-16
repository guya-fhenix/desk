import Foundation

/// A session Desk wants a pane for in the `desk` layout: a background session to attach to, by the id `claude attach`
/// takes, or a review session that runs in its pane, keyed `review:<group>`.
public struct PaneSpec: Equatable, Sendable {
    public var key: String
    public var name: String
    public var isMaster: Bool

    public init(key: String, name: String, isMaster: Bool = false) {
        self.key = key
        self.name = name
        self.isMaster = isMaster
    }

    /// A review session's key: its panes are Desk's to open, and the session's to close when it ends.
    public static func reviewKey(_ group: String) -> String { "review:\(group)" }
    public var isReview: Bool { key.hasPrefix("review:") }
}

/// A pane of the `desk` window as tmux lists it, with the key Desk tagged it with; empty for a pane Desk did not make.
public struct TmuxPane: Equatable, Sendable {
    public var paneId: String
    public var index: Int
    public var key: String

    public init(paneId: String, index: Int, key: String) {
        self.paneId = paneId
        self.index = index
        self.key = key
    }
}

/// What a sync does to the layout: the panes to close, the sessions to open panes for, in order, and the sessions whose
/// pane Guy closed by hand, which stay closed until he shows them or they start waiting for him.
public struct LayoutChange: Equatable, Sendable {
    public var close: [String]
    public var open: [PaneSpec]
    public var dismissed: Set<String>
}

/// The `desk` tmux session: one window, `agents`, the master in its left half and a pane per other session at work on the
/// right, each running `claude attach <id>`. iTerm2 shows it through tmux's control mode (`tmux -CC attach`), so each
/// pane is a native split there, and closing iTerm leaves every session running.
public enum TmuxLayout {
    public static let session = "desk"
    public static let window = "agents"
    public static var target: String { "\(session):\(window)" }
    /// The pane option that says which session a pane is.
    public static let option = "@desk-session"
    public static let listFormat = "#{pane_id}\t#{pane_index}\t#{\(option)}"
    /// How long a session keeps its pane after its turn ends. The master messages its workers, so a worker's turns end
    /// and start again all day: a pane that closed the moment one ended would come and go under your eyes.
    public static let linger: TimeInterval = 600

    /// The panes Desk wants, given the master, the open tasks' workers and the review sessions: the master first, then
    /// each other session that works, waits for you, or worked in the last `linger`, in the order given, once each.
    public static func desired(master: ClaudeJob?, sessions: [ClaudeJob], now: Date = Date()) -> [PaneSpec] {
        var specs: [PaneSpec] = []
        var seen = Set<String>()
        if let master {
            specs.append(PaneSpec(key: master.id, name: "master", isMaster: true))
            seen.insert(master.id)
        }
        for job in sessions where seen.insert(job.id).inserted {
            if job.isBusy || now.timeIntervalSince(job.updatedAt) < linger { specs.append(PaneSpec(key: job.id, name: job.name)) }
        }
        return specs
    }

    /// `list-panes -F listFormat` output. A line that doesn't parse is skipped.
    public static func parse(_ output: String) -> [TmuxPane] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, parts[0].hasPrefix("%"), let index = Int(parts[1]) else { return nil }
            return TmuxPane(paneId: parts[0], index: index, key: parts.count > 2 ? parts[2] : "")
        }
    }

    /// From the panes there are to the panes wanted. `made` are the sessions Desk opened a pane for and has not closed
    /// since; one of them still wanted but gone was closed by hand. `dismissed` stay closed. Review panes and panes Desk
    /// did not make are never closed: they belong to their sessions and to you.
    public static func change(current: [TmuxPane], desired: [PaneSpec], made: Set<String>, dismissed: Set<String>) -> LayoutChange {
        let present = Set(current.map(\.key))
        let wanted = Set(desired.map(\.key))
        let close = current.filter { !$0.key.isEmpty && !$0.key.hasPrefix("review:") && !wanted.contains($0.key) }.map(\.paneId)
        let closedByHand = made.filter { wanted.contains($0) && !present.contains($0) }
        let stillDismissed = dismissed.union(closedByHand).intersection(wanted)
        let open = desired.filter { !present.contains($0.key) && !stillDismissed.contains($0.key) }
        return LayoutChange(close: close, open: open, dismissed: stillDismissed)
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

    public func panes() async throws -> [TmuxPane] {
        TmuxLayout.parse(try await call(["list-panes", "-t", TmuxLayout.target, "-F", TmuxLayout.listFormat]))
    }

    /// How many terminals are attached to the session: none means a terminal has to be opened on it.
    public func clients() async -> Int {
        ((try? await call(["list-clients", "-t", TmuxLayout.session, "-F", "#{client_name}"])) ?? "")
            .split(separator: "\n").count
    }

    /// The session, with its first pane running `command`. Wide and tall, since iTerm resizes it to its window anyway.
    public func create(_ spec: PaneSpec, command: String) async throws {
        try await call(["new-session", "-d", "-s", TmuxLayout.session, "-n", TmuxLayout.window, "-x", "240", "-y", "64", command])
        let first = try await panes().first?.paneId ?? "\(TmuxLayout.target).0"
        try await tag(first, spec)
    }

    /// A pane for `spec`: the master's goes before the first pane, so it is the main pane on the left; the rest go after.
    @discardableResult
    public func open(_ spec: PaneSpec, command: String) async throws -> String {
        var arguments = ["split-window", "-d", "-P", "-F", "#{pane_id}"]
        if spec.isMaster, let first = try await panes().first {
            arguments += ["-b", "-h", "-t", first.paneId]
        } else {
            arguments += ["-t", TmuxLayout.target]
        }
        let pane = try await call(arguments + [command]).trimmingCharacters(in: .whitespacesAndNewlines)
        try await tag(pane, spec)
        return pane
    }

    private func tag(_ pane: String, _ spec: PaneSpec) async throws {
        try await call(["set-option", "-p", "-t", pane, TmuxLayout.option, spec.key])
        try await call(["select-pane", "-t", pane, "-T", spec.name])
    }

    public func close(_ pane: String) async throws { try await call(["kill-pane", "-t", pane]) }

    /// The master in the left half, the rest stacked on the right.
    public func arrange() async throws {
        try await call(["set-option", "-w", "-t", TmuxLayout.target, "main-pane-width", "50%"])
        try await call(["select-layout", "-t", TmuxLayout.target, "main-vertical"])
    }

    /// Makes `key`'s pane the active one, which iTerm follows.
    public func focus(_ key: String) async throws -> Bool {
        guard let pane = try await panes().first(where: { $0.key == key }) else { return false }
        try await call(["select-window", "-t", TmuxLayout.target])
        try await call(["select-pane", "-t", pane.paneId])
        return true
    }

    public func killSession() async throws { try await call(["kill-session", "-t", TmuxLayout.session]) }
}
