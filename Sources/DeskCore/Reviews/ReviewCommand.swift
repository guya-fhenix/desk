import Foundation

/// Builds the `claude` invocation and the prompt for a review. Kept pure so the argument shape is tested:
/// a wrong flag here would either let the session post to GitHub or lose the structured answer the whole
/// screen is built on.
public enum ReviewCommand {
    public static let tools = ["Read", "Grep", "Glob", "Bash"]

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

    public static let systemPrompt = """
    You are a code reviewer run by Fhenix Desk with read-only tools, once, non-interactively. Never post \
    comments, reviews or approvals to GitHub, and never modify files or git state. If a tool call is \
    denied, continue without it. Your entire final message must be the single JSON object the prompt \
    describes: no preamble, no closing remarks, no code fence.
    """

    /// One headless run. The prompt is the first argument because `--allowedTools` and `--disallowedTools`
    /// are variadic and would swallow a prompt placed after them. `--max-budget-usd` is the cost control —
    /// it is enforced by Claude and still returns the work already done, unlike the wall clock, which
    /// kills the process and loses everything it was paid for.
    public static func reviewArguments(pr: PullRequest, otherRepos: [OtherRepo], config: DeskConfig) -> [String] {
        var arguments = [
            prompt(pr, otherRepos: otherRepos), "-p",
            "--output-format", "json",
            "--permission-mode", "dontAsk",
            "--max-budget-usd", String(format: "%.2f", config.reviewBudgetUSD),
            "--tools", tools.joined(separator: ","),
            "--allowedTools", allowedTools.joined(separator: ","),
            "--disallowedTools", disallowedTools.joined(separator: ","),
            "--strict-mcp-config", "--append-system-prompt", systemPrompt,
        ]
        if !config.reviewModel.isEmpty { arguments += ["--model", config.reviewModel] }
        if !config.reviewEffort.isEmpty { arguments += ["--effort", config.reviewEffort] }
        return arguments
    }

    public static func prompt(_ pr: PullRequest, otherRepos: [OtherRepo]) -> String {
        var paragraphs = [
            """
            Review pull request #\(pr.number) in \(pr.repo): "\(pr.title)" by \(pr.author) (\(pr.url)) for me, \
            the requested reviewer. This directory is a detached git worktree at the PR head \(pr.headSha); the \
            base branch is \(pr.baseRef), so the files here are the PR's code.
            """,
            """
            Read before you judge:
            1. `gh pr view \(pr.number) --repo \(pr.repo) --comments` for the description and the discussion so far.
            2. `gh pr diff \(pr.number) --repo \(pr.repo)` for the diff. Every line number you report must come \
            from this diff and nowhere else.
            3. The changed files here in full, with enough surrounding code to judge them. `git log \
            origin/\(pr.baseRef)..HEAD` shows the commits.
            """,
            """
            Look for correctness bugs, missing error handling, concurrency and security problems, untested \
            behaviour, and anything that contradicts the conventions in the surrounding code. Prefer few strong \
            findings to many weak ones: at most 15 comments, and no comment that only restates what the code does.
            """,
        ]
        if let others = otherRepositories(otherRepos) { paragraphs.append(others) }
        paragraphs.append(contract(pr))
        paragraphs.append("Post nothing to GitHub and edit nothing: I read your JSON, decide what to keep, and submit the review myself.")
        return paragraphs.joined(separator: "\n\n")
    }

