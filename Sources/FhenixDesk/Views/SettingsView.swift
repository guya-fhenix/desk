import AppKit
import DeskCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The parts of Settings, each a page of its own in the Settings column.
enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance, github, repos, master, jira, general

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .github: return "GitHub"
        case .repos: return "Repositories"
        case .master: return "Master"
        case .jira: return "Jira"
        case .general: return "General"
        }
    }

    /// The quiet line beside the pane's title.
    var summary: String {
        switch self {
        case .appearance: return "How Desk looks."
        case .github: return "Desk uses gh's own sign-in and stores no token."
        case .repos: return "Which of the org's repos Desk watches."
        case .master: return "The one Claude session you talk to. It starts the workers."
        case .jira: return "Which project Desk reads, and what its statuses are called."
        case .general: return "How often Desk asks each source, and what reaches you."
        }
    }
}

/// What Settings is editing. It lives on the model rather than in the view, so going back to the Desk and
/// returning keeps what you typed. Every change is written a moment after it is made.
@MainActor
@Observable
final class SettingsDraft {
    var config = DeskConfig()
    var repoRootsText = ""
    var botLoginsText = ""
    /// The folders the master sees besides its own; empty follows the repo roots.
    var masterFoldersText = ""
    var repoFilter = ""
    var pane: SettingsPane = .appearance
    /// False until `load` has run, or the untouched default draft would read as an edit.
    private(set) var loaded = false

    func load(_ saved: DeskConfig) {
        config = saved
        repoRootsText = saved.repoRoots.joined(separator: ", ")
        botLoginsText = saved.botLogins.joined(separator: ", ")
        masterFoldersText = saved.masterFolders?.joined(separator: ", ") ?? ""
        loaded = true
    }

    /// What gets written: the draft plus the fields edited as free text. Comparing this to the saved config is
    /// what says whether there is anything to write, so a round trip back to the original counts as no change.
    var pending: DeskConfig {
        var pending = config
        pending.repoRoots = Self.split(repoRootsText)
        pending.botLogins = Self.split(botLoginsText)
        let masterFolders = Self.split(masterFoldersText)
        pending.masterFolders = masterFolders.isEmpty ? nil : masterFolders
        return pending
    }

    func isDirty(against saved: DeskConfig) -> Bool { loaded && pending != saved }

    private static func split(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Settings, in the Desk window beside the workspace sidebar: a column of its panes, and the chosen pane's sections in
/// one column of label and value rows. A change takes effect on its own, the way macOS settings do — there is no Save to
/// forget.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        HStack(spacing: 0) {
            SettingsPaneList(selection: $draft.pane)
                // Esc goes back to the screen you came from; it closes Search first when Search is open over Settings.
                .background {
                    Button("Back") { model.showingSettings = false }
                        .keyboardShortcut(model.showingFinder ? nil : .cancelAction)
                        .opacity(0)
                }
            VStack(spacing: 0) {
                SettingsPage(pane: draft.pane)
                if let error = model.configError {
                    Text(error).scaled(.secondary).foregroundStyle(Theme.danger).lineLimit(2).textSelection(.enabled)
                        .help(model.configErrorDetail ?? error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 10)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ground)
        }
        .savesSettingsDraft()
    }
}

extension View {
    /// Loads the Settings draft and writes each change of it: Settings and first-run setup show the same pages.
    func savesSettingsDraft() -> some View { modifier(SavesSettingsDraft()) }
}

private struct SavesSettingsDraft: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let draft = model.settings
        content
            .onAppear { if !draft.loaded { draft.load(model.config) } }
            .task { model.loadRepositories() }
            // Written a moment after the last change rather than on every one: a path typed key by key would otherwise
            // restart every source once per key.
            .task(id: draft.pending) {
                guard draft.isDirty(against: model.config) else { return }
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                save()
            }
            // Leaving inside that moment still keeps the change.
            .onDisappear { if draft.isDirty(against: model.config) { save() } }
    }

    /// Writes what the draft would be, leaving the draft itself as typed: a prompt box cleared to start over must not
    /// snap its default back in under the cursor.
    private func save() {
        model.config = model.settings.pending
        model.saveConfig()
    }
}

