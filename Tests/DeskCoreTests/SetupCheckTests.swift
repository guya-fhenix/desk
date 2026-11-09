import DeskCore
import Foundation
import Testing

@Suite struct SetupCheckTests {
    /// gh 2.69.0 has no `--json` on `gh auth status`: Setup read its error as nobody signed in, and a sign-in that
    /// succeeded ("You were already logged in to this account") never satisfied it. The gh row now asks for 2.81.0,
    /// and the GitHub row says what gh said.
    @Test func anOldGhIsUpgradedNotSignedInAgain() {
        #expect(Setup.ghVersion(in: "gh version 2.69.0 (2025-03-19) · /opt/homebrew/bin/gh") == [2, 69, 0])
        #expect(Setup.ghVersion(in: "gh version 2.103.3 (2026-10-26)") == [2, 103, 3])
        #expect(Setup.ghVersion(in: "/opt/homebrew/bin/gh") == nil)
        #expect([2, 69, 0].lexicographicallyPrecedes(Setup.minimumGh))
        #expect(![2, 81, 0].lexicographicallyPrecedes(Setup.minimumGh))
        #expect(![2, 103, 3].lexicographicallyPrecedes(Setup.minimumGh))

        let old = Setup.github(statusOutput: Data(), stderr: "unknown flag: --json\n\nUsage:  gh auth status [flags]\n")
        #expect(!old.ok)
        #expect(old.detail == "gh couldn't say who is signed in: unknown flag: --json")
        #expect(old.fixes.isEmpty, "signing in again cannot fix it")
        // Nobody signed in is still that: gh's JSON with no account.
        let nobody = Setup.github(statusOutput: Data(#"{"hosts":{}}"#.utf8), stderr: "")
        #expect(nobody.detail == "Not signed in." && nobody.fixes.map(\.label) == ["Use the browser"] && nobody.asksForToken)
    }

    @Test func readsGitHubAccountsOffGhJSON() throws {
        let json = #"""
        {"hosts":{"github.com":[
          {"active":true,"gitProtocol":"https","login":"guya-fhenix","scopes":"gist, read:org, repo","state":"success"},
          {"active":false,"gitProtocol":"https","login":"guyaluk","scopes":"repo","state":"success"}]}}
        """#
        let accounts = try #require(Setup.githubAccounts(from: Data(json.utf8)))
        #expect(accounts.map(\.login) == ["guya-fhenix", "guyaluk"])
        let check = Setup.github(accounts)
        #expect(check.ok)
        #expect(check.detail.contains("Desk uses guya-fhenix"))
        #expect(check.fixes.map(\.label) == ["Switch account"])
    }

    @Test func gitHubNeedsAnActiveWorkingTokenWithReadOrg() {
        #expect(Setup.github([]).fixes.map(\.label) == ["Use the browser"])
        #expect(!Setup.github([GitHubAccount(login: "a", active: true, state: "failure")]).ok)
        let noOrg = Setup.github([GitHubAccount(login: "a", active: true, scopes: "repo, gist")])
        #expect(!noOrg.ok)
        #expect(noOrg.detail.contains("read:org"))
        // GitHub lists only the broadest org scope, which implies read:org.
        #expect(Setup.github([GitHubAccount(login: "a", active: true, scopes: "admin:org, repo")]).ok)
        // A token gh reads no scopes off is let through: nothing says it lacks them.
        #expect(Setup.github([GitHubAccount(login: "a", active: true, scopes: nil)]).ok)
        // Every press that opens GitHub CLI's sign-in page says that page asks for gh's own scopes, Workflow among them.
        let pages = [Setup.github([]), Setup.github([GitHubAccount(login: "a", active: true, state: "failure")]), noOrg]
        for check in pages {
            #expect(check.fixes.allSatisfy { $0.note?.contains("Workflow") == true })
            #expect(check.asksForToken, "a sign-in that does not work asks for a token first")
        }
        #expect(!Setup.github([GitHubAccount(login: "a", active: true, scopes: "read:org, repo")]).asksForToken)
    }

    /// Jira caps a browser (OAuth) sign-in by the hour and then refuses it until the hour turns, which stopped the
    /// ticket sync; API tokens have no such cap. So a browser sign-in passes, but still asks for a token.
    @Test func jiraAsksForATokenUntilItHasOne() throws {
        let browser = try #require(JiraDecoding.account(fromStatus: """
        ✓ Authenticated
          Site: fhenix.atlassian.net
          Email: guya@fhenix.io
          Authentication Type: oauth
        """))
        #expect(browser.signedInWithBrowser)
        let check = Setup.jira(browser)
        #expect(check.ok && check.asksForToken)
        #expect(check.detail == "Signed in to fhenix.atlassian.net as guya@fhenix.io through the browser")

        let token = Setup.jira(JiraAccount(site: "fhenix.atlassian.net", email: "guya@fhenix.io", authType: "api_token"))
        #expect(token.ok && !token.asksForToken)
        #expect(token.detail.hasSuffix("with an API token"))

        let nobody = Setup.jira(nil)
        #expect(!nobody.ok && nobody.asksForToken)
        #expect(nobody.fixes.map(\.label) == ["Use the browser"])
    }

    /// The token goes to the CLI on stdin, so it shows in no process list and no error message, which carry the arguments.
    @Test func aTokenGoesOnStdinNeverInTheArguments() async throws {
        actor Calls {
            var all: [(arguments: [String], stdin: String?)] = []
            func add(_ arguments: [String], _ stdin: Data?) { all.append((arguments, stdin.map { String(decoding: $0, as: UTF8.self) })) }
        }
        let calls = Calls()
        let run: ShellRun = { _, arguments, _, stdin, _, _ in
            await calls.add(arguments, stdin)
            return ShellResult(status: 0, stdout: Data())
        }
        try await Setup.signInJira(acli: "/acli", site: " fhenix.atlassian.net ", email: "guya@fhenix.io", token: " secret\n", run: run)
        try await Setup.signInGitHub(gh: "/gh", token: "ghp_secret", run: run)
        let all = await calls.all
        #expect(all.map(\.arguments) == [
            ["jira", "auth", "login", "--site", "fhenix.atlassian.net", "--email", "guya@fhenix.io", "--token"],
            ["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--with-token"],
            ["auth", "setup-git", "--hostname", "github.com"],
        ])
        #expect(all.map(\.stdin) == ["secret\n", "ghp_secret\n", nil])

        let refused: ShellRun = { _, _, _, _, _, _ in ShellResult(status: 1, stdout: Data(), stderr: "✗ Error: Unauthorized\n") }
        await #expect(throws: ShellError.self) {
            try await Setup.signInJira(acli: "/acli", site: "s", email: "e", token: "bad", run: refused)
        }
    }

    @Test func readsClaudeSignIn() {
        #expect(Setup.claudeAccount(from: Data(#"{"loggedIn":true,"email":"a@b.io"}"#.utf8)) == "a@b.io")
        #expect(Setup.claudeAccount(from: Data(#"{"loggedIn":false}"#.utf8)) == nil)
        #expect(Setup.claudeAccount(from: Data("not json".utf8)) == nil)
    }

    @Test func findsTheWorkflowPluginInAnyScope() throws {
        let marketplaces = Data(#"{"fhenix":{"source":{"source":"github","repo":"FhenixProtocol/claude-marketplace"}}}"#.utf8)
        let new = FileManager.default.temporaryDirectory.appending(path: "desk-plugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: new) }
        try FileManager.default.createDirectory(at: new.appending(path: "skills/review-pr"), withIntermediateDirectories: true)
        try Data().write(to: new.appending(path: "skills/review-pr/SKILL.md"))
        let installed = Data(#"""
        {"plugins":{"fhenix-workflow@fhenix":[{"scope":"project","version":"0.8.1","installPath":"\#(new.path)"},
          {"scope":"project","version":"0.7.0","installPath":"/nonexistent"}]}}
        """#.utf8)
        let found = Setup.workflowPlugin(marketplaces: marketplaces, installed: installed)
        #expect(found.ok)
        #expect(found.detail == "fhenix-workflow 0.7.0, 0.8.1")
        // Installed, but no install has review-pr: Start review stays off, so it is flagged.
        let old = Data(#"{"plugins":{"fhenix-workflow@fhenix":[{"scope":"user","version":"0.7.0","installPath":"/nonexistent"}]}}"#.utf8)
        let stale = Setup.workflowPlugin(marketplaces: marketplaces, installed: old)
        #expect(!stale.ok)
        #expect(stale.detail.contains("review-pr"))
        // Marketplace known: install from it by its local name. Unknown: add it first.
        #expect(Setup.workflowPlugin(marketplaces: marketplaces, installed: nil).fixes.first?.command == "claude plugin install fhenix-workflow@fhenix")
        #expect(Setup.workflowPlugin(marketplaces: nil, installed: nil).fixes.first?.command.hasPrefix("claude plugin marketplace add FhenixProtocol/claude-marketplace && ") == true)
    }
}
