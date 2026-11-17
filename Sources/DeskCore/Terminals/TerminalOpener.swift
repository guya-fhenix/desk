import Foundation

/// Puts the `desk` layout in front of you. With no terminal attached to it: iTerm2 opens a window on `tmux -CC attach`
/// by AppleScript, so the panes are native splits — macOS asks once to let Desk control iTerm, and iTerm2 asks before it
/// runs a script opened from outside, every time, which is why it isn't handed one; Terminal.app opens a small script in
/// Desk's folder (plain `tmux attach`), which it runs without asking. With one attached, the app is brought forward.
public enum TerminalOpener {
    /// The AppleScript that opens an iTerm2 window attached to the layout in control mode.
    public static func iTermScript(tmux: String, socket: String? = nil) -> String {
        let server = socket.map { " -L \($0)" } ?? ""
        let command = "\(tmux)\(server) -CC attach -t \(TmuxLayout.session)"
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"iTerm\"\nactivate\ncreate window with default profile command \"\(command)\"\nend tell"
    }

    public static let bundleIds: [DeskConfig.TerminalApp: String] = [.iTerm: "com.googlecode.iterm2", .terminal: "com.apple.Terminal"]
    public static let appNames: [DeskConfig.TerminalApp: String] = [.iTerm: "iTerm", .terminal: "Terminal"]

    /// The script's text: attach to the session, in control mode for iTerm2.
    public static func script(app: DeskConfig.TerminalApp, tmux: String, socket: String? = nil) -> String {
        let server = socket.map { " -L \(TmuxLayout.quote($0))" } ?? ""
        let mode = app == .iTerm ? " -CC" : ""
        return "#!/bin/zsh\n# Written by Fhenix Desk: attaches this terminal to the desk tmux session.\n"
            + "exec \(TmuxLayout.quote(tmux))\(server)\(mode) attach -t \(TmuxLayout.session)\n"
    }

    /// A setup fix, `gh auth login` say, as a script for a login shell: Homebrew's PATH and your profile are there.
    public static func commandScript(_ command: String) -> String {
        "#!/bin/zsh -l\n# Written by Fhenix Desk: a setup step. When it is done, go back to Desk; it checks again.\n"
            + "\(command)\necho\necho 'Done. Go back to Fhenix Desk: it checks again when you do.'\n"
    }

    /// Writes the script beside Desk's other files, executable, and returns its path.
    public static func writeScript(_ text: String, in folder: URL, name: String = "desk-attach") throws -> URL {
        let file = folder.appending(path: "\(name).command")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// `open -a <app> [script]`: the script opens a window attached to the layout; without one, the app comes forward.
    public static func openArguments(app: DeskConfig.TerminalApp, script: URL?) -> [String] {
        ["-a", appNames[app] ?? "iTerm"] + (script.map { [$0.path] } ?? [])
    }
}