/// The panes, down a 200 pt column on the panel colour under an uppercase "Settings".
private struct SettingsPaneList: View {
    @Binding var selection: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel("Settings")
                .frame(minHeight: 32, alignment: .leading)
                .padding(EdgeInsets(top: 0, leading: 8, bottom: 14, trailing: 8))
            ForEach(SettingsPane.allCases) { pane in
                let chosen = pane == selection
                Button { selection = pane } label: {
                    Text(pane.title).scaled(chosen ? .body.weight(.medium) : .body)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .background(chosen ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .hoverFill(enabled: !chosen)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 18, leading: 10, bottom: 14, trailing: 10))
        .scaledFrame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.rule).frame(width: 1) }
    }
}

/// One pane: the page's title, the pane's own, then its sections, in a column at most 760 pt wide.
private struct SettingsPage: View {
    var pane: SettingsPane

    var body: some View {
        if pane == .repos {
            // The org's repos scroll in a list of their own, under the header and the filter.
            column { ReposSettings() }
        } else {
            ScrollView { column { content } }
        }
    }

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(title: "Settings", subtitle: "Desk on this Mac. Only you see these.").padding(.bottom, 12)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(pane.title).scaled(.headline)
                Text(pane.summary).scaled(.secondary).foregroundStyle(Theme.quiet)
            }
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }
            content()
        }
        .frame(maxWidth: 760, maxHeight: pane == .repos ? .infinity : nil, alignment: .topLeading)
        .padding(EdgeInsets(top: 18, leading: 40, bottom: 16, trailing: 40))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .appearance: AppearanceSettings()
        case .github: GitHubSettings()
        case .repos: EmptyView()
        case .master: MasterSettings()
        case .jira: JiraSettings()
        case .general: GeneralSettings()
        }
    }
}

/// A section of a pane: its uppercase label, its rows with a hairline under each, and a note.
private struct SettingsGroup<Content: View>: View {
    var title: String?
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title { SectionLabel(title).padding(.bottom, 2) }
            content
            if let note {
                Text(note).scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
        }
        .padding(.top, title == nil ? 8 : 22)
    }
}

/// One setting: its name in a 136 pt column, the value beside it with a quiet note under it, and its press on the right.
private struct SettingsRow<Value: View, Trailing: View>: View {
    var label: String
    var note: String?
    @ViewBuilder var value: Value
    @ViewBuilder var trailing: Trailing

    init(_ label: String, note: String? = nil, @ViewBuilder value: () -> Value, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.note = note
        self.value = value()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(label).fontWeight(.medium).scaledFrame(width: 136, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                value
                if let note {
                    Text(note).scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(_ label: String, note: String? = nil, @ViewBuilder value: () -> Value) {
        self.init(label, note: note, value: value) { EmptyView() }
    }
}

/// An input's name above it, for the few inputs that sit together in one row: a token's site, email and token.
private struct Field<Input: View>: View {
    var label: String
    @ViewBuilder var input: Input

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).scaled(.secondary).foregroundStyle(Theme.quiet)
            input
        }
    }
}

/// A poll interval as people say it: seconds under a minute, minutes from there.
private func interval(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) s" }
    return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s"
}

/// The boxed look every input on these pages shares: 28 pt, white, in the control colour's outline.
private struct InputBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.control))
    }
}

private struct BoxedText: View {
    var placeholder: String
    @Binding var text: String
    /// DM Mono for paths and names; a status name reads as words.
    var mono = true

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .scaled(mono ? .code : .body)
            .modifier(InputBox())
    }
}

/// A number with − and + beside it, in a box.
private struct BoxedStepper<Value: Strideable>: View where Value.Stride: SignedNumeric {
    /// The field's name, which VoiceOver reads for the − and + buttons.
    var label: String
    @Binding var value: Value
    var range: ClosedRange<Value>
    var step: Value.Stride
    var text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(text).scaled(.code).frame(minWidth: 64, alignment: .leading)
            Stepper(label, value: $value, in: range, step: step).labelsHidden()
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 28)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.control))
        .fixedSize()
    }
}

/// A list kept as comma-separated text in the draft, shown as chips: each entry with its own remove button and its own
/// problem, if it has one, so a typo in one cannot run into the next. A new one is typed under them.
private struct TokenField: View {
    var placeholder: String
    @Binding var text: String
    /// Why an entry will not work, shown under the field; nil when it is fine.
    var problem: (String) -> String? = { _ in nil }
    @State private var entry = ""

