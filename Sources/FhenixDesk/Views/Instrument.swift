import DeskCore
import SwiftUI

// Instrument's building blocks, as the redesign's boards draw them: the uppercase section label, the two buttons, the
// details column on the right, label and value rows, the key hints under a list, and a list row's stage chip and age.

/// "NEEDS YOU · 3": 11 pt semibold, uppercase, spaced, quiet.
struct SectionLabel: View {
    var text: String
    var count: Int?
    /// Quiet, or red over a group that waits on you.
    var tone = Theme.quiet

    init(_ text: String, count: Int? = nil, tone: Color = Theme.quiet) {
        self.text = text
        self.count = count
        self.tone = tone
    }

    var body: some View {
        Text(count.map { "\(text) · \($0)" } ?? text)
            .textCase(.uppercase)
            .scaled(.caption.weight(.semibold))
            .tracking(0.44)
            .foregroundStyle(tone)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Instrument's buttons: the primary one filled with the accent and white text, the rest outlined in the control colour.
struct DeskButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    enum Size { case small, regular, large }
    var kind: Kind = .secondary
    var size: Size = .regular
    var wide = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let height: CGFloat = size == .small ? 28 : size == .regular ? 32 : 36
        let radius: CGFloat = size == .small ? 6 : size == .regular ? 7 : 8
        configuration.label
            .scaled(size == .small ? .secondary.weight(.medium) : .body.weight(kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, size == .small ? 10 : kind == .primary ? 14 : 12)
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(height: height)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                if kind == .secondary { RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.control) }
            }
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.quiet }
        return kind == .primary ? .white : Theme.ink
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return isEnabled ? (pressed ? Theme.accent.opacity(0.85) : Theme.accent) : Theme.inset
        case .secondary: return pressed ? Theme.inset : Theme.surface
        case .quiet: return pressed ? Theme.inset : .clear
        }
    }
}

extension ButtonStyle where Self == DeskButtonStyle {
    static var desk: DeskButtonStyle { DeskButtonStyle() }
    static var deskPrimary: DeskButtonStyle { DeskButtonStyle(kind: .primary) }
    static func desk(_ kind: DeskButtonStyle.Kind = .secondary, _ size: DeskButtonStyle.Size = .regular, wide: Bool = false) -> DeskButtonStyle {
        DeskButtonStyle(kind: kind, size: size, wide: wide)
    }
}

/// A primary button's key, after its title: "Start review ↩".
struct ButtonKey: View {
    var key: String

    var body: some View { Text(key).scaled(.caption.monospaced()).opacity(0.85) }
}

/// The white column on the right of a list screen: what the selected row is, in full, and its presses at the foot.
struct DetailColumn<Content: View>: View {
    var width: CGFloat = 360
    @ViewBuilder var content: Content
    @Environment(\.textScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 22) { content }
            .padding(EdgeInsets(top: 18, leading: 22, bottom: 16, trailing: 22))
            .frame(width: width * scale, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.rule).frame(width: 1) }
    }
}

/// A PR's name in a list, as its stack reads: a PR built on another shown above it sits a step in per level, with a turn
/// and its number alone, its repo being its parent's. A root, or a PR alone, has its whole name.
struct StackRef: View {
    var pr: PullRequest
    /// How many of the PRs it is built on show above it (`Linker.depths`).
    var depth: Int
    /// The name a root shows: `cofhe-contracts #175`, `cofhe #1154`.
    var name: String

    var body: some View {
        HStack(spacing: 4) {
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.quiet)
                    .padding(.leading, CGFloat(depth - 1) * 14)
                    .accessibilityLabel("stacked on the one above")
                Text(verbatim: "#\(pr.number)")
            } else {
                Text(verbatim: name)
            }
        }
        .lineLimit(1)
    }
}

