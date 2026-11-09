# Fhenix Desk

Menu bar app that tracks the Fhenix development cycle and carries your own work from a ticket to its merge.
Everything it writes is a press of yours: starting a session, the flow's Run /pre-pr, Mark ready, Fix it and Merge, a
suggested Jira move, and in a PR's conversation Reply, Resolve and Comment. The one exception is Start on a ticket,
which also moves the ticket to In Progress.

Sources: GitHub PRs (`gh`), local git worktrees, Claude Code sessions (`~/.claude`), Jira. What it shows is read
off them on every refresh. Under `~/Library/Application Support/Fhenix Desk` it keeps your settings (`config.json`)
and which nudges it has already notified (`notified.json`). If `config.json` can't be read, Desk starts on its
defaults, keeps the broken file as `config.json.bad`, and Settings says so. Its UserDefaults keep the rest: the
moves you dismissed, each screen's filters and sort, which details panels are open, and that you finished setup.

```sh
make doctor   # print all data as text
make run      # run from the build tree
make install  # quit a running Desk, build the .app, copy it to ~/Applications, open it
```

Jira goes through the Atlassian CLI: run `acli jira auth login --web` once, then Settings (⌘,) → Jira →
Recheck. Desk stores no Jira token.

## Setup

The window opens on Setup until you finish it once; Settings → General → Run setup again, and the app menu's Setup…,
bring it back. **Tools** checks Homebrew, the Command Line Tools, `gh` (2.81.0 or later, the first that reports its
sign-ins as JSON; an older one gets an Upgrade press), `acli` and Claude Code; **Sign in** checks `gh`
(the active account, with the `repo` and `read:org` scopes), `acli jira`, `claude` and the `fhenix-workflow` plugin,
which needs 0.8.0 or later for Start review. Each check is read off the tool every time. Install, Sign in and the
other fixes run their command in the terminal panel, in a login shell, so you can follow it and type a password; the
checks run again when the tab ends. Then come Settings' own GitHub, Repos (Track my clones ticks every org repo you
have a clone of) and Jira pages, and Finish, which needs the Command Line Tools, `gh` signed in and one tracked repo.
Later closes Setup until the next launch. `make doctor` prints the same checks.

Settings → General → Open at login starts Desk when you log in, so nudges keep coming after a restart. It works for
the installed app only; a build run with `swift run` has no bundle to register.

## The window

The sidebar lists Search (⌘K), Up Next, Pull Requests, Reviews and Jira, each with a count of the rows it opens on,
and Settings (⌘,). ⌘1 to ⌘4 pick a screen. The sidebar collapses with its toggle or View → Show/Hide Sidebar (⌃⌘S).
Under it, one status block says how the sync stands: when every source last synced, with the arrow that syncs them
all (⌘R), a spinner while one syncs, or the sources that failed with Retry. Under that, your Claude plan's session and
week limits are two thin meters. Click the block for each source's age and error, the Settings pane that fixes a
sign-in, and when each limit resets.

In a list, the arrow keys walk the rows, and a click, Return or → opens the row's page in place of the list. The
page's back link, ← or Go → Back (⌘[) returns to the list with the row still selected. Only Jira has a details panel
beside its list; View → Show/Hide Details (⌥⌘I) toggles it.

Search finds any open PR by `repo#number`, title or branch, and any of your tickets by key or summary. ↩ opens it here:
your PR on Pull Requests, one in the review queue on Reviews, a ticket on Jira. ⌘↩ opens it on GitHub or Jira. A PR
on none of those screens opens on GitHub.

The menu bar item opens the window on a click. A right-click or Control-click shows a menu: open Desk, quit, your open
PRs and the reviews that need you, each opening its page. A nudge also comes as a macOS notification, unless Settings
→ General turns them off.

## Up Next

The window opens on Up Next: what waits on you, under the section that says what to do. Ready to merge, Your move
(CI failed, conflicts, changes requested, needs a rebase, or a flow or session waits on you), Drafts to submit (reviews
you started on GitHub and have not sent), To review, Jira moves (the moves Desk suggests), Ready to start (sprint
tickets of yours nothing has started), and Waiting (your PRs that wait on someone else). The rows are the other
screens' own, and open their pages here.

