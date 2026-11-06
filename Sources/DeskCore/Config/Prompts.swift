import Foundation

/// Every text the app sends Claude, each one editable in Settings → Prompts. A prompt names the values it
/// takes as `{name}`, and wraps what only belongs on some tickets or PRs in `{#name}…{/name}`, with an
/// optional `{else}` for the text that goes in when the condition does not hold.
public enum PromptID: String, CaseIterable, Sendable, Identifiable {
    case ticketPlan, session, selfReview, fixConflict, fixChecks

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ticketPlan: "Start a ticket"
        case .session: "PR session"
        case .selfReview: "Flow › Self-review"
        case .fixConflict: "Flow › Fix the conflict"
        case .fixChecks: "Flow › Fix CI"
        }
    }

    /// When the text is sent, for the line under its editor.
    public var usage: String {
        switch self {
        case .ticketPlan: "Sent with `claude --bg` when you press Start on a ticket."
        case .session: "Sent with `claude --bg` when you start a background session on a PR."
        case .selfReview: "Sent to the PR's session when you approve its draft. It reviews once and changes no code: the findings come back as threads with suggested fixes, for you to read on the PR and settle with the session. Add --fix to its /pre-pr command to have it fix them itself. Writing the JSON described here to {resultFile} is its last step. The session shows as working while it runs; the PR is Self-reviewed once /pre-pr's evidence is on it."
        case .fixConflict: "Sent to the PR's session when you press Fix it on a PR that conflicts with its base branch. Writing the JSON described here to {resultFile} is its last step. Nothing is sent on its own."
        case .fixChecks: "Sent to the PR's session when you press Fix it on a PR whose CI failed. Writing the JSON described here to {resultFile} is its last step. Nothing is sent on its own."
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
        case .fixConflict, .fixChecks:
            return pr + [("headRef", "the PR branch"), ("worktree", "the worktree path"), ("resultFile", "where the session writes its summary")]
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
        case .selfReview, .fixChecks: [("worktree", "the branch is checked out in a worktree")]
        case .fixConflict: [("worktree", "the branch is checked out in a worktree"), ("draft", "the PR is still a draft")]
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
        // One run, and no code changed: the findings come back as threads with a suggested fix, for you to read on the PR
        // and settle with the session. /pre-pr where the repo adopted the review flow; elsewhere reviewing-code, whose
        // findings are posted the same way so they show among the PR's threads. Add --fix to /pre-pr below to have it
        // fix them itself. The result file comes last because writing it is the last thing to do.
        case .selfReview:
            """
            Review pull request {url} ({repo}#{number}, "{title}") once, then write the summary file below. Change no \
            code: the findings go on the pull request as review threads, each with a suggested fix.

            {#worktree}Its branch {headRef} is checked out in the worktree at {worktree}. Work only there \
            (EnterWorktree with that path if you are not in it already).{else}Its branch is {headRef}; work on that \
            branch.{/worktree}

            How it reviews depends on whether the checkout has adopted the review flow: `REVIEW.md` and \
            `.github/review/tier.sh` at its root.

            If it has: run `claude -p "/fhenix-workflow:pre-pr {number}" --permission-mode auto --output-format text` \
            once, from that checkout, then read its output. /pre-pr sets disable-model-invocation, so it runs as a \
            typed command in that headless session, not as a skill you invoke. It runs the checks and the reviews, \
            posts each finding as a review thread on its line with a suggested fix, and posts the evidence as a pull \
            request comment. Do not run it again, whatever it reports.

            If it has not: run the fhenix-workflow:reviewing-code skill on the pull request once. Post its Important and \
            Nit findings in one review with event COMMENT (gh api repos/{repo}/pulls/{number}/reviews), one comment on \
            each finding's line, each starting with the line `<!-- pre-pr:finding -->`, then `**Important** · <title>` \
            or `**Nit** · <title>`, then why it matters in one sentence and `**Fix:**` with the one fix you recommend. \
            Put Pre-existing findings in the review's body.

            Either way, change no code and keep the pull request a draft: never run `gh pr ready`.

            When you are done, write this JSON to {resultFile} and nothing else:
            {"clean": true, "findings": [{"severity": "important", "file": "src/a.rs", "line": 42, \
            "problem": "what is wrong, in one plain sentence", "fix": "the fix you suggested, in one plain sentence"}]}
            `clean` says whether the review reported no Important finding. `severity` is "important" for an \
            Important finding and "nit" for a Nit. List every finding you posted.
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