/// The top of a details column: a quiet line of what it is, its title, and a sentence under it.
struct DetailHeader: View {
    var kicker: String
    var title: String
    var summary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kicker).scaled(.secondary).foregroundStyle(Theme.quiet)
            Text(title).scaled(.heading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let summary { Text(summary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Label and value rows: the label quiet in a fixed column, the value beside it.
struct FieldRows<Content: View>: View {
    var labelWidth: CGFloat = 88
    @ViewBuilder var content: Content
    @Environment(\.textScale) private var scale

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) { content }
            .environment(\.fieldLabelWidth, labelWidth * scale)
    }
}

struct FieldRow<Value: View>: View {
    var label: String
    /// The value in DM Mono, at the app's scale.
    var mono = false
    @ViewBuilder var value: Value
    @Environment(\.fieldLabelWidth) private var width

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(Theme.quiet).frame(width: width, alignment: .leading)
            Group { if mono { value.scaled(.code) } else { value } }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension FieldRow where Value == Text {
    init(_ label: String, _ value: String, mono: Bool = false) {
        self.init(label: label, mono: mono) { Text(value) }
    }
}

extension EnvironmentValues {
    @Entry var fieldLabelWidth: CGFloat = 88
}

/// A titled run of rows under an uppercase label, each with a hairline over it and the last with one under.
struct RuledList<Content: View>: View {
    var title: String
    var count: Int?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title, count: count).padding(.bottom, 6)
            content
            Rectangle().fill(Theme.ruleSoft).frame(height: 1)
        }
    }
}

/// One row of a `RuledList`: a hairline over it, at least 34 pt tall.
struct RuledRow<Content: View>: View {
    var minHeight: CGFloat = 34
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
    }
}

/// Under a list, the keys that work on it: "J K move · ↩ open".
struct KeyHints: View {
    var hints: [(keys: [String], label: String)]
    var trailing: String?

    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 4) {
                    ForEach(hint.keys, id: \.self) { InstrumentKey(key: $0) }
                    Text(hint.label)
                }
            }
            Spacer(minLength: 8)
            if let trailing { Text(trailing) }
        }
        .scaled(.secondary)
        .foregroundStyle(Theme.quiet)
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 0, trailing: 10))
        .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// A key cap as Instrument draws it: DM Mono on white, in a control-coloured outline.
struct InstrumentKey: View {
    var key: String

    var body: some View {
        Text(key)
            .scaled(.caption.monospaced())
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .frame(minWidth: 18)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.control))
    }
}

/// A stage chip: "Review", "Draft", "On you" — 11 pt medium on the chip colour, or on white over a tinted row.
struct StageChip2: View {
    var text: String
    var onTint = false
    var color: Color?

    var body: some View {
        Text(text)
            .scaled(.caption.weight(.medium))
            .foregroundStyle(color ?? Theme.ink)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.map { $0.opacity(0.14) } ?? (onTint ? Theme.chipOn : Theme.chip), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

/// An age in DM Mono, right-aligned in a fixed column so the ages line up down a list.
struct AgeText: View {
    var date: Date?

    var body: some View {
        Text(Format.age(date)).scaled(.code).foregroundStyle(Theme.quiet).scaledFrame(width: 34, alignment: .trailing)
            .help(Format.date(date))
    }
}

/// The page's title with the quiet line beside it: "Focus  Monday 16 November".
struct ScreenTitle<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).scaled(.title).tracking(-0.3)
                if let subtitle { Text(subtitle).foregroundStyle(Theme.quiet).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 32)
    }
}

extension ScreenTitle where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Instrument's segmented control: a track in the inset colour, the chosen segment on white.
struct Segmented<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: String
        var count: Int?
    }

    var options: [Option]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 6) {
                        Text(option.title)
                        if let count = option.count { Text("\(count)").scaled(.caption.monospaced()) }
                    }
                    .scaled(on ? .body.weight(.medium) : .body)
                    .foregroundStyle(on ? Theme.ink : Theme.quiet)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(on ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .shadow(color: on ? .black.opacity(0.08) : .clear, radius: 1, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }
}

extension Date {
    /// "17:31".
    var clock: String { formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
}