    /// The shape the whole screen is built on. `lineText` is the important one: models miscount `@@`
    /// offsets, so the quoted line is what the app corrects the number against, and it doubles as the
    /// anchor that tells a later push whether the comment still applies.
    private static func contract(_ pr: PullRequest) -> String {
        """
        Answer with one JSON object and nothing else. No prose before or after it, no code fence.

        {
          "verdict": "APPROVE" | "REQUEST_CHANGES" | "COMMENT",
          "summary": "Two sentences at most, 45 words at most, plain text: what the PR does, then the one \
        thing that matters most. Not a recap of the diff. No headings, no bullet list, no preamble.",
          "comments": [
            {
              "path": "src/gauge.rs",
              "side": "RIGHT",
              "line": 42,
              "lineText": "        let mut n = 0;",
              "severity": "blocker" | "major" | "minor" | "nit" | "question",
              "body": "What is wrong, why it matters, and a suggested fix when there is an obvious one. Three \
        sentences at most. State the problem and the reason; do not write step-by-step instructions, do not \
        restate the code, and do not rewrite the change for the author. Markdown is allowed, and a \
        ```suggestion block is welcome when the fix fits on the line."
            }
          ]
        }

        Rules for comments:
        - `path` is exactly the path as it appears after `+++ b/` in the diff, without the `b/`.
        - `side` is "RIGHT" for a line the PR adds or leaves unchanged, "LEFT" only for a line it deletes.
        - `line` is the line number in the new file for RIGHT, in the old file for LEFT. Count down from the \
        `@@ -old,n +new,m @@` header of the hunk the line sits in.
        - `lineText` is that line copied verbatim, without its leading `+`, `-` or space. It is how I check \
        your line number, so copy it exactly, spaces included.
        - Comment only on lines inside a hunk of that diff. A point about code the PR did not touch belongs \
        in `summary`.
        - One comment per line: if two things are wrong on one line, say both in one body.
        - Verdict: APPROVE when nothing left would block the merge. Comments do not stop an approval — a \
        PR with only `minor`, `nit` or `question` findings is an approval with comments, which is the normal \
        outcome for good work. REQUEST_CHANGES only when a `blocker` or `major` comment has to be fixed \
        before merging. COMMENT when what you have is mostly questions you need answered before you can judge.
        """
    }

    /// Every other clone under the repo roots and how to read it: at the branch the app just fetched,
    /// never at the checkout, so the review sees the current code and not someone's half-done branch.
    static func otherRepositories(_ repos: [OtherRepo]) -> String? {
        guard !repos.isEmpty else { return nil }
        let intro = """
        Other repositories under my repo roots, each fetched just now. Read them directly from the remote default \
        branch named below and never from their working trees, which may be on any branch with local edits: \
        `git -C <root> show <ref>:<file>`, `git -C <root> ls-tree -r --name-only <ref>`, `git -C <root> grep \
        <pattern> <ref>`, `git -C <root> log <ref> -- <file>`.
        """
        let lines = repos.map { "- \($0.name): \($0.root) at \($0.ref)" + ($0.fetched ? "" : " (fetch failed, so possibly behind the remote)") }
        return ([intro] + lines).joined(separator: "\n")
    }

    /// A second pass that reshapes an answer the parser could not read. Not a second review: under `-p`
    /// there is no conversation to continue, so re-asking would buy a formatting fix at the price of the
    /// whole PR again. The text to reshape goes on stdin, which `claude` appends to this prompt.
    public static func reformatArguments() -> [String] {
        [
            reformatPrompt, "-p",
            "--output-format", "json",
            "--permission-mode", "dontAsk",
            "--max-budget-usd", "0.50",
            // "" disables every built-in tool: this pass reads nothing and runs nothing.
            "--tools", "",
            "--disallowedTools", (disallowedTools + tools).joined(separator: ","),
            "--strict-mcp-config",
        ]
    }

    public static let reformatPrompt = """
    The text below is a code review. Re-emit it as the single JSON object described here and nothing else: \
    {"verdict": "APPROVE" | "REQUEST_CHANGES" | "COMMENT", "summary": "...", "comments": [{"path": "...", \
    "side": "RIGHT" | "LEFT", "line": 1, "lineText": "...", "severity": "blocker" | "major" | "minor" | \
    "nit" | "question", "body": "..."}]}. Invent nothing, and drop any finding that has no file and line.
    """
}
