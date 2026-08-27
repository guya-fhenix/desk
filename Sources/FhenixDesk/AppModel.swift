import AppKit
import DeskCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var state: DeskState
    var refreshing: Set<Source> = []
    var configError: String?
    var jiraHasToken = false

    private let support = AppSupport()
    private let service: DeskService
    private let notifier: Notifier
    private var loops: [Source: Task<Void, Never>] = [:]

    init() {
        let config = DeskService.loadConfig(support: support)
        state = DeskState(config: config)
        service = DeskService(config: config, support: support)
        notifier = Notifier(support: support)
        Task { await self.start() }
    }

    var config: DeskConfig {
        get { state.config }
        set { state.config = newValue }
    }

    var urgentCount: Int { state.nudges.filter { $0.severity >= .warning }.count }

    func start() async {
        jiraHasToken = await service.hasJiraToken()
        for source in Source.allCases where loops[source] == nil {
            loops[source] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refresh(source)
                    let seconds = self.interval(for: source)
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }
        }
    }

    private func interval(for source: Source) -> Int {
        switch source {
        case .github: return max(config.githubPollSeconds, 30)
        case .git: return max(config.gitPollSeconds, 15)
        case .claude: return max(config.claudePollSeconds, 10)
        case .jira: return max(config.jiraPollSeconds, 60)
        }
    }

    func refreshAll() {
        for source in Source.allCases {
            Task { await refresh(source) }
        }
    }

    func refresh(_ source: Source) async {
        guard !refreshing.contains(source) else { return }
        refreshing.insert(source)
        defer { refreshing.remove(source) }
        do {
            switch source {
            case .github:
                state.github = try await service.refreshGitHub()
            case .git:
                let firstScan = state.gitScan == nil
                let scan = await service.refreshGit()
                state.gitScan = scan
                state.errors[.git] = scan.errors.isEmpty ? nil : scan.errors.joined(separator: "\n")
                // Claude data depends on the repo list, so the first scan unblocks it right away.
                if firstScan { Task { await refresh(.claude) } }
            case .claude:
                guard let gitScan = state.gitScan else { return }
                let result = try await service.refreshClaude(gitScan: gitScan)
                state.liveSessions = result.live
                state.claudeScan = result.scan
            case .jira:
                guard await service.jiraReady else {
                    state.errors[.jira] = nil
                    state.lastRefresh[.jira] = Date()
                    return
                }
                state.tickets = try await service.refreshJira(referencedKeys: state.referencedTicketKeys)
            }
            if source != .git { state.errors[source] = nil }
            state.lastRefresh[source] = Date()
        } catch {
            state.errors[source] = "\(error)"
        }
        state.recompute()
        notifier.deliver(state.nudges, post: config.notificationsEnabled && allSourcesReported)
    }

    private var allSourcesReported: Bool {
        Source.allCases.allSatisfy { state.lastRefresh[$0] != nil || state.errors[$0] != nil }
    }

    func saveConfig() {
        do {
            try support.save(config, to: DeskService.configFile)
            configError = nil
        } catch {
            configError = "\(error)"
        }
        Task {
            await service.update(config: config)
            jiraHasToken = await service.hasJiraToken()
            refreshAll()
        }
    }

    func setJiraToken(_ token: String) {
        Task {
            do {
                try await service.setJiraToken(token)
                configError = nil
            } catch {
                configError = "\(error)"
            }
            jiraHasToken = await service.hasJiraToken()
            await refresh(.jira)
        }
    }

    func approve(_ pr: PullRequest) {
        Task {
            do {
                try await service.approve(url: pr.url)
                await refresh(.github)
            } catch {
                state.errors[.github] = "\(error)"
            }
        }
    }

    func open(_ url: String?) {
        guard let url, let parsed = URL(string: url) else { return }
        NSWorkspace.shared.open(parsed)
    }

    func reveal(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func openTerminal(_ path: String?) {
        guard let path else { return }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func act(on nudge: Nudge) {
        if let url = nudge.url { open(url) } else if let path = nudge.path { openTerminal(path) }
    }
}
