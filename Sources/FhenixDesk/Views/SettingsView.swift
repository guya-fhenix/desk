import DeskCore
import SwiftUI

/// The parts of Settings, each a page of its own in the Settings sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, github, repos, jira, reviews, prompts

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .github: return "GitHub"
        case .repos: return "Repos"
        case .jira: return "Jira"
        case .reviews: return "Reviews"
        case .prompts: return "Prompts"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .repos: return "folder"
        case .jira: return "checklist"
        case .reviews: return "eye"
        case .prompts: return "text.bubble"
        }
    }
}

/// What Settings is editing. It lives on the model rather than in the view, so going back to the Desk and
/// returning keeps what you typed; Save writes it, Revert reloads it.
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

    /// What Save would write: the draft plus the fields edited as free text. Comparing this to the saved
    /// config is what makes the buttons light up, so a round trip back to the original counts as no change.
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

/// Settings, in the Desk window: its own sidebar with the way back, one page per part, and Save at the foot.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let draft = model.settings
        HStack(spacing: 0) {
            SidebarColumn {
                Button { model.showingSettings = false } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "chevron.left").foregroundStyle(.secondary).frame(width: 16)
                        Text("Back to Desk").foregroundStyle(.secondary)
                        Spacer()
                        KeyCap(key: "Esc")
                    }
                    .scaled(.body)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Esc closes Search first when it is open over Settings.
                .keyboardShortcut(model.showingFinder ? nil : .cancelAction)
                .padding(.bottom, 10)
                SidebarHeading(title: "Settings")
                ForEach(SettingsPane.allCases) { pane in
                    SidebarItem(title: pane.title, icon: pane.icon, selected: draft.pane == pane) { draft.pane = pane }
                }
            }
            Rectangle().fill(Theme.line).frame(width: 1).ignoresSafeArea()
            VStack(spacing: 0) {
                page(draft.pane)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                saveBar
                KeyHints(hints: [(["⌘", "S"], "save"), (["Esc"], "back")])
            }
            .background(Theme.background)
        }
        .onAppear { if !draft.loaded { draft.load(model.config) } }
        .task { model.loadRepositories() }
    }

    @ViewBuilder private func page(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: FormPage(title: pane.title) { GeneralSettings() }
        case .github: FormPage(title: pane.title) { GitHubSettings() }
        case .repos: ReposSettings()
        case .jira: FormPage(title: pane.title) { JiraSettings() }
        case .reviews: FormPage(title: pane.title) { ReviewsSettings() }
        case .prompts: PromptsSettings()
        }
    }

    /// Pinned under every page. Save and Revert stay dead until something actually differs from what is saved.
    private var saveBar: some View {
        let dirty = model.settings.isDirty(against: model.config)
        return VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 12) {
                if let error = model.configError {
                    Text(error).scaled(.caption).foregroundStyle(.red).lineLimit(1).textSelection(.enabled)
                } else if dirty {
                    Text("Unsaved changes").scaled(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { model.settings.load(model.config) }
                    .buttonStyle(.plain)
                    .foregroundStyle(dirty ? .primary : .tertiary)
                    .disabled(!dirty)
                Button(action: save) {
                    HStack(spacing: 8) {
                        Text("Save changes")
                        HStack(spacing: 3) {
                            ForEach(["⌘", "S"], id: \.self) { key in
                                Text(key)
                                    .scaled(.caption.monospaced())
                                    .frame(minWidth: 16, minHeight: 16)
                                    .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.accent, in: Capsule())
                    .opacity(dirty ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!dirty)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 12)
        }
    }

    private func save() {
        let draft = model.settings
        draft.config = draft.pending
        model.config = draft.config
        model.saveConfig()
    }
}

/// A page of fields: the title, then the groups, scrolling when they run long.
private struct FormPage<Content: View>: View {
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
    @ViewBuilder var input: Input

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).scaled(.body.weight(.medium))
            input
        }
    }
}