    private var tokens: [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tokens.isEmpty {
                Flow(spacing: 6) {
                    ForEach(tokens, id: \.self) { token in
                        HStack(spacing: 5) {
                            if problem(token) != nil {
                                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Theme.warn)
                            }
                            Text(token).scaled(.caption.monospaced())
                            Button { set(tokens.filter { $0 != token }) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.quiet)
                                    .frame(width: 12, height: 12).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(token)")
                        }
                        .padding(.leading, 6).padding(.trailing, 3).padding(.vertical, 2)
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            TextField(placeholder, text: $entry)
                .textFieldStyle(.plain)
                .scaled(.code)
                .onSubmit {
                    let new = entry.trimmingCharacters(in: .whitespaces)
                    if !new.isEmpty, !tokens.contains(new) { set(tokens + [new]) }
                    entry = ""
                }
                .modifier(InputBox())
            ForEach(tokens.compactMap(problem), id: \.self) { Text($0).scaled(.secondary).foregroundStyle(Theme.danger) }
        }
    }

    private func set(_ list: [String]) { text = list.joined(separator: ", ") }
}

/// One of the project's statuses, from Jira's own list, by category. A saved name the project doesn't have stays
/// shown, flagged: a move to it would fail.
private struct StatusPicker: View {
    @Binding var selection: String
    var statuses: [JiraStatus]
    var project: String

