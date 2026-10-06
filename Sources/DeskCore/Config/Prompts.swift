import Foundation

/// Every text the app sends Claude, each one editable in Settings → Prompts. A prompt names the values it
/// takes as `{name}`. A block — a paragraph that only belongs on some tickets or PRs — is a prompt of its
/// own, filled into its parent's `{…Block}` when its condition holds and left out otherwise; removing the
/// placeholder from the parent drops the block for good.
public enum PromptID: String, CaseIterable, Sendable, Identifiable {
    case ticketPlan, ticketDescription, ticketNote
    case session, sessionInWorktree, sessionHere, sessionUnresolved, sessionConflict
    case review, reviewSystem, reviewOtherRepos, reviewOutputFormat, reviewReformat

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ticketPlan: "Plan a ticket"
        case .ticketDescription: "Plan a ticket › Description block"
        case .ticketNote: "Plan a ticket › Note block"
        case .session: "PR session"
        case .sessionInWorktree: "PR session › Checkout in a worktree"
        case .sessionHere: "PR session › Checkout here"
        case .sessionUnresolved: "PR session › Unresolved threads block"
        case .sessionConflict: "PR session › Conflict block"
        case .review: "Review"
        case .reviewSystem: "Review › System prompt"
        case .reviewOtherRepos: "Review › Other repos block"
        case .reviewOutputFormat: "Review › Output format (JSON)"
        case .reviewReformat: "Review › Reformat pass"
        }
    }

    /// When the text is sent, for the line under its editor.
    public var usage: String {
        switch self {
        case .ticketPlan: "Sent with `claude --bg` when you press Plan on a ticket."
        case .ticketDescription: "Fills {descriptionBlock} when the ticket has a description."
        case .ticketNote: "Fills {noteBlock} when you typed a note before pressing Plan."
        case .session: "Sent with `claude --bg` when you start a background session on a PR."
        case .sessionInWorktree: "Fills {checkout} when the branch is checked out in a worktree."
        case .sessionHere: "Fills {checkout} when the branch is checked out in the repo's own folder."
        case .sessionUnresolved: "Fills {unresolvedBlock} when the PR has unresolved review threads."
        case .sessionConflict: "Fills {conflictBlock} when the PR conflicts with its base branch."
        case .review: "Sent with `claude -p` when you press Review."
        case .reviewSystem: "Sent as `--append-system-prompt` on every review run."
        case .reviewOtherRepos: "Fills {otherReposBlock} when there are other clones under the repo roots."
        case .reviewOutputFormat: "Fills {outputFormat}. The app reads the answer as this JSON, so keep its field names."
        case .reviewReformat: "Sent with `claude -p` only when a review answer does not parse; that answer follows on stdin. Keep the JSON shape."
        }
    }

    /// The placeholders this text is filled with, and what each one becomes.
    public var placeholders: [(name: String, meaning: String)] {
        let pr: [(name: String, meaning: String)] = [("repo", "owner/name"), ("number", "the PR number"), ("title", "the PR title"), ("url", "the PR link")]
        switch self {
        case .ticketPlan:
            return [
                ("key", "the ticket key"), ("summary", "the ticket title"), ("url", "the Jira link"),
                ("descriptionBlock", "the description block, or nothing"), ("noteBlock", "the note block, or nothing"),
            ]
        case .ticketDescription: return [("description", "the ticket description")]
        case .ticketNote: return [("note", "what you typed")]
        case .session:
            return pr + [
                ("headRef", "the PR branch"), ("baseRef", "the base branch"), ("checkout", "one of the two checkout texts"),
                ("unresolvedBlock", "the unresolved threads block, or nothing"), ("conflictBlock", "the conflict block, or nothing"),
            ]
        case .sessionInWorktree: return [("worktree", "the worktree path")]
        case .sessionUnresolved: return [("threads", "\"3 review threads are\"")]
        case .sessionConflict: return [("baseRef", "the base branch")]
        case .review:
            return pr + [
                ("author", "the PR author"), ("headSha", "the PR head commit"), ("baseRef", "the base branch"),
                ("otherReposBlock", "the other repos block, or nothing"), ("outputFormat", "the output format"),
            ]
        case .reviewOtherRepos: return [("repos", "one line per clone: name, path, ref")]
        case .sessionHere, .reviewSystem, .reviewOutputFormat, .reviewReformat: return []
        }
    }

    public var defaultText: String {
        switch self {
        case .ticketPlan:
            """
            Plan {key} — {summary}
            {url}

            {descriptionBlock}

            {noteBlock}

            Work out how to do this in this repository: what it touches, in what order, and what is \
            unclear enough to ask about first. Write the plan and wait — do not change anything yet.
            """
        case .ticketDescription:
            """
            The ticket says:

            {description}
            """
        case .ticketNote:
            """
            What I want from the plan:

            {note}
            """
        // Both blocks ask for a proposal and neither for a change — the session stops and waits, the way
        // everything else here waits for a press.
        case .session:
            """
            Working on {repo}#{number} — {title}
            {url}

            Its branch {headRef} {checkout}. Read the pull request and the review threads on it, say what \
            is left to do, then wait for instructions.

            {unresolvedBlock}

            {conflictBlock}
            """
        // The session starts in the repository's checkout, so it is sent into the branch's worktree before
        // anything else, or it reads the wrong checkout — or makes a worktree of its own off the default branch.
        case .sessionInWorktree:
            "is checked out in the worktree at {worktree}. Enter that worktree (EnterWorktree with that path) before anything else, and work only there"
        case .sessionHere:
            "is checked out here"
        // "Unresolved" is what GitHub reports; which of them went unanswered is something only the threads
        // themselves say, so that part is the session's to work out.
        case .sessionUnresolved:
            """
            {threads} still unresolved. Work out which of them nobody has replied to, and for each one \
            propose the fix it is asking for — show the change rather than making it.
            """
        case .sessionConflict:
            """
            It conflicts with {baseRef}. Work out which files conflict and propose how to resolve each one, \
            but leave the branch as it is until I say so.
            """
        case .review:
            """
            Review pull request #{number} in {repo}: "{title}" by {author} ({url}) for me, the requested \
            reviewer. This directory is a detached git worktree at the PR head {headSha}; the base branch is \
            {baseRef}, so the files here are the PR's code.

            Read before you judge:
            1. `gh pr view {number} --repo {repo} --comments` for the description and the discussion so far.
            2. `gh pr diff {number} --repo {repo}` for the diff. Every line number you report must come from \
            this diff and nowhere else.
            3. The changed files here in full, with enough surrounding code to judge them. `git log \
            origin/{baseRef}..HEAD` shows the commits.

            Look for correctness bugs, missing error handling, concurrency and security problems, untested \
            behaviour, and anything that contradicts the conventions in the surrounding code. Prefer few strong \
            findings to many weak ones: at most 15 comments, and no comment that only restates what the code does.

            {otherReposBlock}

            {outputFormat}

            Post nothing to GitHub and edit nothing: I put your comments into a draft review on the PR, and I \
            decide there what to keep and what verdict to send.
            """
        case .reviewSystem:
            """
            You are a code reviewer run by Fhenix Desk with read-only tools, once, non-interactively. Never post \
            comments, reviews or approvals to GitHub, and never modify files or git state. If a tool call is \
            denied, continue without it. Your entire final message must be the single JSON object the prompt \
            describes: no preamble, no closing remarks, no code fence.
            """
        // Every other clone, read at the branch the app just fetched and never at its checkout, so the review
        // sees current code and not someone's half-done branch. The list must come before the output format,
        // or it reads as part of it.
        case .reviewOtherRepos:
            """
            Other repositories under my repo roots, each fetched just now. Read them directly from the remote \
            default branch named below and never from their working trees, which may be on any branch with \
            local edits: `git -C <root> show <ref>:<file>`, `git -C <root> ls-tree -r --name-only <ref>`, \
            `git -C <root> grep <pattern> <ref>`, `git -C <root> log <ref> -- <file>`.
            {repos}
            """
        // `lineText` is the important one: models miscount `@@` offsets, so the quoted line is what the app
        // corrects the number against before GitHub sees it.
        case .reviewOutputFormat:
            """
            Answer with one JSON object and nothing else. No prose before or after it, no code fence.

            {
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
            - Comment only on lines inside a hunk of that diff. Leave out points about code the PR did not touch.
            - One comment per line: if two things are wrong on one line, say both in one body.
            - `severity`: `blocker` or `major` only for what has to be fixed before merging; that is what I judge \
            the verdict by. No findings is a fine answer for good work: `{"comments": []}`.
            """
        case .reviewReformat:
            """
            The text below is a code review. Re-emit it as the single JSON object described here and nothing else: \
            {"verdict": "APPROVE" | "REQUEST_CHANGES" | "COMMENT", "summary": "...", "comments": [{"path": "...", \
            "side": "RIGHT" | "LEFT", "line": 1, "lineText": "...", "severity": "blocker" | "major" | "minor" | \
            "nit" | "question", "body": "..."}]}. Invent nothing, and drop any finding that has no file and line.
            """
        }
    }
}

