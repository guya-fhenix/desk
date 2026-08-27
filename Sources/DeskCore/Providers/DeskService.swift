import Foundation

public enum DeskError: Error, CustomStringConvertible, Sendable {
    case ghNotFound
    case jiraNotConfigured

    public var description: String {
        switch self {
        case .ghNotFound: return "gh CLI not found. Install it or set the path in Settings."
        case .jiraNotConfigured: return "Jira: set the site, email, and API token in Settings."
        }
    }
}

/// Owns the providers and the on-disk caches. The app and the doctor share it.
public actor DeskService {
    public static let configFile = "config.json"
    private static let claudeCacheFile = "claude-scan.json"

    private var config: DeskConfig
    private let support: AppSupport
    private var github: GitHubProvider?
    private let git = GitProvider()
    private var claude: ClaudeProvider
    private var jira: JiraProvider?
    private var claudeCache: ClaudeScan

    public init(config: DeskConfig, support: AppSupport) {
        self.config = config
        self.support = support
        self.claude = ClaudeProvider(home: config.expandedClaudeHome)
        let cached = try? support.load(ClaudeScan.self, from: Self.claudeCacheFile)
        self.claudeCache = cached?.isCurrent == true ? cached! : ClaudeScan()
        (github, jira) = Self.makeProviders(config)
    }

    public static func loadConfig(support: AppSupport) -> DeskConfig {
        (try? support.load(DeskConfig.self, from: configFile)) ?? DeskConfig()
    }

    public func update(config: DeskConfig) {
        self.config = config
        claude = ClaudeProvider(home: config.expandedClaudeHome)
        (github, jira) = Self.makeProviders(config)
    }

    private static func makeProviders(_ config: DeskConfig) -> (GitHubProvider?, JiraProvider?) {
        let github = config.resolvedGhPath.map { GitHubProvider(ghPath: $0, org: config.githubOrg) }
        guard config.jiraConfigured,
              let token = try? Keychain.read(service: Keychain.jiraService, account: config.jiraSite), !token.isEmpty else {
            return (github, nil)
        }
        return (github, JiraProvider(site: config.jiraSite, email: config.jiraEmail, token: token))
    }

    public var jiraReady: Bool { jira != nil }

    public func refreshGitHub(now: Date = Date()) async throws -> GitHubSnapshot {
        guard let github else { throw DeskError.ghNotFound }
        let since = now.addingTimeInterval(-TimeInterval(config.metricsWeeks) * 7 * 86_400)
        return try await github.snapshot(since: since, now: now)
    }

    public func refreshGit() async -> GitScan {
        await git.scan(roots: config.expandedRepoRoots, org: config.githubOrg)
    }

    public func refreshClaude(gitScan: GitScan) async throws -> (live: [LiveSession], scan: ClaudeScan) {
        let scope = ClaudeScope(
            repoPaths: gitScan.repos.map(\.root) + gitScan.worktrees.map(\.path),
            rootFolders: config.expandedRepoRoots
        )
        let live = try await claude.liveSessions(scope: scope)
        let scan = try await claude.scanTranscripts(scope: scope, previous: claudeCache)
        claudeCache = scan
        try support.save(scan, to: Self.claudeCacheFile)
        return (live, scan)
    }

    public func refreshJira(referencedKeys: [String]) async throws -> [Ticket] {
        guard let jira else { throw DeskError.jiraNotConfigured }
        let mine = try await jira.myOpenIssues()
        let mineKeys = Set(mine.map(\.key))
        let others = try await jira.issues(keys: referencedKeys.filter { !mineKeys.contains($0) })
        return mine + others
    }

    public func jiraProjectKeys() async throws -> [String] {
        guard let jira else { throw DeskError.jiraNotConfigured }
        return try await jira.projectKeys()
    }

    public func approve(url: String) async throws {
        guard let github else { throw DeskError.ghNotFound }
        try await github.approve(url: url)
    }

    public func setJiraToken(_ token: String) throws {
        if token.isEmpty {
            try Keychain.delete(service: Keychain.jiraService, account: config.jiraSite)
        } else {
            try Keychain.write(token, service: Keychain.jiraService, account: config.jiraSite)
        }
        (github, jira) = Self.makeProviders(config)
    }

    public func hasJiraToken() -> Bool {
        ((try? Keychain.read(service: Keychain.jiraService, account: config.jiraSite)) ?? nil).map { !$0.isEmpty } ?? false
    }
}
