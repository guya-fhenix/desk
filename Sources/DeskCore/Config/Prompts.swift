import Foundation

/// Every text the app sends Claude, each one editable in Settings → Prompts. A prompt names the values it
/// takes as `{name}`, and wraps what only belongs on some tickets or PRs in `{#name}…{/name}`, with an
/// optional `{else}` for the text that goes in when the condition does not hold.
public enum PromptID: String, CaseIterable, Sendable, Identifiable {
    case ticketPlan, session, selfReview, proposeFixes, applyFixes, fixConflict, fixChecks, review, reviewSystem, reviewReformat
    case reviewHandoff

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ticketPlan: "Start a ticket"
        case .session: "PR session"
        case .selfReview: "Flow › Self-review"
        case .proposeFixes: "Flow › Propose fixes"
        case .applyFixes: "Flow › Apply fixes"
        case .fixConflict: "Flow › Fix a conflict"
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
        case .selfReview: "Sent to the PR's session when you approve its draft. It must start with /goal, and the session must write the JSON described here to {resultFile}: that file is how the app knows it has finished."
        case .proposeFixes: "Sent to the PR's session when a teammate reviews it. The app reads the proposals from the JSON written to {resultFile}, so keep its field names."
        case .applyFixes: "Sent to the PR's session when you apply the fixes you approved. The session writes the JSON described here to {resultFile} when it is done."
        case .fixConflict: "Sent on its own when a PR in the flow conflicts with its base, once its session has been idle for 10 minutes; once per PR head."
        case .fixChecks: "Sent on its own when CI fails on a PR in the flow, once its session has been idle for 10 minutes; once per PR head."
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
        case .selfReview, .proposeFixes, .fixConflict, .fixChecks:
            return pr + [("headRef", "the PR branch"), ("worktree", "the worktree path"), ("resultFile", "where the session writes its summary")]
        case .applyFixes:
            return pr + [
                ("headRef", "the PR branch"), ("worktree", "the worktree path"), ("resultFile", "where the session writes its summary"),
                ("fixes", "the fixes you approved, one per line"),
            ]
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
        case .selfReview, .proposeFixes, .applyFixes, .fixChecks: [("worktree", "the branch is checked out in a worktree")]
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
        // PRs, from Reviews, where it must never push — on your own PRs the flow sends the conflict fix itself.
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
        // The whole text is the goal's condition, and a multi-paragraph one holds: the session works until the
        // evaluator agrees it is met. The result file comes last because writing it is the last thing to do, and it
        // is what the app waits for — the session reports `done` between rounds as well.
        // A repo that adopted the review flow gets /pre-pr, the review the CLI runs, so its evidence comment and
        // `local-reviewed` label are on the PR when you approve the draft; any other repo keeps the reviewing-code loop.
        case .selfReview:
            """
            /goal Review and fix pull request {url} ({repo}#{number}, "{title}") until a review comes back clean, \
            or three reviews have run, and the summary file below is written.

            {#worktree}Its branch {headRef} is checked out in the worktree at {worktree}. Work only there \
            (EnterWorktree with that path if you are not in it already).{else}Its branch is {headRef}; work on that \
            branch.{/worktree}

            How each round reviews depends on whether the checkout has adopted the review flow: `REVIEW.md` and \
            `.github/review/tier.sh` at its root.

            If it has: each round, run `claude -p "/fhenix-workflow:pre-pr --no-ready --fix {number}" \
            --permission-mode auto --output-format text` from that checkout, then read its output. /pre-pr sets \
            disable-model-invocation, so it runs as a typed command in that headless session, not as a skill you \
            invoke. It runs the checks and the reviews, commits and pushes its /simplify edits and its fixes, \
            re-reviews every commit it adds, posts each open finding as a review thread on its line, and posts the \
            evidence as a pull request comment. A round is clean when it reports no Important finding; a run that \
            stops before its reviews is not clean.

            If it has not: each round, run the fhenix-workflow:reviewing-code skill on the pull request, fix every \
            Important finding it reports, and the Nits whose fix is a line or two. Commit the round's fixes with a \
            message that says what the review found, and push. A round is clean when it reports no Important finding.

            Either way, keep the pull request a draft: never run `gh pr ready`.

            When you stop, write this JSON to {resultFile} and nothing else:
            {"rounds": 2, "clean": true, "findings": [{"severity": "important", "file": "src/a.rs", "line": 42, \
            "problem": "what was wrong, in one plain sentence", "fix": "what you changed, in one plain sentence, or \
            why you left it", "round": 1, "fixed": true}]}
            `rounds` is the number of reviews that ran, and `clean` says whether the last one was clean, as defined \
            above. `severity` is "important" for an Important finding and "nit" for a Nit. List every Important \
            finding from every round, and the Nits you fixed.
            """
        // Unresolved threads are the set to answer: what a reviewer still wants is what nobody has closed. Nothing
        // changes here — you approve each fix first — and `resolve` is the session's guess, which you can flip.
        case .proposeFixes:
            """
            A teammate reviewed pull request {url} ({repo}#{number}, "{title}"). Read every review thread that is \
            still unresolved, with its id (gh api graphql, reviewThreads), and the bodies of the reviews submitted \
            since your last push (gh pr view {number} --repo {repo} --comments).

            {#worktree}Its branch {headRef} is checked out in the worktree at {worktree}. Read the code there.{/worktree}

            For each comment that asks for something, work out the fix — but change nothing, commit nothing and post \
            nothing. I approve each fix myself before anything happens.

            Write this JSON to {resultFile} and nothing else:
            {"proposals": [{"thread": "PRRT_…", "reviewer": "login", "file": "src/a.rs", "line": 12, "comment": "what \
            the reviewer asks, in one plain sentence", "fix": "what you would change, in one or two plain sentences", \
            "diff": "a short unified diff of the change, or empty", "resolve": true}]}
            Set "resolve" to true when the fix is simple and plainly what was asked, so the thread can be resolved once \
            it is in; false when the reviewer should look at it again. No proposals is a fine answer: {"proposals": []}.
            """
        // Only the approved fixes are listed; the ones you skipped get no reply on their threads, by your choice.
        case .applyFixes:
            """
            Apply these fixes to pull request {url} ({repo}#{number}) — the ones I approved from your proposals, and \
            only these:

            {fixes}

            {#worktree}Its branch {headRef} is checked out in the worktree at {worktree}. Work only there \
            (EnterWorktree with that path if you are not in it already).{/worktree}

            Commit them with a message that says which review comments they answer, and push. Then resolve the threads \
            marked "resolve it" (gh api graphql, resolveReviewThread) and leave every other thread open. Post nothing \
            on any thread.

            When you are done, write this JSON to {resultFile} and nothing else:
            {"applied": 2, "summary": "what changed, in one plain sentence"}
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
