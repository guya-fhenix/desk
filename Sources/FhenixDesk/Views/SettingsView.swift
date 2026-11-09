import DeskCore
import SwiftUI
import UniformTypeIdentifiers

/// The parts of Settings, each a page of its own in the Settings sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, github, repos, jira, prompts

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .github: return "GitHub"
        case .repos: return "Repos"
        case .jira: return "Jira"
        case .prompts: return "Prompts"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .repos: return "folder"
        case .jira: return SidebarIcon.jira
        case .prompts: return "text.bubble"
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
    var projectKeysText = ""
    var repoFilter = ""
    var selectedPrompt: PromptID = .ticketPlan
    var pane: SettingsPane = .general
    /// False until `load` has run, or the untouched default draft would read as an edit.
    private(set) var loaded = false

    func load(_ saved: DeskConfig) {
        config = saved
        repoRootsText = saved.repoRoots.joined(separator: ", ")
        botLoginsText = saved.botLogins.joined(separator: ", ")
        projectKeysText = saved.jiraProjectKeys.joined(separator: ", ")
        loaded = true
    }

    /// What gets written: the draft plus the fields edited as free text. Comparing this to the saved config is
    /// what says whether there is anything to write, so a round trip back to the original counts as no change.
    var pending: DeskConfig {
        var pending = config
        pending.repoRoots = Self.split(repoRootsText)
        pending.botLogins = Self.split(botLoginsText)
        pending.jiraProjectKeys = Self.split(projectKeysText).map { $0.uppercased() }
        // Only real edits are kept: a prompt typed back to its default, or cleared, is the default again, and
        // a key the app no longer has a prompt for is dropped.
        pending.prompts = config.prompts.filter { key, text in
            guard let id = PromptID(rawValue: key) else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text != id.defaultText
        }
        return pending
    }

    func isDirty(against saved: DeskConfig) -> Bool { loaded && pending != saved }

    private static func split(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Settings, in the Desk window beside the workspace sidebar: a column of its parts, and one page per part. A change
/// takes effect on its own, the way macOS settings do — there is no Save to forget.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let draft = model.settings
        HStack(spacing: 0) {
            PaneColumn(title: "Settings") {
                ForEach(SettingsPane.allCases) { pane in
                    SidebarItem(title: pane.title, icon: pane.icon, selected: draft.pane == pane) { draft.pane = pane }
                }
            }
            // Esc goes back to the screen you came from; it closes Search first when Search is open over Settings.
            .background {
                Button("Back") { model.showingSettings = false }
                    .keyboardShortcut(model.showingFinder ? nil : .cancelAction)
                    .opacity(0)
            }
            Rectangle().fill(Theme.line).frame(width: 1).ignoresSafeArea()
            VStack(spacing: 0) {
                page(draft.pane)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let error = model.configError {
                    Hairline()
                    Text(error).scaled(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                        .help(model.configErrorDetail ?? error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.gutter)
                        .padding(.vertical, 10)
                }
            }
            .background(Theme.background)
        }
        .savesSettingsDraft()
    }

    @ViewBuilder private func page(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: FormPage(title: pane.title) { GeneralSettings() }
        case .github: FormPage(title: pane.title) { GitHubSettings() }
        case .repos: ReposSettings()
        case .jira: FormPage(title: pane.title) { JiraSettings() }
        case .prompts: PromptsSettings()
        }
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

/// The column of parts beside a Settings-like page: Settings' panes, setup's steps.
struct PaneColumn<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarHeading(title: title)
            content
            Spacer()
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.top, Theme.Space.xxl)
        .frame(width: 168)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.ignoresSafeArea())
    }
}

/// A page of fields: the title, then the groups, scrolling when they run long.
struct FormPage<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: title) { EmptyView() }
                content
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
    }
}