public enum PromptTemplate {
    /// Fills each `{name}` from `values` and drops the paragraphs that come out empty — the ones that held
    /// only a block whose condition did not hold. Paragraphs are split on the template before filling, so
    /// blank lines inside a value survive. One pass: a value is never searched for placeholders itself, so a
    /// ticket description that says `{note}` is sent as written. An unknown `{…}` also stays as written,
    /// which is what keeps the JSON in the output format intact.
    public static func fill(_ template: String, _ values: [String: String]) -> String {
        template.components(separatedBy: "\n\n")
            .map { substitute($0, values) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private static func substitute(_ text: String, _ values: [String: String]) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let afterOpen = rest.index(after: open)
            let name = rest[afterOpen...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if name.endIndex < rest.endIndex, rest[name.endIndex] == "}", let value = values[String(name)] {
                out += value
                rest = rest[rest.index(after: name.endIndex)...]
            } else {
                out += "{"
                rest = rest[afterOpen...]
            }
        }
        return out + rest
    }
}

extension DeskConfig {
    /// The prompt as edited in Settings, or the app's own text where it is not. An edit cleared to nothing
    /// is the app's text too: an empty prompt would start a session with nothing to do.
    public func prompt(_ id: PromptID) -> String {
        guard let text = prompts[id.rawValue], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return id.defaultText
        }
        return text
    }

    /// The prompt with `values` filled in.
    public func prompt(_ id: PromptID, _ values: [String: String]) -> String {
        PromptTemplate.fill(prompt(id), values)
    }
}
