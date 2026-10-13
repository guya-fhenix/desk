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

    // Five roles, as they render at `scale`: title 24, headline 15, body 14, secondary 12, caption 11 — so a view
    // has a few sizes to choose from rather than ten. The older names stay as aliases of the role they now are.
    // Sizes and weights follow PR Cockpit's: its page title, row title, meta line and badges are these.

    /// Page titles and the big numbers.
    static let title = AppTextStyle(size: 22.25, weight: .medium)
    /// Section and panel titles; `title3` is the same size, its weight set where it is used.
    static let headline = AppTextStyle(size: 14, weight: .semibold)
    static let title3 = AppTextStyle(size: 14)
    static let body = AppTextStyle(size: 13)
    /// A list row's title: body size, medium, so it leads the line of facts under it.
    static let rowTitle = AppTextStyle(size: 13, weight: .medium)
    /// Secondary text: group headers, notes, counts.
    static let secondary = AppTextStyle(size: 11)
    static let subheadline = secondary
    static let callout = secondary
    /// The smallest text, key caps included.
    static let caption = AppTextStyle(size: 10)
    static let caption2 = AppTextStyle(size: 10, weight: .medium)
    /// Code, at the secondary size. A diff's row height scales with it, or the lines would overlap.
    static let code = AppTextStyle(size: 11, design: .monospaced)

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

    /// Rounded to a whole point: a fractional size (15.6, 14.4) puts glyph edges between pixels, which reads as
    /// soft text on a 1× display such as an external monitor without Retina scaling.
    func font(scale: CGFloat) -> Font { .system(size: (size * scale).rounded(), weight: weight, design: design) }
}

extension EnvironmentValues {
    /// The app's text, and the few widths and heights that hold text, at this multiple of macOS's own sizes: 14 pt
    /// body text, the reference app's size.
    @Entry var textScale: CGFloat = 1.08
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
    func appFont() -> some View { modifier(ScaledFont(style: .body)) }}