/// A group of fields: a hairline, its name, then the fields two to a row, and a note under them.
private struct FieldGroup<Content: View>: View {
    var title: String?
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Hairline().padding(.top, 20)
            if let title { Text(title).scaled(.callout).foregroundStyle(.secondary) }
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 32, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                alignment: .leading, spacing: 18
            ) { content }
            if let note {
                Text(note).scaled(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One setting: its name above a boxed input.
private struct Field<Input: View>: View {
    var label: String
    /// How to fill it in, under the input: a placeholder says it only until the first key is typed.
    var hint: String?
    @ViewBuilder var input: Input

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).scaled(.body.weight(.medium))
            input
            if let hint { Text(hint).scaled(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A poll interval as people say it: seconds under a minute, minutes from there.
private func interval(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) s" }
    return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s"
}

/// The boxed look every input on these pages shares.
private struct InputBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: 300, alignment: .leading)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.controlBorder))
    }
}

private struct BoxedText: View {
    var placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .scaled(.callout.monospaced())
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
        HStack {
            Text(text).scaled(.callout.monospaced())
            Spacer()
            Stepper(label, value: $value, in: range, step: step).labelsHidden()
        }
        .modifier(InputBox())
    }
}

/// A list kept as comma-separated text in the draft, edited one entry per line: each entry with its own remove button
/// and its own problem, if it has one, so a typo in one cannot run into the next.
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tokens, id: \.self) { token in
                    HStack(spacing: 6) {
                        Text(token).scaled(.callout.monospaced())
                        if problem(token) != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        Spacer(minLength: 4)
                        Button { set(tokens.filter { $0 != token }) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(token)")
                    }
                }
                TextField(placeholder, text: $entry)
                    .textFieldStyle(.plain)
                    .scaled(.callout.monospaced())
                    .onSubmit {
                        let new = entry.trimmingCharacters(in: .whitespaces)
                        if !new.isEmpty, !tokens.contains(new) { set(tokens + [new]) }
                        entry = ""
                    }
            }
            .modifier(InputBox())
            ForEach(tokens.compactMap(problem), id: \.self) { Text($0).scaled(.caption).foregroundStyle(.red) }
        }
    }

    private func set(_ list: [String]) { text = list.joined(separator: ", ") }
}

/// A Jira status: typed, or picked from the statuses your tickets are in — the ones `acli jira` has shown the app,
/// spelt the way Jira spells them. Not flagged for being none of those: no ticket of yours may sit in Done today. A
/// stray space at either end is flagged, since Jira's names have none and the move would fail on it.
private struct StatusField: View {
    var placeholder: String
    @Binding var text: String
    var known: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                BoxedText(placeholder: placeholder, text: $text)
                if !known.isEmpty {
                    Menu {
                        ForEach(known, id: \.self) { status in Button(status) { text = status } }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Pick one of the statuses your tickets are in")
                    .accessibilityLabel("Pick a status")
                }
            }
            if text != text.trimmingCharacters(in: .whitespaces) {
                Text("“\(text)” has a space at the start or end; Jira's status names do not.").scaled(.caption).foregroundStyle(.red)
            }
        }
    }
}

