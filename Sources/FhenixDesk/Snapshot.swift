#if DEBUG
import AppKit
import DeskCore
import ScreenCaptureKit
import SwiftUI

/// Draws a PR's page, or its review diff at its first open thread, off screen into a PNG, with live data, as the app
/// shows it: `FhenixDesk --snapshot <pr url> <out.png> [page|diff] [height] [dark]`. `--snapshot window <tab> <out.png>
/// [height] [dark]` draws the whole Desk window on one of its screens instead. For checking a view without driving the
/// window. Debug builds only.
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
        if arguments.first == "window" {
            await window(Array(arguments.dropFirst()))
            return
        }
        guard arguments.count >= 2 else {
            print("usage: --snapshot <pr url> <out.png> [page|diff] [height] [dark]")
            return
        }
        let (url, out) = (arguments[0], arguments[1])
        let mode = arguments.count > 2 ? arguments[2] : "page"
        let height = arguments.count > 3 ? CGFloat(Double(arguments[3]) ?? 2400) : 2400
        appearance(arguments)
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
        await capture(view, size: NSSize(width: 1180, height: height), to: out)
    }

    /// The whole window, sidebar and screen, on a tab or Settings, once every source has answered. The terminal panel
    /// is left out: it only shows with a session in it.
    private static func window(_ arguments: [String]) async {
        let screen = arguments.first ?? ""
        guard arguments.count >= 2, screen == "settings" || DeskWindow.Tab(rawValue: screen) != nil else {
            print("usage: --snapshot window <upNext|pullRequests|reviews|tickets|settings> <out.png> [height] [dark]")
            return
        }
        let height = arguments.count > 2 ? CGFloat(Double(arguments[2]) ?? 720) : 720
        appearance(arguments)
        let model = AppModel()
        model.showingSetup = false
        model.showingSettings = screen == "settings"
        model.pendingTab = DeskWindow.Tab(rawValue: screen)
        for _ in 0..<120 where Set(model.state.lastRefresh.keys).union(model.state.errors.keys).count < Source.allCases.count {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let size = NSSize(width: 1180, height: height)
        await capture(DeskWindow().handButtons().environment(model), size: size, to: arguments[1], titled: true)
    }

    private static func appearance(_ arguments: [String]) {
        if arguments.contains("dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("light") { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
    }

    /// `titled` draws it in a window like the app's, title bar and all, as the window server composites it: drawing the
    /// views themselves leaves out the system's materials, such as the inspector's. Otherwise the view alone.
    private static func capture(_ view: some View, size: NSSize, to out: String, titled: Bool = false) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = OffscreenWindow(
            contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
            styleMask: titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless],
            backing: .buffered, defer: false
        )
        if titled {
            window.title = "Fhenix Desk"
            // As `.hiddenTitleBar` draws it: the window's buttons over the sidebar, and no title.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            host.sceneBridgingOptions = .all
        }
        window.contentView = host
        window.orderFrontRegardless()
        // The diff, the checks and the avatars arrive after the page does.
        try? await Task.sleep(for: .seconds(5))
        var image: CGImage?
        // With the screen locked a capture fails now and then, so it is tried a few times.
        for _ in 0..<(titled ? 10 : 0) where image == nil {
            image = try? await composited(window)
            if image == nil { try? await Task.sleep(for: .seconds(1)) }
        }
        if image == nil {
            // The window's frame, so its buttons and toolbar come out too.
            let view = titled ? window.contentView?.superview ?? host : host
            if titled {
                print("can't capture the window (is the screen locked?): drawing its views, without the system's materials or forms")
            }
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            rep.map { view.cacheDisplay(in: view.bounds, to: $0) }
            image = rep?.cgImage
        }
        guard let png = image.flatMap({ NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }),
              (try? png.write(to: URL(fileURLWithPath: out))) != nil else {
            print("couldn't draw \(out)")
            return
        }
        print("wrote \(out)")
    }

    /// The window as the window server composites it, from wherever it is.
    private static func composited(_ window: NSWindow) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let shared = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: shared)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// A titled window stays where it is put, off every screen, instead of being pulled back onto one.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
#endif