    var body: some View {
        let known = statuses.contains { $0.name == selection }
        VStack(alignment: .leading, spacing: 4) {
            Picker("Status", selection: $selection) {
                Text("Not set").tag("")
                ForEach(JiraStatus.Category.allCases, id: \.self) { category in
                    let inCategory = statuses.filter { $0.category == category }
                    if !inCategory.isEmpty {
                        Section(category.title) { ForEach(inCategory, id: \.name) { Text($0.name).tag($0.name) } }
                    }
                }
                if !selection.isEmpty, !known { Text(selection).tag(selection) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            if !selection.isEmpty, !known {
                Text("“\(selection)” isn't one of \(project)'s statuses: pick one of its own.").scaled(.secondary).foregroundStyle(Theme.danger)
            }
        }
    }
}

/// The project, from the ones Jira shows you; typed, when that list couldn't be read.
private struct ProjectField: View {
    @Binding var key: String
    var projects: [String]

    var body: some View {
        if projects.isEmpty {
            BoxedText(placeholder: "PRO", text: $key)
        } else {
            Picker("Project", selection: $key) {
                Text("None").tag("")
                ForEach(projects.contains(key) || key.isEmpty ? projects : projects + [key], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }
}

/// The folders clones live under: picked in a folder dialog rather than typed, and flagged when one is gone.
private struct RepoRootsField: View {
    @Binding var text: String
    @State private var picking = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TokenField(placeholder: "Add a path", text: $text) { root in
                var isFolder: ObjCBool = false
                let path = (root as NSString).expandingTildeInPath
                return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue ? nil : "No folder at \(root)."
            }
            Button("Add folder") { picking = true }.buttonStyle(.desk(.secondary, .small))
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            let path = (url.path as NSString).abbreviatingWithTildeInPath
            text = text.isEmpty ? path : "\(text), \(path)"
        }
    }
}

/// System, Light or Dark, and the accent. Both apply on the press, not after the draft's pause: what Desk looks like is
/// the answer to it.
private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model
    /// Names for `DeskConfig.accents`, in its order, for VoiceOver and the tooltip.
    private static let accentNames = ["Indigo", "Teal", "Violet", "Graphite"]

    var body: some View {
        let config = model.settings.config
        SettingsGroup {
            SettingsRow("Theme") {
                HStack(spacing: 14) {
                    Segmented(
                        options: [.init(value: .system, title: "System"), .init(value: .light, title: "Light"), .init(value: .dark, title: "Dark")],
                        selection: Binding(get: { config.appearance }, set: { value in apply { $0.appearance = value } })
                    )
                    Text("System follows macOS. Light and Dark keep Desk on one.").scaled(.secondary).foregroundStyle(Theme.quiet)
                }
            }
            SettingsRow("Accent") {
                HStack(spacing: 4) {
                    ForEach(Array(zip(DeskConfig.accents, Self.accentNames)), id: \.0) { hex, name in
                        swatch(hex: hex, name: name, chosen: config.accent == hex)
                    }
                }
            }
        }
    }

    /// A 22 pt disc of the accent; the chosen one ringed in it, two points out.
    private func swatch(hex: String, name: String, chosen: Bool) -> some View {
        Button { apply { $0.accent = hex } } label: {
            Circle().fill(Color(nsColor: NSColor(hex: hex)))
                .frame(width: 22, height: 22)
                .overlay {
                    if chosen {
                        Circle().strokeBorder(Theme.accentInk, lineWidth: 1.5).padding(-3.5)
                    } else {
                        Circle().strokeBorder(Theme.control, lineWidth: 1).padding(-1)
                    }
                }
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// Writes the change now, with whatever else the draft holds, as the draft's own save would; `saveConfig` applies the
    /// appearance and the accent.
    private func apply(_ change: (inout DeskConfig) -> Void) {
        change(&model.settings.config)
        model.config = model.settings.pending
        model.saveConfig()
    }
}

/// The master session: whether it runs, where, the terminal it shows in, what it sees, whether Desk tells it what happens
/// on GitHub, and where its plugins load from while skills are being tried.
private struct MasterSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        let folder = model.masterFolder
        let master = model.state.master
        let app = draft.config.terminalApp
        SettingsGroup(title: "Session") {
            SettingsRow("Session") {
                HStack(spacing: 6) {
                    Circle().fill(master == nil ? Theme.control : master!.isAsking || !model.state.asks.isEmpty ? Theme.warn : Theme.ok)
                        .frame(width: 6, height: 6)
                    Text(model.masterStatus)
                }
                if let error = model.masterError { Text(error).scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled) }
            } trailing: {
                // Running, Open is Desk's Master screen; Start starts it and shows it in the terminal.
                Button(master == nil ? "Start" : "Open") {
                    if master == nil { model.openMaster() } else { model.showMasterScreen() }
                }
                .buttonStyle(.desk(.secondary, .small))
                .disabled(model.startingMaster)
            }
            SettingsRow("Runs in", note: "graph.json and events.jsonl are Desk's, asks.json is the master's.") {
                Text((folder.path as NSString).abbreviatingWithTildeInPath).scaled(.code).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            } trailing: {
                Button("Show in Finder") { NSWorkspace.shared.open(folder.url) }.buttonStyle(.desk(.secondary, .small))
            }
            SettingsRow("Terminal") {
                HStack(spacing: 10) {
                    Segmented(options: [.init(value: .iTerm, title: "iTerm2"), .init(value: .terminal, title: "Terminal")],
                              selection: $draft.config.terminalApp)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("through the tmux session").foregroundStyle(Theme.quiet)
                        Text(TmuxLayout.session).scaled(.code)
                    }
                }
                Text("The master on the left, a pane per running session on the right. Desk opens no terminal of its own.")
                    .scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            } trailing: {
                Button(app == .iTerm ? "Open in iTerm" : "Open in Terminal") { model.openMaster() }
                    .buttonStyle(.desk(.secondary, .small))
                    .disabled(model.startingMaster)
            }
        }
        SettingsGroup(
            title: "What it sees and hears",
            note: "The folders go into the master folder's .claude/settings.json and apply the next time the master starts."
        ) {
            SettingsRow("Also sees", note: "Empty sees your repo roots.") { RepoRootsField(text: $draft.masterFoldersText) }
            SettingsRow("Events to the master") {
                Text("What Desk notifies you about on GitHub, as lines of events.jsonl for the master to route.")
                    .foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            } trailing: {
                Toggle("Send events to the master", isOn: $draft.config.sendEvents).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
        }
        WorkflowPluginGroup()
        SettingsGroup(
            title: "Development",
            note: "Only for trying plugin changes before they're merged into the marketplace. Passed as --plugin-dir to the master, which passes it to every worker; takes effect for sessions started after it changes."
        ) {
            SettingsRow("Plugin folder", note: "Such as a claude-marketplace branch's plugins folder. Leave it empty day to day: Desk's sessions then use the plugins installed for your user.") {
                BoxedText(placeholder: "Installed plugins", text: $draft.config.pluginDir)
            }
        }
    }
}

/// fhenix-workflow, checked once, here: installed for your user in the Claude Code Desk runs, since the master, its
/// workers and review sessions need it in every repo. Checked as the pane opens and again when Desk comes back to the
/// front, after the install ran in your terminal.
private struct WorkflowPluginGroup: View {
    @Environment(AppModel.self) private var model
    @State private var check: SetupCheck?

