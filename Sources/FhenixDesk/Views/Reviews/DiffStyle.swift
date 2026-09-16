import AppKit
import DeskCore
import SwiftUI

/// Diff colours as dynamic NSColors, the same technique `ChartPalette` uses, with GitHub's own values.
/// SwiftUI's `.green.opacity(…)` is unreadable in dark mode, and a diff is mostly background.
enum DiffPalette {
    static let addedRow = dynamic(light: 0xE6FF_EC, dark: 0x1226_1E)
    static let addedGutter = dynamic(light: 0xCCFF_D8, dark: 0x1B47_21)
    static let removedRow = dynamic(light: 0xFFEB_E9, dark: 0x2517_1C)
    static let removedGutter = dynamic(light: 0xFFD7_D5, dark: 0x5424_26)
    static let hunk = dynamic(light: 0xF6F8_FA, dark: 0x1C21_28)

    static func row(_ change: DiffLineKind) -> Color {
        switch change {
        case .added: return addedRow
        case .removed: return removedRow
        case .context: return .clear
        }
    }

    static func gutter(_ change: DiffLineKind) -> Color {
        switch change {
        case .added: return addedGutter
        case .removed: return removedGutter
        case .context: return .clear
        }
    }

    static func severity(_ severity: CommentSeverity) -> Color {
        switch severity {
        case .blocker: return .red
        case .major: return .orange
        case .minor: return .blue
        case .nit: return .secondary
        case .question: return .purple
        }
    }

    static func state(_ state: CommentState) -> Color {
        switch state {
        case .pending: return .orange
        case .approved: return .green
        case .rejected: return .secondary
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
        })
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: 1
        )
    }
}

enum DiffMetrics {
    /// Uniform, so the lazy stack's offset estimates stay exact and `scrollTo` lands where it says.
    /// These are the sizes at 100%; every use multiplies by the window's text scale, because the code
    /// sitting in them does too. `AppTextStyle.code` is the font itself.
    static let rowHeight: CGFloat = 16
    static let numberWidth: CGFloat = 38
    static let gutterWidth: CGFloat = 88
    /// Fixed, not `maxWidth`: a horizontally scrollable ScrollView proposes infinite width, and a
    /// wrapping Text given that never wraps — it renders on one line and drags the content width out
    /// to thousands of points.
    static let commentWidth: CGFloat = 620
    static let headerHeight: CGFloat = 26
    /// Files longer than this start folded, and on a very large diff so does anything without a comment.
    static let autoFoldLines = 600
    static let largeDiffRows = 3_000

    /// Measured rather than assumed: a monospaced advance is not the point size.
    static let charWidth: CGFloat = NSAttributedString(
        string: "0", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)]
    ).size().width
}

/// Scroll targets are their own type: `scrollTo` matches ForEach ids too, and both rows and files are
/// keyed by Int, so a bare number would be ambiguous.
enum DiffAnchor: Hashable {
    case file(Int)
    case comment(UUID)
}

/// The nonce is what makes clicking the same file twice fire `onChange` again. It is also why this is a
/// plain value and not a Binding: a Binding never compares equal, which would defeat `.equatable()` on
/// the diff pane and give back the 30-second re-render this design exists to avoid.
struct DiffScrollTarget: Equatable {
    var anchor: DiffAnchor
    var fileID: Int
    var nonce: Int
}
