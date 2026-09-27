import DeskCore
import Foundation
import Testing

@Suite struct ReviewCommandTests {
    let pr = Fixtures.pr(number: 928, head: "feat/gauge")

    func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @Test func promptIsTheFirstArgumentAndNamesThePullRequest() {
        let arguments = ReviewCommand.reviewArguments(pr: pr, otherRepos: [], config: DeskConfig())
        // Before every flag: --allowedTools and --disallowedTools are variadic and would swallow it.
        #expect(arguments[0] == ReviewCommand.prompt(pr, otherRepos: []))
        #expect(arguments[1] == "-p")
        #expect(arguments[0].contains("#928 in FhenixProtocol/cofhe"))
        #expect(arguments[0].contains("gh pr diff 928 --repo FhenixProtocol/cofhe"))
        #expect(arguments[0].contains("Post nothing to GitHub"))
        #expect(!arguments[0].contains("Other repositories"))
    }

    @Test func promptDemandsTheJSONContractAndTheQuotedLine() {
        let prompt = ReviewCommand.prompt(pr, otherRepos: [])
        #expect(prompt.contains("Answer with one JSON object and nothing else"))
        #expect(prompt.contains("\"comments\""))
        #expect(prompt.contains("\"lineText\""))
        // The quoted line is what the app corrects a wrong line number against, so it must be verbatim.
        #expect(prompt.contains("copied verbatim"))
        #expect(prompt.contains("is \"RIGHT\" for a line the PR adds"))
        #expect(prompt.contains("blocker"))
        // Only comments are posted, into a draft; the verdict and body are the user's to write on GitHub.
        #expect(!prompt.contains("\"summary\""))
        #expect(!prompt.contains("\"verdict\""))
        #expect(prompt.contains("draft review"))
    }

    @Test func promptListsOtherRepositoriesAtTheirFetchedDefaultBranch() {
        let repos = [
            OtherRepo(name: "cofhe-contracts", root: "/r/cofhe-contracts", ref: "origin/main", fetched: true),
            OtherRepo(name: "fhevm", root: "/r/fhevm", ref: "origin/master", fetched: false),
        ]
        let prompt = ReviewCommand.prompt(pr, otherRepos: repos)
        #expect(prompt.contains("- cofhe-contracts: /r/cofhe-contracts at origin/main\n"))
        #expect(prompt.contains("- fhevm: /r/fhevm at origin/master (fetch failed"))
        #expect(prompt.contains("never from their working trees"))
        #expect(prompt.contains("`git -C <root> show <ref>:<file>`"))
        // The repo list has to arrive before the answer shape, or it reads as part of the contract.
        let repoIndex = try! #require(prompt.range(of: "Other repositories")).lowerBound
        let contractIndex = try! #require(prompt.range(of: "Answer with one JSON object")).lowerBound
        #expect(repoIndex < contractIndex)
    }

    @Test func argumentsCarryEveryRestriction() {
        let arguments = ReviewCommand.reviewArguments(pr: pr, otherRepos: [], config: DeskConfig())
        #expect(value(after: "--output-format", in: arguments) == "json")
        #expect(value(after: "--permission-mode", in: arguments) == "dontAsk")
        #expect(value(after: "--tools", in: arguments) == "Read,Grep,Glob,Bash")
        #expect(value(after: "--append-system-prompt", in: arguments) == ReviewCommand.systemPrompt)
        #expect(arguments.contains("--strict-mcp-config"))
        // The cost cap Claude enforces itself, which still returns the work already done.
        #expect(value(after: "--max-budget-usd", in: arguments) == "10.00")

        let denied = try! #require(value(after: "--disallowedTools", in: arguments))
        for rule in ["Bash(gh pr comment:*)", "Bash(gh pr review:*)", "Bash(gh api:*)", "Bash(git fetch:*)",
                     "Bash(git push:*)", "Bash(git -C * push*)", "Edit", "Write"] {
            #expect(denied.contains(rule))
        }
        #expect(try! #require(value(after: "--allowedTools", in: arguments)).contains("Bash(git -C * show *)"))

        // No session: everything that made one is gone.
        #expect(!arguments.contains("--bg"))
        #expect(!arguments.contains("--resume"))
        #expect(!arguments.contains("-n"))
        #expect(!arguments.contains("--session-id"))
        #expect(!arguments.contains("--model"))
        #expect(!arguments.contains("--effort"))
    }

    @Test func modelAndEffortAppearOnlyWhenConfigured() {
        var config = DeskConfig()
        config.reviewModel = "opus"
        config.reviewEffort = "high"
        config.reviewBudgetUSD = 4.5
        let arguments = ReviewCommand.reviewArguments(pr: pr, otherRepos: [], config: config)
        #expect(value(after: "--model", in: arguments) == "opus")
        #expect(value(after: "--effort", in: arguments) == "high")
        #expect(value(after: "--max-budget-usd", in: arguments) == "4.50")
    }

    @Test func noAllowedRuleIsAlsoDenied() {
        let allowed = Set(ReviewCommand.allowedTools)
        let denied = Set(ReviewCommand.disallowedTools)
        #expect(allowed.intersection(denied).isEmpty)
        #expect(!ReviewCommand.tools.contains("Edit"))
        #expect(!ReviewCommand.tools.contains("Write"))
    }

    @Test func otherRepoRulesUseTheGlobForm() {
        // Claude Code 2.1.258: reads take a ref, so the rule ends " *)"; the deny form has no space, so a
        // bare `git -C <root> push` is caught too. The mixed `Bash(git -C * show:*)` matches nothing.
        let reads = ReviewCommand.allowedTools.filter { $0.hasPrefix("Bash(git -C * ") }
        #expect(reads.count == ReviewCommand.otherRepoReads.count)
        for rule in reads {
            #expect(rule.hasSuffix(" *)"))
            #expect(!rule.contains(":*"))
        }
        let writes = ReviewCommand.disallowedTools.filter { $0.hasPrefix("Bash(git -C * ") }
        #expect(writes.count == ReviewCommand.gitWrites.count)
        for rule in writes {
            #expect(rule.hasSuffix("*)"))
            #expect(!rule.hasSuffix(" *)"))
        }
        for write in ReviewCommand.gitWrites {
            #expect(ReviewCommand.disallowedTools.contains("Bash(git \(write):*)"))
            #expect(!ReviewCommand.otherRepoReads.contains(write))
        }
    }

    @Test func systemPromptForbidsPostingAndDemandsJSON() {
        #expect(ReviewCommand.systemPrompt.contains("Never post"))
        #expect(ReviewCommand.systemPrompt.contains("single JSON object"))
        #expect(ReviewCommand.systemPrompt.contains("no code fence"))
    }

    @Test func reformatPassReadsNothingAndRunsNothing() {
        let arguments = ReviewCommand.reformatArguments()
        #expect(arguments[0] == ReviewCommand.reformatPrompt)
        #expect(arguments.contains("-p"))
        // "" is claude's own way of disabling every built-in tool.
        #expect(value(after: "--tools", in: arguments) == "")
        let denied = try! #require(value(after: "--disallowedTools", in: arguments))
        for tool in ReviewCommand.tools { #expect(denied.contains(tool)) }
        // A formatting fix must never cost what a whole review costs.
        #expect(value(after: "--max-budget-usd", in: arguments) == "0.50")
    }
}
