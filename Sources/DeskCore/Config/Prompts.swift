import Foundation

/// Every text the app sends Claude, each one editable in Settings → Prompts. A prompt names the values it
/// takes as `{name}`, and wraps what only belongs on some tickets or PRs in `{#name}…{/name}`, with an
/// optional `{else}` for the text that goes in when the condition does not hold.
public enum PromptID: String, CaseIterable, Sendable, Identifiable {
    case ticketPlan, session, review, reviewSystem, reviewReformat

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ticketPlan: "Plan a ticket"
        case .session: "PR session"
        case .review: "Review"
        case .reviewSystem: "Review › System prompt"
        case .reviewReformat: "Review › Reformat pass"
        }
    }

    /// When the text is sent, for the line under its editor.
    public var usage: String {
        switch self {
        case .ticketPlan: "Sent with `claude --bg` when you press Plan on a ticket."
        case .session: "Sent with `claude --bg` when you start a background session on a PR."
        case .review: "Sent with `claude -p` when you press Review. The app reads the answer as the JSON described here, so keep its field names."
        case .reviewSystem: "Sent as `--append-system-prompt` on every review run."
        case .reviewReformat: "Sent with `claude -p` only when a review answer does not parse; that answer follows on stdin. Keep the JSON shape."
        }
    }

    /// The placeholders this text is filled with, and what each one becomes.
    public var placeholders: [(name: String, meaning: String)] {
        let pr: [(name: String, meaning: String)] = [
            ("repo", "owner/name"), ("number", "the PR number"), ("title", "the PR title"), ("url", "the PR link"),
            ("baseRef", "the base branch"),
        ]
        switch self {
        case .ticketPlan:
            return [
                ("key", "the ticket key"), ("summary", "the ticket title"), ("url", "the Jira link"),
                ("description", "the ticket description"), ("note", "what you typed"),
            ]
        case .session:
            return pr + [("headRef", "the PR branch"), ("worktree", "the worktree path"), ("threads", "\"3 review threads are\"")]
        case .review:
            return pr + [("author", "the PR author"), ("headSha", "the PR head commit"), ("repos", "one line per other clone")]
        case .reviewSystem, .reviewReformat:
            return []
        }
    }

    /// The `{#name}` sections this text can use, and when each one holds.
    public var conditions: [(name: String, meaning: String)] {
        switch self {
        case .ticketPlan: [("description", "the ticket has a description"), ("note", "you typed a note")]
        case .session:
            [
                ("worktree", "the branch is checked out in a worktree"), ("unresolved", "the PR has unresolved threads"),
                ("conflict", "the PR conflicts with its base branch"),
            ]
        case .review: [("otherRepos", "there are other clones under the repo roots")]
        case .reviewSystem, .reviewReformat: []
        }
    }

    public var defaultText: String {
        switch self {
        case .ticketPlan:
            """
            Plan {key} — {summary}
            {url}

            {#description}The ticket says:

            {description}{/description}

            {#note}What I want from the plan:

            {note}{/note}

            Work out how to do this in this repository: what it touches, in what order, and what is \
            unclear enough to ask about first. Write the plan and wait — do not change anything yet.
            """
        // The session starts in the repository's checkout, so it is sent into the branch's worktree before
        // anything else, or it reads the wrong checkout — or makes a worktree of its own off the default
        // branch. Both problem sections ask for a proposal and neither for a change: the session stops and
        // waits, the way everything else here waits for a press. "Unresolved" is what GitHub reports; which
        // threads went unanswered only the threads themselves say, so that part is the session's to work out.
        case .session:
            """
            Working on {repo}#{number} — {title}
            {url}

            Its branch {headRef} {#worktree}is checked out in the worktree at {worktree}. Enter that worktree \
            (EnterWorktree with that path) before anything else, and work only there{else}is checked out \
            here{/worktree}. Read the pull request and the review threads on it, say what is left to do, then \
            wait for instructions.

            {#unresolved}{threads} still unresolved. Work out which of them nobody has replied to, and for each \
            one propose the fix it is asking for — show the change rather than making it.{/unresolved}

            {#conflict}It conflicts with {baseRef}. Work out which files conflict and propose how to resolve each \
            one, but leave the branch as it is until I say so.{/conflict}
            """
        // Other clones are read at the branch the app just fetched and never at their checkout, so the review
        // sees current code and not someone's half-done branch; the list comes before the answer format, or it
        // reads as part of it. `lineText` is the field that matters most: models miscount `@@` offsets, so the
        // quoted line is what the app corrects the number against before GitHub sees it.
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

            {#otherRepos}Other repositories under my repo roots, each fetched just now. Read them directly from \
            the remote default branch named below and never from their working trees, which may be on any branch \
            with local edits: `git -C <root> show <ref>:<file>`, `git -C <root> ls-tree -r --name-only <ref>`, \
            `git -C <root> grep <pattern> <ref>`, `git -C <root> log <ref> -- <file>`.
            {repos}{/otherRepos}

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
    /// Resolves the sections, fills each `{name}` from `values`, and drops the paragraphs that come out
    /// empty — the ones that held only a section whose condition did not hold. Sections are resolved and
    /// paragraphs split on the template alone, before any value goes in, so a ticket description that says
    /// `{note}` or `{/note}` is sent as written and its blank lines survive. Anything that is not a known
    /// name — the JSON in the review's answer format, a typo — also stays as written.
    public static func fill(_ template: String, _ values: [String: String], when conditions: [String: Bool] = [:]) -> String {
        resolveSections(Substring(template), conditions)
            .components(separatedBy: "\n\n")
            .map { substitute($0, values) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    /// `{#name}…{/name}` keeps its text when `name` holds and drops it otherwise; an `{else}` inside splits
    /// it into the two cases. A section with an unknown name or no closing marker stays as typed, so a
    /// broken one is sent every time rather than never.
    private static func resolveSections(_ text: Substring, _ conditions: [String: Bool]) -> String {
        var out = ""
        var rest = text
        while let open = rest.range(of: "{#") {
            let name = rest[open.upperBound...].prefix(while: isNameCharacter)
            guard name.endIndex < rest.endIndex, rest[name.endIndex] == "}", let holds = conditions[String(name)],
                  let close = rest[name.endIndex...].range(of: "{/\(name)}")
            else {
                out += rest[..<open.upperBound]
                rest = rest[open.upperBound...]
                continue
            }
            out += rest[..<open.lowerBound]
            let body = rest[rest.index(after: name.endIndex)..<close.lowerBound]
            let split = body.range(of: "{else}")
            let kept = holds ? body[..<(split?.lowerBound ?? body.endIndex)] : split.map { body[$0.upperBound...] } ?? ""
            out += resolveSections(kept, conditions)
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    private static func substitute(_ text: String, _ values: [String: String]) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let afterOpen = rest.index(after: open)
            let name = rest[afterOpen...].prefix(while: isNameCharacter)
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

    private static func isNameCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
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

    /// The prompt with its sections resolved and `values` filled in.
    public func prompt(_ id: PromptID, _ values: [String: String], when conditions: [String: Bool] = [:]) -> String {
        PromptTemplate.fill(prompt(id), values, when: conditions)
    }
}