    var body: some View {
        SettingsGroup(
            title: "Team plugin",
            note: "The master, its workers and review sessions run on fhenix-workflow's skills, installed for your user in the Claude Code Desk runs."
        ) {
            SettingsRow("fhenix-workflow") {
                if let check {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: check.ok ? "checkmark" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(check.ok ? Theme.ok : Theme.warn)
                        Text(check.detail).foregroundStyle(check.ok ? Theme.ink : Theme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            } trailing: {
                HStack(spacing: 6) {
                    if let fix = check?.fixes.first {
                        Button(fix.label) { model.runInTerminal(fix.command, name: "setup-workflowPlugin") }
                            .help(fix.command)
                    }
                    Button("Recheck") { Task { await recheck() } }
                }
                .buttonStyle(.desk(.secondary, .small))
            }
        }
        .task { await recheck() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await recheck() }
        }
    }

    private func recheck() async {
        check = await Setup.check(.workflowPlugin, config: model.config)
        model.state.workflowSkill = ClaudePlugins.reviewSkill(pluginDir: model.config.pluginDir)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        SettingsGroup(title: "Polling") {
            SettingsRow("GitHub") {
                BoxedStepper(label: "GitHub poll interval", value: $draft.config.githubPollSeconds, range: 30...3_600, step: 30, text: interval(draft.config.githubPollSeconds))
            }
            SettingsRow("Git") {
                BoxedStepper(label: "Git poll interval", value: $draft.config.gitPollSeconds, range: 15...3_600, step: 15, text: interval(draft.config.gitPollSeconds))
            }
            SettingsRow("Jira") {
                BoxedStepper(label: "Jira poll interval", value: $draft.config.jiraPollSeconds, range: 60...3_600, step: 60, text: interval(draft.config.jiraPollSeconds))
            }
        }
        SettingsGroup(title: "Notifications") {
            SettingsRow("Notifications") {
                Text("Failed CI, review requests and the rest, as macOS notifications.").foregroundStyle(Theme.quiet)
            } trailing: {
                Toggle("Notify me", isOn: $draft.config.notificationsEnabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            OpenAtLogin()
        }
        SettingsGroup(title: "About") {
            SettingsRow("Version") { Text(Bundle.main.versionText).scaled(.code).textSelection(.enabled) }
            SettingsRow("Setup") {
                Text("Checks the tools and sign-ins again, and walks the settings it needs.").foregroundStyle(Theme.quiet)
            } trailing: {
                Button("Run setup again") { model.showingSetup = true }.buttonStyle(.desk(.secondary, .small))
            }
        }
    }
}

/// Desk as a login item, so its nudges come back after a restart without opening it first. macOS keeps this, not
/// config.json, and can turn it off in System Settings → Login Items; the switch reads its state each time it shows.
private struct OpenAtLogin: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        SettingsRow(
            "Open at login",
            note: Bundle.main.bundleIdentifier == nil ? "Only for the installed app: a build run with swift run has no bundle to register." : nil
        ) {
            Text("Desk starts with your Mac, so its notifications come back after a restart.").foregroundStyle(Theme.quiet)
            if status == .requiresApproval {
                Button("Allow it in Login Items…") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.desk(.secondary, .small))
            }
            if let error { Text(error).scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled) }
        } trailing: {
            Toggle("Open at login", isOn: Binding(get: { status == .enabled }, set: { set($0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .disabled(Bundle.main.bundleIdentifier == nil)
        }
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Could not \(on ? "add" : "remove") the login item: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}

struct GitHubSettings: View {
    @Environment(AppModel.self) private var model
    /// gh's sign-in, read off gh when the page opens; nil until it answers.
    @State private var signIn: SetupCheck?
    @State private var newToken = false

    var body: some View {
        @Bindable var draft = model.settings
        SettingsGroup(title: "Account") {
            SettingsRow("Sign-in") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let signIn {
                        Image(systemName: signIn.ok ? "checkmark" : "xmark").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(signIn.ok ? Theme.ok : Theme.danger)
                    }
                    Text(signIn?.detail ?? "Checking…")
                        .foregroundStyle(signIn.map { $0.ok ? Theme.ink : Theme.danger } ?? Theme.quiet)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            } trailing: {
                HStack(spacing: 6) {
                    if signIn?.ok == true, !newToken { Button("Sign in with a token") { newToken = true } }
                    Button("Recheck") { Task { await readSignIn() } }
                }
                .buttonStyle(.desk(.secondary, .small))
            }
            if signIn?.asksForToken == true || newToken {
                SettingsRow("Token") {
                    TokenSignIn(.github) {
                        newToken = false
                        model.loadRepositories(force: true)
                        Task { await readSignIn() }
                    }
                }
            }
            SettingsRow("GitHub org") { BoxedText(placeholder: "FhenixProtocol", text: $draft.config.githubOrg) }
            SettingsRow("gh path", note: "Leave empty to find gh on your PATH.") { BoxedText(placeholder: "Automatic", text: $draft.config.ghPath) }
        }
        SettingsGroup(
            title: "Local clones",
            note: "Where your clones live: sessions start in them, and their worktrees show as your work. The list of repos comes from GitHub."
        ) {
            SettingsRow("Repo roots", note: "Type a path and press Return, or pick one with Add folder.") {
                RepoRootsField(text: $draft.repoRootsText)
            }
        }
        SettingsGroup(title: "Noise", note: "PRs by these authors stay out of the review queue.") {
            SettingsRow("Bot logins", note: "Type a GitHub login and press Return.") {
                TokenField(placeholder: "Add a login", text: $draft.botLoginsText)
            }
        }
        .task { await readSignIn() }
    }

    private func readSignIn() async { signIn = await Setup.check(.github, config: model.config) }
}

struct JiraSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newToken = false

    var body: some View {
        @Bindable var draft = model.settings
        let account = model.jiraAccount
        SettingsGroup(
            title: "Account",
            note: "acli holds the sign-in: Desk hands it your token and keeps none, and only ever runs `acli jira`."
        ) {
            // Plain text, not input boxes: nothing here can be typed into.
            if let account {
                SettingsRow("Site") { Text(account.site).scaled(.code).textSelection(.enabled) }
                SettingsRow("Signed in as") { Text(account.email ?? "—").scaled(.code).textSelection(.enabled) }
            }
            SettingsRow("Sign-in") {
                // Green only on the mark that is good news; the words are just words.
                if let account {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ok)
                        Text(account.signedInWithBrowser ? "Signed in through the browser" : "Signed in with an API token")
                    }
                } else {
                    Text(signedOutText).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                HStack(spacing: 6) {
                    // A token runs out after at most a year; a new one replaces it here.
                    if account?.signedInWithBrowser == false, !newToken { Button("Use a new token") { newToken = true } }
                    Button("Recheck") { model.refreshJiraAccount() }
                }
                .buttonStyle(.desk(.secondary, .small))
            }
            if draft.config.resolvedAcliPath != nil, account?.signedInWithBrowser != false || newToken {
                SettingsRow("Token") { TokenSignIn(.jira) { newToken = false } }
            }
        }
        let key = draft.config.jiraProjectKey
        SettingsGroup(
            title: "Project",
            note: "The one Jira project Desk reads. Each project names its statuses its own way, so they come from Jira: pick where Desk moves a ticket at each step. Desk suggests a move once a ticket's pull requests say it has fallen behind, never backwards, and moves it when you press Move."
        ) {
            SettingsRow("Project") {
                ProjectField(key: Binding { key } set: { draft.config.jiraProjectKey = $0.uppercased() }, projects: model.jiraProjects)
            }
            if !key.isEmpty { statuses(key, draft: draft) }
        }
        .task { model.loadJiraProjects() }
        // A moment after the key stops changing: typing PRO would read P's and PR's statuses too.
        .task(id: key) {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await model.loadJiraStatuses(for: key)
        }
        SettingsGroup(title: "Tool") {
            SettingsRow("acli path", note: "Leave empty to find acli on your PATH.") { BoxedText(placeholder: "Automatic", text: $draft.config.acliPath) }
        }
    }

    /// The three moves, each picked from the project's statuses; while they're read, a spinner; a failed read, why.
    @ViewBuilder private func statuses(_ key: String, draft: SettingsDraft) -> some View {
        @Bindable var draft = draft
        if let statuses = model.jiraStatuses.flatMap({ $0.key == key ? $0.statuses : nil }) {
            SettingsRow("In progress", note: "When work on it starts.") {
                StatusPicker(selection: $draft.config.jiraInProgressStatus, statuses: statuses, project: key)
            }
            SettingsRow("Review", note: "While a PR is open for review.") {
                StatusPicker(selection: $draft.config.jiraReviewStatus, statuses: statuses, project: key)
            }
            SettingsRow("Done", note: "Once every PR has merged.") {
                StatusPicker(selection: $draft.config.jiraDoneStatus, statuses: statuses, project: key)
            }
            let fields = [\DeskConfig.jiraInProgressStatus, \.jiraReviewStatus, \.jiraDoneStatus]
            let suggested = zip(fields, JiraStatus.Role.allCases).map { ($0, JiraStatus.suggested($1, in: statuses)) }
            if fields.contains(where: { draft.config[keyPath: $0].isEmpty }), suggested.contains(where: { $0.1 != nil }) {
                SettingsRow("Suggested") {
                    Text(suggested.map { $0.1 ?? "—" }.joined(separator: "  ·  ")).foregroundStyle(Theme.quiet)
                } trailing: {
                    Button("Use these") {
                        for (field, name) in suggested where draft.config[keyPath: field].isEmpty { draft.config[keyPath: field] = name ?? "" }
                    }
                    .buttonStyle(.desk(.secondary, .small))
                }
            }
        } else if model.readingJiraStatuses == key || model.jiraStatusesError == nil {
            SettingsRow("Statuses") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(key)'s statuses from Jira…").foregroundStyle(Theme.quiet)
                }
            }
        } else if let error = model.jiraStatusesError {
            SettingsRow("Statuses") {
                Text(error).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } trailing: {
                Button("Retry") { Task { await model.loadJiraStatuses(for: key, force: true) } }.buttonStyle(.desk(.secondary, .small))
            }
        }
    }

