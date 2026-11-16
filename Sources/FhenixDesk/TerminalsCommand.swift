import AppKit
import DeskCore
import Foundation

/// `FhenixDesk --terminals <status|sync|show <master|name|id>>`: the iTerm layout driven from the command line, through
/// the same `AppModel` code the buttons run, once every source has answered. For checking the layout without a click.
@MainActor
enum TerminalsCommand {
    static func start(_ arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task {
            await run(arguments)
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }

    private static func run(_ arguments: [String]) async {
        let model = AppModel()
        for _ in 0..<240 where Set(model.state.lastRefresh.keys).union(model.state.errors.keys).count < Source.allCases.count {
            try? await Task.sleep(for: .milliseconds(500))
        }
        switch arguments.first {
        case "sync":
            await model.syncTerminals()
        case "show":
            let name = arguments.dropFirst().first ?? "master"
            let job = name == "master" ? model.state.master : model.state.claudeJobs.first { $0.name == name || $0.id == name }
            guard let job else {
                print("no session named \(name)")
                return
            }
            await model.showNow(jobId: job.id)
            if let error = model.terminalError { print(error) }
        case "status", nil:
            break
        default:
            print("usage: FhenixDesk --terminals <status|sync|show <master|name|id>>")
            return
        }
        guard let tmux = model.tmux else {
            print(DeskError.tmuxNotFound.description)
            return
        }
        print("wanted: \(model.layoutPanes.map(\.name).joined(separator: ", "))")
        guard await tmux.hasSession() else {
            print("no \(TmuxLayout.session) session yet")
            return
        }
        for pane in (try? await tmux.panes()) ?? [] {
            print("\(pane.paneId)\t\(pane.index)\t\(pane.key)\t\(model.state.claudeJobs.first { $0.id == pane.key }?.name ?? "")")
        }
        print("terminals attached: \(await tmux.clients())")
    }
}
