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
        case .repos: return "Repositories"
        case .jira: return "Jira"
        case .finish: return "Finish"
        }
    }

    /// The sentence under the step's title; Finish says its own.
    var summary: String {
        switch self {
        case .tools: return "Desk drives these command-line tools and keeps no token of its own."
        case .accounts: return "Each tool holds its own sign-in. GitHub and Jira ask for a token, which Desk hands to the tool and keeps none of."
        case .github: return "The org Desk reads, where your clones live, and whose pull requests stay out of the queue."
        case .repos: return "The repos you work in. Desk watches these and nothing else."
        case .jira: return SettingsPane.jira.summary
        case .finish: return ""
        }
    }
}

/// Setup, in the Desk window in place of everything else, sidebar and all: the steps across the top, and the step's
/// checks or settings in one column under them. A fix runs in your terminal app, where you can follow it and type a
/// password, and the checks run again when you come back to Desk.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var step: SetupStep
    @State private var checks: [SetupCheck.Kind: SetupCheck] = [:]
    @State private var checking = false

    /// A step other than the first is for the debug snapshot.
    init(step: SetupStep = .tools) { _step = State(initialValue: step) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if step == .repos {
                // The org's repos scroll in a list of their own.
                column { ReposSettings() }
            } else {
                ScrollView { column { page } }
            }
        }
        .padding(EdgeInsets(top: 18, leading: 28, bottom: 24, trailing: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.ground)
        .savesSettingsDraft()
        .task { await recheck() }
        // A fix runs in your terminal app: coming back to Desk is the moment its check may have changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await recheck() }
        }
    }

    /// The app's mark, the steps, and where you are in them.
    private var header: some View {
        let index = SetupStep.allCases.firstIndex(of: step) ?? 0
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                AppMark()
                Text("Fhenix Desk").scaled(.body.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SetupStepper(step: $step)
            Text("Step \(index + 1) of \(SetupStep.allCases.count)").scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: 32)
    }

    /// The step in a centred column at most 760 pt wide: its title and sentence, its body, and Back and Continue under it.
    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(step.title).scaled(.title).tracking(-0.3)
                    Text(summary).foregroundStyle(step == .finish && !missingRequired.isEmpty ? Theme.danger : Theme.quiet)
                        .frame(maxWidth: 620, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if step == .tools || step == .accounts || step == .finish {
                    if checking { ProgressView().controlSize(.small) }
                    Button("Check again") { Task { await recheck() } }.buttonStyle(.desk(.secondary, .small)).disabled(checking)
                }
            }
            content()
            footer
        }
        .frame(maxWidth: 760, maxHeight: step == .repos ? .infinity : nil, alignment: .topLeading)
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }

    private var summary: String {
        guard step == .finish else { return step.summary }
        return missingRequired.isEmpty
            ? "Desk has what it needs. Anything still open below can be set up later from Settings → General → Run setup again."
            : "Still needed before Desk can show anything: \(missingRequired.joined(separator: ", "))."
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .tools: checksCard(SetupCheck.Kind.tools)
        case .accounts: checksCard(SetupCheck.Kind.accounts)
        case .github: VStack(alignment: .leading, spacing: 0) { GitHubSettings() }
        case .repos: EmptyView()
        case .jira: VStack(alignment: .leading, spacing: 0) { JiraSettings() }
        case .finish: SetupFinish(checks: checks)
        }
    }

    /// The Tools and Sign in steps: a row per check, and under a sign-in that wants one, the token box.
    private func checksCard(_ kinds: [SetupCheck.Kind]) -> some View {
        SetupCard {
            ForEach(kinds, id: \.self) { kind in
                SetupCheckRow(kind: kind, check: checks[kind]) { run($0, for: kind) }
                if checks[kind]?.asksForToken == true, let service = TokenSignIn.Service(kind) {
                    TokenSignIn(service) { Task { await recheck() } }.padding(EdgeInsets(top: 12, leading: 30, bottom: 14, trailing: 0))
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(step == .jira && !jiraReady
                 ? "Pick where Desk moves a ticket at each step, or leave the project empty to skip Jira."
                 : "Desk never stores a token: gh, acli and Claude Code keep their own.")
                .scaled(.secondary).foregroundStyle(Theme.quiet)
            Spacer(minLength: 16)
            Button("Later") { model.showingSetup = false }
                .buttonStyle(.desk(.quiet, .large))
                .help("Close setup for now. It opens again on the next launch until you finish it.")
            if let previous = SetupStep.allCases.before(step) {
                Button("Back") { step = previous }.buttonStyle(.desk(.secondary, .large))
            }
            if let next = SetupStep.allCases.after(step) {
                Button("Continue") { step = next }.buttonStyle(.desk(.primary, .large)).keyboardShortcut(.defaultAction)
                    .disabled(step == .jira && !jiraReady)
            } else {
                Button("Finish") { model.completeSetup() }
                    .buttonStyle(.desk(.primary, .large))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!missingRequired.isEmpty)
            }
        }
        .padding(.top, 4)
    }

    /// No project, which leaves Jira off, or a project with all three moves picked from its statuses.
    private var jiraReady: Bool {
        let config = model.settings.config
        return config.jiraProjectKey.isEmpty
            || ![config.jiraInProgressStatus, config.jiraReviewStatus, config.jiraDoneStatus].contains(where: \.isEmpty)
    }

    /// What has to be there before Desk can show anything: git, gh signed in, and a repo to watch.
    private var missingRequired: [String] {
        var missing = SetupCheck.Kind.allCases.filter { $0.isRequired && checks[$0]?.ok != true }.map(\.title)
        if model.settings.config.trackedRepos.isEmpty { missing.append("A tracked repo") }
        return missing
    }

    /// In your terminal app, in a login shell, so Homebrew's PATH and your own profile are there.
    private func run(_ fix: SetupFix, for kind: SetupCheck.Kind) {
        model.runInTerminal(fix.command, name: "setup-\(kind.rawValue)")
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

/// The steps across the top: those behind you ticked, yours numbered on the accent's tint, the rest numbered quietly,
/// with a hairline between each. Any of them is a press away.
private struct SetupStepper: View {
    @Binding var step: SetupStep

    var body: some View {
        let current = SetupStep.allCases.firstIndex(of: step) ?? 0
        HStack(spacing: 10) {
            ForEach(Array(SetupStep.allCases.enumerated()), id: \.element) { index, item in
                if index > 0 { Rectangle().fill(Theme.control).frame(width: 32, height: 1).accessibilityHidden(true) }
                Button { step = item } label: {
                    HStack(spacing: 8) {
                        mark(index + 1, done: index < current, here: index == current)
                        Text(item.title)
                            .scaled(.secondary.weight(index == current ? .semibold : .regular))
                            .foregroundStyle(index == current ? Theme.ink : Theme.quiet)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step \(index + 1), \(item.title)\(index < current ? ", done" : "")")
                .accessibilityAddTraits(index == current ? .isSelected : [])
            }
        }
        .fixedSize()
    }

    private func mark(_ number: Int, done: Bool, here: Bool) -> some View {
        ZStack {
            if done {
                Circle().strokeBorder(Theme.quiet, lineWidth: 1.5)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.quiet)
            } else {
                Circle().fill(here ? Theme.tint : Theme.surface)
                Circle().strokeBorder(here ? Theme.tintLine : Theme.control)
                Text("\(number)").scaled(AppTextStyle(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(here ? Theme.accentInk : Theme.quiet)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// The white card the checks sit in.
private struct SetupCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 16)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.rule))
    }
}

/// One row of a setup card: a tick, a dot when it needs you or a spinner while it is read; its name and what was found;
/// and on the right its state or the press that fixes it. A row that needs you is tinted edge to edge.
private struct SetupRow<Detail: View, Trailing: View>: View {
    var title: String
    /// Nil while it is being checked.
    var ok: Bool?
    var required = false
    @ViewBuilder var detail: Detail
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let needsYou = ok == false
        HStack(spacing: 12) {
            Group {
                switch ok {
                case nil: ProgressView().controlSize(.mini)
                case true?: Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ok)
                case false?: Circle().fill(Theme.accentInk).frame(width: 10, height: 10)
                }
            }
            .frame(width: 18)
            .accessibilityLabel(ok == nil ? "Checking" : ok == true ? "Done" : "Needs you")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold)
                    if required { StageChip2(text: "Required", onTint: needsYou) }
                }
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing.fixedSize()
        }
        .padding(.vertical, needsYou ? 12 : 8)
        .padding(.horizontal, needsYou ? 16 : 0)
        .frame(minHeight: 56)
        .background(needsYou ? Theme.tint : .clear)
        .overlay(alignment: .top) { if needsYou { Rectangle().fill(Theme.tintLine).frame(height: 1) } }
        .overlay(alignment: .bottom) { if needsYou { Rectangle().fill(Theme.tintLine).frame(height: 1) } }
        .padding(.horizontal, needsYou ? -16 : 0)
    }
}

