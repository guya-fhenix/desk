import Foundation

/// Puts the `desk` layout in front of you: with no terminal attached to it, a small script in Desk's folder that
/// attaches, opened in iTerm2 (`tmux -CC`, so the panes are native splits) or Terminal.app (plain `tmux attach`); with
/// one attached, just that app brought forward. `open -a` with a script needs no Automation permission, which driving
/// iTerm by AppleScript would.
public enum TerminalOpener {
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
