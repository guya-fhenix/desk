import DeskCore
import SwiftUI

/// The app's look: a dark workspace — a sidebar a shade lighter than the content, hairlines instead of boxes,
/// large page titles, pill tabs, and two-line rows whose second line is monospaced.
enum Theme {
    static let background = Color(white: 0.105)
    static let sidebar = Color(white: 0.135)
    /// Pills, cards, inputs and key caps.
    static let raised = Color(white: 0.165)
    /// The chosen sidebar item and pill.
    static let selected = Color(white: 0.205)
    static let line = Color(white: 0.2)
    static let accent = Color(red: 0.24, green: 0.51, blue: 0.97)
    /// The selected list row, with an accent bar down its left edge.
    static let rowSelected = Color(red: 0.09, green: 0.14, blue: 0.23)
    static let sidebarWidth: CGFloat = 212
    /// The content's side margins.
    static let gutter: CGFloat = 32
}

/// A key as the reference app draws one: a small rounded cap with the key in it.
struct KeyCap: View {
    var key: String

    var body: some View {
        Text(key)
            .scaled(.footnote.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
    }
}

/// The top of every screen: a large title, what sits beside it on the right, and a hairline under both.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(title).scaled(.size(22).weight(.semibold))
                if let subtitle { Text(subtitle).scaled(.callout).foregroundStyle(.secondary) }
                Spacer()
                trailing
            }
            .padding(.bottom, 12)
            Hairline()
        }
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

/// What a screen's header carries on the right: the details panel's switch, on the screens that have one.
struct HeaderControls: View {
    var inspector: String?

    var body: some View {
        if let inspector { InspectorToggle(key: inspector) }
    }
}

/// Shows and hides a screen's details panel. Reads the same remembered flag the panel does.
struct InspectorToggle: View {
    @AppStorage private var shown: Bool

    init(key: String) {
        _shown = AppStorage(wrappedValue: true, "inspector.\(key)")
    }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "sidebar.trailing")
                .foregroundStyle(shown ? .primary : .secondary)
                .frame(width: 28, height: 24)
                .background(Theme.raised, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(shown ? "Hide the details panel" : "Show the details panel")
    }
}

/// The row of tabs under a page title, each a pill with its count.
struct PillTabs<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: String
        var count: Int?
    }

    var options: [Option]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let chosen = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 6) {
                        Text(option.title)
                        if let count = option.count {
                            Text("\(count)").scaled(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(chosen ? Theme.selected : Color.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The line between the page header and the list: tabs and filters on the left, search and sort on the right.
struct FilterBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 12)
    }
}

/// A group's name and count over its rows, the way the reference app heads "Ready to merge".
struct GroupHeader: View {
    var title: String
    var count: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).scaled(.callout).foregroundStyle(.secondary)
                Spacer()
                if let count { Text("\(count)").scaled(.callout).monospacedDigit().foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Hairline()
        }
    }
}

/// One row of a list screen: a hairline under it, and the selected one tinted with a bar down its left edge.
/// A click anywhere that is not a button selects it; a double-click runs `open`.
struct ListRow<Content: View>: View {
    var selected = false
    var select: (() -> Void)?
    var open: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.rowSelected : Color.clear)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(Theme.accent).frame(width: 2) }
            }
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
            // Alongside the single click rather than ahead of it, so selecting never waits out a double-click.
            .simultaneousGesture(TapGesture(count: 2).onEnded { open?() })
            .onTapGesture { select?() }
    }
}

/// The monospaced second line of a row: its parts joined by middle dots.
struct MetaLine: View {
    var parts: [Text]

    var body: some View {
        parts.enumerated().reduce(Text("")) { line, part in
            part.offset == 0 ? part.element : line + Text("  ·  ").foregroundColor(.secondary) + part.element
        }
        .scaled(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// A GitHub account's picture, or its initial while it loads or when there is none.
struct Avatar: View {
    var login: String
    private let scale = AppTextStyle.scale

    var body: some View {
        Group {
            if let image = AvatarStore.shared.images[login] {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(login.prefix(1).uppercased())
                    .scaled(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.raised)
            }
        }
        .frame(width: (28 * scale).rounded(), height: (28 * scale).rounded())
        .clipShape(Circle())
        .help(login)
        .task(id: login) { AvatarStore.shared.load(login) }
    }
}

/// Every GitHub picture, loaded once for the whole app and kept, so each row by the same person shows the same
/// one. A per-row loader gave up for good when a list redraw cancelled it mid-download, which is how one row of
/// an author got the picture and the next only the initial. The download here belongs to no row, so a redraw
/// cannot cancel it, and a failed one is tried again a few minutes later, the next time a row asks.
@MainActor
@Observable
final class AvatarStore {
    static let shared = AvatarStore()

    private(set) var images: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private var failedAt: [String: Date] = [:]

    func load(_ login: String) {
        guard images[login] == nil, !loading.contains(login),
              failedAt[login].map({ Date().timeIntervalSince($0) > 300 }) ?? true,
              let url = URL(string: "https://github.com/\(login).png?size=64")
        else { return }
        loading.insert(login)
        Task {
            defer { loading.remove(login) }
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) {
                images[login] = image
            } else {
                failedAt[login] = Date()
            }
        }
    }
}

/// A search field drawn as one of the reference app's boxed inputs.
struct SearchBox: View {
    var prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 240)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }
}

