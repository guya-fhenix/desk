import AppKit
import DeskCore
import SwiftUI
import UserNotifications

/// First-run setup's steps, in order. The settings steps are Settings' own pages.
enum SetupStep: String, CaseIterable, Identifiable {
    case tools, accounts, github, repos, jira, finish

    var id: Self { self }

    var title: String {
        switch self {
        case .tools: return "Tools"
        case .accounts: return "Sign in"
        case .github: return "GitHub"
        case .repos: return "Repos"
        case .jira: return "Jira"
        case .finish: return "Finish"
        }
    }

    var icon: String {
        switch self {
        case .tools: return "wrench.and.screwdriver"
        case .accounts: return "person.badge.key"
        case .github: return SettingsPane.github.icon
        case .repos: return SettingsPane.repos.icon
        case .jira: return SettingsPane.jira.icon
        case .finish: return "checkmark.seal"
        }
    }
}

/// Setup, in the Desk window in place of everything else: the tools Desk drives, the accounts they are signed in to,
/// then the settings it cannot guess. A fix runs in the terminal panel, where you can follow it and type a password,
/// and the checks run again when it ends.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var step: SetupStep
    @State private var checks: [SetupCheck.Kind: SetupCheck] = [:]
    @State private var checking = false

    /// A step other than the first is for the debug snapshot.
    init(step: SetupStep = .tools) { _step = State(initialValue: step) }

    var body: some View {
        HStack(spacing: 0) {
            PaneColumn(title: "Setup") {
                ForEach(SetupStep.allCases) { item in
                    SidebarItem(title: item.title, icon: item.icon, selected: step == item) { step = item }
                }
            }
            Rectangle().fill(Theme.line).frame(width: 1).ignoresSafeArea()
            VStack(spacing: 0) {
                page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Hairline()
                footer
            }
            .background(Theme.background)
        }
        .savesSettingsDraft()
        .task { await recheck() }
        // A fix's tab ending (or being closed) is the moment its check may have changed.
        .onChange(of: runningFixes) { old, new in
            if new.count < old.count { Task { await recheck() } }
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .tools:
            ChecksPage(title: "Tools", note: "Desk drives these command-line tools and keeps no token of its own.", kinds: SetupCheck.Kind.tools,
                       checks: checks, checking: checking, run: run, recheck: { Task { await recheck() } })
        case .accounts:
            ChecksPage(title: "Sign in", note: "Each tool holds its own sign-in. GitHub and Jira ask for a token, which Desk hands to the tool and keeps none of.",
                       kinds: SetupCheck.Kind.accounts,
                       checks: checks, checking: checking, run: run, recheck: { Task { await recheck() } })
        case .github: FormPage(title: "GitHub") { GitHubSettings() }
        case .repos: ReposSettings()
        case .jira: FormPage(title: "Jira") { JiraSettings() }
        case .finish: FinishPage(checks: checks, missing: missingRequired)
        }
    }

    private var footer: some View {
        HStack {
            Button("Later") { model.showingSetup = false }
                .help("Close setup for now. It opens again on the next launch until you finish it.")
            Spacer()
            if let previous = SetupStep.allCases.before(step) { Button("Back") { step = previous } }
            if let next = SetupStep.allCases.after(step) {
                Button("Next") { step = next }.keyboardShortcut(.defaultAction)
            } else {
                Button("Finish") { model.completeSetup() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!missingRequired.isEmpty)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
    }

    /// What has to be there before Desk can show anything: git, gh signed in, and a repo to watch.
    private var missingRequired: [String] {
        var missing = SetupCheck.Kind.allCases.filter { $0.isRequired && checks[$0]?.ok != true }.map(\.title)
        if model.settings.config.trackedRepos.isEmpty { missing.append("A tracked repo") }
        return missing
    }

    /// The setup tabs still running in the terminal panel.
    private var runningFixes: [String] {
        model.terminals.tabs.filter { $0.id.hasPrefix("setup.") && $0.running }.map(\.id)
    }

    private func run(_ fix: SetupFix, for kind: SetupCheck.Kind) {
        // A login shell, so Homebrew's PATH and the user's own profile are there as in Terminal.
        model.terminals.open(id: "setup.\(kind.rawValue)", title: "\(fix.label): \(kind.title)", executable: "/bin/zsh", arguments: ["-lc", fix.command])
    }

    private func recheck() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let first = checks.isEmpty
        let before = Set(checks.values.filter(\.ok).map(\.kind))
        let config = model.config
        await withTaskGroup(of: SetupCheck.self) { group in
            for kind in SetupCheck.Kind.allCases { group.addTask { await Setup.check(kind, config: config) } }
            for await check in group { checks[check.kind] = check }
        }
        let after = Set(checks.values.filter(\.ok).map(\.kind))
        guard !first, after != before else { return }
        // A tool just installed or an account just signed in: the sources pick it up now rather than at the next launch.
        model.saveConfig()
        if after.contains(.github), !before.contains(.github) { model.loadRepositories(force: true) }
    }
}

