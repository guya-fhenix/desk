# Fhenix Desk

Menu bar app that tracks the Fhenix development cycle. You talk to one master session, in the Master tab; it starts a
worker session per task, and the workers follow the Fhenix workflow on their own and ask, through the master, before
anything other people will see. Desk is the board: your work by task, the reviews waiting on you, Jira, and what changed
on GitHub, which it hands to the master.

What Desk writes itself is a press of yours: Squash and merge, Close, Ready for Review and Convert to Draft, a
suggested Jira move, a review session's start, and in a PR's conversation Reply, Resolve and Comment. Everything else is
the master's and its workers', on your word.

Sources: GitHub PRs (`gh`), local git worktrees, Claude Code sessions (`~/.claude`), Jira. What it shows is read
off them on every refresh. Under `~/Library/Application Support/Fhenix Desk` it keeps your settings (`config.json`),
which nudges it has already notified (`notified.json`), and the master's folder (see The master and its workers). If
`config.json` can't be read, Desk starts on its defaults, keeps the broken file as `config.json.bad`, and Settings says
so. Its UserDefaults keep the rest: the moves you dismissed, each screen's filters and sort, and that you finished
setup.

```sh
make doctor   # print all data as text: the tasks and the master included
make run      # run from the build tree
make install  # quit a running Desk, build the .app, copy it to ~/Applications, open it
```

GitHub and Jira go through their CLIs, signed in with a token: Setup's Sign in step and Settings (⌘,) → GitHub and
→ Jira take one and hand it to `gh` or `acli` on stdin, and Desk keeps none of it. A token rather than the browser
because Jira limits how much a browser (OAuth) sign-in may ask each hour and then refuses it until the hour turns,
which stops the ticket sync; API tokens have no such limit. So a Jira signed in through the browser is asked for one too.

## Setup