/// What a table's column headers used to do: pick the column to sort by, and pick it again to turn the order.
struct SortMenu<Value>: View {
    var sort: TableSort<Value>
    @Binding var order: [KeyPathComparator<Value>]

    var body: some View {
        let current = order.first
        let currentName = current.flatMap { comparator in sort.columns.first { $0.template.keyPath == comparator.keyPath }?.name }
        Menu {
            ForEach(sort.columns.indices, id: \.self) { index in
                let column = sort.columns[index]
                Button {
                    var next = column.template
                    if current?.keyPath == column.template.keyPath { next.order = current?.order == .forward ? .reverse : .forward }
                    order = [next]
                } label: {
                    if currentName == column.name {
                        Label(column.name.capitalized, systemImage: current?.order == .reverse ? "arrow.down" : "arrow.up")
                    } else {
                        Text(column.name.capitalized)
                    }
                }
            }
        } label: {
            MenuBox(
                title: "Sort", value: currentName?.capitalized ?? "Default",
                icon: currentName == nil ? nil : current?.order == .reverse ? "arrow.down" : "arrow.up"
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The face of a filter or sort menu in a screen's header: what it sets, in grey, then its value, in a box.
struct MenuBox: View {
    var title: String
    var value: String
    var icon: String? = "chevron.down"

    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(value)
            if let icon { Image(systemName: icon).scaled(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The details panel's body: plain sections on the window's own background, in place of a grouped form's cards.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .labeledContentStyle(PanelRowStyle())
    }
}

/// One part of a details panel, headed the way the reference app heads "Quick actions".
struct PanelSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title { Text(title).scaled(.callout.weight(.medium)).foregroundStyle(.secondary) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label on the left and its value on the right, the way a form row reads.
struct PanelRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label.foregroundStyle(.secondary)
            Spacer(minLength: 8)
            configuration.content
        }
    }
}

/// The sidebar column both the workspace and Settings use: room for the window buttons at the top, the items,
/// and the sync status pinned at the bottom.
struct SidebarColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
            Spacer(minLength: 12)
            SidebarStatus()
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.ignoresSafeArea())
    }
}

/// A small grey heading over a group of sidebar items.
struct SidebarHeading: View {
    var title: String

    var body: some View {
        Text(title).scaled(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
    }
}

/// One sidebar item: icon and title, with a count or a key on the right, and a rounded fill when chosen.
struct SidebarItem<Trailing: View>: View {
    var title: String
    var icon: String
    var selected = false
    var action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                Text(title).foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: 4)
                trailing
            }
            .scaled(.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

extension SidebarItem where Trailing == EmptyView {
    init(title: String, icon: String, selected: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, icon: icon, selected: selected, action: action) { EmptyView() }
    }
}

/// Pinned under the sidebar: the sync pill, which refreshes every source at once, what is running, and one dot
/// per source, which says on its own whether each answered.
struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RefreshControl()
            if let running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(running).scaled(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            SourceDots()
        }
        .padding(.horizontal, 10)
    }

    private var running: String? {
        let reviews = model.busyReviews.count
        let sessions = model.state.claudeJobs.count { $0.isRunning }
        var parts: [String] = []
        if reviews > 0 { parts.append("\(reviews) \(reviews == 1 ? "review" : "reviews")") }
        if sessions > 0 { parts.append("\(sessions) \(sessions == 1 ? "session" : "sessions")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ") + " running"
    }
}

/// The strip along the bottom of a screen naming its keys, as the reference app does.
struct KeyHints: View {
    var hints: [(keys: [String], label: String)]

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 18) {
                ForEach(hints.indices, id: \.self) { index in
                    HStack(spacing: 4) {
                        ForEach(hints[index].keys, id: \.self) { KeyCap(key: $0) }
                        Text(hints[index].label).scaled(.caption).foregroundStyle(.secondary).padding(.leading, 2)
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A screen of the workspace: header and filters at the top, a scrolling body under them, in the content's
/// margins.
struct Screen<Header: View, Body: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }
}
