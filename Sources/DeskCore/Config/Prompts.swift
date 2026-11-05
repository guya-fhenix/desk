import Foundation

/// Every text the app sends Claude, each one editable in Settings → Prompts. A prompt names the values it
/// takes as `{name}`, and wraps what only belongs on some tickets or PRs in `{#name}…{/name}`, with an
/// optional `{else}` for the text that goes in when the condition does not hold.
public enum PromptID: String, CaseIterable, Sendable, Identifiable {
    case ticketPlan, session, selfReview, threadNotes, fixConflict, fixChecks, review, reviewSystem, reviewReformat, reviewHandoff

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ticketPlan: "Start a ticket"
        case .session: "PR session"
        case .selfReview: "Flow › Self-review"
        case .threadNotes: "Flow › Apply thread notes"
        case .fixConflict: "Flow › Fix the conflict"
        case .fixChecks: "Flow › Fix CI"
        case .review: "Review"
        case .reviewSystem: "Review › System prompt"
        case .reviewReformat: "Review › Reformat pass"
        case .reviewHandoff: "Review › Hand-off to the session"
        }
    }

    /// When the text is sent, for the line under its editor.
    public var usage: String {
        switch self {
        case .ticketPlan: "Sent with `claude --bg` when you press Start on a ticket."
        case .session: "Sent with `claude --bg` when you start a background session on a PR."
        case .selfReview: "Sent to the PR's session when you approve its draft. It runs the review once; writing the JSON described here to {resultFile} is its last step. The session shows as working while it runs; the PR is Self-reviewed once /pre-pr's evidence is on it."
        case .threadNotes: "Sent to the PR's session when you press Apply under its open threads, with each thread you wrote a note on. Writing the JSON described here to {resultFile} is its last step. The app itself never writes to a thread."
        case .fixConflict: "Sent to the PR's session when you press Fix it on a PR that conflicts with its base branch. Writing the JSON described here to {resultFile} is its last step. Nothing is sent on its own."
        case .fixChecks: "Sent to the PR's session when you press Fix it on a PR whose CI failed. Writing the JSON described here to {resultFile} is its last step. Nothing is sent on its own."
        case .review: "Sent with `claude -p` when you press Review. The app reads the answer as the JSON described here, so keep its field names."
        case .reviewSystem: "Sent as `--append-system-prompt` on every review run."
        case .reviewReformat: "Sent with `claude -p` only when a review answer does not parse; that answer follows on stdin. Keep the JSON shape."
        case .reviewHandoff: "Sent to the PR's background session once a review has put its comments in your draft, so you can talk them through there: as soon as the session is idle, never while it works or waits on you. With no session on the PR, a new one starts with it."
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
        case .selfReview:
            return pr + [("headRef", "the PR branch"), ("worktree", "the worktree path"), ("resultFile", "where the session writes its summary")]
        case .threadNotes:
            return pr + [
                ("headRef", "the PR branch"), ("worktree", "the worktree path"), ("resultFile", "where the session writes its summary"),
                ("threads", "the threads you wrote a note on: link, place, who started it, its first comment and your note"),
            ]
        case .fixConflict, .fixChecks:
            return pr + [("headRef", "the PR branch"), ("worktree", "the worktree path"), ("resultFile", "where the session writes its summary")]
        case .review:
            return pr + [("author", "the PR author"), ("headSha", "the PR head commit"), ("repos", "one line per other clone")]
        case .reviewSystem, .reviewReformat:
            return []
        case .reviewHandoff:
            return pr + [
                ("posted", "how many comments went into the draft"), ("summary", "what the review said overall"),
                ("findings", "the comments, one per line with file and line"),
            ]
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
        case .selfReview, .threadNotes, .fixChecks: [("worktree", "the branch is checked out in a worktree")]
        case .fixConflict: [("worktree", "the branch is checked out in a worktree"), ("draft", "the PR is still a draft")]
        case .review: [("otherRepos", "there are other clones under the repo roots")]
        case .reviewSystem, .reviewReformat: []
        case .reviewHandoff: [("summary", "the review wrote a summary"), ("findings", "the review placed comments on lines")]
        }
    }

    public var defaultText: String {
        switch self {
        // The plan waits for you; what follows it is what the app's flow needs: a draft, because nothing leaves
        // draft until you approve it, and the key in the branch and title, which is how the ticket finds its PR.
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

            Once I approve the plan, build it in a worktree of its own (EnterWorktree, named after {key}) so the \
            branch carries the ticket key, and put {key} in the pull request title too. Open the pull request as a \
            draft — always a draft, never ready for review — then stop and wait: Fhenix Desk takes it from there.
            """
        // The session starts in the repository's checkout, so it is sent into the branch's worktree before
        // anything else, or it reads the wrong checkout — or makes a worktree of its own off the default
        // branch. Both problem sections ask for a proposal and no change: this session also opens on teammates'
        // PRs, from Reviews, where it must never push.
        // "Unresolved" is what GitHub reports; which threads went unanswered only the threads themselves say, so
        // that part is the session's to work out.
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
        // One run: /pre-pr where the repo adopted the review flow, its own fix loop being the only loop, and one
        // reviewing-code pass elsewhere. The result file comes last because writing it is the last thing to do.
        case .selfReview:
            """
            Review and fix pull request {url} ({repo}#{number}, "{title}") once, then write the summary file below.

            {#worktree}Its branch {headRef} is checked out in the worktree at {worktree}. Work only there \
            (EnterWorktree with that path if you are not in it already).{else}Its branch is {headRef}; work on that \
            branch.{/worktree}

            How it reviews depends on whether the checkout has adopted the review flow: `REVIEW.md` and \
            `.github/review/tier.sh` at its root.

            If it has: run `claude -p "/fhenix-workflow:pre-pr --fix {number}" --permission-mode auto \
            --output-format text` once, from that checkout, then read its output. /pre-pr sets \
            disable-model-invocation, so it runs as a typed command in that headless session, not as a skill you \
            invoke. It runs the checks and the reviews, commits and pushes its fixes, re-reviews every commit it adds, \
            posts each open finding as a review thread on its line, and posts the evidence as a pull request comment. \
            Do not run it again, whatever it reports.

            If it has not: run the fhenix-workflow:reviewing-code skill on the pull request once, fix every Important \
            finding it reports and the Nits whose fix is a line or two, commit the fixes with a message that says what \
            the review found, and push.

            Either way, keep the pull request a draft: never run `gh pr ready`.

            When you are done, write this JSON to {resultFile} and nothing else:
            {"clean": true, "findings": [{"severity": "important", "file": "src/a.rs", "line": 42, \
            "problem": "what was wrong, in one plain sentence", "fix": "what you changed, in one plain sentence, or \
            why you left it", "fixed": true}]}
            `clean` says whether the review reported no Important finding. `severity` is "important" for an \
            Important finding and "nit" for a Nit. List every Important finding, and the Nits you fixed.
            """
        // Only the threads you wrote a note on are listed, each saying who started it: a review tool's thread is
        // resolved once answered, a person's is left for that person. The app writes nothing to GitHub itself.
        case .threadNotes:
            """
            Work on these review threads of pull request {url} ({repo}#{number}, "{title}"), and only these. Each \
            comes with my note on what I want done with it:

            {threads}

            {#worktree}Its branch {headRef} is checked out in the worktree at {worktree}. Work only there \
            (EnterWorktree with that path if you are not in it already).{else}Its branch is {headRef}; work on that \
            branch.{/worktree}

            Make the changes the notes ask for, commit them with a message that says which threads they answer, and \
            push. Never force-push. Then reply in each listed thread on GitHub with what you did, or why you did not \
            where my note says to leave it (gh api graphql, addPullRequestReviewThreadReply). Once you have replied, \
            resolve the threads /pre-pr or CodeRabbit started (resolveReviewThread), and leave the threads a person \
            started unresolved, for their reviewer. Leave every thread that is not listed here untouched.

            When you are done, write this JSON to {resultFile} and nothing else:
            {"replied": 3, "resolved": 2, "summary": "what changed, in one plain sentence"}
            """
        // Rebase while nobody reviews it, merge once somebody does: a rebase moves every line a reviewer's comment
        // is pinned to. A conflict only you can settle is the one reason to stop and ask.
        case .fixConflict:
            """
            Pull request {url} ({repo}#{number}) conflicts with {baseRef}. Resolve it and push — there is no need to \
            ask me.

            {#worktree}Its branch {headRef} is checked out in the worktree at {worktree}. Work only there \
            (EnterWorktree with that path if you are not in it already).{/worktree}

            {#draft}It is still a draft, so rebase it onto origin/{baseRef} and push with --force-with-lease.{else}\
            Reviewers are on it, so merge origin/{baseRef} into it rather than rebasing, so their comments stay on \
            the right lines, and push.{/draft} Keep what both sides meant; if a conflict needs a decision only I can \
            make, stop and ask me instead.

            When you are done, write this JSON to {resultFile} and nothing else:
            {"fixed": true, "summary": "what you did, in one plain sentence"}
            """
        case .fixChecks:
            """
            CI failed on pull request {url} ({repo}#{number}). Find out why (gh pr checks {number} --repo {repo}, \
            then the failing job's log), fix it and push — there is no need to ask me. If the failure has nothing to \
            do with this change, such as a flaky test or an outage, rerun the failed jobs instead of changing code. If \
            the fix needs a decision only I can make, stop and ask me.

            {#worktree}Its branch {headRef} is checked out in the worktree at {worktree}. Work only there \
            (EnterWorktree with that path if you are not in it already).{/worktree}

            When you are done, write this JSON to {resultFile} and nothing else:
            {"fixed": true, "summary": "what was wrong and what you did, in one plain sentence"}
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

            Review it with the fhenix-workflow:reviewing-code skill, the team's checklist, on that diff, and report \
            only: post nothing and change nothing. A step that needs a tool you do not have, such as a subagent, you \
            do yourself or skip. Its findings become the comments below, with its severity: Important, Nit or \
            Pre-existing. If the skill is not available here, look for correctness bugs, missing error handling, \
            concurrency and security problems, untested behaviour, and anything that contradicts the conventions in \
            the surrounding code. Either way, prefer few strong findings to many weak ones: at most 15 comments, and \
            no comment that only restates what the code does.

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
                  "severity": "important" | "nit" | "pre-existing" | "question",
                  "body": "At most three lines as GitHub shows them, about 250 characters in all: one or two \
            short sentences on what goes wrong and when, then one on what to do about it, in plain words, the way \
            you would say it to the author sitting next to you. No headings, lists or blank lines. A ```suggestion \
            block is welcome below those lines when the fix fits on the line."
                }
              ]
            }

            How to write each comment — like a teammate talking to the author, not like a linter or a spec:
            - Say what actually goes wrong, with a concrete case: "if the list is empty, this crashes on the first \
            item" rather than "missing bounds check".
            - Use everyday words. Skip jargon and acronyms (TOCTOU, idempotent, invariant, UB…); when a technical \
            word really is the clearest one, add a few words saying what it means here.
            - Name a function or variable only when that is the quickest way to point at it. The comment already \
            sits on the line, so do not restate the code, quote signatures or paste stack traces.
            - Say what to do about it in one plain sentence. Do not write step-by-step instructions or rewrite the \
            change for the author.
            - Be direct and friendly: no hedging ("it might be worth considering…"), no lecturing, no padding.
            - A `question` is a real question you would ask out loud: "Is this meant to skip archived repos?"

            Rules for comments:
            - `path` is exactly the path as it appears after `+++ b/` in the diff, without the `b/`.
            - `side` is "RIGHT" for a line the PR adds or leaves unchanged, "LEFT" only for a line it deletes.
            - `line` is the line number in the new file for RIGHT, in the old file for LEFT. Count down from the \
            `@@ -old,n +new,m @@` header of the hunk the line sits in.
            - `lineText` is that line copied verbatim, without its leading `+`, `-` or space. It is how I check \
            your line number, so copy it exactly, spaces included.
            - Comment only on lines inside a hunk of that diff. Leave out points about code the PR did not touch.
            - One comment per line: if two things are wrong on one line, say both in one body.
            - `severity`: `important` only for what has to be fixed before merging; that is what I judge the \
            verdict by. `nit` for what could be better but need not block, `pre-existing` for a real problem on a \
            line of the hunk that the PR did not change, and `question` for a question. No findings is a fine answer \
            for good work: `{"comments": []}`.

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
        // Into a session that can push and post: the review is the user's to finish, so it says so, and it hands over
        // the talk, not a task.
        case .reviewHandoff:
            """
            Claude just reviewed {repo}#{number} — {title} ({url}) and put {posted} comments into my pending review \
            on GitHub. Nobody else can see that draft yet.

            {#summary}Its summary: {summary}{/summary}

            {#findings}The comments:

            {findings}{/findings}

            I want to talk them through with you: which hold up, which are wrong, and how to word them. Read the code \
            they point at as you need to. Don't post, comment, approve or push anything: the review is mine to finish \
            on GitHub. Wait for my questions.
            """
        case .reviewReformat:
            """
            The text below is a code review. Re-emit it as the single JSON object described here and nothing else: \
            {"verdict": "APPROVE" | "REQUEST_CHANGES" | "COMMENT", "summary": "...", "comments": [{"path": "...", \
            "side": "RIGHT" | "LEFT", "line": 1, "lineText": "...", "severity": "important" | "nit" | \
            "pre-existing" | "question", "body": "..."}]}. Invent nothing, and drop any finding that has no file and \
            line.
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
