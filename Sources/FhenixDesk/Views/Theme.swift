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

    /// GitHub's purple for a merged PR (#8250DF) and its red for one closed unmerged (#CF222E): the light-mode shades in
    /// both appearances, the ones white text clears 4.5:1 on.
    static let merged = Color(red: 0.51, green: 0.31, blue: 0.87)
    static let closed = Color(red: 0.81, green: 0.13, blue: 0.18)

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

/// A key as a small rounded cap with the key in it.
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
                if let subtitle { Text(subtitle).scaled(.secondary).foregroundStyle(.secondary) }
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
                // A pill keeps its one line: squeezed, its title broke a letter a line. The bar wraps instead.
                .fixedSize()
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }
}

/// The line between the page header and the list: tabs and filters on the left, search and sort on the right. Where
/// they do not fit side by side, search and sort go to a second line, on the right.
struct FilterBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) {
                leading
                Spacer(minLength: Theme.Space.m)
                trailing
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) { leading }
                HStack(spacing: Theme.Space.s) {
                    Spacer(minLength: 0)
                    trailing
                }
            }
        }
        .padding(.vertical, Theme.Space.m)
    }
}

/// A group's name and count over its rows, such as "Ready to merge".
struct GroupHeader<Trailing: View>: View {
    var title: String
    var count: Int?
    /// A press for the whole group, after its count.
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).scaled(.secondary.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if let count { Text("\(count)").scaled(.secondary).monospacedDigit().foregroundStyle(.secondary) }
                trailing
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
            Hairline()
        }
    }
}

extension GroupHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// One row of a list screen: a hairline under it, and the selected one tinted with a bar down its left edge.
/// It sits in a `List(selection:)`, which is what selects it — on a click or the arrow keys — and runs the
/// screen's primary action on a double-click or Return; the row only keeps the app's look.
struct ListRow<Content: View>: View {
    var selected = false
    /// For a row with a page of its own: a click opens it, and the pointer is a hand over the row to say so.
    var open: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, Theme.Space.m)
            // Two lines of text with room above and below, not packed edge to edge.
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
            .modifier(OpensOnClick(open: open))
            .plainListRow(background: selected ? Theme.rowSelected : Color.clear)
    }
}

/// A click anywhere on the row opens it, except on a button in it, which keeps its own click; so does VoiceOver's
/// press.
private struct OpensOnClick: ViewModifier {
    var open: (() -> Void)?

    func body(content: Content) -> some View {
        if let open {
            content
                .pointerStyle(.link)
                .onTapGesture(perform: open)
                .accessibilityAction(.default) { open() }
        } else {
            content
        }
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
            // Rows stop short of the scroll bar instead of running under it.
            .contentMargins(.trailing, Theme.Space.m, for: .scrollContent)
            .deskScrollBar()
    }

    /// The full-width scroll bar with its track, shown whenever there is something to scroll, in place of the thin one
    /// that overlays the content and fades.
    func deskScrollBar() -> some View { scrollIndicators(.visible) }
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

/// A search field drawn as a boxed input.
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
        .menuBox()
    }
}

extension View {
    /// The box a header menu's face sits in, as `MenuBox` draws it.
    func menuBox() -> some View {
        padding(.horizontal, 10)
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

/// One part of a details panel, under a small secondary heading such as "Quick actions".
struct PanelSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let title { Text(title).scaled(.secondary.weight(.medium)).foregroundStyle(.secondary) }
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
        Text(title).scaled(.secondary).foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.s).padding(.bottom, Theme.Space.xs)
    }
}

/// One item of a Settings-like page's column of parts: icon and title, and a rounded fill when chosen.
struct SidebarItem: View {
    var title: String
    var icon: String
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                SidebarIcon(name: icon).foregroundStyle(.secondary).frame(width: 16)
                Text(title).foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: Theme.Space.xs)
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

/// Pinned under the sidebar, one block: the sync state with its one press — the arrow that syncs every source, a spinner
/// while one syncs, Retry naming the sources that failed — and your Claude plan's session and week limits as two thin
/// meters. A click on it opens the detail: each source's age and error, and each limit's reset and the sessions at work.
struct SidebarStatus: View {
    @Environment(AppModel.self) private var model
    @State private var showingDetail = false

