import Foundation

/// A command that puts a setup check right, run in a terminal tab so you can follow it and answer what it asks.
public struct SetupFix: Sendable, Hashable {
    public var label: String
    public var command: String
    /// What the press brings up that Desk does not choose, said beside its button.
    public var note: String?

    public init(_ label: String, _ command: String, note: String? = nil) {
        self.label = label
        self.command = command
        self.note = note
    }
}

/// One thing first-run setup looks at: a command-line tool Desk drives, or an account one of them is signed in to.
/// Each is read off the tool itself, every time; Desk keeps none of it.
public struct SetupCheck: Identifiable, Sendable, Equatable {
    public enum Kind: String, CaseIterable, Sendable {
        case homebrew, commandLineTools, gh, acli, claude, github, jira, claudeAccount, workflowPlugin

        public static let tools: [Kind] = [.homebrew, .commandLineTools, .gh, .acli, .claude]
        public static let accounts: [Kind] = [.github, .jira, .claudeAccount, .workflowPlugin]

        public var title: String {
            switch self {
            case .homebrew: return "Homebrew"
            case .commandLineTools: return "Command Line Tools (git)"
            case .gh: return "GitHub CLI (gh)"
            case .acli: return "Atlassian CLI (acli)"
            case .claude: return "Claude Code"
            case .github: return "GitHub"
            case .jira: return "Jira"
            case .claudeAccount: return "Claude"
            case .workflowPlugin: return "fhenix-workflow plugin"
            }
        }

        /// Without these Desk shows nothing at all; the rest each turn one part off.
        public var isRequired: Bool { self == .commandLineTools || self == .gh || self == .github }

        /// What stays off while it is missing.
        public var without: String {
            switch self {
            case .homebrew: return "Installs gh and acli here; without it, install them yourself."
            case .commandLineTools: return "Required: git reads every clone and worktree."
            case .gh: return "Required: every pull request comes through gh."
            case .acli: return "Jira tickets and the ticket sync stay off."
            case .claude: return "No sessions: Start, Run /pre-pr, Fix it and review sessions stay off."
            case .github: return "Required: gh must be signed in, with the read:org scope, to list the org's pull requests."
            case .jira: return "Jira tickets and the ticket sync stay off."
            case .claudeAccount: return "Sessions cannot start."
            case .workflowPlugin: return "Run /pre-pr and Start review need it; Start review needs 0.8.0 or later."
            }
        }
    }

    public var kind: Kind
    public var ok: Bool
    /// What was found, or what is wrong, in a line.
    public var detail: String
    /// What to run about it. An ok check can still have one, such as switching the GitHub account.
    public var fixes: [SetupFix]
    /// Whether to offer a token sign-in here: the tool is there but signed out or broken, or Jira signed in through the
    /// browser, which Jira caps by the hour.
    public var asksForToken: Bool

    public var id: Kind { kind }

    public init(_ kind: Kind, ok: Bool, detail: String, fixes: [SetupFix] = [], asksForToken: Bool = false) {
        self.kind = kind
        self.ok = ok
        self.detail = detail
        self.fixes = fixes
        self.asksForToken = asksForToken
    }
}

/// One `gh` account on github.com, as `gh auth status --json hosts` lists it.
public struct GitHubAccount: Sendable, Equatable, Decodable {
    public var login: String
    public var active: Bool
    /// "success" while the token works.
    public var state: String
    /// Comma-separated, and missing for tokens gh cannot read scopes off, such as fine-grained ones.
    public var scopes: String?

    public init(login: String, active: Bool, state: String = "success", scopes: String? = nil) {
        self.login = login
        self.active = active
        self.state = state
        self.scopes = scopes
    }
}

