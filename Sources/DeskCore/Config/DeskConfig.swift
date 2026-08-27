import Foundation

public struct DeskConfig: Codable, Sendable, Equatable {
    public var repoRoots: [String] = ["~/Repos"]
    public var githubOrg: String = "FhenixProtocol"
    public var ghPath: String = ""
    public var botLogins: [String] = ["claude", "github-actions", "dependabot", "renovate"]
    public var automatedTitlePrefixes: [String] = ["Update Submodule from"]
    public var jiraSite: String = "fhenix.atlassian.net"
    public var jiraEmail: String = ""
    public var jiraProjectKeys: [String] = ["PRO"]
    public var claudeHome: String = "~/.claude"
    public var githubPollSeconds: Int = 180
    public var gitPollSeconds: Int = 60
    public var claudePollSeconds: Int = 30
    public var jiraPollSeconds: Int = 300
    public var stalePullRequestDays: Int = 3
    public var claudeWaitingMinutes: Int = 10
    public var unpushedWorkDays: Int = 2
    public var metricsWeeks: Int = 8
    public var notificationsEnabled: Bool = true
    public var openWindowOnLaunch: Bool = false

    public init() {}

    public var botLoginSet: Set<String> { Set(botLogins) }
    public var automation: Automation { Automation(logins: botLoginSet, titlePrefixes: automatedTitlePrefixes) }
    public var expandedRepoRoots: [String] { repoRoots.map { ($0 as NSString).expandingTildeInPath } }
    public var expandedClaudeHome: String { (claudeHome as NSString).expandingTildeInPath }
    public var resolvedGhPath: String? { ghPath.isEmpty ? Shell.which("gh") : ghPath }
    public var jiraConfigured: Bool { !jiraSite.isEmpty && !jiraEmail.isEmpty }
}

/// Files the app owns under ~/Library/Application Support/Fhenix Desk.
public struct AppSupport: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("Fhenix Desk", isDirectory: true)
        }
    }

    public func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    public func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        let url = url(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSON.decoder().decode(T.self, from: Data(contentsOf: url))
    }

    public func save<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSON.encoder().encode(value).write(to: url(name), options: .atomic)
    }
}