Until GitHub has answered, Up Next names the sources it is still reading over grey placeholder rows. If GitHub never
answered, it says so with GitHub's error and Retry. A source that failed after loading shows a banner over its last
good rows. All clear shows only once every source answered without an error.

## Pull Requests

Open lists your open PRs, and Recently merged the ones merged in the last month. ⌃Tab and ⌃⇧Tab flip between the two,
from the list or the search box; Tab moves focus. Each row leads with the title. Under it is a line with the checks,
number, repo, branches, size, open threads and ticket. On the right is one pill for what the PR waits on, coloured by
whose move it is: Conflicts, CI failed, Changes requested, Ready to merge, Draft · run /pre-pr (or · finding open, or ·
mark ready), Waiting on review. Then the session's mark (a spinner while it works, a bubble while it asks you
something, red when your last press on it failed) and when the PR last moved. A PR stacked on another sits indented
under it.

Your PR's page leads with its title, which you can edit while it is open. The status line under it says how it ended,
or its checks, review and merge state; then its Jira ticket; on the right the session (see Background sessions), and
⋯ with Open on GitHub, Copy Branch, Copy Link and Close Pull Request…, which asks first. The wide column holds the
description, editable too, and the conversation. The side column holds three cards. **Next step** is what the PR's
stage waits on and the press that moves it (see Flow). **Checks** sums up every check on the head commit in one line,
"✓ 14 passed, 2 skipped"; Show all lists them, worst first, with where a failed one stopped. **About this PR** has the
open threads by who started them (/pre-pr, CodeRabbit, each person by name) with the way to them on GitHub, the
reviewers and where each stands, labels, size, when it was opened and updated, and its stack.

## Reviews

The Reviews screen opens on **Needs you**: the PRs asked of you, and the open PRs by others you have not reviewed
yet. One you reviewed comes back when its author asks you again. **On you** keeps to the ones GitHub asked of you,
**Reviewed** to the ones you reviewed that wait on their authors, and **All** shows every open PR by someone else.

One Filters menu holds the rest, and each filter in force shows under the bar as a token you can remove. **Needs an
approval**, on by default, keeps to the PRs the `review-gate/approvals` status on the head commit says still need one:
fewer approvals on the latest commit than the risk tier needs, CodeRabbit not done reviewing it yet, or a repo that
posts no such status at all. "low risk: no approval needed" and a met count drop out. A day limit keeps to the PRs
opened in the last few days, and you can hide authors. Up Next, the sidebar badge and the menu bar's menu follow the
same filters. The tier shows as a Risk chip on each row, and PRs CodeRabbit labels `needs-human` come first, with a
Needs a person chip. Drafts and bot PRs stay out of the queue altogether.

The review is yours. By the time a PR is ready, /pre-pr and CodeRabbit have run the review checklist on it. What is
left is the person's part: does it do what the ticket asks, is the approach right, is the risk tier right, would its
How to revert work, does Testing prove it, and what does it change outside this PR (other services, shared data,
deploys, production) that the diff alone does not show. A PR's page shows its description, checks and risk. **Start
review** swaps the page for the PR's diff and opens a regular Claude session beside it, in the terminal panel, on the
fhenix-workflow `review-pr` skill. The session summarizes the description, CodeRabbit's walkthrough and the /pre-pr
evidence, gives its take on each of those questions with where to look, and posts the comments and the verdict you
decide on.

While the diff shows, the sidebar folds away to give the code the room; it comes back as it was when you leave the
diff, and ⌃⌘S shows it in between. The file you are in stays pinned at the top, and the menu at the top, "File 2 of 4
· contracts/ACL.sol", lists every file with its +/− counts and jumps to one. A file's header folds it. One gutter holds
the new line number, or a removed line's old one; hover a line for its old number. Each review thread shows under the
line it ends on, with Reply and Resolve; new line comments and the verdict stay the session's. If the PR gets new
commits while you read, Reload fetches the diff again.

