import DeskCore
import SwiftUI

struct SettingsTab: View {
    /// Settings split into panes. One long form buried the repo picker and the Save button alike; each
    /// pane is short enough to read at a glance, and the repo list gets a screen of its own.
    enum Pane: String, CaseIterable, Identifiable {
        case github, repos, jira, reviews, advanced

        var id: Pane { self }

        var title: String {
            switch self {
            case .github: return "GitHub"
            case .repos: return "Repos"
            case .jira: return "Jira"
            case .reviews: return "Reviews"
            case .advanced: return "Advanced"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var pane: Pane = .github
    @State private var draft = DeskConfig()
    @State private var repoRootsText = ""
    @State private var botLoginsText = ""
    @State private var projectKeysText = ""
    @State private var repoFilter = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            actions
            Divider()
            switch pane {
            case .github: githubPane
            case .repos: reposPane
            case .jira: jiraPane
            case .reviews: reviewsPane
            case .advanced: advancedPane
            }
        }
        .navigationTitle("Settings")
        .onAppear { if !loaded { load() } }
        .task { model.loadRepositories() }
    }

    /// Pinned above every pane: the pane picker on one side, the two buttons on the other. They stay
    /// dead until something actually differs from what is saved, and a pane switch never loses an edit.
    private var actions: some View {
        HStack(spacing: 12) {
            Picker("Pane", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if let error = model.configError {
                Text(error).scaled(.caption).foregroundStyle(.red).lineLimit(1).textSelection(.enabled)
            } else if isDirty {
                Text("Unsaved changes").scaled(.caption).foregroundStyle(.secondary)
            }
            Button("Revert") { load() }.disabled(!isDirty)
            Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!isDirty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                if model.reviewSpendToday > 0 {
                    Text("Reviews have cost \(Format.usd(model.reviewSpendToday)) in the last 24 hours.")
                        .scaled(.caption).foregroundStyle(.secondary)
                }
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
                the PR, with read-only tools, and cannot reach GitHub. New commits re-point the existing \
                comments instead of re-running. Nothing is posted until you press Submit in the review, \
                and only the comments you approved go with it.
                """)
                .scaled(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var advancedPane: some View {
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
            Section("Notifications") {
                Toggle("macOS notifications", isOn: $draft.notificationsEnabled)
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
