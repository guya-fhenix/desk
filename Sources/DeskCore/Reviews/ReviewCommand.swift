import Foundation

/// Builds the `claude` invocation and the prompt for a review. Kept pure so the argument shape is tested:
/// a wrong flag here would either let the session post to GitHub or lose the structured answer the whole
/// screen is built on.
public enum ReviewCommand {
    /// Skill loads fhenix-workflow:reviewing-code, the team's rubric; the skills it reads run under the same allow
    /// and deny rules. No Agent: a subagent would be one more session to keep read-only.
    public static let tools = ["Read", "Grep", "Glob", "Bash", "Skill"]

    /// Read-only subcommands that also work against another clone as `git -C <root> <subcommand> <ref> …`.
    public static let otherRepoReads = ["show", "ls-tree", "grep", "log", "blame", "diff", "rev-parse"]

    /// Subcommands that change a repo, denied in the worktree and through `git -C` alike.
    public static let gitWrites = [
        "push", "commit", "checkout", "switch", "reset", "rebase", "merge", "stash", "add", "pull", "fetch", "worktree", "branch",
    ]

    /// `git -C <root> …` is how the session reads other clones from the worktree. Only the glob form admits
    /// the path: `*` matches any text including spaces, `Bash(git show:*)` is a plain prefix, and the mixed
    /// `Bash(git -C * show:*)` matches nothing (Claude Code 2.1.258). A read always takes a ref, hence the
    /// space before the last `*`; the deny form below has none, so a bare `git -C <root> push` is caught too.
    public static let allowedTools = [
        "Skill",
        "Bash(gh pr view:*)", "Bash(gh pr diff:*)", "Bash(gh pr checks:*)",
        "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)", "Bash(git status:*)", "Bash(git blame:*)",
        "Bash(git grep:*)", "Bash(git ls-files:*)", "Bash(git rev-parse:*)",
        "Bash(ls:*)", "Bash(cat:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(wc:*)", "Bash(tree:*)",
    ] + otherRepoReads.map { "Bash(git -C * \($0) *)" }

    /// Deny rules beat allow rules and the user's own settings. That last part is why these stay even
    /// under `--permission-mode dontAsk`: the user's settings.json is itself a source of pre-approval, and
    /// only a deny rule outranks it. The app does all fetching, so Claude never needs a git write.
    public static let disallowedTools = [
        "Bash(gh pr comment:*)", "Bash(gh pr review:*)", "Bash(gh pr edit:*)", "Bash(gh pr merge:*)",
        "Bash(gh pr close:*)", "Bash(gh pr ready:*)", "Bash(gh api:*)", "Bash(gh issue:*)", "Bash(gh repo:*)",
    ] + gitWrites.map { "Bash(git \($0):*)" } + gitWrites.map { "Bash(git -C * \($0)*)" } + [
        "Edit", "Write", "MultiEdit", "NotebookEdit", "WebFetch", "WebSearch",
    ]

    /// One headless run. The prompt is the first argument because `--allowedTools` and `--disallowedTools`
    /// are variadic and would swallow a prompt placed after them. No `--max-budget-usd`: on a subscription it caps
    /// an API-price estimate nobody pays, so the review time limit is the one cap.
    public static func reviewArguments(pr: PullRequest, otherRepos: [OtherRepo], config: DeskConfig) -> [String] {
        var arguments = [
            prompt(pr, otherRepos: otherRepos, config: config), "-p",
            "--output-format", "json",
            "--permission-mode", "dontAsk",
            "--tools", tools.joined(separator: ","),
            "--allowedTools", allowedTools.joined(separator: ","),
            "--disallowedTools", disallowedTools.joined(separator: ","),
            "--strict-mcp-config", "--append-system-prompt", config.prompt(.reviewSystem),
        ]
        if !config.reviewModel.isEmpty { arguments += ["--model", config.reviewModel] }
        if !config.reviewEffort.isEmpty { arguments += ["--effort", config.reviewEffort] }
        return arguments
    }

    public static func prompt(_ pr: PullRequest, otherRepos: [OtherRepo], config: DeskConfig = DeskConfig()) -> String {
        let repos = otherRepos.map { "- \($0.name): \($0.root) at \($0.ref)" + ($0.fetched ? "" : " (fetch failed, so possibly behind the remote)") }
        let values = [
            "repo": pr.repo, "number": String(pr.number), "title": pr.title, "author": pr.author, "url": pr.url,
            "headSha": pr.headSha, "baseRef": pr.baseRef, "repos": repos.joined(separator: "\n"),
        ]
        return config.prompt(.review, values, when: ["otherRepos": !otherRepos.isEmpty])
    }

    /// A second pass that reshapes an answer the parser could not read. Not a second review: under `-p`
    /// there is no conversation to continue, so re-asking would buy a formatting fix at the price of the
    /// whole PR again. The text to reshape goes on stdin, which `claude` appends to this prompt.
    public static func reformatArguments(config: DeskConfig) -> [String] {
        [
            config.prompt(.reviewReformat), "-p",
            "--output-format", "json",
            "--permission-mode", "dontAsk",
            // "" disables every built-in tool: this pass reads nothing and runs nothing.
            "--tools", "",
            "--disallowedTools", (disallowedTools + tools).joined(separator: ","),
            "--strict-mcp-config",
        ]
    }
}