The diff and the session are linked. When the session points at a line, the diff moves there: it runs Desk's
`desk-show` helper, which opens one `fhenixdesk://show/…` link and nothing else, and is allowed for it without asking.
Only a link to a PR Desk knows brings the window forward. Select lines in the diff (click, then shift-click, or move
with ↑ ↓ and stretch with ⇧↑ ⇧↓) and Ask Claude (⌘↩) pastes them into the session's input for your question. To
background the session, use Claude's own agents view. Review on GitHub still opens the Files tab. The row says where
your review stands: `draft · 7` while you have a pending review, or the verdict you sent. Nothing of it is stored:
every poll reads your pending and submitted reviews off the PR.

## Terminal panel

Sessions open in a panel on the right of the window, a tab each: background sessions attached with `claude attach`,
review sessions, and Setup's installs and sign-ins. Switching tabs or screens leaves them running; closing a tab stops
what runs in it. An attached session only detaches, and a review session can be reopened with `claude --resume`. View
→ Show/Hide Terminal (⌃`) hides the panel. It is SwiftTerm, inside the app.

## Jira

The Jira screen lists the running sprint or the backlog, one group per status in workflow order, yours unless the
assignee filter (the row of pictures) picks others. Done is left out. Selecting a row previews it in the details
panel; Return, a double-click or → opens its page, and ⌘↩ opens it in Jira. A ticket's page shows its key and summary,
where it stands with **Start in…** on the right, its description, and beside it the PRs that name it, the sessions
started on it with each one's flow stage, and the move Desk suggests for it, if any.

## Ticket sync

Desk reads the Jira key out of each PR's branch and title, never its description, which is prose about other
tickets. From the PRs it works out where the ticket should be: `👀 Review Ready` while a PR of its is open and marked
ready, `Done` once they have all merged and one of them landed on the repo's default branch. A revert lands nothing.

Where Jira is behind, Desk suggests the move; it never makes it. Each suggestion waits for your **Move** or
**Dismiss**: on the Jira screen above the status groups (Move all moves every one), under Jira moves on Up Next, and on
the ticket's page and details panel. Move runs `acli jira workitem transition`. If Jira refuses, the suggestion turns
red with Jira's reason, and Move becomes Retry. Dismiss hides the suggestion until the ticket's PRs point it somewhere
else. A Jira row shows the suggested status as a chip, and a Pull Requests row an orange arrow beside the ticket key.

It only suggests moving a ticket forward, and only your own. A ticket Jira calls done stays done, and one past In
Progress (in QA, say) is never suggested for review. A PR merged into the branch below it in a stack finishes nothing,
and an open draft keeps the ticket out of both statuses.

The one move Desk makes on its own is Start: once the ticket's planning session is running, the ticket moves to In
Progress, unless it is there already or done. That can move it from any other status, Review Ready included. If Jira
refuses, the ticket says so beside its sessions; the session keeps running.

Set the three status names in Settings → Jira, exactly as Jira spells them. An empty one turns its move off.

## Background sessions

On your PR's page, and on a review's page, the session press says whether one of Claude Code's background sessions
(`claude agents`, the ones under `~/.claude/jobs`) is about that PR. A PR's session is the one started on it or on its
ticket, else the earliest one that links to it. **Attach** runs `claude attach <id>` in the terminal panel: the only
way into a background session from outside the terminal that started it, and it works whether the session is still
running or has finished. With more than one, the arrow beside it lists them all, newest first. Interactive sessions
never appear: nothing outside their own terminal can reach them.

With no session, **Start session** starts one with the PR's branch checked out: in the worktree you already have on
that branch, or in a new one under the repo's `.claude/worktrees`, where `claude -w` puts its own. A fork's PR is
checked out detached at its PR head, in `.claude/worktrees/pr-<number>-<branch>`: its branch is not origin's even
when origin has one of the same name, and nothing can be pushed back to the fork from there. The session itself starts
in the repo's folder, so it gets that repo's plugins, settings and memory, and its prompt sends it into the
worktree. It is seeded with the PR's url, which ties it to the PR.

## Flow

**Start in…** on a ticket picks the repo and asks what the plan should focus on, then opens a background session
there. It writes a plan and waits; once you approve the plan in the session, it builds in a worktree of its own and
opens the PR as a draft. A PR of yours is in the flow while a background session works on it: the one that opened it,
or the one started on it or on its ticket. Its stage is the app's own, and picks what the Next step card shows. The
card shows on every open PR of yours, session or not: Mark ready and Merge need none, and Run /pre-pr starts one when
there is none. Nothing of it is saved: every refresh works it out again from GitHub and the session, so a relaunch
shows the same stage.

| Stage | When, and what Next step offers |
|---|---|
| Working | the ticket's session has not opened its PR yet |
| Draft | a draft. Two presses, both yours, in any order. **Run /pre-pr** sends the session one `/fhenix-workflow:pre-pr` run (or starts a session on the branch for it when the PR has none) where the repo has adopted the review flow, one `reviewing-code` pass elsewhere. It changes no code; its findings come back as threads on the PR, each with a suggested fix, and /pre-pr adds the `local-reviewed` label once no Important finding is open. **Mark ready**, once any session on it is idle, marks it ready and asks the review team. The card says where /pre-pr stands (not run, passed, or a finding open), and Mark ready asks first without the label |
| In review | ready, until it is ready to merge. The card says who it waits on: you, to fix what is red or requested, or the review team |
| Ready to merge | the approvals it needs, no open threads, CI not red and no conflicts. **Squash and merge** asks first, and merges only the head the page showed: GitHub refuses one pushed since |
| Merged, Closed | as GitHub says |

At any stage, Next step also says when the session is asking you something. A PR that conflicts with its base
branch, or whose CI failed, shows Fix it there: it sends the session the matching prompt (Settings → Prompts), which
fixes and pushes. Nothing is sent on its own.

Approved means the `review-gate/approvals` status on the head commit says so ("no approval needed", or as many
approvals on the latest commit as the tier needs) and, in a repo that posts no such status, GitHub's review decision.
The review team is a setting (GitHub → Flow, `protocol-team` by default). Settings → Repos, the PR page and the
ticket's repo menu say whether a repo's sessions can run the skills these presses call: `reviewing-code` (in
fhenix-workflow since 0.5.0), `pre-pr` (0.6.0) and `review-pr` (0.8.0), so 0.8.0 is the version to have. Run /pre-pr
on a draft stays off where the self-review skill is missing, and Start review where `review-pr` is.

## Conversation

Under the description, on your PR's page and on a review's page, is the PR's conversation, laid out as GitHub's,
each comment with its author's picture: the open review threads first, each a card with its file and line and
**Resolve**, every comment, and a reply box always open with **Reply** beside it; then the PR's comments and the
reviews that say something (an approval, changes requested, a review with a body), oldest first, and a comment box
always open with **Comment** beside it; and the resolved threads, folded to who started them and how, with
**Unresolve**. A long comment, such as CodeRabbit's walkthrough, shows its start until opened; the HTML bots write
shows as what it means. ⌘↩ posts from the box you are typing in. Each goes to GitHub as you, through `gh`, and only
on your press; Resolve and Unresolve show only where GitHub lets you. The conversation is fetched when the page shows
the PR and again whenever the PR changes; a thread can still be answered by telling the PR's session what to do with
it.

The app talks to the session the only way a background session takes outside input: once it has finished its
turn, it is stopped and resumed under the same id with the instruction, so the conversation carries on. It never
sends anything to a session that is working or asking you something (Run /pre-pr, Mark ready and Fix it wait for it
to be idle), and it sends nothing on its own: a conflict or red CI is yours to hand to the session. Each instruction
ends with the session writing a small result file in its own scratch folder. A PR you did not start from a ticket
joins the flow at its current stage once you start a session on it.

## Prompts

Every text the app sends Claude is editable in Settings → Prompts, one text each: Start a ticket, PR session, Review
a PR (what starts a review session on the `review-pr` skill), and the flow's Run /pre-pr, Fix the conflict
and Fix CI. `{name}` placeholders are filled when the prompt is sent, and `{#name}…{/name}` wraps what only applies
sometimes (a ticket description, unresolved threads, a conflict), with `{else}` for the other case. Only edits are
stored, in `config.json`, so an untouched prompt follows the app's own text; Reset to default removes an edit.