/// The folders clones live under: picked in a folder dialog rather than typed, and flagged when one is gone.
private struct RepoRootsField: View {
    @Binding var text: String
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TokenField(placeholder: "~/Repos", text: $text) { root in
                var isFolder: ObjCBool = false
                let path = (root as NSString).expandingTildeInPath
                return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue ? nil : "No folder at \(root)."
            }
            Button("Add folder…") { picking = true }.controlSize(.small)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            let path = (url.path as NSString).abbreviatingWithTildeInPath
            text = text.isEmpty ? path : "\(text), \(path)"
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        FieldGroup(title: "Polling") {
            Field(label: "GitHub poll interval") {
                BoxedStepper(label: "GitHub poll interval", value: $draft.config.githubPollSeconds, range: 30...3_600, step: 30, text: interval(draft.config.githubPollSeconds))
            }
            Field(label: "Git poll interval") {
                BoxedStepper(label: "Git poll interval", value: $draft.config.gitPollSeconds, range: 15...3_600, step: 15, text: interval(draft.config.gitPollSeconds))
            }
            Field(label: "Jira poll interval") {
                BoxedStepper(label: "Jira poll interval", value: $draft.config.jiraPollSeconds, range: 60...3_600, step: 60, text: interval(draft.config.jiraPollSeconds))
            }
        }
        FieldGroup(title: "Alerts") {
            Field(label: "macOS notifications") {
                Toggle("Notify me", isOn: $draft.config.notificationsEnabled).toggleStyle(.switch).controlSize(.small)
            }
        }
        FieldGroup(title: "About") {
            Field(label: "Version") { Text(Bundle.main.versionText).scaled(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            Field(label: "Setup", hint: "Checks the tools and sign-ins again, and walks the settings it needs.") {
                Button("Run setup again") { model.showingSetup = true }.controlSize(.small)
            }
        }
    }
}

struct GitHubSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        FieldGroup(title: "Account") {
            Field(label: "GitHub org") { BoxedText(placeholder: "FhenixProtocol", text: $draft.config.githubOrg) }
            Field(label: "gh path", hint: "Leave empty to find gh on your PATH.") { BoxedText(placeholder: "Automatic", text: $draft.config.ghPath) }
        }
        FieldGroup(
            title: "Flow",
            note: "The team slug in the org, asked to review a PR when you press Mark ready on it."
        ) {
            Field(label: "Review team") { BoxedText(placeholder: "protocol-team", text: $draft.config.reviewTeam) }
        }
        FieldGroup(
            title: "Local clones",
            note: "Where your clones live: sessions start in them, and their worktrees show as your work. The list of repos comes from GitHub."
        ) {
            Field(label: "Repo roots", hint: "One folder per line; type a path and press Return, or add one with the folder dialog.") {
                RepoRootsField(text: $draft.repoRootsText)
            }
        }
        FieldGroup(title: "Noise", note: "PRs by these authors stay out of the review queue.") {
            Field(label: "Bot logins", hint: "One GitHub login per line; type it and press Return.") {
                TokenField(placeholder: "Add a login", text: $draft.botLoginsText)
            }
        }
    }
}

