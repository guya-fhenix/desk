import AppKit
import DeskCore
import SwiftUI

/// One of the app's text styles, held as a point size rather than a `Font` so every size can be set at
/// `scale` times the system's.
///
/// SwiftUI's semantic fonts cannot be scaled. `Font.caption` carries no size to read back and
/// multiply, and macOS has no Dynamic Type to do it for us — `dynamicTypeSize` renders identically at
/// every setting, accessibility sizes included, measured. So the styles are restated with the sizes
/// `NSFont.preferredFont(forTextStyle:)` reports on macOS, and every call site asks for one of these
/// instead of a `Font`. The chaining mirrors `Font`'s, so `.caption.weight(.semibold)` still reads the
/// way it did.
struct AppTextStyle: Equatable {
    var size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default

    // Instrument's roles, in Instrument Sans with identifiers in DM Mono: title 20, heading 17 (the details column's
    // title), headline 15, body 13.5, secondary 12, caption 11 — the sizes the redesign's boards use. A different weight
    // is set where it is used.

    /// Page titles.
    static let title = AppTextStyle(size: 20, weight: .semibold)
    /// The details column's title.
    static let heading = AppTextStyle(size: 17, weight: .semibold)
    /// Section and panel titles.
    static let headline = AppTextStyle(size: 15, weight: .semibold)
    static let body = AppTextStyle(size: 13.5)
    /// A list row's title: body size, medium, so it leads the line of facts under it.
    static let rowTitle = AppTextStyle(size: 13.5, weight: .medium)
    /// Secondary text: notes, counts, the line under a row's title.
    static let secondary = AppTextStyle(size: 12)
    /// The smallest text: key caps, chips, section labels.
    static let caption = AppTextStyle(size: 11)
    /// Code and identifiers. A diff's row height scales with it, or the lines would overlap.
    static let code = AppTextStyle(size: 12, design: .monospaced)

    func weight(_ weight: Font.Weight) -> Self {
        var copy = self
        copy.weight = weight
        return copy
    }

    func monospaced() -> Self {
        var copy = self
        copy.design = .monospaced
        return copy
    }

    /// Instrument Sans, or DM Mono for the monospaced design, at half-point steps: 13.5 is the boards' body size. A face
    /// that did not register falls back to the system's.
    func font(scale: CGFloat) -> Font {
        let points = (size * scale * 2).rounded() / 2
        let family = design == .monospaced ? AppFonts.mono : AppFonts.sans
        return .custom(family, fixedSize: points).weight(weight)
    }
}

extension EnvironmentValues {
    /// The app's text, and the few widths and heights that hold text, at this multiple of the boards' sizes.
    @Entry var textScale: CGFloat = 1
}

private struct ScaledFont: ViewModifier {
    @Environment(\.textScale) private var scale
    var style: AppTextStyle

    func body(content: Content) -> some View { content.font(style.font(scale: scale)) }
}

extension View {
    /// The app's text, in one of its styles. Stands in for `.font(...)` everywhere, because `.font(.caption)`
    /// is macOS's size, not the app's.
    func scaled(_ style: AppTextStyle) -> some View { modifier(ScaledFont(style: style)) }

    /// The default font that unstyled text, button titles and fields fall back on.
    func appFont() -> some View { modifier(ScaledFont(style: .body)) }

    /// A fixed frame for text — a column of keys, a details column — that grows with the app's text.
    func scaledFrame(width: CGFloat, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(ScaledFrame(width: width, height: height, alignment: alignment))
    }
}

private struct ScaledFrame: ViewModifier {
    @Environment(\.textScale) private var scale
    var width: CGFloat
    var height: CGFloat?
    var alignment: Alignment

    func body(content: Content) -> some View {
        content.frame(width: width * scale, height: height.map { $0 * scale }, alignment: alignment)
    }
}

/// Tells its view the screen its window is on: when the window shows, when it moves to another screen, and when the
/// screens change. Not while the window is on none.
struct ScreenReader: NSViewRepresentable {
    var changed: @MainActor (NSScreen) -> Void

    func makeNSView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: ScreenView, context: Context) { view.changed = changed }

    final class ScreenView: NSView {
        var changed: (@MainActor (NSScreen) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let report: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { if let self, let screen = self.window?.screen { self.changed?(screen) } }
            }
            observers = [
                NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main, using: report),
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: report),
            ]
            if let screen = window.screen { changed?(screen) }
        }
    }
}