    private var signedOutText: String {
        model.settings.config.resolvedAcliPath == nil
            ? "acli not found. Install it with `brew install acli`, or set the path below."
            : "Not signed in. Sign in with an API token below."
    }
}

/// Signs gh or acli in with a token pasted here: Desk hands it to the tool on stdin, the tool keeps it as its own
/// sign-in, and the field empties once it is sent, so Desk keeps none of it. Setup's Sign in step and Settings both ask
/// for one: Jira caps browser sign-ins by the hour, and tokens are not capped that way.
struct TokenSignIn: View {
    enum Service {
        case github, jira

        init?(_ kind: SetupCheck.Kind) {
            switch kind {
            case .github: self = .github
            case .jira: self = .jira
            default: return nil
            }
        }
    }

    @Environment(AppModel.self) private var model
    var service: Service
    /// After the tool took the token.
    var signedIn: () -> Void = {}
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var sending = false
    @State private var failure: String?

    init(_ service: Service, signedIn: @escaping () -> Void = {}) {
        self.service = service
        self.signedIn = signedIn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(why).scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            if service == .jira {
                HStack(alignment: .top, spacing: 12) {
                    Field(label: "Site") { BoxedText(placeholder: "fhenix.atlassian.net", text: $site) }
                    Field(label: "Email") { BoxedText(placeholder: "you@fhenix.io", text: $email) }
                }
            }
            Field(label: service == .jira ? "API token" : "Token") {
                SecureField("Paste it here", text: $token)
                    .textFieldStyle(.plain).scaled(.code).modifier(InputBox())
                    .onSubmit(send)
            }
            HStack(spacing: 8) {
                Button("Create a token…") { NSWorkspace.shared.open(service == .jira ? Setup.jiraTokenPage : Setup.githubTokenPage) }
                    .buttonStyle(.desk(.secondary, .small))
                Button("Sign in with the token", action: send).buttonStyle(.desk(.primary, .small)).disabled(!ready)
                if sending { ProgressView().controlSize(.small) }
            }
            if let failure { Text(failure).scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled) }
        }
        .onAppear {
            // The account acli has now, if any: the token replaces its browser sign-in.
            if site.isEmpty { site = model.jiraAccount?.site ?? "fhenix.atlassian.net" }
            if email.isEmpty { email = model.jiraAccount?.email ?? "" }
        }
    }

    private var why: String {
        switch service {
        case .github:
            return "Sign in with a classic token. Create a token opens GitHub with the scopes gh needs ticked: repo, read:org and gist. "
                + "gh keeps it and signs git in with it; tick workflow too if you push changes to GitHub Actions files."
        case .jira:
            let browser = model.jiraAccount?.signedInWithBrowser == true
            return (browser ? "Jira limits how much a browser sign-in can ask for each hour, and once that is spent the ticket sync fails until the hour turns. "
                            : "Sign in with an API token: Jira limits browser sign-ins by the hour, and tokens have no such limit. ")
                + "Create a token opens Atlassian: choose Create API token, not the one with scopes. It lasts up to a year; then sign in here with a new one."
        }
    }

    private var ready: Bool {
        !sending && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (service == .github || !(site.trimmingCharacters(in: .whitespaces).isEmpty || email.trimmingCharacters(in: .whitespaces).isEmpty))
    }

    private func send() {
        guard ready else { return }
        let config = model.config
        let token = token
        self.token = ""
        sending = true
        failure = nil
        Task {
            defer { sending = false }
            do {
                switch service {
                case .github:
                    guard let gh = config.resolvedGhPath else { failure = "Install the GitHub CLI first."; return }
                    try await Setup.signInGitHub(gh: gh, token: token)
                case .jira:
                    guard let acli = config.resolvedAcliPath else { failure = "Install the Atlassian CLI first."; return }
                    try await Setup.signInJira(acli: acli, site: site, email: email, token: token)
                }
                // New providers read the new sign-in, and every source refreshes on it.
                model.saveConfig()
                signedIn()
            } catch ShellError.failed(_, _, let stderr) {
                failure = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "The token was refused."
            } catch {
                failure = "\(error)"
            }
        }
    }
}

