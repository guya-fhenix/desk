import SwiftUI

/// One of the app's text styles, held as a point size rather than a `Font` so the text-size control can
/// multiply it.
///
/// SwiftUI's semantic fonts cannot be scaled here. `Font.caption` carries no size to read back and
/// multiply, and macOS has no Dynamic Type to do it for us — `dynamicTypeSize` renders identically at
/// every setting, accessibility sizes included, measured. So the styles are restated with the sizes
/// `NSFont.preferredFont(forTextStyle:)` reports on macOS, and every call site asks for one of these
/// instead of a `Font`. The chaining mirrors `Font`'s, so `.caption.weight(.semibold)` still reads the
/// way it did.
struct AppTextStyle: Equatable {
    var size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default

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

    func font(scale: Double) -> Font { .system(size: size * scale, weight: weight, design: design) }
}

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    /// What the toolbar's − and + buttons are set to. Read by `scaled(_:)` and by the handful of fixed
    /// heights and widths that have to grow with the text sitting in them.
    var textScale: Double {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

extension View {
    /// The app's text, at the size the user asked for. Stands in for `.font(...)` everywhere, because
    /// `.font(.caption)` is a size nobody can change afterwards.
    func scaled(_ style: AppTextStyle) -> some View { modifier(ScaledFont(style: style)) }

    /// Scales everything below: the styles `scaled(_:)` applies, and the default font that unstyled text,
    /// button titles and table cells fall back on.
    func textScale(_ scale: Double) -> some View {
        environment(\.textScale, scale)
            .environment(\.font, AppTextStyle.body.font(scale: scale))
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.textScale) private var scale
    var style: AppTextStyle

    func body(content: Content) -> some View { content.font(style.font(scale: scale)) }
}
