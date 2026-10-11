# Fhenix Desk

Menu bar app that tracks the Fhenix development cycle and carries your own work from a ticket to its merge.
Everything it writes is either a press of yours — putting a Claude review into your draft review on a PR,
starting a background session, and the flow's Approve, Apply and Merge — or one of the few moves it makes on
its own: moving a Jira ticket that has fallen behind its PRs, and sending a flow's session the fix for a
conflict, red CI, or a teammate's review.

Sources: GitHub PRs (`gh`), local git worktrees, Claude Code sessions (`~/.claude`), Jira. Its own state is
`config.json` and `flows.json` under `~/Library/Application Support/Fhenix Desk`.

```sh
make doctor   # print all data as text
make run      # run from the build tree
make install  # build .app, copy to ~/Applications, open
swift run FhenixDesk --review <pr-url>   # review one PR headlessly into your draft review on it
```

Jira goes through the Atlassian CLI: run `acli jira auth login --web` once, then Settings (⌘,) → Jira →
Recheck. Desk stores no Jira token.

The window opens on Today: every nudge (CI failed, changes requested, needs rebase, ready to merge, review
waiting, Claude reviewed, quiet PRs) and every ticket the app could not move to where its PRs say, each
with the button that deals with it. Pull Requests and Jira show a details panel on the right for the selected row, and Settings (⌘,) open inside the same window. Search (⌘K) finds any open PR by `repo#number`, title or branch, and any screen by name: ↩ opens it on its screen here, ⌘↩ on GitHub.

Claude reviews: the Reviews tab lists the PRs waiting on you and marks which are ready to run — ones you
have not reviewed, ones re-requested since your last review, and a run that failed. Nothing starts on its own; you press
Review on the ones you want. Each press checks the PR head out into a detached worktree under
`~/Repos/.reviews/<repo>/pr-<n>` and runs `claude -p` there once, with read-only tools and no session to
attach to. Every other clone under the repo roots is fetched first and offered at its remote default
branch (`git -C <root> show origin/main:<file>`), so the review reads current code there, not whatever
branch happens to be checked out.

When the run finishes, its comments go into your **pending review** on the PR — a draft only you can see,
which notifies nobody. Each comment starts with its severity (`**Blocker**`, `**Nit**`, …); one whose line
has left the diff, in a file the PR changes, becomes a comment on that file naming the line. Then you
finish the review on GitHub, in the PR's Files tab: edit or delete comments, write the body, pick the
verdict, submit. The row says where your review stands — `draft · 7`, or the verdict you sent — and Open
on GitHub goes straight there. Claude itself cannot reach GitHub; the app never submits, approves or
requests changes.

None of that is stored. The app keeps no review records: every poll reads your pending review and your
submitted reviews off the PR, and each comment it posts ends with an invisible `<!-- fhenix-desk -->`
marker, which is how a draft's comments are told apart as Claude's or yours. A run in progress, or one
that failed, lives in memory until the app quits. Review worktrees sit at a fixed path, so the path
alone says which PR one belongs to.

GitHub allows one pending review per person per PR, so a draft you already started by hand is added to,
never replaced. Review again adds only comments on lines the draft does not already cover. New commits
start nothing: GitHub marks the draft's comments on changed lines outdated by itself. Drafts and bot PRs
stay out of the queue altogether, and the app removes a review worktree once its PR is merged or closed —
the draft, if you left one, stays on GitHub.

Runs are capped at two at once so a review cannot starve the git and GitHub polls, and each run has its
own dollar cap, which `claude` enforces.

## Ticket sync

Desk reads the Jira key out of each PR's branch and title — never its description, which is prose about
other tickets — and says where the ticket should be: `👀 Review Ready` while a PR of its is open and
marked ready, `Done` once they have all merged and one of them landed on the repo's default branch. A
ticket that has fallen behind is moved there on its own (`acli jira workitem transition`) once every
source has answered, and the board shows a chip naming the status while the move is in flight. Each
ticket and status is tried once per launch: a move Jira refuses turns the chip red with the reason and
lists the ticket on Today, and a ticket you move back by hand stays where you put it. The Pull Requests
table shows the same disagreement as an orange arrow beside the ticket key.

