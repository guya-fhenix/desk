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
    /// The whole app's text, and the few widths and heights that hold text, at this multiple of macOS's own
    /// sizes: 14 pt body text, the reference app's size.
    static let scale: CGFloat = 1.08

    var size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default

    /// Keys: the smallest text in the app.
    static let footnote = AppTextStyle(size: 9)
    static let caption2 = AppTextStyle(size: 10, weight: .medium)
    static let caption = AppTextStyle(size: 10)
    static let subheadline = AppTextStyle(size: 11)
    static let callout = AppTextStyle(size: 12)
    static let body = AppTextStyle(size: 13)
    static let headline = AppTextStyle(size: 13, weight: .bold)
    static let title3 = AppTextStyle(size: 15)
    /// The diff's code font. Its row height scales with it, or the lines would overlap.
    static let code = AppTextStyle(size: 11.5, design: .monospaced)

    /// A one-off size, for the few places that never used a text style to begin with.
    static func size(_ size: CGFloat) -> AppTextStyle { AppTextStyle(size: size) }

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
    var font: Font { .system(size: (size * Self.scale).rounded(), weight: weight, design: design) }
}

extension View {
    /// The app's text, in one of its styles. Stands in for `.font(...)` everywhere, because `.font(.caption)`
    /// is macOS's size, not the app's.
    func scaled(_ style: AppTextStyle) -> some View { font(style.font) }

    /// The default font that unstyled text, button titles and fields fall back on.
    func appFont() -> some View { environment(\.font, AppTextStyle.body.font) }
}