The window opens on Setup until you finish it once; Settings → General → Run setup again, and the app menu's Setup…,
bring it back. **Tools** checks Homebrew, the Command Line Tools, `gh` (2.81.0 or later, the first that reports its
sign-ins as JSON; an older one gets an Upgrade press), `acli` and Claude Code; **Sign in** checks `gh`
(the active account, with the `repo` and `read:org` scopes), `acli jira`, `claude` and the `fhenix-workflow` plugin,
which needs a review skill: `review-teammate-task` (1.0, any set of PRs) or `review-pr` (0.8, one PR). Each check is read
off the tool every time. GitHub and Jira ask for a token there (Create a token opens GitHub with a classic token's scopes
ticked, or Atlassian's API tokens page), with Use the browser beside it. Install, Use the browser and the other fixes run
their command in the terminal panel, in a login shell, so you can follow it and type a password; the checks run again
when the tab ends. Then come Settings' own GitHub, Repos (Track my clones ticks every org repo you have a clone of) and
Jira pages, and Finish, which needs the Command Line Tools, `gh` signed in and one tracked repo. Later closes Setup until
the next launch. `make doctor` prints the same checks.

Settings → General → Open at login starts Desk when you log in, so nudges keep coming after a restart. It works for
the installed app only; a build run with `swift run` has no bundle to register.

## The window

The sidebar lists Search (⌘K), Up Next, Tasks, Reviews and Jira, each screen with a count of the rows it opens on,
and Settings (⌘,). ⌘1 to ⌘4 pick a screen. The sidebar collapses with its toggle or View → Show/Hide Sidebar (⌃⌘S).
Under it, the Master block is the master session: its state under its name (not running, starting, working, listening,
waiting for you) with the questions it has open for you, and Start or Open. Under that, one status block says how the
sync stands: when every
source last synced, with the arrow that syncs them all (⌘R), a spinner while one syncs, or the sources that failed with
Retry. Under that, your Claude plan's session and week limits are two thin meters. Click the block for each source's age
and error, the Settings pane that fixes a sign-in, and when each limit resets. When a newer Desk is out, a block above it
says "Update to 1.1.7 · You have 1.1.6" and opens the release page. Desk asks `gh` for the latest release at launch and
every six hours; without access to the repo, it never shows.

In a list, the arrow keys walk the rows, and a click, Return or → opens the row's page in place of the list. The
page's back link, ← or Go → Back (⌘[) returns to the list with the row still selected. Jira's rows open in place
instead (see Jira).

Search finds any open PR by `repo#number`, title or branch, and any of your tickets by key or summary. ↩ opens it here:
your PR on Tasks, one in the review queue on Reviews, a ticket on Jira. ⌘↩ opens it on GitHub or Jira. A PR on none of
those screens opens on GitHub.

The menu bar item opens the window on a click. A right-click or Control-click shows a menu: open Desk, quit, your open
PRs and the reviews that need you, each opening its page. A nudge also comes as a macOS notification, unless Settings
→ General turns them off.

## Up Next

The window opens on Up Next: what waits on you, under the section that says what to do. **Waiting on you** first: the
questions the master has open for you, each with the task it is about and how long ago it asked; a row, or Open Master,
opens the Master tab to answer it. Then Ready to merge, Your move (CI failed, conflicts, changes requested, a review
thread open, needs a rebase, or a session waits on you; conflicts by GitHub's own `mergeable`, whatever its merge state
sums up), Drafts to submit (reviews you started on GitHub and have not sent), To review, Jira moves (the moves Desk
suggests), Ready to start (sprint tickets of yours nothing has started: tell the master "start PRO-123"), and Waiting
(your PRs that wait on someone else). The rows are the other screens' own, and open their pages here.

Until GitHub has answered, Up Next names the sources it is still reading over grey placeholder rows. If GitHub never
answered, it says so with GitHub's error and Retry. A source that failed after loading shows a banner over its last
good rows. All clear shows only once every source answered without an error.

## Tasks

Your work by task. A task starts from a Jira ticket (named after its key), from a session started without one, such as an
investigation of errors in the cloud (named after the session), or from a PR with neither (named after its stack's
root). A ticket's task holds every open PR of yours that names it, in any repo, and the PRs stacked on them; a worker
that opens a PR with no key keeps it in its own task. Nothing of it is stored: every refresh works it out again.

Open lists the tasks, Recently merged your PRs merged in the last month; ⌃Tab and ⌃⇧Tab flip between the two. Show PRs
gives the flat list of your open PRs instead. Each task is a band with a gap above it, its left edge in the colour of
who it waits on: orange for you, blue for its worker, gray for reviewers. The band names the task, with an icon for what
it started from (ticket, session or PR), its title, Jira's status for a ticket, who it waits on, its worker to attach,
and under them what the worker is doing (Claude Code's own status line) and what the task depends on: someone else's
open PR, or a branch no open PR opens. Its PRs sit indented under the band, stacked base first. A task with no PR yet
is its band alone, and says "No PR yet".

Each PR row leads with the title. Under it is a line with the checks, number, repo, branches, size, open threads and
ticket. On the right is one pill for what the PR waits on, coloured by whose move it is: Conflicts, CI failed, Changes
requested, Ready to merge, Draft · not self-reviewed (or · self-reviewed, or · finding open), N open threads, Waiting on
review. Then the session's mark (a spinner while it works, a bubble while it asks you something) and when the PR last
moved.

Your PR's page leads with its title, which you can edit while it is open. The status line under it says how it ended,
or its checks, review and merge state; then its Jira ticket; on the right its session's Attach, and ⋯ with Open on
GitHub, Copy Branch, Copy Link, Mark Ready for Review on a draft or Convert to Draft on a ready PR, and Close Pull
Request…, which asks first. The wide column has two tabs. **Conversation** holds the description, editable too, and the
conversation. **Files changed** holds the code the PR changed, a box per file that folds, with each review thread under
the line it ends on, to reply to or resolve there (an outdated one has no line left, so only Conversation lists it); it
is fetched when the tab opens and again once new commits move the head. The side column holds up to four cards. **Task**,
when the task is more than this PR: its other PRs and where each stands, what it depends on, its worker and what it is
doing, and the master's questions about it. **Next step** says what the PR's stage waits on: where its self-review
stands on a draft, whose move it is in review, and on one ready to merge **Squash and merge**, which asks first and merges
only the head the page showed. A conflict, red CI or a base to rebase onto shows there too, for the worker to fix when the
master hands it over. **Checks** sums up every check on the head commit in one line, "✓ 14 passed, 2 skipped"; Show all
lists them, worst first, with where a failed one stopped. **About this PR** has the open threads by who started them, the
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

The queue groups by task: a ticket's PRs, or a stack, under one line saying who wrote it, how many parts and how big. Tick
any rows, or a group's tick for all its parts, from any repos and authors, and **Review together** asks for notes (what
to focus on, what to check, what you already know) and starts one review session for all of them, on the
fhenix-workflow `review-teammate-task` skill, in the first PR's clone with the others' clones added. **Start review** on one
PR asks for notes the same way. Where the skill is not there, from the plugin folder or the installed plugin, the ticks
stay hidden and a review is one PR on `review-pr`.

The review is yours. By the time a PR is ready, the author's self-review and CodeRabbit have run the review checklist on
it. What is left is the person's part: does it do what the ticket asks, is the approach right, is the risk tier right,
would How to revert work, do the tests prove it, and what does it change outside these PRs (other services, shared data,
deploys, production) that the diff alone does not show. The session summarizes the set, gives its take on each of those
questions with where to look, follows your notes, and posts the comments and the verdicts you decide on, each PR's
together.

The review swaps the page for the diff, with the session beside it in the terminal panel. The group's PRs sit above the
diff, base first, to move between them, with your notes under them. While the diff shows, the sidebar folds away to give
the code the room; it comes back as it was when you leave the diff, and ⌃⌘S shows it in between. The file you are in
stays pinned at the top, and the menu at the top, "File 2 of 4 · contracts/ACL.sol", lists every file with its +/− counts
and jumps to one. A file's header folds it. One gutter holds the new line number, or a removed line's old one; hover a
line for its old number. Each review thread shows under the line it ends on, with Reply and Resolve; new line comments
and the verdicts stay the session's. If a PR gets new commits while you read, Reload fetches the diff again.

The diff and the session are linked. When the session points at a line, the diff moves there, to whichever PR of the
group the line is in: it runs Desk's `desk-show` helper, which opens one `fhenixdesk://show/…` link and nothing else, and
is allowed for it without asking. Only a link to a PR Desk knows brings the window forward. Select lines in the diff
(click, then shift-click, or move with ↑ ↓ and stretch with ⇧↑ ⇧↓) and Ask Claude (⌘↩) pastes them into the session's
input, with the PR they are from, for your question. To background the session, use Claude's own agents view. Review on
GitHub still opens the Files tab. The row says where your review stands: `draft · 7` while you have a pending review, or
the verdict you sent. Nothing of it is stored: every poll reads your pending and submitted reviews off the PR.

## Terminal panel

Sessions open in a panel on the right of the window, a tab each: the master, first and pinned; background sessions
attached with `claude attach`; review sessions; and Setup's installs and sign-ins. Switching tabs or screens leaves them
running; closing a tab stops what runs in it. An attached session, the master included, only detaches, and a review
session can be reopened with `claude --resume`. View → Show/Hide Terminal (⌃`) hides the panel. It is SwiftTerm, inside
the app.

Drag the line beside it to widen it, as far as the screen's own minimum allows; for more, the panel's expand button
(View → Expand Terminal, ⌃⇧`) lays it over the whole window beside the sidebar, and choosing a screen puts it back. Its
text size buttons, and View → Terminal Text Bigger, Smaller and Default Size (⌘=, ⌘-, ⌘0), set every tab's text from
9 to 24 pt, 12 to start; Desk remembers it.

## Jira

The Jira screen lists the running sprint or the backlog, one group per status in workflow order, yours unless the
assignee filter (the row of pictures) picks others. Done is left out. A click, Space or Return opens a ticket under
its row and closes the one open before, so one is open at a time. The open part has only what the row doesn't say:
who opened it, its PRs and sessions, why Desk suggests its move with Move and Dismiss, and its description, editable,
with Open page and Open in Jira. → opens its page, and ⌘↩ opens it in Jira. A ticket's page shows its key and summary,
where it stands, its description, and beside it the PRs that name it, the sessions started on it, and the move Desk
suggests for it, if any. To start work on one, tell the master: "start PRO-123".

## Ticket sync

Desk reads the Jira key out of each PR's branch and title, never its description, which is prose about other
tickets. From the PRs it works out where the ticket should be: `👀 Review Ready` while a PR of its is open and marked
ready, `Done` once they have all merged and one of them landed on the repo's default branch. A revert lands nothing.

Where Jira is behind, Desk suggests the move; it never makes it. Each suggestion waits for your **Move** or
**Dismiss**: on the Jira screen above the status groups (Move all moves every one), under Jira moves on Up Next, and on
the ticket's page and under its row. Move runs `acli jira workitem transition`; a ticket still in To Do passes through
the in-progress status on its way. If Jira refuses, the suggestion turns red with Jira's reason, and Move becomes Retry.
Dismiss hides the suggestion until the ticket's PRs point it somewhere else. A Jira row shows the suggested status as a
chip, and a Tasks row an orange arrow beside the ticket key.

It only suggests moving a ticket forward, and only your own. A ticket Jira calls done stays done, and one past In
Progress (in QA, say) is never suggested for review. A PR merged into the branch below it in a stack finishes nothing,
and an open draft keeps the ticket out of both statuses. The workers never move a ticket: the sync is Desk's.

Set the three status names in Settings → Jira, exactly as Jira spells them. An empty one turns its move off.

## Background sessions

On your PR's page, and on a review's page, the session press says whether one of Claude Code's background sessions
(`claude agents`, the ones under `~/.claude/jobs`) is about that PR. A PR's session is the one started on it or on its
ticket, else the earliest one that links to it. **Attach** runs `claude attach <id>` in the terminal panel: the only
way into a background session from outside the terminal that started it, and it works whether the session is still
running or has finished. With more than one, the arrow beside it lists them all, newest first. Interactive sessions
never appear: nothing outside their own terminal can reach them.

Desk reads every background session that is about a PR or a ticket, that its prompt names as the master, a worker or a
review, or that runs in one of your tracked clones. It starts none of them itself, except the master and review
sessions: the master starts the workers.

## The master and its workers

The **Master** block in the sidebar attaches the terminal panel to the master session, first among the tabs. With none running it
starts one, named `master`, in the master folder: `~/Library/Application Support/Fhenix Desk/master`. It runs the
fhenix-workflow `coordinate-tasks` skill, in auto mode, and starts every worker in the same mode, so no worker holds its
messages for approval. Closing the tab only detaches; the master keeps running.

You talk to it in plain words: "start PRO-123", "find out why decrypt requests fail on testnet", "what's waiting on
me?", "review PRO-646 and teecryptor#14". It starts one worker per task, even across repos, named after the ticket or
after what you asked, on the `work-on-task` skill. A worker plans and waits for your yes, builds in worktrees, opens its
PRs as drafts, self-reviews them and recommends a fix for each finding, fixes the ones you pick, and asks before anything
other people will see: marking ready, replies posted as you, filing a ticket, merging. It reports to the master, and the
master asks you, one line each, and keeps the open questions in `asks.json`, which Up Next, the Task card and the Master
badge read.

Desk feeds the master through two files in its folder. `graph.json` holds the tasks, their PRs and their workers,
rewritten once every source has answered and whenever the tasks change. `events.jsonl` gets one line for each nudge Desk
notifies you about (CI failed, a conflict or a base to rebase onto, changes requested, ready to merge, a review asked of
you), which the master routes to the task's worker or to you. Only the installed app writes events: a build without a
bundle sends no notifications.

Settings → Master shows whether the master runs and where, the folders it also sees (your repo roots until you list
others; written to the master folder's `.claude/settings.json`, for the next time it starts), whether Desk sends it
events, and **Load plugins from**: a folder of plugins the master, its workers and review sessions load in place of the
installed ones (`--plugin-dir`), for trying skill changes before they ship.

## Conversation

Under the description, on your PR's page and on a review's page, is the PR's conversation, laid out as GitHub's,
each comment with its author's picture: the open review threads first, each a card with its file and line and
**Resolve**, every comment, and a reply box always open with **Reply** beside it; then the PR's comments and the
reviews that say something (an approval, changes requested, a review with a body), oldest first, and a comment box
always open with **Comment** beside it; and the resolved threads, folded to who started them and how, with
**Unresolve**. A long comment, such as CodeRabbit's walkthrough, shows its start until opened; the HTML bots write
shows as what it means. ⌘↩ posts from the box you are typing in. Each goes to GitHub as you, through `gh`, and only
on your press; Resolve and Unresolve show only where GitHub lets you. The conversation is fetched when the page shows
the PR and again whenever the PR changes; a thread can also be answered through the master, by the PR's worker.
