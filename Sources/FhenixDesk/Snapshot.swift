#if DEBUG
import AppKit
import DeskCore
import ScreenCaptureKit
import SwiftUI

/// Draws a PR's page, or its review diff at its first open thread, off screen into a PNG, with live data, as the app
/// shows it: `FhenixDesk --snapshot <pr url> <out.png> [page|files|diff] [height] [dark|light|system] [running]`.
/// `--snapshot window <tab> <out.png> [height] [dark|light|system]` draws the whole Desk window on one of its screens
/// instead, and with `steps=` presses keys and moves the pointer in it first; `--snapshot popover <prefix>` clicks the menu bar item. For
/// checking a view, and its keys, without driving the window. Debug builds only.
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
        if arguments.first == "popover" {
            await popover(arguments.count > 1 ? arguments[1] : "popover")
            return
        }
        guard arguments.count >= 2 else {
            print("usage: --snapshot <pr url> <out.png> [page|files|diff] [height] [dark]")
            return
        }
        let (url, out) = (arguments[0], arguments[1])
        let mode = arguments.count > 2 ? arguments[2] : "page"
        let height = arguments.count > 3 ? CGFloat(Double(arguments[3]) ?? 2400) : 2400
        appearance(arguments)
        let model = AppModel()
        settings(model, arguments)
        appearance(arguments)
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
        // `running`: its review session running in its pane, as the panel beside the diff shows it while one runs.
        if arguments.contains("running") { model.panes.insert(PaneSpec.reviewKey(url)) }
        let view: AnyView
        if mode == "diff" {
            model.loadDiff(pr)
            if let thread = model.conversations[url]?.threads.first(where: { !$0.isOutdated && $0.line != nil }), let line = thread.line {
                model.diffJump = DiffJump(url: url, path: thread.path, side: thread.side, line: line)
            }
            view = AnyView(ReviewDiffScreen(pr: pr, model: model) {})
        } else if model.state.mine.contains(where: { $0.url == url }) {
            // `files`: your PR's page on its Files changed tab.
            view = AnyView(PullRequestPage(pr: pr, model: model, tab: mode == "files" ? .files : .conversation) {})
        } else {
            view = AnyView(ReviewPage(pr: pr, model: model, onMe: false) {})
        }
        await capture(view, size: NSSize(width: 1440, height: height), to: out)
    }

    /// The whole window, sidebar and screen, on a tab, Settings or Setup, once every source has answered. `open=<pr url>`
    /// shows that PR's page, as Search would; `pane=<appearance|master|…>` picks Settings' page and `step=<accounts|…>`
    /// Setup's. `menubar` draws the menu bar item's popover alone, 380 pt wide; `ghError=<text>` draws it, or any
    /// screen, as if GitHub's last refresh had failed with that.
    private static func window(_ arguments: [String]) async {
        let screen = arguments.first ?? ""
        let screens = ["settings", "setup", "master", "menubar"]
        guard arguments.count >= 2, screens.contains(screen) || DeskWindow.Tab(rawValue: screen) != nil else {
            print("usage: --snapshot window <upNext|pullRequests|reviews|tickets|master|settings|setup|menubar> <out.png> [height] [dark|light|system] [accent=<hex>] [open=<pr url>] [pane=<pane>] [step=<step>] [update=<current>,<latest>] [ghError=<text>] [asks=1] [steps=key:j;move:700,338;shot:<png>;report;wait:1]")
            return
        }
        func value(_ name: String) -> String? { arguments.first { $0.hasPrefix("\(name)=") }.map { String($0.dropFirst(name.count + 1)) } }
        let height = arguments.count > 2 ? CGFloat(Double(arguments[2]) ?? 720) : 720
        appearance(arguments)
        let model = AppModel()
        settings(model, arguments)
        appearance(arguments)
        model.showingSetup = false
        model.showingSettings = screen == "settings"
        model.showingMaster = screen == "master"
        model.pendingTab = DeskWindow.Tab(rawValue: screen)
        for _ in 0..<120 where Set(model.state.lastRefresh.keys).union(model.state.errors.keys).count < Source.allCases.count {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let open = arguments.first(where: { $0.hasPrefix("open=") }) { model.selectPullRequest = String(open.dropFirst(5)) }
        if let pane = value("pane").flatMap(SettingsPane.init(rawValue:)) { model.settings.pane = pane }
        // `finder=<query>`: Search (⌘K) open over the screen with that query.
        if let query = value("finder") {
            FinderView.initialQuery = query
            model.showingFinder = true
        }
        if let error = value("ghError") { model.state.errors[.github] = error }
        // `asks=1`: a question from the master, in memory only, for the screens that show one.
        if value("asks") != nil {
            model.state.asks = [MasterAsk(id: "sample", task: "PRO-650", text: "The signer options doc is written. Share it with Roee on the ticket, or keep it a draft?", askedAt: Date().addingTimeInterval(-720))]
        }
        // `steps=key:j;key:x;move:700,338;shot:<png>;report;wait:1`: keys, pointer moves, captures and the model's state,
        // run against the window before the last capture.
        let steps = value("steps").map { $0.split(separator: ";").map(String.init) } ?? []
        let report = {
            "report: finder=\(model.showingFinder) master=\(model.showingMaster) settings=\(model.showingSettings) "
                + "terminalError=\(model.terminalError ?? "none") panes=\(model.panes.sorted())"
        }
        // `update=<current>,<latest>`: the sidebar's update notice, which an unbundled build never checks for.
        if let versions = value("update")?.split(separator: ","), versions.count == 2 {
            model.update = AppUpdate.Available(current: String(versions[0]), latest: String(versions[1]))
        }
        let size = NSSize(width: value("width").flatMap(Double.init).map { CGFloat($0) } ?? 1440, height: height)
        // Drawn off screen, the split view's sidebar column comes out blank: snapshots lay the sidebar beside the screen,
        // unless `split` asks for the real split view, for how it moves.
        DeskWindow.flat = !arguments.contains("split")
        if screen == "menubar" {
            let popover = SettingsMenuBarPopover().environment(model).frame(maxHeight: .infinity, alignment: .top).background(Theme.panel)
            await capture(popover, size: NSSize(width: 380, height: height), to: arguments[1])
        } else if screen == "setup" {
            await capture(SetupView(step: value("step").flatMap(SetupStep.init(rawValue:)) ?? .tools).environment(model), size: size, to: arguments[1], titled: true)
        } else {
            await capture(DeskWindow().environment(model), size: size, to: arguments[1], titled: true, steps: steps, report: report)
        }
    }

    /// The menu bar item clicked four times with mouse events: the popover opens and is drawn, a click on the item while
    /// it shows closes it (without opening it again on the release), and the next opens it and the last closes it.
    /// Prints each state.
    private static func popover(_ prefix: String) async {
        let model = AppModel()
        for _ in 0..<120 where Set(model.state.lastRefresh.keys).union(model.state.errors.keys).count < Source.allCases.count {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let delegate = AppDelegate()
        delegate.installMenuBarItem(model: model)
        try? await Task.sleep(for: .seconds(1))
        // A click on the item, as AppKit gets one: a press and a release in the queue, so the popover's watch for clicks
        // outside it sees the press, the button tracks it, and the release sends the button's action.
        func press() {
            guard let button = delegate.statusItem?.button, let window = button.window else { return print("no menu bar item") }
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                ).map { NSApp.postEvent($0, atStart: false) }
            }
        }
        // A process that can't come forward over the user's apps never finishes a popover's animation, and AppKit holds
        // the close until it does; a real click brings the app forward first.
        func settle() async {
            try? await Task.sleep(for: .milliseconds(300))
            delegate.popover?.animates = false
            try? await Task.sleep(for: .milliseconds(700))
        }
        func state(_ when: String) { print("\(when): \(delegate.popover?.isShown == true ? "open" : "closed")") }
        press()
        await settle()
        state("a click")
        if let view = delegate.popover?.contentViewController?.view.window?.contentView { write(layerImage(of: view), "\(prefix)-open.png") }
        press()
        await settle()
        state("a second click, on the item while it shows")
        press()
        await settle()
        state("a third click")
        press()
        await settle()
        state("a fourth click")
    }

    /// `system`: Desk set to follow macOS, which a run passed `-AppleInterfaceStyle Dark` (or `Light`) takes for the
    /// system's look; `accent=<hex>`: that accent. In memory only: the config on disk stays as it is.
    private static func settings(_ model: AppModel, _ arguments: [String]) {
        if arguments.contains("system") { model.config.appearance = .system }
        let accent = arguments.first { $0.hasPrefix("accent=") }.flatMap { DeskConfig.validAccent(String($0.dropFirst(7))) }
        if let accent { model.config.accent = accent }
        if arguments.contains("system") || accent != nil { model.applyAppearance() }
    }

    private static func appearance(_ arguments: [String]) {
        if arguments.contains("dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("light") { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
    }

    /// `titled` draws it in a window like the app's, title bar and all, as the window server composites it: drawing the
    /// views themselves leaves out the system's materials, such as the inspector's. Otherwise the view alone.
    private static func capture(
        _ view: some View, size: NSSize, to out: String, titled: Bool = false, steps: [String] = [], report: (() -> String)? = nil
    ) async {
        // A titled window sizes its content the way the app's does, from the window, with the app's minimum; a fixed frame
        // on the root misleads a split view about the room it has.
        let host = titled
            ? NSHostingView(rootView: AnyView(view.frame(minWidth: 960, minHeight: 560)))
            : NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        let window = OffscreenWindow(
            contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
            styleMask: titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless],
            backing: .buffered, defer: false
        )
        if titled {
            window.title = "Fhenix Desk"
            // The view's toolbar and title go to the window, as a scene's do.
            host.sceneBridgingOptions = .all
        }
        window.contentView = host
        window.orderFrontRegardless()
        // The diff, the checks and the avatars arrive after the page does.
        try? await Task.sleep(for: .seconds(5))
        // Keys go to the focused list only in the key window.
        if !steps.isEmpty {
            window.actsKey = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            try? await Task.sleep(for: .milliseconds(500))
        }
        for step in steps { await perform(step, in: window, host: host, titled: titled, report: report) }
        write(await grab(window, host: host, titled: titled), out)
    }

    /// One harness step against the window: a key press, a pointer move, a wait, a capture, or the model's state printed.
    private static func perform(_ step: String, in window: OffscreenWindow, host: NSView, titled: Bool, report: (() -> String)?) async {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "key":
            let codes: [String: (UInt16, String)] = [
                "j": (38, "j"), "k": (40, "k"), "x": (7, "x"), "r": (15, "r"), "m": (46, "m"), "space": (49, " "),
                "return": (36, "\r"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"), "right": (124, "\u{F703}"), "escape": (53, "\u{1B}"),
            ]
            guard let (code, characters) = codes[argument] else { return print("unknown key \(argument)") }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)
                // Through the window, as a press arrives: SwiftUI's key handlers see it there before the list's own.
                event.map(window.sendEvent)
            }
            // A capture shows what it did: the list's selected row and the first responder trail SwiftUI and say nothing.
            print("key \(argument)")
        case "wait":
            try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
        case "layout":
            // With `split`: the split view's height against the window's — taller pushes the screen up under the window's
            // top — and each scroll view's frame and offset, in the window.
            func walk(_ view: NSView) {
                if let split = view as? NSSplitView {
                    print("split view \(Int(split.frame.height)) tall in a \(Int(window.contentLayoutRect.height + window.contentView!.safeAreaInsets.top)) pt window")
                } else if let scroll = view as? NSScrollView {
                    print("scroll view \(scroll.convert(scroll.bounds, to: nil).integral), scrolled to \(scroll.contentView.bounds.origin.y)")
                }
                view.subviews.forEach(walk)
            }
            window.contentView.map(walk)
        case "frames":
            // `frames:<prefix>:<n>`: n captures 50 ms apart, for what moves in between.
            let bits = argument.split(separator: ":").map(String.init)
            for index in 0..<(bits.count > 1 ? Int(bits[1]) ?? 10 : 10) {
                write(layerImage(of: titled ? window.contentView?.superview ?? host : host), "\(bits[0])-\(index).png")
                try? await Task.sleep(for: .milliseconds(50))
            }
        case "shot":
            // Always the layer tree, so a run's captures compare with each other wherever the window is.
            write(layerImage(of: titled ? window.contentView?.superview ?? host : host), argument)
        case "report":
            print(report?() ?? "report: none")
        case "move":
            let xy = argument.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { return print("move takes x,y") }
            print("pointer to \(argument): \(hover(window, at: NSPoint(x: xy[0], y: window.frame.height - xy[1])))")
        default:
            print("unknown step \(step)")
        }
        try? await Task.sleep(for: .milliseconds(700))
    }

    /// `move:x,y`, from the window's top left. The window server raises hover from the tracking areas the pointer crosses,
    /// which an app can't move the pointer over for its own window: each area under the point that the pointer wasn't in
    /// gets the entry AppKit would send, naming the area as AppKit's do, each one it was in and left gets the exit, and
    /// every area under it the move. SwiftUI's pointer bridge is among them: its area is the view's visible rect, and it
    /// isn't a responder. Returns the owners reached.
    private static func hover(_ window: OffscreenWindow, at point: NSPoint) -> String {
        guard let content = window.contentView else { return "no content" }
        var under: [(area: NSTrackingArea, view: NSView)] = []
        var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        while let current = view {
            let local = current.convert(point, from: nil)
            under += current.trackingAreas
                .filter { ($0.options.contains(.inVisibleRect) ? current.visibleRect : $0.rect).contains(local) }
                .map { ($0, current) }
            view = current.superview
        }
        let time = ProcessInfo.processInfo.systemUptime
        func send(_ selector: Selector, _ type: NSEvent.EventType, to area: NSTrackingArea) {
            guard let owner = area.owner as? NSObject, owner.responds(to: selector) else { return }
            let event = type == .mouseMoved
                ? NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
                : NSEvent.enterExitEvent(
                    with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil)
            event.map { _ = owner.perform(selector, with: $0) }
        }
        let now = under.map(\.area)
        for area in window.entered where !now.contains(where: { $0 === area }) && area.options.contains(.mouseEnteredAndExited) {
            send(#selector(NSResponder.mouseExited(with:)), .mouseExited, to: area)
        }
        for area in now where !window.entered.contains(where: { $0 === area }) && area.options.contains(.mouseEnteredAndExited) {
            send(#selector(NSResponder.mouseEntered(with:)), .mouseEntered, to: area)
        }
        for area in now where area.options.contains(.mouseMoved) { send(#selector(NSResponder.mouseMoved(with:)), .mouseMoved, to: area) }
        window.entered = now
        return under.map { String(describing: type(of: $0.view)).components(separatedBy: "<")[0] }.joined(separator: ", ")
    }

    private static func write(_ image: CGImage?, _ out: String) {
        guard let png = image.flatMap({ NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }),
              (try? png.write(to: URL(fileURLWithPath: out))) != nil else {
            print("couldn't draw \(out)")
            return
        }
        print("wrote \(out)")
    }

    /// The window as it shows now: composited by the window server where it can be, else its layer tree drawn.
    private static func grab(_ window: NSWindow, host: NSView, titled: Bool) async -> CGImage? {
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
            // The layer tree, which holds what SwiftUI draws into layers — a scroll view's content, the sidebar — that
            // `cacheDisplay` leaves blank; `cacheDisplay` where a view has no layer.
            image = layerImage(of: view) ?? {
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                rep.map { view.cacheDisplay(in: view.bounds, to: $0) }
                return rep?.cgImage
            }()
        }
        return image
    }

    /// The view's layer tree drawn into a bitmap at the screen's scale, upright.
    private static func layerImage(of view: NSView) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // A flipped view — the hosting view of a page drawn alone — draws top-down; the bitmap is bottom-up.
        if view.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        return context.makeImage()
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
    /// Key without taking focus from the app in front: the harness's keys reach SwiftUI's focused view only in a key
    /// window, and an accessory process isn't allowed to activate over the user's apps.
    var actsKey = false
    override var isKeyWindow: Bool { actsKey || super.isKeyWindow }
    /// The tracking areas a `move` step put the pointer in.
    var entered: [NSTrackingArea] = []
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

#endif
