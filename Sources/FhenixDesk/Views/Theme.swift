import DeskCore
import SwiftUI

/// The app's look: a workspace in the system's appearance — a sidebar a shade off the content, hairlines instead of
/// boxes, large page titles, pill tabs, and two-line rows whose second line is monospaced. Every colour has a light,
/// a dark, and an Increase Contrast version of each, so the app follows System Settings rather than overriding it.
enum Theme {
    static let background = gray(light: 0.98, dark: 0.105, lightContrast: 1, darkContrast: 0)
    static let sidebar = gray(light: 0.94, dark: 0.135, lightContrast: 0.96, darkContrast: 0.08)
    /// Pills, cards, inputs and key caps.
    static let raised = gray(light: 0.92, dark: 0.165, lightContrast: 0.9, darkContrast: 0.2)
    /// The chosen sidebar item and pill.
    static let selected = gray(light: 0.86, dark: 0.205, lightContrast: 0.8, darkContrast: 0.3)
    static let line = gray(light: 0.85, dark: 0.2, lightContrast: 0.55, darkContrast: 0.45)
    /// The edge of a control — an input, a menu box, a tile — at 3:1 against the background, where a hairline would
    /// leave the control's shape to guesswork.
    static let controlBorder = gray(light: 0.55, dark: 0.42, lightContrast: 0.3, darkContrast: 0.65)
    /// Dark enough that white text on it clears 4.5:1, for the filled buttons — in either appearance.
    static let accent = Color(red: 0.16, green: 0.42, blue: 0.85)
    /// The selected list row, with an accent bar down its left edge.
    static let rowSelected = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(red: 0.09, green: 0.14, blue: 0.23, alpha: 1)
            : NSColor(red: 0.86, green: 0.91, blue: 0.98, alpha: 1)
    })

    /// A grey that resolves per appearance: light, dark, and each with Increase Contrast on.
    private static func gray(light: CGFloat, dark: CGFloat, lightContrast: CGFloat, darkContrast: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: return NSColor(white: dark, alpha: 1)
            case .accessibilityHighContrastDarkAqua?: return NSColor(white: darkContrast, alpha: 1)
            case .accessibilityHighContrastAqua?: return NSColor(white: lightContrast, alpha: 1)
            default: return NSColor(white: light, alpha: 1)
            }
        })
    }
    /// The spacing scale, on a 4 pt grid: every gap and padding in the shared components is one of these.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    static let sidebarWidth: CGFloat = 212
    /// The content's side margins.
    static let gutter = Space.xxl
}

/// A key as the reference app draws one: a small rounded cap with the key in it.
struct KeyCap: View {
    var key: String

    var body: some View {
        Text(key)
            .scaled(.caption.monospaced())
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
                Text(title).scaled(.title)
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
        .accessibilityLabel("Details panel")
        .accessibilityValue(shown ? "Shown" : "Hidden")
    }
}

/// The row of tabs under a page title, each a pill with its count.
struct PillTabs<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: String
        var count: Int?
        /// The key that reaches this pill from the keyboard, drawn as a key cap after the count.
        var hint: String? = nil
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
                        Text(option.title).scaled(.body.weight(.medium)).foregroundStyle(chosen ? .primary : .secondary)
                        if let count = option.count {
                            Text("\(count)").scaled(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if let hint = option.hint { KeyCap(key: hint).accessibilityHidden(true) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    // The chosen pill is told apart by more than a shade of grey: an accent fill and edge.
                    .background(chosen ? Theme.accent.opacity(0.25) : Color.clear, in: Capsule())
                    .hoverFill(cornerRadius: 100, enabled: !chosen)
                    .overlay(Capsule().strokeBorder(chosen ? Theme.accent : Theme.controlBorder))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }
}

/// The line between the page header and the list: tabs and filters on the left, search and sort on the right.
struct FilterBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            leading
            Spacer(minLength: Theme.Space.m)
            trailing
        }
        .padding(.vertical, Theme.Space.m)
    }
}

/// A group's name and count over its rows, the way the reference app heads "Ready to merge".
struct GroupHeader: View {
    var title: String
    var count: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).scaled(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if let count { Text("\(count)").scaled(.callout).monospacedDigit().foregroundStyle(.secondary) }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
            Hairline()
        }
    }
}

/// One row of a list screen: a hairline under it, and the selected one tinted with a bar down its left edge.
/// It sits in a `List(selection:)`, which is what selects it — on a click or the arrow keys — and runs the
/// screen's primary action on a double-click or Return; the row only keeps the app's look.
struct ListRow<Content: View>: View {
    var selected = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, Theme.Space.m)
            // About PR Cockpit's: two lines of text with room above and below, not packed edge to edge.
            .padding(.vertical, Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverFill(Theme.raised.opacity(0.6), cornerRadius: 0, enabled: !selected)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(Theme.accent).frame(width: 2) }
            }
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
            // One element per row for VoiceOver, its buttons still reachable as actions.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .plainListRow(background: selected ? Theme.rowSelected : Color.clear)
    }
}