struct JiraSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        FieldGroup(
            title: "Account",
            note: "Signing in is a browser flow owned by acli. It grants the CLI access to your Atlassian products; this app only ever runs `acli jira`."
        ) {
            // Plain text, not input boxes: nothing here can be typed into.
            if let account = model.jiraAccount {
                Field(label: "Site") { Text(account.site).scaled(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                Field(label: "Signed in as") {
                    Text(account.email ?? "—").scaled(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                // Green only on the one word that is good news; the note itself is just a note.
                if model.jiraAccount != nil {
                    Label("Signed in", systemImage: "checkmark.circle.fill").scaled(.caption)
                        .foregroundStyle(.green)
                }
                Text(accountText).scaled(.caption).foregroundStyle(model.jiraAccount == nil ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Recheck") { model.refreshJiraAccount() }.controlSize(.small)
            }
        }
        FieldGroup(
            title: "Tickets",
            note: "Status names exactly as Jira spells them, emoji and all; empty turns that half off. Desk suggests moving a ticket of yours once its pull requests say it has fallen behind, never backwards; it moves when you press Move."
        ) {
            Field(label: "Project keys", hint: "One Jira project key per line, such as PRO; type it and press Return.") {
                TokenField(placeholder: "Add a key", text: $draft.projectKeysText) { key in
                    key.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) == nil ? "“\(key)” is not a Jira project key." : nil
                }
            }
            Field(label: "Status when planning starts") {
                StatusField(placeholder: "In Progress", text: $draft.config.jiraInProgressStatus, known: knownStatuses)
            }
            Field(label: "Status while a PR is open for review") {
                StatusField(placeholder: "👀 Review Ready", text: $draft.config.jiraReviewStatus, known: knownStatuses)
            }
            Field(label: "Status once every PR has merged") {
                StatusField(placeholder: "Done", text: $draft.config.jiraDoneStatus, known: knownStatuses)
            }
        }
        FieldGroup(title: "Tool") {
            Field(label: "acli path", hint: "Leave empty to find acli on your PATH.") { BoxedText(placeholder: "Automatic", text: $draft.config.acliPath) }
        }
    }

    /// Every status your tickets are in, as acli reported them.
    private var knownStatuses: [String] { Set(model.state.tickets.map(\.status)).sorted() }

    private var accountText: String {
        if model.jiraAccount != nil { return "The Atlassian CLI holds the credentials. Fhenix Desk stores no Jira token." }
        return model.settings.config.resolvedAcliPath == nil
            ? "acli not found. Install it with `brew install acli`, or set the path below."
            : "Not signed in. Run `acli jira auth login --web` in a terminal, then press Recheck."
    }
}

/// A page of its own: the org runs to hundreds of repos, which no field group can hold.
struct ReposSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Repos") { EmptyView() }
            // Untrack all sits with the count it empties, away from the harmless Reload.
            FilterBar {
                SearchBox(prompt: "Filter", text: $draft.repoFilter)
                Text("\(draft.config.trackedRepos.count) tracked of \(model.repositories.count)")
                    .scaled(.caption).foregroundStyle(.secondary).monospacedDigit()
                if !draft.config.trackedRepos.isEmpty {
                    Button("Untrack all") { draft.config.trackedRepos = [] }.controlSize(.small)
                }
            } trailing: {
                if model.loadingRepositories { ProgressView().controlSize(.small) }
                Button("Track my clones") { model.trackClones() }.controlSize(.small)
                    .disabled(model.repositories.isEmpty)
                    .help("Track every repo here that has a clone under your repo roots")
                Button("Reload") { model.loadRepositories(force: true) }.controlSize(.small)
            }
            if let error = model.repositoriesError {
                EmptyState(text: error).padding(.vertical)
            } else if model.repositories.isEmpty {
                EmptyState(text: model.loadingRepositories ? "Asking GitHub…" : "No repositories found for \(draft.config.githubOrg).")
                    .padding(.vertical)
            } else if draft.config.trackedRepos.isEmpty {
                Text("Nothing is tracked, so the app is watching nothing. Pick the repos you work in.")
                    .scaled(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            Hairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleRepos) { repo in
                        ListRow {
                            Toggle(isOn: binding(for: repo)) {
                                HStack(spacing: 8) {
                                    Text(repo.name)
                                    if repo.isArchived { Chip(text: "Archived", color: .secondary) }
                                    if draft.config.trackedRepoSlugs.contains(repo.slug), let skill = model.state.reviewSkill(forSlug: repo.slug) {
                                        // The reason in words: nine identical triangles said nothing without a hover.
                                        ReviewSkillMark(skill: skill, showsText: true)
                                    }
                                    Spacer()
                                    Text(Format.age(repo.pushedAt)).scaled(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 14)
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

/// A page of its own, like Repos: a prompt runs to dozens of lines, more than a field holds.
private struct PromptsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        let id = draft.selectedPrompt
        let edits = draft.pending.prompts
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Prompts") { EmptyView() }
            FilterBar {
                Picker("Prompt", selection: $draft.selectedPrompt) {
                    ForEach(PromptID.allCases) { prompt in
                        Text(edits[prompt.rawValue] == nil ? prompt.title : "\(prompt.title) (edited)").tag(prompt)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
                if edits[id.rawValue] != nil { Chip(text: "Edited", color: .orange) }
            } trailing: {
                Button("Reset to default") { draft.config.prompts[id.rawValue] = nil }
                    .controlSize(.small)
                    // The draft, not `pending`: a box cleared to nothing is not an edit, but Reset still refills it.
                    .disabled(draft.config.prompts[id.rawValue] == nil)
            }
            TextEditor(text: promptBinding(id))
                .scaled(.code)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.controlBorder))
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(id.usage))
                if !id.placeholders.isEmpty {
                    Text(id.placeholders.map { "{\($0.name)} \($0.meaning)" }.joined(separator: " · "))
                }
                if !id.conditions.isEmpty {
                    Text(id.conditions.map { "{#\($0.name)}…{/\($0.name)} when \($0.meaning)" }.joined(separator: " · "))
                    Text("{else} inside a section gives the text for when it does not hold. A broken or unknown marker is sent as typed.")
                }
                Text("Empty uses the default.")
            }
            .scaled(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 14)
    }

    /// The default until you type. What you type is kept as typed — even empty, so clearing the box to start
    /// over does not snap the default back in — and `pending` decides at Save what is an edit.
    private func promptBinding(_ id: PromptID) -> Binding<String> {
        let draft = model.settings
        return Binding(get: { draft.config.prompts[id.rawValue] ?? id.defaultText }, set: { draft.config.prompts[id.rawValue] = $0 })
    }
}
