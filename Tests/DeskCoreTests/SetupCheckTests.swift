import DeskCore
import Foundation
import Testing

@Suite struct SetupCheckTests {
    @Test func readsGitHubAccountsOffGhJSON() {
        let json = #"""
        {"hosts":{"github.com":[
          {"active":true,"gitProtocol":"https","login":"guya-fhenix","scopes":"gist, read:org, repo","state":"success"},
          {"active":false,"gitProtocol":"https","login":"guyaluk","scopes":"repo","state":"success"}]}}
        """#
        let accounts = Setup.githubAccounts(from: Data(json.utf8))
        #expect(accounts.map(\.login) == ["guya-fhenix", "guyaluk"])
        let check = Setup.github(accounts)
        #expect(check.ok)
        #expect(check.detail.contains("Desk uses guya-fhenix"))
        #expect(check.fixes.map(\.label) == ["Switch account"])
    }

    @Test func gitHubNeedsAnActiveWorkingTokenWithReadOrg() {
        #expect(Setup.github([]).fixes.map(\.label) == ["Sign in"])
        #expect(!Setup.github([GitHubAccount(login: "a", active: true, state: "failure")]).ok)
        let noOrg = Setup.github([GitHubAccount(login: "a", active: true, scopes: "repo, gist")])
        #expect(!noOrg.ok)
        #expect(noOrg.detail.contains("read:org"))
        // A token gh reads no scopes off is let through: nothing says it lacks them.
        #expect(Setup.github([GitHubAccount(login: "a", active: true, scopes: nil)]).ok)
    }

    @Test func readsClaudeSignIn() {
        #expect(Setup.claudeAccount(from: Data(#"{"loggedIn":true,"email":"a@b.io"}"#.utf8)) == "a@b.io")
        #expect(Setup.claudeAccount(from: Data(#"{"loggedIn":false}"#.utf8)) == nil)
        #expect(Setup.claudeAccount(from: Data("not json".utf8)) == nil)
    }

    @Test func findsTheWorkflowPluginInAnyScope() {
        let marketplaces = Data(#"{"fhenix":{"source":{"source":"github","repo":"FhenixProtocol/claude-marketplace"}}}"#.utf8)
        let installed = Data(#"{"plugins":{"fhenix-workflow@fhenix":[{"scope":"project","version":"0.8.1"},{"scope":"project","version":"0.8.0"}]}}"#.utf8)
        let found = Setup.workflowPlugin(marketplaces: marketplaces, installed: installed)
        #expect(found.ok)
        #expect(found.detail == "fhenix-workflow 0.8.0, 0.8.1")
        // Marketplace known: install from it by its local name. Unknown: add it first.
        #expect(Setup.workflowPlugin(marketplaces: marketplaces, installed: nil).fixes.first?.command == "claude plugin install fhenix-workflow@fhenix")
        #expect(Setup.workflowPlugin(marketplaces: nil, installed: nil).fixes.first?.command.hasPrefix("claude plugin marketplace add FhenixProtocol/claude-marketplace && ") == true)
    }
}