private extension Array where Element: Equatable {
    func before(_ element: Element) -> Element? { firstIndex(of: element).flatMap { $0 > 0 ? self[$0 - 1] : nil } }
    func after(_ element: Element) -> Element? { firstIndex(of: element).flatMap { $0 + 1 < count ? self[$0 + 1] : nil } }
}

/// The Tools and Sign in steps: a row per check.
private struct ChecksPage: View {
    var title: String
    var note: String
    var kinds: [SetupCheck.Kind]
    var checks: [SetupCheck.Kind: SetupCheck]
    var checking: Bool
    var run: (SetupFix, SetupCheck.Kind) -> Void
    var recheck: () -> Void

    var body: some View {
        FormPage(title: title) {
            HStack {
                Text(note).scaled(.secondary).foregroundStyle(.secondary)
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button("Check again", action: recheck).controlSize(.small).disabled(checking)
            }
            .padding(.bottom, 8)
            ForEach(kinds, id: \.self) { kind in
                Hairline()
                CheckRow(kind: kind, check: checks[kind]) { run($0, kind) }
                if checks[kind]?.asksForToken == true, let service = TokenSignIn.Service(kind) {
                    TokenSignIn(service, signedIn: recheck).padding(.leading, 26).padding(.bottom, 14)
                }
            }
        }
    }
}

private struct CheckRow: View {
    var kind: SetupCheck.Kind
    var check: SetupCheck?
    var run: ((SetupFix) -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.title).scaled(.body.weight(.medium))
                    if kind.isRequired { Chip(text: "Required") }
                }
                Text(check?.detail ?? "Checking…").scaled(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if check?.ok == false {
                    Text(kind.without).scaled(.caption).foregroundStyle(kind.isRequired ? .red : .orange)
                }
                // What a fix's press brings up that Desk does not choose, such as GitHub CLI's own permissions.
                if run != nil {
                    ForEach(Array(Set((check?.fixes ?? []).compactMap(\.note))).sorted(), id: \.self) { note in
                        Text(note).scaled(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer()
            if let run {
                ForEach(check?.fixes ?? [], id: \.self) { fix in
                    Button(fix.label) { run(fix) }.controlSize(.small).help(fix.command)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var symbol: String {
        guard let check else { return "circle.dotted" }
        if check.ok { return "checkmark.circle.fill" }
        return kind.isRequired ? "xmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var color: Color {
        guard let check else { return .secondary }
        if check.ok { return .green }
        return kind.isRequired ? .red : .orange
    }
}

/// Where everything stands, what stays off for each thing skipped, and notifications.
private struct FinishPage: View {
    @Environment(AppModel.self) private var model
    var checks: [SetupCheck.Kind: SetupCheck]
    var missing: [String]
    @State private var notifications: UNAuthorizationStatus?

    var body: some View {
        FormPage(title: "Finish") {
            Text(missing.isEmpty ? "Desk has what it needs. Anything still open below can be set up later from Settings → General → Run setup again."
                                 : "Still needed before Desk can show anything: \(missing.joined(separator: ", ")).")
                .scaled(.secondary).foregroundStyle(missing.isEmpty ? Color.secondary : .red)
                .padding(.bottom, 8)
            ForEach(SetupCheck.Kind.allCases, id: \.self) { kind in
                Hairline()
                CheckRow(kind: kind, check: checks[kind])
            }
            Hairline()
            repos.padding(.vertical, 10)
            Hairline()
            notificationRow.padding(.vertical, 10)
        }
        .task { await readNotifications() }
    }

    private var repos: some View {
        let count = model.settings.config.trackedRepos.count
        return HStack(spacing: 10) {
            Image(systemName: count > 0 ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(count > 0 ? .green : .red)
            Text(count > 0 ? "\(count) repos tracked" : "No repo tracked: pick some in the Repos step.").scaled(.body.weight(.medium))
        }
    }

    private var notificationRow: some View {
        HStack(spacing: 10) {
            Image(systemName: notifications == .authorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(notifications == .authorized ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Notifications").scaled(.body.weight(.medium))
                Text(notifications == .authorized ? "Allowed" : "Off: failed CI, review requests and the rest show only inside Desk.")
                    .scaled(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if notifications == .notDetermined {
                Button("Allow") {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                        await readNotifications()
                    }
                }
                .controlSize(.small)
            } else if notifications == .denied {
                Button("Open Notification Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .controlSize(.small)
            }
        }
    }

    /// `swift run` has no bundle, and the notification center will not start without one.
    private func readNotifications() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
