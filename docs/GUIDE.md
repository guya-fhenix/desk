# Fhenix Desk

Menu bar app that tracks the Fhenix development cycle. You talk to one master session, in iTerm; it starts a
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
installed for your user in the Claude Code Desk runs (one repo's install doesn't count: the master, its workers and
review sessions need it in every repo), with a review skill: `review-teammate-task` (1.0, any set of PRs) or `review-pr`
(0.8, one PR). Settings → Master shows the same check, with Install. Each check is read
off the tool every time. GitHub and Jira ask for a token there (Create a token opens GitHub with a classic token's scopes
ticked, or Atlassian's API tokens page), with Use the browser beside it. Install, Use the browser and the other fixes run
their command in a window of your terminal app (iTerm2 unless Settings → Master says Terminal), in a login shell, so you
can follow it and type a password; the checks run again when you come back to Desk. Tools also checks tmux and iTerm2,
which show the master and its workers. Then come Settings' own GitHub, Repositories (Track my clones ticks every org repo you have a clone of) and
Jira pages, and Finish, which needs the Command Line Tools, `gh` signed in and one tracked repo. On the Jira page you
pick the project and, from the statuses Jira lists for it, where Desk moves a ticket at each step; Continue waits for
all three, or for no project, which leaves Jira off. Later closes Setup until
the next launch. `make doctor` prints the same checks.

Settings → General → Open at login starts Desk when you log in, so nudges keep coming after a restart. It works for
the installed app only; a build run with `swift run` has no bundle to register.

## The window

Desk is drawn in Nightshift's Instrument look: a warm off-white ground (or a warm near-black one), a panel-coloured
sidebar, white details columns, small uppercase section labels, Instrument Sans with identifiers in DM Mono. Settings →
Appearance picks System, Light or Dark, and the accent (indigo, teal, violet or graphite); both apply at once. The
fonts ship inside the app, with their licences (SIL Open Font License) in `Resources/Fonts`.

The sidebar has the app's mark, Search (⌘K), and Up Next, Tasks, Reviews and Jira, each with a count of the rows it opens
on (a dot beside Tasks while a worker is at work). ⌘1 to ⌘4 pick a screen. The sidebar collapses with its toggle or
View → Show/Hide Sidebar (⌃⌘S). At its foot, the Master block is the master session: its state under its name (not
running, starting, working, listening, waiting for you) with the questions it has open for you; it opens the Master
screen, or Start starts a master. Under it, one status block says how the sync stands: when every
source last synced, with the arrow that syncs them all (⌘R), a spinner while one syncs, or the sources that failed with
Retry. Under that, your Claude plan's session and week limits are two thin meters. Click the block for each source's age
and error, the Settings pane that fixes a sign-in, and when each limit resets. When a newer Desk is out, a block above it
says "Update to 1.1.7 · You have 1.1.6" and opens the release page. Desk asks `gh` for the latest release at launch and
every six hours; without access to the repo, it never shows.

Under the status block, your GitHub login and which accounts are signed in open Settings (⌘,).

Up Next, Tasks, Reviews and Jira are a list with a details column on the right. The arrow keys, or J and K, walk the
rows; a click selects one and the details column shows it in full, with its presses at the foot. Return, → or a
double-click opens the row's page in place of the list; the page's breadcrumb, ← or Go → Back (⌘[) returns to the list
with the row still selected. M shows the master in iTerm. Each list's key hints sit under it.

Search is a palette over the window. It finds any open PR by `repo#number`, title or branch, and any of your tickets by
key or summary, and has commands: Open master in iTerm, Sync now, Settings. ↩ opens a result here: your PR on Tasks,
one in the review queue on Reviews, a ticket on Jira. ⌘↩ opens it on GitHub or Jira. A PR on none of those screens
opens on GitHub.

A click on the menu bar item shows a popover: the master with Open, what needs you (the items Up Next counts, each
opening Desk on it), the workers at it (each shown in iTerm), the sync line and Open Desk. When GitHub's last refresh
failed, a banner says why with Retry, and the lists say how old they are. A right-click or Control-click shows the menu:
open Desk, quit, your open PRs and the reviews that need you, each opening its page. A nudge also comes as a macOS notification, unless Settings
→ General turns them off.

## Up Next

The window opens on Up Next, today's date beside its title: what waits on you, under the section that says what to
do. **Needs you** first: the questions the master has open for you, each with the task it is about and how long ago it
asked (its details column has Answer in iTerm, which shows the master's pane), then your PRs whose move is yours. Then
Ready to merge, Your move (CI failed, conflicts, changes requested, a review
thread open, needs a rebase, or a session waits on you; conflicts by GitHub's own `mergeable`, whatever its merge state
sums up), Drafts to submit (reviews you started on GitHub and have not sent), To review (the first few, then a link to
Reviews), Workers at it (the open tasks' workers at work, each shown in iTerm), Jira moves (the moves Desk
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

Open lists the tasks with their PRs under them, Merged your PRs merged in the last month; ⌃Tab and ⌃⇧Tab flip between
the two. The tasks are grouped by who they wait on: **Waits on you** (the master asks about it, a session of it asks you,
or a PR of it is yours to fix: conflicts, red CI, changes requested, a thread open), **Worker at it**, **In review**, and
**No pull request yet**. A task's row has an icon for what it started from (ticket, session or PR), its key, its title,
and a line with its PRs and what its worker is doing (Claude Code's own status line), with a chip (Working, Your move,
Draft, In review, Investigating…) and how long since it moved. Its PRs follow, a step in, joined to it by a line, each
stacked one a further step in with ↳; a task that is a PR is that PR's row, and selects and opens as any PR does. One
header names the columns, so the facts line up down the list at any depth. J and K walk tasks and PRs alike; Return or
a double-click opens a PR's page. A task has no page: the details column is its view, with the ticket's summary, its PRs
and where each stands (each opens its page), what it depends on (someone else's open PR, or a branch no open PR opens),
its worker with Show in iTerm, and the master's questions about it, and at its foot Master in iTerm and Open in Jira.

Each PR row leads with the title, and under it its branches, size and ticket. On the right each fact has a column of
its own: State (Draft or Open), Self (self-reviewed: the `local-reviewed` label), CI, Review (approved, the review
gate's count of approvals, changes requested, or waiting), Threads (open ones) and Branch (conflicts, behind its base,
or its base merged). Ready to merge is every column green. Then the session's mark (a spinner while it works, a bubble
while it asks you something) and when the PR last moved. Hover a mark for its words; Up Next's rows of your PRs show the
same columns.

Your PR's page leads with a breadcrumb back to Tasks, its title, which you can edit while it is open, and a line with
its number, branches and size; on the right a chip for where it stands, Open on GitHub, and ⋯ with Mark Ready for Review
on a draft or Convert to Draft on a ready PR, Squash and merge… on one ready to merge (it asks first and merges only the
head the page showed), Copy Branch, Copy Link, and Close Pull Request…, which asks first. The wide column has two tabs. **Conversation** holds the description, editable too, and the
conversation. **Files changed** holds the code the PR changed, a box per file that folds, with each review thread under
the line it ends on, to reply to or resolve there (an outdated one has no line left, so only Conversation lists it); it
is fetched when the tab opens and again once new commits move the head. The details column on the right: **Next step** says what the PR's stage waits on: where its self-review stands on a
draft, whose move it is in review (nothing, when the reviewer who asked for changes has been asked again), with Master
in iTerm when the move is the master's or a worker's. A conflict, red CI or a base to rebase onto shows there too, for the worker to fix when the
master hands it over. **Checks** sums up every check on the head commit in one line, "✓ 14 passed, 2 skipped"; Show all
lists them, worst first, with where a failed one stopped. **Task** names the task, its worker and what it did, with Show in iTerm; **Jira** its
ticket and status, or that it has none. **About** has the open threads by who started them, the
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

The queue groups by task: a ticket's PRs, or a stack, under one line saying who wrote it, which repos and how many
parts; lone PRs by one author in one repo share that line. The details column has the group's or PR's parts with their
size and checks, the review skill, and Start review (R) or, while its session runs, Show in iTerm. Tick any rows (X), or
a group's tick for all its parts, from any repos and authors; the bar at the foot says how many and from how many repos,
and **Review together** (R) opens a sheet that asks for notes (what
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

The review swaps the page for the diff; the session runs in a window of its own in iTerm. The group's PRs sit above the
diff, base first, to move between them, with your notes under them. While the diff shows, the sidebar folds away to give
the code the room; it comes back as it was when you leave the diff, and ⌃⌘S shows it in between. The file you are in
stays pinned at the top, and the menu at the top, "File 2 of 4 · contracts/ACL.sol", lists every file with its +/− counts
and jumps to one. A file's header folds it. One gutter holds the new line number, or a removed line's old one; hover a
line for its old number. Each review thread shows under the line it ends on, with Reply and Resolve; new line comments
and the verdicts stay the session's. If a PR gets new commits while you read, Reload fetches the diff again.

The diff and the session are linked. When the session points at a line, the diff moves there, to whichever PR of the
group the line is in: it runs Desk's `desk-show` helper, which opens one `fhenixdesk://show/…` link and nothing else, and
is allowed for it without asking. Only a link to a PR Desk knows brings the window forward. Select lines in the diff
(click, then shift-click, or move with ↑ ↓ and stretch with ⇧↑ ⇧↓) and Copy lines (⇧⌘C) puts them on the clipboard,
with the PR, path and line numbers, to paste into the session's pane. Review on
GitHub still opens the Files tab. The row says where your review stands: `draft · 7` while you have a pending review, or
the verdict you sent. Nothing of it is stored: every poll reads your pending and submitted reviews off the PR.

## Terminals: iTerm and tmux

Desk opens no terminal of its own and sends nothing to a session. The master and its workers run in iTerm2, in one
tmux session, `desk`. Its window `agents` is always two halves: the master on the left (`claude attach <id>`) and
`claude agents` on the right, Claude Code's view of every background session, to open one or start one from. A worker
or any other background session you show takes `claude agents`' place in the right half; when you detach from it, or it
ends, `claude agents` comes back. A review session, which runs where it shows rather than in the background, opens in a
window of its own. iTerm2 shows the session through
tmux's control mode (`tmux -CC attach -t desk`), so the panes are native iTerm splits and the windows iTerm's own, and
closing iTerm leaves every session running.

Desk makes the layout the first time you ask to see a session: the Master block's Open, a Show in iTerm on a page,
Answer in iTerm, Start review. Then, on every scan of the sessions, it keeps the `agents` window to its two panes: one
closed by hand comes back, and a master that restarted gets its new pane. A review's window is yours to close. Show
in iTerm focuses the pane, or the review's window, and brings iTerm forward, opening a window on
the layout when no terminal is attached, through AppleScript (macOS asks once to let Desk control iTerm). Before it
attaches, Desk turns on iTerm's "Automatically bury the tmux client session after connecting", so the window `tmux -CC`
runs in, with tmux's command menu, hides as it connects. Settings → Master → Terminal picks Terminal.app instead, with
plain `tmux attach`. View → Show
Master in iTerm (⇧⌘M) goes straight there. `FhenixDesk --terminals status|sync|show <name>` drives the same code from the
command line, and `make doctor` prints the layout.

## Jira

The Jira screen lists the running sprint or the backlog, one group per status in workflow order, yours unless the
assignee filter (the row of pictures) picks others. Done is left out. A row has the key, summary, status, priority and
how many open PRs name it, under a column header. The selected ticket opens in the details column on the right: who
opened it, its status, priority, assignee and the task it belongs to, its PRs and sessions (Show in iTerm), the move
Desk suggests with Move and Dismiss, and its description, editable; at the foot Open ticket (↩, its page) and Open in
Jira (⌘↩). A ticket's page shows its key and summary,
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

Desk reads one Jira project, picked in Settings → Jira (or Setup) from the projects Jira shows you. Every project
names its statuses its own way, so they come from Jira: Desk finds the project's statuses (one search per status, a few
seconds), and you pick each move from them: In progress, Review and Done, grouped as Jira files them. Suggested fills
the empty ones from the names and Jira's categories. A saved status the project doesn't have is flagged; an empty one
turns its move off.

## Background sessions

On your PR's page, and on a review's page, the session press says whether one of Claude Code's background sessions
(`claude agents`, the ones under `~/.claude/jobs`) is about that PR. A PR's session is the one started on it or on its
ticket, else the earliest one that links to it. **Show in iTerm** puts its pane of the `desk` layout in front, where
`claude attach <id>` runs: the only way into a background session from outside the terminal that started it, and it
works whether the session is still running or has finished. With more than one, the arrow beside it lists them all, newest first. Interactive sessions
never appear: nothing outside their own terminal can reach them.

Desk reads every background session that is about a PR or a ticket, that its prompt names as the master, a worker or a
review, or that runs in one of your tracked clones or in a repo root itself (Settings → Local clones), such as a plan
across repos started in `~/Repos`; one in an untracked clone under a root stays out. It starts none of them itself,
except the master and review sessions: the master starts the workers.

## The master and its workers

The **Master** block in the sidebar opens the Master screen: the sessions down a column, the `desk` layout as iTerm
shows it with Show on each pane, the questions the master asked you with Answer in iTerm, and the events Desk told it
today; beside them where it runs and its terminal. Open in iTerm (↩) shows the master's pane. With none running, the
block's Start starts one, named `master`, in the master folder: `~/Library/Application Support/Fhenix Desk/master`. It
runs the fhenix-workflow `coordinate-tasks` skill, in auto mode, and starts every worker in the same mode, so no worker
holds its messages for approval. Stop master runs `claude stop`; its workers run on. You talk to it in its pane; Desk
shows what it asked and sends it nothing but the files below.

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
events, the **fhenix-workflow** check (installed for your user, with Install when it isn't), and under Development the
**Plugin folder**: a folder of plugins the master, its workers and review sessions load in place of the installed ones
(`--plugin-dir`), only for trying plugin changes before they're merged into the marketplace. Left empty, as it should be
day to day, Desk's sessions use the plugins installed for your user.

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