It never moves a ticket backwards and never touches one assigned to somebody else. A PR merged into the
branch below it in a stack finishes nothing, and an open draft keeps the ticket out of both statuses. Set the two
status names in Settings → Jira, exactly as Jira spells them; empty turns that half off.

## Background sessions

The Agent column on the Pull Requests screen, and the same button on the Reviews queue, say whether one of
Claude Code's background sessions (`claude agents`, the ones under `~/.claude/jobs`) is about that PR. A
filled terminal means yes, and pressing it runs `claude attach <id>` in Terminal — the only way into a
background session from outside the terminal that started it, and it works whether the session is still
running or has finished. Interactive sessions never appear: nothing outside their own terminal can reach
them.

A hollow terminal means no session mentions the PR, and pressing it starts one with its branch checked
out — in the worktree you already have on that branch, or in a new one under the repo's
`.claude/worktrees`, where `claude -w` puts its own. The session itself starts in the repo's folder, so it
gets that repo's plugins, settings and memory, and its prompt sends it into the branch's worktree. The
session is seeded with the PR's url, which is what ties it to the PR until it has read the PR itself.

## Flow

Start on a ticket opens a background session in the repo you pick. It writes a plan and waits; once you approve
the plan in the session, it builds in a worktree of its own and opens the PR as a draft. From then on the PR has
a stage of the app's own — not Jira's, not GitHub's — kept in `flows.json`, shown in the Stage column and in the
PR details panel, and the same session carries it all the way:

| Stage | Moves on when |
|---|---|
| Working | the session opens its PR |
| Draft | you press Approve |
| Self-review | the session's `/goal` finishes: `fhenix-workflow:reviewing-code`, fix what it finds, until no High or Medium is left or three rounds have run |
| Fixes to check | you press Approve, after its findings and View changes (GitHub's diff of exactly the loop's commits); the PR goes ready and the review team is asked |
| In review | a teammate reviews: the session proposes fixes and changes nothing. An approval with nothing left open goes to Approved |
| Fixes proposed | you press Apply or Skip on each comment, with a Resolve toggle on each thread |
| Applying | the session pushes the fixes you approved and resolves only the threads marked so; still not approved, the team is asked again |
| Approved | you press Merge, always a squash |

A conflict with the base (rebased while a draft, merged in after) and red CI are fixed without asking, once per
PR head; a push that dismisses an approval sends the PR back to the review team. The review team is a setting (GitHub → Flow, `protocol-team` by default). Settings → Repos, the PR
details panel and the ticket's repo menu say whether a repo's sessions can run `reviewing-code` at all — it
ships in `fhenix-workflow` 0.5.0 — and Approve on a draft stays off where they cannot.

The app talks to the session the only way a background session takes outside input: once it has finished its
turn, it is stopped and resumed under the same id with the next instruction, so the conversation carries on.
It never stops a session that is working — your press waits for it — and never sends anything to one that is
asking you something; an automatic fix also waits until the session has been idle for 10 minutes, so it does
not cut in right after you talked to it. Pause on a PR holds everything while you drive the session yourself.
Each instruction ends with the session writing a small result file in its own scratch folder, which is how the
app knows it has finished. A PR you did not start from a ticket joins the flow at its current stage with Start,
or Use for flow on a session that already works on it.

## Prompts

Every text the app sends Claude is editable in Settings → Prompts, one text each: starting a ticket, the PR
session, the flow's self-review, proposed fixes, applying them, a conflict and red CI, the review, the review's
system prompt and its reformat pass. `{name}` placeholders are filled
when the prompt is sent, and `{#name}…{/name}` wraps what only applies sometimes — a ticket description,
unresolved threads, a conflict, other repos — with `{else}` for the other case. Only edits are stored, in
`config.json`, so an untouched prompt follows the app's own text; Reset to default removes an edit.