/// The boxed look every input on these pages shares.
private struct InputBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: 300, alignment: .leading)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.27)))
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
    @Binding var value: Value
    var range: ClosedRange<Value>
    var step: Value.Stride
    var text: String

    var body: some View {
        HStack {
            Text(text).scaled(.callout.monospaced())
            Spacer()
            Stepper("", value: $value, in: range, step: step).labelsHidden()
        }
        .modifier(InputBox())
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        FieldGroup(title: "Polling") {
            Field(label: "GitHub, every") {
                BoxedStepper(value: $draft.config.githubPollSeconds, range: 30...3_600, step: 30, text: "\(draft.config.githubPollSeconds) s")
            }
            Field(label: "Git, every") {
                BoxedStepper(value: $draft.config.gitPollSeconds, range: 15...3_600, step: 15, text: "\(draft.config.gitPollSeconds) s")
            }
            Field(label: "Jira, every") {
                BoxedStepper(value: $draft.config.jiraPollSeconds, range: 60...3_600, step: 60, text: "\(draft.config.jiraPollSeconds) s")
            }
        }
        FieldGroup(title: "Thresholds") {
            Field(label: "Stale PR after") {
                BoxedStepper(value: $draft.config.stalePullRequestDays, range: 1...30, step: 1, text: "\(draft.config.stalePullRequestDays) days")
            }
        }
        FieldGroup(title: "Alerts") {
            Field(label: "macOS notifications") {
                Toggle("Notify me", isOn: $draft.config.notificationsEnabled).toggleStyle(.switch).controlSize(.small)
            }
        }
    }
}

private struct GitHubSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        FieldGroup(title: "Account") {
            Field(label: "GitHub org") { BoxedText(placeholder: "FhenixProtocol", text: $draft.config.githubOrg) }
            Field(label: "gh path") { BoxedText(placeholder: "empty = auto", text: $draft.config.ghPath) }
        }
        FieldGroup(
            title: "Flow",
            note: "The team slug in the org, asked to review a PR once you approve its self-review, and again after each round of fixes."
        ) {
            Field(label: "Review team") { BoxedText(placeholder: "protocol-team", text: $draft.config.reviewTeam) }
        }
        FieldGroup(
            title: "Local clones",
            note: "Where your clones live. Only used to run a review against a checked-out repo — the list of repos comes from GitHub."
        ) {
            Field(label: "Repo roots") { BoxedText(placeholder: "comma separated", text: $draft.repoRootsText) }
        }
        FieldGroup(title: "Noise", note: "PRs by these authors stay out of the review queue.") {
            Field(label: "Bot logins") { BoxedText(placeholder: "comma separated", text: $draft.botLoginsText) }
        }
    }
}

private struct JiraSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        FieldGroup(
            title: "Account",
            note: "Signing in is a browser flow owned by acli. It grants the CLI access to your Atlassian products; this app only ever runs `acli jira`."
        ) {
            if let account = model.jiraAccount {
                Field(label: "Site") { Text(account.site).scaled(.callout.monospaced()).modifier(InputBox()) }
                Field(label: "Signed in as") { Text(account.email ?? "—").scaled(.callout.monospaced()).modifier(InputBox()) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(accountText).scaled(.caption).foregroundStyle(model.jiraAccount == nil ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Recheck") { model.refreshJiraAccount() }.controlSize(.small)
            }
        }
        FieldGroup(
            title: "Tickets",
            note: "Status names exactly as Jira spells them, emoji and all; empty turns that half off. Desk moves a ticket of yours on its own once its pull requests say it has fallen behind, never backwards."
        ) {
            Field(label: "Project keys") { BoxedText(placeholder: "comma separated", text: $draft.projectKeysText) }
            Field(label: "Status when planning starts") { BoxedText(placeholder: "In Progress", text: $draft.config.jiraInProgressStatus) }
            Field(label: "Status while a PR is open for review") { BoxedText(placeholder: "👀 Review Ready", text: $draft.config.jiraReviewStatus) }
            Field(label: "Status once every PR has merged") { BoxedText(placeholder: "Done", text: $draft.config.jiraDoneStatus) }
        }
        FieldGroup(title: "Tool") {
            Field(label: "acli path") { BoxedText(placeholder: "empty = auto", text: $draft.config.acliPath) }
        }
    }

    private var accountText: String {
        if model.jiraAccount != nil { return "The Atlassian CLI holds the credentials. Fhenix Desk stores no Jira token." }
        return model.settings.config.resolvedAcliPath == nil
            ? "acli not found. Install it with `brew install acli`, or set the path below."
            : "Not signed in. Run `acli jira auth login --web` in a terminal, then press Recheck."
    }
}