/// A fill under whatever the pointer is over, so a row or a button shows it can be pressed before it is.
private struct HoverFill: ViewModifier {
    var color: Color
    var cornerRadius: CGFloat
    var enabled: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(enabled && hovering ? color : Color.clear, in: RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Selects `first` whenever nothing is selected: when rows arrive after the screen does, and when a click
    /// clears the list's selection, so the details panel never sits on an empty column.
    func selectsFirstRow(_ first: String?, selection: Binding<String?>) -> some View {
        onChange(of: [first, selection.wrappedValue], initial: true) {
            if selection.wrappedValue == nil, let first { selection.wrappedValue = first }
        }
    }

    func hoverFill(_ color: Color = Theme.raised, cornerRadius: CGFloat = 6, enabled: Bool = true) -> some View {
        modifier(HoverFill(color: color, cornerRadius: cornerRadius, enabled: enabled))
    }

    /// Drops the list's own insets and separator, so a row draws edge to edge with the app's hairlines.
    func plainListRow(background: Color = .clear) -> some View {
        listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(background)
    }

    /// A list screen's `List`: plain, on the window's own background, rows as short as their content.
    func deskList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
    }
}

/// The monospaced second line of a row: its parts joined by middle dots.
struct MetaLine: View {
    var parts: [Text]

    var body: some View {
        parts.enumerated().reduce(Text("")) { line, part in
            part.offset == 0 ? part.element : line + Text("  ·  ").foregroundColor(.secondary) + part.element
        }
        .scaled(.secondary.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Someone's picture — a GitHub account's, or the one at `url` — or their initial while it loads or when there is
/// none.
struct Avatar: View {
    var login: String
    /// Where the picture is, for someone who is not a GitHub login, such as a Jira assignee.
    var url: String? = nil
    var size: CGFloat = 28
    @Environment(\.textScale) private var scale

    var body: some View {
        let key = url ?? login
        Group {
            if let image = AvatarStore.shared.images[key] {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(login.prefix(1).uppercased())
                    .scaled(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.raised)
            }
        }
        .frame(width: (size * scale).rounded(), height: (size * scale).rounded())
        .clipShape(Circle())
        .help(login)
        .task(id: key) { AvatarStore.shared.load(key, from: url ?? "https://github.com/\(login).png?size=64") }
    }
}

/// Nobody's picture: Jira's grey silhouette for an unassigned ticket.
struct NobodyAvatar: View {
    var size: CGFloat = 28
    @Environment(\.textScale) private var scale

    var body: some View {
        Image(systemName: "person.fill")
            .resizable()
            .scaledToFit()
            .padding((size * scale * 0.24).rounded())
            .foregroundStyle(.secondary)
            .frame(width: (size * scale).rounded(), height: (size * scale).rounded())
            .background(Theme.raised, in: Circle())
            .help("Unassigned")
    }
}

/// Every picture, loaded once for the whole app and kept, so each row by the same person shows the same
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

    /// Keyed by `key`, a GitHub login or the picture's own URL.
    func load(_ key: String, from address: String) {
        guard images[key] == nil, !loading.contains(key),
              failedAt[key].map({ Date().timeIntervalSince($0) > 300 }) ?? true,
              let url = URL(string: address)
        else { return }
        loading.insert(key)
        Task {
            defer { loading.remove(key) }
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) {
                images[key] = image
            } else {
                failedAt[key] = Date()
            }
        }
    }
}

/// A search field drawn as one of the reference app's boxed inputs.
struct SearchBox: View {
    @Environment(AppModel.self) private var model
    var prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
                .focused($focused)
                // View → Find (⌘F) lands here.
                .onChange(of: model.searchFocusRequest) { focused = true }
            if !text.isEmpty {
                Button { text = "" } label: {
                    // A 24 pt target, pulled into the box's own height so it does not grow when you type.
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        .frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                        .padding(.vertical, -4)
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 240)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.controlBorder))
        .onAppear { model.visibleSearchBoxes += 1 }
        .onDisappear { model.visibleSearchBoxes -= 1 }
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
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.controlBorder))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The details panel's body: plain sections on the window's own background, in place of a grouped form's cards.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) { content }
                .padding(Theme.Space.l)
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
        VStack(alignment: .leading, spacing: Theme.Space.s) {
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
            Spacer(minLength: Theme.Space.m)
            SidebarStatus()
        }
        .padding(.horizontal, Theme.Space.s)
        // Clear of the window's buttons, which sit over the top of the sidebar.
        .padding(.top, Theme.Space.xxl + Theme.Space.s)
        .padding(.bottom, Theme.Space.m)
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.ignoresSafeArea())
    }
}