/// The org's repos to watch, ticked off a list of its own: the org runs to hundreds of repos, which no row can hold.
struct ReposSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        VStack(alignment: .leading, spacing: 0) {
            // Untrack all sits with the count it empties, away from the harmless Reload.
            FilterBar {
                SearchBox(prompt: "Filter", text: $draft.repoFilter)
                Text("\(draft.config.trackedRepos.count) tracked of \(model.repositories.count)")
                    .scaled(.secondary).foregroundStyle(Theme.quiet).monospacedDigit()
                if !draft.config.trackedRepos.isEmpty {
                    Button("Untrack all") { draft.config.trackedRepos = [] }.buttonStyle(.desk(.secondary, .small))
                }
            } trailing: {
                if model.loadingRepositories { ProgressView().controlSize(.small) }
                Button("Track my clones") { model.trackClones() }.buttonStyle(.desk(.secondary, .small))
                    .disabled(model.repositories.isEmpty)
                    .help("Track every repo here that has a clone under your repo roots")
                Button("Reload") { model.loadRepositories(force: true) }.buttonStyle(.desk(.secondary, .small))
            }
            if let error = model.repositoriesError {
                EmptyState(text: error).padding(.bottom, 12)
            } else if model.repositories.isEmpty {
                EmptyState(text: model.loadingRepositories ? "Asking GitHub…" : "No repositories found for \(draft.config.githubOrg).")
                    .padding(.bottom, 12)
            } else if draft.config.trackedRepos.isEmpty {
                Text("Nothing is tracked, so the app is watching nothing. Pick the repos you work in.")
                    .scaled(.secondary).foregroundStyle(Theme.quiet).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleRepos) { repo in
                        RuledRow(minHeight: 38) {
                            Toggle(isOn: binding(for: repo)) {
                                HStack(spacing: 8) {
                                    Text(repo.name).scaled(.code)
                                    if repo.isArchived { StageChip2(text: "Archived") }
                                    Spacer()
                                    AgeText(date: repo.pushedAt)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
            }
        }
    }

    /// Tracked repos first so a pick never scrolls out of reach, then the rest by most recent push.
    private var visibleRepos: [GitHubRepo] {
        let draft = model.settings
        let needle = draft.repoFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let tracked = Set(draft.config.trackedRepoSlugs)
        return model.repositories
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .sorted { lhs, rhs in
                let (l, r) = (tracked.contains(lhs.slug), tracked.contains(rhs.slug))
                if l != r { return l }
                return (lhs.pushedAt ?? .distantPast) > (rhs.pushedAt ?? .distantPast)
            }
    }

    private func binding(for repo: GitHubRepo) -> Binding<Bool> {
        let draft = model.settings
        return Binding(
            get: { draft.config.trackedRepoSlugs.contains(repo.slug) },
            set: { on in
                var tracked = draft.config.trackedRepos.filter { $0.lowercased() != repo.slug }
                if on { tracked.append(repo.slug) }
                draft.config.trackedRepos = tracked.sorted()
            }
        )
    }
}
