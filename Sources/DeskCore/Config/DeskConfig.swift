import Foundation

public struct DeskConfig: Codable, Sendable, Equatable {
    public var repoRoots: [String] = ["~/Repos"]
    public var githubOrg: String = "FhenixProtocol"
    /// The org team asked to review a PR when it leaves draft, and again after each round of fixes.
    public var reviewTeam: String = "protocol-team"
    /// `owner/name` of the repositories to watch, picked in Settings from what GitHub lists for the org.
    /// Empty by default: the app tracks nothing until you say so.
    public var trackedRepos: [String] = []
    public var ghPath: String = ""
    /// PRs by these authors stay out of the review queue.
    public var botLogins: [String] = ["claude", "github-actions", "dependabot", "renovate"]
    /// PRs a workflow opens under a human token: recognised by title and kept out of the review queue too.
    public var automatedTitlePrefixes: [String] = ["Update Submodule from"]
    public var jiraProjectKeys: [String] = ["PRO"]
    /// The status a ticket takes while one of its pull requests waits for review, and the one it takes
    /// once they have all landed. Names, not ids: they are what `acli jira workitem transition --status`
    /// wants, emoji and all. Empty turns that half of the sync off.
    /// Where a ticket goes when you start planning it, so the next glance says somebody is on it.
    public var jiraInProgressStatus: String = "In Progress"
    public var jiraReviewStatus: String = "👀 Review Ready"
    public var jiraDoneStatus: String = "Done"
    public var githubPollSeconds: Int = 180
    public var gitPollSeconds: Int = 60
    public var jiraPollSeconds: Int = 300
    public var notificationsEnabled: Bool = true
    public var claudePath: String = ""
    /// The Atlassian CLI. It owns the Jira credentials, the way `gh` owns the GitHub ones.
    public var acliPath: String = ""
    /// Where review worktrees live: `<reviewRoot>/<repoName>/pr-<number>`.
    public var reviewRoot: String = "~/Repos/.reviews"
    public var reviewModel: String = ""
    public var reviewEffort: String = ""
    public var cleanupReviewsOnMerge: Bool = true
    /// How many reviews may run at once. `Shell` allows 8 processes and `GitProvider.scanRepo` wants 6 of
    /// them, so 2 is what is left; more and every git scan and gh call queues behind a review that runs
    /// for minutes. Reviews are started by hand, so this only bounds how many you can have going.
    public var reviewConcurrency: Int = 2
    /// A headless run is one long process. `Shell`'s 90 s default would kill every review.
    public var reviewTimeoutMinutes: Int = 20
    /// Prompt texts edited in Settings, by `PromptID`. Only edits are kept: a prompt you never touched
    /// follows the app's own text when that changes.
    public var prompts: [String: String] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case repoRoots, githubOrg, reviewTeam, trackedRepos, ghPath, botLogins, automatedTitlePrefixes, jiraProjectKeys
        case jiraInProgressStatus, jiraReviewStatus, jiraDoneStatus
        case githubPollSeconds, gitPollSeconds, jiraPollSeconds
        case notificationsEnabled
        case claudePath, acliPath, reviewRoot, reviewModel, reviewEffort, cleanupReviewsOnMerge
        case reviewConcurrency, reviewTimeoutMinutes, prompts
    }

    /// Every key is optional so a config.json written before a field existed still loads. Synthesized
    /// decoding would fail on the missing key and the app would silently fall back to defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeskConfig()
        repoRoots = try c.decodeIfPresent([String].self, forKey: .repoRoots) ?? d.repoRoots
        githubOrg = try c.decodeIfPresent(String.self, forKey: .githubOrg) ?? d.githubOrg
        reviewTeam = try c.decodeIfPresent(String.self, forKey: .reviewTeam) ?? d.reviewTeam
        trackedRepos = try c.decodeIfPresent([String].self, forKey: .trackedRepos) ?? d.trackedRepos
        ghPath = try c.decodeIfPresent(String.self, forKey: .ghPath) ?? d.ghPath
        botLogins = try c.decodeIfPresent([String].self, forKey: .botLogins) ?? d.botLogins
        automatedTitlePrefixes = try c.decodeIfPresent([String].self, forKey: .automatedTitlePrefixes) ?? d.automatedTitlePrefixes
        jiraProjectKeys = try c.decodeIfPresent([String].self, forKey: .jiraProjectKeys) ?? d.jiraProjectKeys
        jiraInProgressStatus = try c.decodeIfPresent(String.self, forKey: .jiraInProgressStatus) ?? d.jiraInProgressStatus
        jiraReviewStatus = try c.decodeIfPresent(String.self, forKey: .jiraReviewStatus) ?? d.jiraReviewStatus
        jiraDoneStatus = try c.decodeIfPresent(String.self, forKey: .jiraDoneStatus) ?? d.jiraDoneStatus
        githubPollSeconds = try c.decodeIfPresent(Int.self, forKey: .githubPollSeconds) ?? d.githubPollSeconds
        gitPollSeconds = try c.decodeIfPresent(Int.self, forKey: .gitPollSeconds) ?? d.gitPollSeconds
        jiraPollSeconds = try c.decodeIfPresent(Int.self, forKey: .jiraPollSeconds) ?? d.jiraPollSeconds
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? d.claudePath
        acliPath = try c.decodeIfPresent(String.self, forKey: .acliPath) ?? d.acliPath
        reviewRoot = try c.decodeIfPresent(String.self, forKey: .reviewRoot) ?? d.reviewRoot
        reviewModel = try c.decodeIfPresent(String.self, forKey: .reviewModel) ?? d.reviewModel
        reviewEffort = try c.decodeIfPresent(String.self, forKey: .reviewEffort) ?? d.reviewEffort
        cleanupReviewsOnMerge = try c.decodeIfPresent(Bool.self, forKey: .cleanupReviewsOnMerge) ?? d.cleanupReviewsOnMerge
        reviewConcurrency = try c.decodeIfPresent(Int.self, forKey: .reviewConcurrency) ?? d.reviewConcurrency
        reviewTimeoutMinutes = try c.decodeIfPresent(Int.self, forKey: .reviewTimeoutMinutes) ?? d.reviewTimeoutMinutes
        prompts = try c.decodeIfPresent([String: String].self, forKey: .prompts) ?? d.prompts
    }

    /// Lowercased `owner/name`, which is how remotes and search qualifiers are compared.
    public var trackedRepoSlugs: [String] { trackedRepos.map { $0.lowercased() } }

    public var botLoginSet: Set<String> { Set(botLogins) }
    public var automation: Automation { Automation(logins: botLoginSet, titlePrefixes: automatedTitlePrefixes) }
    public var expandedRepoRoots: [String] { repoRoots.map { ($0 as NSString).expandingTildeInPath } }
    public var expandedReviewRoot: String { (reviewRoot as NSString).expandingTildeInPath }
    public var resolvedGhPath: String? { ghPath.isEmpty ? Shell.which("gh") : ghPath }
    public var resolvedClaudePath: String? { claudePath.isEmpty ? Shell.which("claude") : claudePath }
    public var resolvedAcliPath: String? { acliPath.isEmpty ? Shell.which("acli") : acliPath }
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
