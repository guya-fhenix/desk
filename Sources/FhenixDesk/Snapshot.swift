#if DEBUG
import AppKit
import DeskCore
import SwiftUI

/// Draws a PR's page, or its review diff at its first open thread, off screen into a PNG, with live data, as the app
/// shows it: `FhenixDesk --snapshot <pr url> <out.png> [page|diff] [height] [dark]`. For checking a view without driving
/// the window. Debug builds only.
@MainActor
enum Snapshot {
    static func start(_ arguments: [String]) {
        Task {
            await run(arguments)
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }

    private static func run(_ arguments: [String]) async {
        guard arguments.count >= 2 else {
            print("usage: --snapshot <pr url> <out.png> [page|diff] [height] [dark]")
            return
        }
        let (url, out) = (arguments[0], arguments[1])
        let mode = arguments.count > 2 ? arguments[2] : "page"
        let height = arguments.count > 3 ? CGFloat(Double(arguments[3]) ?? 2400) : 2400
        if arguments.contains("dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("light") { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
        let model = AppModel()
        var found: PullRequest?
        for _ in 0..<120 where found == nil {
            try? await Task.sleep(for: .milliseconds(500))
            let all = model.state.github.map { $0.mine + $0.reviewRequests + $0.openForReview + $0.mergedRecent } ?? []
            found = all.first { $0.url == url }
        }
        guard let pr = found else {
            print("not in any of Desk's lists: \(url)")
            return
        }
        await model.loadConversation(pr)
        let view: AnyView
        if mode == "diff" {
            model.loadDiff(pr)
            if let thread = model.conversations[url]?.threads.first(where: { !$0.isOutdated && $0.line != nil }), let line = thread.line {
                model.diffJump = DiffJump(url: url, path: thread.path, side: thread.side, line: line)
            }
            view = AnyView(ReviewDiffScreen(pr: pr, model: model) {})
        } else if model.state.mine.contains(where: { $0.url == url }) {
            view = AnyView(PullRequestPage(pr: pr, model: model) {})
        } else {
            view = AnyView(ReviewPage(pr: pr, model: model, onMe: false) {})
        }
        let size = NSSize(width: 1180, height: height)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        // The diff, the checks and the avatars arrive after the page does.
        try? await Task.sleep(for: .seconds(5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
    }
}
#endif
