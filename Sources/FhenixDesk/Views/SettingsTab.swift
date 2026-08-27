import DeskCore
import SwiftUI

struct SettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var draft = DeskConfig()
    @State private var repoRootsText = ""
    @State private var botLoginsText = ""
    @State private var projectKeysText = ""
    @State private var jiraToken = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Repos") {
                TextField("Repo roots (comma separated)", text: $repoRootsText)
                TextField("GitHub org", text: $draft.githubOrg)
                TextField("gh path (empty = auto)", text: $draft.ghPath)
                TextField("Bot logins (comma separated)", text: $botLoginsText)
            }
            Section("Jira") {
                TextField("Site", text: $draft.jiraSite)
                TextField("Email", text: $draft.jiraEmail)
                TextField("Project keys (comma separated)", text: $projectKeysText)
                HStack {
                    SecureField("API token", text: $jiraToken)
                    Button("Save token") {
                        model.setJiraToken(jiraToken)
                        jiraToken = ""
                    }
                    .disabled(jiraToken.isEmpty)
                }
                Text(model.jiraHasToken ? "Token stored in Keychain." : "No token. Create one at id.atlassian.com → Security → API tokens.")
                    .font(.caption).foregroundStyle(model.jiraHasToken ? .green : .secondary)
            }
            Section("Polling (seconds)") {
                Stepper("GitHub: \(draft.githubPollSeconds)", value: $draft.githubPollSeconds, in: 30...3_600, step: 30)
                Stepper("Git: \(draft.gitPollSeconds)", value: $draft.gitPollSeconds, in: 15...3_600, step: 15)
                Stepper("Claude: \(draft.claudePollSeconds)", value: $draft.claudePollSeconds, in: 10...600, step: 10)
                Stepper("Jira: \(draft.jiraPollSeconds)", value: $draft.jiraPollSeconds, in: 60...3_600, step: 60)
            }
            Section("Nudges") {
                Stepper("Stale PR after \(draft.stalePullRequestDays) days", value: $draft.stalePullRequestDays, in: 1...30)
                Stepper("Claude waits after \(draft.claudeWaitingMinutes) min", value: $draft.claudeWaitingMinutes, in: 1...240)
                Stepper("Unpushed work after \(draft.unpushedWorkDays) days", value: $draft.unpushedWorkDays, in: 1...30)
                Stepper("Metrics window: \(draft.metricsWeeks) weeks", value: $draft.metricsWeeks, in: 2...26)
                Toggle("macOS notifications", isOn: $draft.notificationsEnabled)
            }
            Section {
                HStack {
                    Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    Button("Revert") { load() }
                    if let error = model.configError { Text(error).foregroundStyle(.red).font(.caption) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { if !loaded { load() } }
    }

    private func load() {
        draft = model.config
        repoRootsText = draft.repoRoots.joined(separator: ", ")
        botLoginsText = draft.botLogins.joined(separator: ", ")
        projectKeysText = draft.jiraProjectKeys.joined(separator: ", ")
        loaded = true
    }

    private func save() {
        draft.repoRoots = split(repoRootsText)
        draft.botLogins = split(botLoginsText)
        draft.jiraProjectKeys = split(projectKeysText).map { $0.uppercased() }
        model.config = draft
        model.saveConfig()
    }

    private func split(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
