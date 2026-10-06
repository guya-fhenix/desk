import DeskCore
import SwiftUI

/// The app's Settings window (⌘,). One pane per tab in the window's toolbar, the way every Mac app does
/// it; the draft lives here, above the tabs, so switching panes never loses an edit.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = DeskConfig()
    @State private var repoRootsText = ""
    @State private var botLoginsText = ""
    @State private var projectKeysText = ""
    @State private var repoFilter = ""
    @State private var selectedPrompt: PromptID = .ticketPlan
    @State private var loaded = false

    var body: some View {
        TabView {
            pane(generalPane).tabItem { Label("General", systemImage: "gearshape") }
            pane(githubPane).tabItem { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
            pane(reposPane).tabItem { Label("Repos", systemImage: "folder") }
            pane(jiraPane).tabItem { Label("Jira", systemImage: "checklist") }
            pane(reviewsPane).tabItem { Label("Reviews", systemImage: "eye") }
            pane(promptsPane).tabItem { Label("Prompts", systemImage: "text.bubble") }
        }
        .frame(width: 580, height: 520)
        .onAppear { if !loaded { load() } }
        .task { model.loadRepositories() }
        // The Metrics toolbar writes this setting too; an open window must follow rather than call it an edit.
        .onChange(of: model.config.metricsWeeks) { _, weeks in draft.metricsWeeks = weeks }
    }

    private func pane(_ content: some View) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) { actions }
    }

    /// Pinned under every pane. The buttons stay dead until something actually differs from what is saved.
    private var actions: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if let error = model.configError {
                    Text(error).scaled(.caption).foregroundStyle(.red).lineLimit(1).textSelection(.enabled)
                } else if isDirty {
                    Text("Unsaved changes").scaled(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { load() }.disabled(!isDirty)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!isDirty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var githubPane: some View {
        Form {
            Section("Account") {
                TextField("GitHub org", text: $draft.githubOrg)
                TextField("gh path (empty = auto)", text: $draft.ghPath)
            }
            Section {
                TextField("Repo roots (comma separated)", text: $repoRootsText)
            } header: {
                Text("Local clones")
            } footer: {
                Text("Where your clones live. Only used to run a review against a checked-out repo — the list of repos comes from GitHub.")
                    .scaled(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Bot logins (comma separated)", text: $botLoginsText)
            } header: {
                Text("Noise")
            } footer: {
                Text("PRs by these authors stay out of the review queue and the cycle-time metrics.")
                    .scaled(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A screen of its own: the org runs to hundreds of repos, which no form section can hold.
    private var reposPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Filter", text: $repoFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Text("\(draft.trackedRepos.count) tracked of \(model.repositories.count)")
                    .scaled(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if !draft.trackedRepos.isEmpty {
                    Button("Clear") { draft.trackedRepos = [] }.controlSize(.small)
                }
                if model.loadingRepositories { ProgressView().controlSize(.small) }
                Button("Reload") { model.loadRepositories(force: true) }.controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if let error = model.repositoriesError {
                EmptyText(text: error).padding()
            } else if model.repositories.isEmpty {
                EmptyText(text: model.loadingRepositories ? "Asking GitHub…" : "No repositories found for \(draft.githubOrg).").padding()
            } else if draft.trackedRepos.isEmpty {
                // A banner rather than an overlay: it must not sit on top of the row underneath it.
                Text("Nothing is tracked, so the app is watching nothing. Pick the repos you work in.")
                    .scaled(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.4))
                Divider()
            }
            List(visibleRepos) { repo in
                Toggle(isOn: binding(for: repo)) {
                    HStack(spacing: 6) {
                        Text(repo.name)
                        if repo.isArchived { Chip(text: "archived", color: .secondary) }
                        Spacer()
                        Text(Format.age(repo.pushedAt)).scaled(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var jiraPane: some View {
        Form {
            Section {
                if let account = model.jiraAccount {
                    LabeledContent("Site", value: account.site)
                    LabeledContent("Signed in as", value: account.email ?? "—")
                    Text("The Atlassian CLI holds the credentials. Fhenix Desk stores no Jira token.")
                        .scaled(.caption).foregroundStyle(.green)
                } else {
                    Text(draft.resolvedAcliPath == nil
                        ? "acli not found. Install it with `brew install acli`, or set the path below."
                        : "Not signed in. Run `acli jira auth login --web` in a terminal, then press Recheck.")
                        .scaled(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Recheck") { model.refreshJiraAccount() }.controlSize(.small)
                    Spacer()
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Signing in is a browser flow owned by acli. It grants the CLI access to your Atlassian products; this app only ever runs `acli jira`.")
                    .scaled(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Project keys (comma separated)", text: $projectKeysText)
                TextField("Status when planning starts", text: $draft.jiraInProgressStatus)
                TextField("Status while a PR is open for review", text: $draft.jiraReviewStatus)
                TextField("Status once every PR has merged", text: $draft.jiraDoneStatus)
            } header: {
                Text("Tickets")
            } footer: {
                Text("Status names exactly as Jira spells them, emoji and all; empty turns that half off. Desk only marks the tickets that have fallen behind — moving one is a press on the Tickets screen.")
                    .scaled(.caption).foregroundStyle(.secondary)
            }
            Section("Tool") {
                TextField("acli path (empty = auto)", text: $draft.acliPath)
            }
        }
        .formStyle(.grouped)
    }

    private var reviewsPane: some View {
        Form {
            Section("Claude") {
                TextField("claude path (empty = auto)", text: $draft.claudePath)
                Text(draft.resolvedClaudePath.map { "Using \($0)" } ?? "claude not found. Install it or set the path.")
                    .scaled(.caption).foregroundStyle(draft.resolvedClaudePath == nil ? .red : .secondary)
                TextField("Model (empty = default)", text: $draft.reviewModel)
                TextField("Effort (empty = default)", text: $draft.reviewEffort)
            }
            Section("Limits") {
                Stepper("At most \(draft.reviewConcurrency) reviews at once", value: $draft.reviewConcurrency, in: 1...4)
                Stepper("Give up on a review after \(draft.reviewTimeoutMinutes) min", value: $draft.reviewTimeoutMinutes, in: 5...90, step: 5)
                Stepper("Spend at most \(Format.usd(draft.reviewBudgetUSD)) per run", value: $draft.reviewBudgetUSD, in: 1...100, step: 1)
            }
            Section {
                TextField("Review worktrees root", text: $draft.reviewRoot)
                Toggle("Remove the review and its worktree when the PR is merged", isOn: $draft.cleanupReviewsOnMerge)
            } header: {
                Text("Worktrees")
            } footer: {
                Text("""
                Reviews never start on their own. The Reviews tab marks which PRs are ready to run and you \
                press Review on the ones you want. Each run is one `claude -p` in a detached worktree of \
                the PR, with read-only tools, and cannot reach GitHub. When it finishes, the app puts its \
                comments into your pending review on the PR — visible only to you — and you finish it on \
                GitHub: edit or drop comments, pick the verdict, submit.
                """)
                .scaled(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A screen of its own, like Repos: a prompt runs to dozens of lines, more than a form row holds.
    private var promptsPane: some View {
        let id = selectedPrompt
        let edits = pending.prompts
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Picker("Prompt", selection: $selectedPrompt) {
                    ForEach(PromptID.allCases) { prompt in
                        Text(edits[prompt.rawValue] == nil ? prompt.title : "\(prompt.title) (edited)").tag(prompt)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                if edits[id.rawValue] != nil { Chip(text: "edited", color: .orange) }
                Spacer()
                Button("Reset to default") { draft.prompts[id.rawValue] = nil }
                    .controlSize(.small)
                    // The draft, not `pending`: a box cleared to nothing is not an edit, but Reset still refills it.
                    .disabled(draft.prompts[id.rawValue] == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            TextEditor(text: promptBinding(id))
                .scaled(.code)
                .autocorrectionDisabled()
                .padding(8)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(id.usage))
                if !id.placeholders.isEmpty {
                    Text(id.placeholders.map { "{\($0.name)} \($0.meaning)" }.joined(separator: " · "))
                }
                Text("Empty uses the default. To drop a block, remove its placeholder from the prompt it fills.")
            }
            .scaled(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// The default until you type. What you type is kept as typed — even empty, so clearing the box to
    /// start over does not snap the default back in — and `pending` decides at Save what is an edit.
    private func promptBinding(_ id: PromptID) -> Binding<String> {
        Binding(get: { draft.prompts[id.rawValue] ?? id.defaultText }, set: { draft.prompts[id.rawValue] = $0 })
    }

    private var generalPane: some View {
        Form {
            Section("Polling (seconds)") {
                Stepper("GitHub: \(draft.githubPollSeconds)", value: $draft.githubPollSeconds, in: 30...3_600, step: 30)
                Stepper("Git: \(draft.gitPollSeconds)", value: $draft.gitPollSeconds, in: 15...3_600, step: 15)
                Stepper("Jira: \(draft.jiraPollSeconds)", value: $draft.jiraPollSeconds, in: 60...3_600, step: 60)
            }
            Section("Thresholds") {
                Stepper("Stale PR after \(draft.stalePullRequestDays) days", value: $draft.stalePullRequestDays, in: 1...30)
                Stepper("Metrics window: \(draft.metricsWeeks) weeks", value: $draft.metricsWeeks, in: 2...26)
            }
            Section {
                LabeledContent("Text size") { TextSizeControl() }
                Toggle("macOS notifications", isOn: $draft.notificationsEnabled)
            } header: {
                Text("Appearance and alerts")
            } footer: {
                Text("Text size applies at once, like the buttons in the Desk toolbar.")
                    .scaled(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// What Save would write: the draft plus the fields edited as free text. Comparing this to the saved
    /// config is what makes the buttons light up, so a round trip back to the original counts as no change.
    private var pending: DeskConfig {
        var config = draft
        config.repoRoots = split(repoRootsText)
        config.botLogins = split(botLoginsText)
        config.jiraProjectKeys = split(projectKeysText).map { $0.uppercased() }
        // Only real edits are kept: a prompt typed back to its default, or cleared, is the default again.
        config.prompts = draft.prompts.filter { key, text in
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text != PromptID(rawValue: key)?.defaultText
        }
        return config
    }

    /// False until `load()` has run, or the untouched default draft would read as an edit.
    private var isDirty: Bool { loaded && pending != model.config }

    /// Tracked repos first so a pick never scrolls out of reach, then the rest by most recent push.
    private var visibleRepos: [GitHubRepo] {
        let needle = repoFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let tracked = Set(draft.trackedRepoSlugs)
        return model.repositories
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .sorted { lhs, rhs in
                let (l, r) = (tracked.contains(lhs.slug), tracked.contains(rhs.slug))
                if l != r { return l }
                return (lhs.pushedAt ?? .distantPast) > (rhs.pushedAt ?? .distantPast)
            }
    }

    private func binding(for repo: GitHubRepo) -> Binding<Bool> {
        Binding(
            get: { draft.trackedRepoSlugs.contains(repo.slug) },
            set: { on in
                var tracked = draft.trackedRepos.filter { $0.lowercased() != repo.slug }
                if on { tracked.append(repo.slug) }
                draft.trackedRepos = tracked.sorted()
            }
        )
    }

    private func load() {
        draft = model.config
        repoRootsText = draft.repoRoots.joined(separator: ", ")
        botLoginsText = draft.botLogins.joined(separator: ", ")
        projectKeysText = draft.jiraProjectKeys.joined(separator: ", ")
        loaded = true
    }

    private func save() {
        draft = pending
        model.config = draft
        model.saveConfig()
    }

    private func split(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