/// A check as a setup row: what Desk ran to read it in DM Mono and what came back, what stays off while it fails, and
/// its fixes, each opening your terminal app on its command.
private struct SetupCheckRow: View {
    var kind: SetupCheck.Kind
    var check: SetupCheck?
    var run: ((SetupFix) -> Void)?
    @Environment(\.textScale) private var scale

    var body: some View {
        SetupRow(title: kind.title, ok: check?.ok, required: kind.isRequired) {
            Text("\(Text(command).font(AppTextStyle.code.font(scale: scale)).foregroundStyle(Theme.ink)) · \(check?.detail ?? "Checking…")")
                .foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if check?.ok == false {
                Text(kind.without).scaled(.secondary).foregroundStyle(kind.isRequired ? Theme.danger : Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // What a fix's press brings up that Desk does not choose, such as GitHub CLI's own permissions.
            if run != nil {
                ForEach(Array(Set((check?.fixes ?? []).compactMap(\.note))).sorted(), id: \.self) { note in
                    Text(note).scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                }
            }
        } trailing: {
            HStack(spacing: 8) {
                let fixes = run == nil ? [] : check?.fixes ?? []
                if let check, check.ok || fixes.isEmpty { Text(state(check.ok)).foregroundStyle(Theme.quiet) }
                ForEach(fixes, id: \.self) { fix in
                    Button(fix.label) { run?(fix) }.buttonStyle(.desk(.secondary, check?.ok == true ? .small : .regular)).help(fix.command)
                }
            }
        }
    }

    /// "Signed in" for an account, "Installed" for a tool.
    private func state(_ ok: Bool) -> String {
        switch kind {
        case .github, .jira, .claudeAccount: return ok ? "Signed in" : "Not signed in"
        default: return ok ? "Installed" : "Missing"
        }
    }

    /// What `Setup.check` runs, or reads, to say how this one stands.
    private var command: String {
        switch kind {
        case .homebrew: return "brew --version"
        case .commandLineTools: return "xcode-select -p"
        case .gh: return "gh --version"
        case .acli: return "acli --version"
        case .claude: return "claude --version"
        case .tmux: return "tmux -V"
        case .github: return "gh auth status"
        case .jira: return "acli jira auth status"
        case .claudeAccount: return "claude auth status"
        case .workflowPlugin: return "~/.claude/plugins"
        }
    }
}

/// Where everything stands, what stays off for each thing skipped, and notifications.
private struct SetupFinish: View {
    @Environment(AppModel.self) private var model
    var checks: [SetupCheck.Kind: SetupCheck]
    @State private var notifications: UNAuthorizationStatus?

    var body: some View {
        let count = model.settings.config.trackedRepos.count
        SetupCard {
            ForEach(SetupCheck.Kind.allCases, id: \.self) { kind in
                SetupCheckRow(kind: kind, check: checks[kind])
            }
            SetupRow(title: "Repositories", ok: count > 0, required: true) {
                Text(count > 0 ? "\(count) repos tracked" : "No repo tracked: pick some in the Repos step.").foregroundStyle(Theme.quiet)
            } trailing: {
                EmptyView()
            }
            SetupRow(title: "Notifications", ok: notifications == .authorized) {
                Text(notifications == .authorized ? "Allowed" : "Off: failed CI, review requests and the rest show only inside Desk.")
                    .foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            } trailing: {
                if notifications == .notDetermined {
                    Button("Allow") {
                        Task {
                            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                            await readNotifications()
                        }
                    }
                    .buttonStyle(.desk)
                } else if notifications == .denied {
                    Button("Open Notification Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                    .buttonStyle(.desk)
                }
            }
        }
        .task { await readNotifications() }
    }

    /// `swift run` has no bundle, and the notification center will not start without one.
    private func readNotifications() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