    var body: some View {
        // A failed source that is trying again shows as syncing, so Retry gives way to the spinner it started.
        let failed = Source.allCases.filter { model.state.errors[$0] != nil && !model.refreshing.contains($0) }
        let limits = model.state.claudeLimits.prefix(2)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: Theme.Space.s) {
                if !failed.isEmpty {
                    StatusDot(color: .red)
                    Text("\(Source.names(failed)) didn't answer").lineLimit(1)
                    Spacer(minLength: Theme.Space.xs)
                    Button("Retry") { for source in failed { Task { await model.refresh(source) } } }
                        .buttonStyle(.link).handCursor()
                } else if !model.refreshing.isEmpty {
                    ProgressView().controlSize(.mini)
                    Text("Syncing \(Source.names(Source.allCases.filter(model.refreshing.contains)))…").lineLimit(1)
                    Spacer(minLength: Theme.Space.xs)
                } else {
                    StatusDot(color: model.state.lastRefresh.isEmpty ? .gray : .green)
                    Text(model.state.lastRefresh.isEmpty ? "Not synced yet" : "Synced \(Format.ago(model.state.lastRefresh.values.min()))")
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.xs)
                    Button { model.refreshAll() } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 20, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Sync GitHub, Git and Jira now")
                    .accessibilityLabel("Sync now")
                }
            }
            .scaled(.secondary)
            if !limits.isEmpty {
                HStack(spacing: 6) {
                    Text("Claude").scaled(.caption).foregroundStyle(.secondary)
                    ForEach(limits) { limit in
                        ProgressView(value: Double(min(limit.percent, 100)), total: 100)
                            .tint(limit.color)
                            .controlSize(.small)
                            .help("\(limit.name): \(limit.percent)% used")
                            .accessibilityLabel("\(limit.name): \(limit.percent)% used")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { showingDetail = true }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show sync details") { showingDetail = true }
        .popover(isPresented: $showingDetail, arrowEdge: .trailing) { SyncDetail() }
    }
}

/// The sidebar status's detail: each source with its dot, how long ago it synced, and its error with Retry — and, when
/// the error is a sign-in or a missing CLI, the Settings pane that fixes it; then each Claude limit with when it starts
/// over, and the sessions at work now.
private struct SyncDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let running = model.state.claudeJobs.count { $0.isRunning }
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            heading("Sources")
            ForEach(Source.allCases, id: \.self) { source in
                let error = model.state.errors[source]
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) {
                        StatusDot(color: error != nil ? .red : model.state.lastRefresh[source] == nil ? .gray : .green)
                        Text(source.title)
                        Spacer(minLength: Theme.Space.s)
                        Text(age(source)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let error {
                        Text(error).scaled(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                            .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        HStack(spacing: Theme.Space.s) {
                            Button("Retry") { Task { await model.refresh(source) } }
                                .disabled(model.refreshing.contains(source))
                            if source != .git, Source.isSignInProblem(error) {
                                Button("Open Settings → \(source.title)") {
                                    model.openSettings(source == .jira ? .jira : .github)
                                    dismiss()
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            if !model.state.claudeLimits.isEmpty || running > 0 {
                heading("Claude")
                ForEach(model.state.claudeLimits) { limit in
                    HStack(spacing: Theme.Space.s) {
                        Text(limit.name)
                        Spacer(minLength: Theme.Space.s)
                        Text("\(limit.percent)%" + (limit.resetsAt.map { " · resets in \(TimeText.duration($0.timeIntervalSinceNow))" } ?? ""))
                            .monospacedDigit().foregroundStyle(limit.percent >= 70 ? limit.color : .secondary)
                    }
                    .help(limit.resetsAt.map { "Starts over \(Format.date($0))" } ?? "Starts over with your next session")
                }
                if running > 0 {
                    HStack(spacing: Theme.Space.s) {
                        Text("Running")
                        Spacer(minLength: Theme.Space.s)
                        ProgressView().controlSize(.mini)
                        Text("\(running) \(running == 1 ? "session" : "sessions")").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func heading(_ title: String) -> some View {
        Text(title).scaled(.secondary.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func age(_ source: Source) -> String {
        if model.refreshing.contains(source) { return "syncing…" }
        if model.state.errors[source] != nil { return "failed" }
        return model.state.lastRefresh[source].map { "synced \(Format.ago($0))" } ?? "not synced yet"
    }
}

extension ClaudeLimit {
    /// Blue while there is room, orange from 70%, red from 90%: the statusline's thresholds.
    var color: Color { percent >= 90 ? .red : percent >= 70 ? .orange : Theme.accent }
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

/// A pull request's own page, in place of the list it was opened from: a back link at the top, a header, then the
/// long reads in a wide column and the facts and presses in a side one. ← goes back; the page takes focus when it
/// opens so that works without a click first.
struct DetailPage<Header: View, Main: View, Side: View, Accessory: View>: View {
    var back: String
    var onBack: () -> Void
    @ViewBuilder var header: Header
    @ViewBuilder var main: Main
    @ViewBuilder var side: Side
    /// What the page has to warn about, on the right of the back link: the page's top right.
    @ViewBuilder var accessory: Accessory
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BackLink(title: back, action: onBack)
                Spacer(minLength: Theme.Space.m)
                accessory
            }
            .padding(.horizontal, Theme.gutter)
            // Out to the window's edge, the margins inside it: the scroll bar then sits in the right margin, clear of
            // the cards, rather than against them.
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    header
                    Hairline()
                    HStack(alignment: .top, spacing: Theme.Space.xl) {
                        VStack(alignment: .leading, spacing: Theme.Space.xl) { main }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: Theme.Space.m) { side }
                            .frame(width: 300, alignment: .leading)
                    }
                }
                .padding(.bottom, Theme.Space.xl)
                .padding(.horizontal, Theme.gutter)
                .labeledContentStyle(PanelRowStyle())
            }
            .deskScrollBar()
        }
        .environment(\.focusPage, { [focus = $focused] in focus.wrappedValue = true })
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
        // Not while a field is being typed in, such as the title being renamed: there ← moves the caret. The page
        // counts as focused with its field focused, and its key handler runs before the field's, so the window's
        // first responder is what tells.
        .onKeyPress(.leftArrow) {
            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return .ignored }
            onBack()
            return .handled
        }
    }
}

extension DetailPage where Accessory == EmptyView {
    init(
        back: String, onBack: @escaping () -> Void, @ViewBuilder header: () -> Header, @ViewBuilder main: () -> Main,
        @ViewBuilder side: () -> Side
    ) {
        self.init(back: back, onBack: onBack, header: header, main: main, side: side) { EmptyView() }
    }
}

/// One card of a PR page's side column: a title, a count beside it where there is one, what sits at its right,
/// the content.
struct SideCard<Content: View, Trailing: View>: View {
    var title: String
    var count: Int? = nil
    /// Tinted on the card that leads the column, so it reads as the one to act on.
    var edge: Color = Theme.line
    @ViewBuilder var content: Content
    /// A stage, or a summary, at the title's right.
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title).scaled(.body.weight(.medium))
                if let count { Text("\(count)").scaled(.secondary).monospacedDigit().foregroundStyle(.secondary) }
                Spacer(minLength: Theme.Space.s)
                trailing
            }
            content
        }
        .sideCard(edge: edge)
    }
}

extension SideCard where Trailing == EmptyView {
    init(title: String, count: Int? = nil, edge: Color = Theme.line, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, edge: edge, content: content) { EmptyView() }
    }
}

extension View {
    /// A side-column card's frame, for a view that brings its own heading.
    func sideCard(edge: Color = Theme.line) -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(edge))
    }

    /// A status-line pill: a few words on a raised capsule with an edge.
    func pill() -> some View {
        scaled(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.controlBorder))
            .fixedSize()
    }
}

extension EnvironmentValues {
    /// Puts the keyboard focus back on the page around a view that took it — a field, once it is done — so ← goes
    /// back again.
    @Entry var focusPage: () -> Void = {}
}

/// "‹ Pull Requests": the back link, faint until the pointer is on it.
struct BackLink: View {
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
        .buttonStyle(.plain).handCursor()
        .onHover { hovering = $0 }
        .help("Back to \(title) (←)")
    }
}

extension View {
    /// The pointing hand over a link while it is enabled. On macOS the hand means a link, and the arrow stays over
    /// buttons, menus and toggles, so only links and the rows a click opens ask for it; a hand on every control would
    /// make a real link look like everything else.
    func handCursor() -> some View { modifier(HandCursor()) }
}

private struct HandCursor: ViewModifier {
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View { content.pointerStyle(enabled ? .link : nil) }
}

extension NSAppearance {
    /// Dark Aqua, with or without Increase Contrast.
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