private struct ReviewsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        FieldGroup(title: "Claude") {
            Field(label: "claude path") {
                VStack(alignment: .leading, spacing: 4) {
                    BoxedText(placeholder: "empty = auto", text: $draft.config.claudePath)
                    Text(draft.config.resolvedClaudePath.map { "Using \($0)" } ?? "claude not found. Install it or set the path.")
                        .scaled(.caption).foregroundStyle(draft.config.resolvedClaudePath == nil ? .red : .secondary)
                }
            }
            Field(label: "Model") { BoxedText(placeholder: "empty = default", text: $draft.config.reviewModel) }
            Field(label: "Effort") { BoxedText(placeholder: "empty = default", text: $draft.config.reviewEffort) }
        }
        FieldGroup(title: "Limits") {
            Field(label: "Reviews at once, at most") {
                BoxedStepper(value: $draft.config.reviewConcurrency, range: 1...4, step: 1, text: "\(draft.config.reviewConcurrency)")
            }
            Field(label: "Give up on a review after") {
                BoxedStepper(value: $draft.config.reviewTimeoutMinutes, range: 5...90, step: 5, text: "\(draft.config.reviewTimeoutMinutes) min")
            }
            Field(label: "Spend per run, at most") {
                BoxedStepper(value: $draft.config.reviewBudgetUSD, range: 1...100, step: 1, text: Format.usd(draft.config.reviewBudgetUSD))
            }
        }
        FieldGroup(
            title: "Worktrees",
            note: """
            Reviews never start on their own. The Reviews tab marks which PRs are ready to run and you press Review \
            on the ones you want. Each run is one `claude -p` in a detached worktree of the PR, with read-only tools, \
            and cannot reach GitHub. When it finishes, the app puts its comments into your pending review on the PR — \
            visible only to you — and you finish it on GitHub: edit or drop comments, pick the verdict, submit.
            """
        ) {
            Field(label: "Review worktrees root") { BoxedText(placeholder: "~/Repos/.reviews", text: $draft.config.reviewRoot) }
            Field(label: "When the PR is merged") {
                Toggle("Remove the review and its worktree", isOn: $draft.config.cleanupReviewsOnMerge)
                    .toggleStyle(.switch).controlSize(.small)
            }
        }
    }
}

/// A page of its own: the org runs to hundreds of repos, which no field group can hold.
private struct ReposSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settings
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Repos") { EmptyView() }
            FilterBar {
                SearchBox(prompt: "Filter", text: $draft.repoFilter)
                Text("\(draft.config.trackedRepos.count) tracked of \(model.repositories.count)")
                    .scaled(.caption).foregroundStyle(.secondary).monospacedDigit()
            } trailing: {
                if !draft.config.trackedRepos.isEmpty {
                    Button("Clear") { draft.config.trackedRepos = [] }.controlSize(.small)
                }
                if model.loadingRepositories { ProgressView().controlSize(.small) }
                Button("Reload") { model.loadRepositories(force: true) }.controlSize(.small)
            }
            if let error = model.repositoriesError {
                EmptyText(text: error).padding(.vertical)
            } else if model.repositories.isEmpty {
                EmptyText(text: model.loadingRepositories ? "Asking GitHub…" : "No repositories found for \(draft.config.githubOrg).")
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
                                    if repo.isArchived { Chip(text: "archived", color: .secondary) }
                                    if draft.config.trackedRepoSlugs.contains(repo.slug), let skill = model.state.reviewSkill(forSlug: repo.slug) {
                                        ReviewSkillMark(skill: skill)
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
                .frame(maxWidth: 320)
                if edits[id.rawValue] != nil { Chip(text: "edited", color: .orange) }
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
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.27)))
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