/// A sidebar icon: an SF Symbol by name, or Jira's own mark for `jira`, in the same grey as the rest.
struct SidebarIcon: View {
    nonisolated static let jira = "jira"
    var name: String

    var body: some View {
        if name == Self.jira {
            Image(nsImage: Self.jiraMark).resizable().scaledToFit().frame(width: 13, height: 13)
        } else {
            Image(systemName: name)
        }
    }

    /// Jira's mark, its three stacked chevrons, from the SVG outline; a template, so it takes the text colour.
    private static let jiraMark: NSImage = {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">\
            <path d="M244.658 0H121.707a55.502 55.502 0 0 0 55.502 55.502h22.649V77.37c.02 30.625 24.841 55.447 55.466 55.467V10.666C255.324 4.777 250.55.003 244.658 0z"/>\
            <path d="M183.822 61.262H60.872c.019 30.625 24.84 55.447 55.466 55.467h22.649v21.938c.039 30.625 24.877 55.43 55.502 55.43V71.93c0-5.891-4.776-10.667-10.667-10.667z"/>\
            <path d="M122.951 122.489H0c0 30.653 24.85 55.502 55.502 55.502h22.72v21.867c.02 30.597 24.798 55.408 55.396 55.466V133.156c0-5.891-4.776-10.667-10.667-10.667z"/>\
            </svg>
            """
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}

/// A small grey heading over a group of sidebar items.
struct SidebarHeading: View {
    var title: String

    var body: some View {
        Text(title).scaled(.subheadline).foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.s).padding(.bottom, Theme.Space.xs)
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
            HStack(spacing: Theme.Space.s) {
                SidebarIcon(name: icon).foregroundStyle(.secondary).frame(width: 16)
                Text(title).foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: Theme.Space.xs)
                trailing
            }
            .scaled(.body)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(selected ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .hoverFill(enabled: !selected)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            SyncRow()
            VStack(alignment: .leading, spacing: 8) {
                if let running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(running).scaled(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                SourceDots()
            }
            .padding(.horizontal, Theme.Space.m)
        }
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

/// The sidebar's sync row, as wide as the items above it: whether every source is synced, and the arrow that syncs
/// them all now, which gives way to a spinner while any of them loads. A press anywhere on the row syncs.
struct SyncRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let syncing = !model.refreshing.isEmpty
        let failed = !model.state.errors.isEmpty
        Button { model.refreshAll() } label: {
            HStack(spacing: 9) {
                Circle().fill(failed ? Color.orange : .green).frame(width: 7, height: 7).frame(width: 16)
                Text(syncing ? "Syncing…" : failed ? "Sync failed" : "Synced").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if syncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                }
            }
            .scaled(.body)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(model.syncHelp)
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

/// A pull request's own page, in place of the list it was opened from, laid out as PR Cockpit lays its PR page: a back
/// link at the top, a header, then the long reads in a wide column and the facts and presses in a side one. ← goes
/// back; the page takes focus when it opens so that works without a click first.
struct DetailPage<Header: View, Main: View, Side: View>: View {
    var back: String
    var onBack: () -> Void
    @ViewBuilder var header: Header
    @ViewBuilder var main: Main
    @ViewBuilder var side: Side
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BackLink(title: back, action: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    header
                    Hairline()
                    HStack(alignment: .top, spacing: Theme.Space.xl) {
                        VStack(alignment: .leading, spacing: Theme.Space.xl) { main }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: Theme.Space.xl) { side }
                            .frame(width: 300, alignment: .leading)
                    }
                }
                .padding(.bottom, Theme.Space.xl)
                .labeledContentStyle(PanelRowStyle())
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // A turn of the run loop later: asked for while the page is still being put on screen, in place of the list
        // that had focus, the focus is dropped, and ← does nothing until a click.
        .task {
            await Task.yield()
            focused = true
        }
        .onKeyPress(.leftArrow) {
            onBack()
            return .handled
        }
    }
}

/// "‹ Pull Requests": PR Cockpit's back link, faint until the pointer is on it.
private struct BackLink: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                Text(title)
            }
            .scaled(.secondary)
            .foregroundStyle(hovering ? .primary : .secondary)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Back to \(title) (←)")
    }
}

extension NSAppearance {
    /// Dark Aqua, with or without Increase Contrast.
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