public enum Setup {
    /// GitHub CLI's sign-in page lists its own scopes beside the ones Desk asks for: its minimum, and Workflow whenever it
    /// is git's login over HTTPS (gh adds it so git can push changes to workflow files), and a refresh asks again for
    /// every scope the token already has. Said beside the buttons that open that page, so Workflow is no surprise.
    static let githubScopesNote = "GitHub CLI asks for its own permissions too, Workflow among them: it signs git in over HTTPS, "
        + "and pushing changes to workflow files needs it. Desk itself needs only repo and read:org."
    static let githubLogin = SetupFix(
        "Use the browser", "gh auth login --hostname github.com --web --git-protocol https --scopes read:org", note: githubScopesNote
    )
    static let marketplace = "FhenixProtocol/claude-marketplace"

    /// A classic token with the scopes `gh auth login --with-token` insists on ticked: repo and read:org for Desk, gist for gh.
    public static let githubTokenPage = URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org,gist&description=Fhenix%20Desk")!
    public static let jiraTokenPage = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!

    /// Signs gh in with a token. It goes on stdin, never in the arguments, and gh keeps it, as a browser sign-in's would be;
    /// then gh signs git in over HTTPS with it, which the browser flow does by itself.
    public static func signInGitHub(gh: String, token: String, run: ShellRun = Shell.run) async throws {
        try await Shell.output(gh, ["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--with-token"],
                               stdin: Data((token.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8), run: run)
        try await Shell.output(gh, ["auth", "setup-git", "--hostname", "github.com"], run: run)
    }

    /// Signs acli in to Jira with an API token, on stdin. acli keeps one sign-in per account, so this one replaces a
    /// browser sign-in to the same account rather than sitting beside it.
    public static func signInJira(acli: String, site: String, email: String, token: String, run: ShellRun = Shell.run) async throws {
        let site = site.trimmingCharacters(in: .whitespaces)
        let email = email.trimmingCharacters(in: .whitespaces)
        try await Shell.output(acli, ["jira", "auth", "login", "--site", site, "--email", email, "--token"],
                               stdin: Data((token.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8), run: run)
    }

    public static func check(_ kind: SetupCheck.Kind, config: DeskConfig, home: String = ClaudeJobs.home) async -> SetupCheck {
        switch kind {
        case .homebrew:
            return await tool(kind, Shell.which("brew"), install: #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#)
        case .commandLineTools:
            // Not `git --version`: without the tools, /usr/bin/git is a stub that pops the installer up.
            guard let result = try? await Shell.run("/usr/bin/xcode-select", ["-p"]), result.status == 0 else {
                return SetupCheck(kind, ok: false, detail: "Not installed. macOS opens its own installer; press Check again once it is done.",
                                  fixes: [SetupFix("Install", "xcode-select --install")])
            }
            return SetupCheck(kind, ok: true, detail: result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .gh:
            let check = await tool(kind, config.resolvedGhPath, install: "brew install gh")
            guard check.ok, let version = ghVersion(in: check.detail), version.lexicographicallyPrecedes(minimumGh) else { return check }
            return SetupCheck(kind, ok: false, detail: "\(check.detail). Desk needs 2.81.0 or later: the first gh that reports who is signed in as JSON, which the GitHub check reads.",
                              fixes: [SetupFix("Upgrade", "brew upgrade gh")])
        case .acli:
            return await tool(kind, config.resolvedAcliPath, install: "brew install atlassian/acli/acli")
        case .claude:
            return await tool(kind, config.resolvedClaudePath, install: "curl -fsSL https://claude.ai/install.sh | bash")
        case .github:
            guard let gh = config.resolvedGhPath else { return SetupCheck(kind, ok: false, detail: "Install the GitHub CLI first.") }
            // Exits 1 when nobody is signed in, with the JSON still on stdout.
            guard let result = try? await Shell.run(gh, ["auth", "status", "--hostname", "github.com", "--json", "hosts"]) else {
                return SetupCheck(kind, ok: false, detail: "gh didn't answer; press Check again.")
            }
            return github(statusOutput: result.stdout, stderr: result.stderr)
        case .jira:
            guard let acli = config.resolvedAcliPath else { return SetupCheck(kind, ok: false, detail: "Install the Atlassian CLI first.") }
            return jira((try? await Shell.output(acli, ["jira", "auth", "status"])).flatMap(JiraDecoding.account(fromStatus:)))
        case .claudeAccount:
            guard let claude = config.resolvedClaudePath else { return SetupCheck(kind, ok: false, detail: "Install Claude Code first.") }
            let result = try? await Shell.run(claude, ["auth", "status", "--json"])
            guard let email = result.flatMap({ claudeAccount(from: $0.stdout) }) else {
                return SetupCheck(kind, ok: false, detail: "Not signed in.", fixes: [SetupFix("Sign in", "claude auth login")])
            }
            return SetupCheck(kind, ok: true, detail: email.isEmpty ? "Signed in" : "Signed in as \(email)")
        case .workflowPlugin:
            guard config.resolvedClaudePath != nil else { return SetupCheck(kind, ok: false, detail: "Install Claude Code first.") }
            return workflowPlugin(
                marketplaces: FileManager.default.contents(atPath: "\(home)/plugins/known_marketplaces.json"),
                installed: FileManager.default.contents(atPath: "\(home)/plugins/installed_plugins.json")
            )
        }
    }

    /// A tool on disk: its version and where it is, or the command that installs it.
    private static func tool(_ kind: SetupCheck.Kind, _ path: String?, install: String) async -> SetupCheck {
        guard let path else { return SetupCheck(kind, ok: false, detail: "Not installed.", fixes: [SetupFix("Install", install)]) }
        let version = (try? await Shell.output(path, ["--version"], timeout: 20))
            .flatMap { $0.split(separator: "\n").first.map(String.init) }
        return SetupCheck(kind, ok: true, detail: [version, path].compactMap { $0 }.joined(separator: " · "))
    }

    /// The oldest gh Desk works with: 2.81.0 is the first whose `gh auth status` reports sign-ins as JSON. An older one
    /// rejected `--json`, which read as nobody signed in, so Setup asked for a sign-in that could never satisfy it.
    public static let minimumGh = [2, 81, 0]

    /// The version in gh's own first line, "gh version 2.69.0 (2025-03-19)", as numbers to compare.
    public static func ghVersion(in text: String) -> [Int]? {
        guard let match = text.firstMatch(of: /gh version (\d+)\.(\d+)\.(\d+)/) else { return nil }
        return [match.1, match.2, match.3].compactMap { Int($0) }
    }

    /// The accounts `gh auth status --json hosts` listed, none when nobody is signed in; nil when what it printed is
    /// not that JSON at all.
    public static func githubAccounts(from data: Data) -> [GitHubAccount]? {
        struct Status: Decodable { var hosts: [String: [GitHubAccount]] }
        return (try? JSONDecoder().decode(Status.self, from: data)).map { $0.hosts["github.com"] ?? [] }
    }

    /// The GitHub check from what `gh auth status` printed: the accounts it lists, or, when it printed none of its JSON,
    /// gh's own complaint — an old gh rejecting `--json`, say — rather than "not signed in", which a sign-in cannot fix.
    public static func github(statusOutput stdout: Data, stderr: String) -> SetupCheck {
        guard let accounts = githubAccounts(from: stdout) else {
            let reason = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "it printed nothing"
            return SetupCheck(.github, ok: false, detail: "gh couldn't say who is signed in: \(reason)")
        }
        return github(accounts)
    }

    /// Desk runs as gh's active account, which needs `repo` and `read:org`: the org's repos and teams are behind the second.
    /// GitHub drops a scope another one implies, so a `write:org` or `admin:org` token lists no `read:org` but has it.
    public static func github(_ accounts: [GitHubAccount]) -> SetupCheck {
        guard let active = accounts.first(where: \.active) else {
            return SetupCheck(.github, ok: false, detail: "Not signed in.", fixes: [githubLogin], asksForToken: true)
        }
        guard active.state == "success" else {
            return SetupCheck(.github, ok: false, detail: "Signed in as \(active.login), but the token no longer works.",
                              fixes: [githubLogin], asksForToken: true)
        }
        let scopes = Set((active.scopes ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = [("repo", ["repo"]), ("read:org", ["read:org", "write:org", "admin:org"])]
            .filter { _, any in any.allSatisfy { !scopes.contains($0) } }.map(\.0)
        if active.scopes != nil, !missing.isEmpty {
            return SetupCheck(.github, ok: false, detail: "Signed in as \(active.login), without the \(missing.joined(separator: " and ")) scope.",
                              fixes: [SetupFix("Add scopes", "gh auth refresh --hostname github.com --scopes repo,read:org", note: githubScopesNote)],
                              asksForToken: true)
        }
        let others = accounts.filter { !$0.active }.map(\.login)
        guard !others.isEmpty else { return SetupCheck(.github, ok: true, detail: "Signed in as \(active.login)") }
        return SetupCheck(.github, ok: true, detail: "Signed in as \(active.login). Also signed in: \(others.joined(separator: ", ")); Desk uses \(active.login).",
                          fixes: [SetupFix("Switch account", "gh auth switch --hostname github.com")])
    }

    /// The Jira check from acli's sign-in, nil when it has none. A browser sign-in works, so it is ok, but it still asks
    /// for a token: Jira caps it by the hour, which once stopped the ticket sync for hours at a time.
    public static func jira(_ account: JiraAccount?) -> SetupCheck {
        guard let account else {
            return SetupCheck(.jira, ok: false, detail: "Not signed in.", fixes: [SetupFix("Use the browser", "acli jira auth login --web")],
                              asksForToken: true)
        }
        let how = account.signedInWithBrowser ? "through the browser" : "with an API token"
        return SetupCheck(.jira, ok: true, detail: "Signed in to \(account.site)\(account.email.map { " as \($0)" } ?? "") \(how)",
                          asksForToken: account.signedInWithBrowser)
    }

    /// The signed-in email off `claude auth status --json`, empty when it names none; nil when nobody is signed in.
    public static func claudeAccount(from data: Data) -> String? {
        struct Status: Decodable { var loggedIn: Bool; var email: String? }
        guard let status = try? JSONDecoder().decode(Status.self, from: data), status.loggedIn else { return nil }
        return status.email ?? ""
    }

    /// Installed anywhere, user-wide or for one repo, is enough here: Fhenix repos turn the plugin on in their own
    /// settings, and Settings → Repos says per repo whether it is there. An install without the review-pr skill, before
    /// 0.8.0, is flagged: Run /pre-pr works with it, but Start review stays off.
    public static func workflowPlugin(marketplaces: Data?, installed: Data?) -> SetupCheck {
        let known = (marketplaces.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let name = known.first { _, value in
            ((value as? [String: Any])?["source"] as? [String: Any])?["repo"].map { "\($0)".lowercased() } == marketplace.lowercased()
        }?.key
        let plugins = ((installed.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["plugins"] as? [String: Any]) ?? [:]
        let records = plugins.filter { $0.key.hasPrefix("\(ClaudePlugins.plugin)@") }.values.flatMap { ($0 as? [[String: Any]]) ?? [] }
        let versions = records.compactMap { $0["version"] as? String }
        if !versions.isEmpty {
            let detail = "\(ClaudePlugins.plugin) \(Array(Set(versions)).sorted().joined(separator: ", "))"
            let reviews = records.contains { record in
                (record["installPath"] as? String)
                    .map { FileManager.default.fileExists(atPath: "\($0)/skills/\(ClaudePlugins.reviewPR)/SKILL.md") } ?? false
            }
            guard reviews else {
                return SetupCheck(.workflowPlugin, ok: false,
                                  detail: "\(detail), without the \(ClaudePlugins.reviewPR) skill: update it to 0.8.0 or later for Start review.")
            }
            return SetupCheck(.workflowPlugin, ok: true, detail: detail)
        }
        let install = "claude plugin install \(ClaudePlugins.plugin)@\(name ?? "fhenix")"
        return SetupCheck(.workflowPlugin, ok: false, detail: "Not installed.",
                          fixes: [SetupFix("Install", name == nil ? "claude plugin marketplace add \(marketplace) && \(install)" : install)])
    }
}
