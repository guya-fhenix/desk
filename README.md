# Fhenix Desk

Menu bar app that tracks the Fhenix development cycle. It reads, you do not type — the exceptions are
submitting a review, starting a background session, and moving a Jira ticket, and all three only ever
happen when you press the button.

Sources: GitHub PRs (`gh`), local git worktrees, Claude Code sessions (`~/.claude`), Jira.

```sh
make doctor   # print all data as text
make run      # run from the build tree
make install  # build .app, copy to ~/Applications, open
swift run FhenixDesk --review <pr-url>   # review one PR headlessly and print every comment
```

Jira needs an API token: Desk window → Settings → paste token. Create one at
https://id.atlassian.com/manage-profile/security/api-tokens.

Claude reviews: the Reviews tab lists the PRs waiting on you and marks which are ready to run — never
reviewed, re-requested since the last run, or a run that failed. Nothing starts on its own; you press
Review on the ones you want. Each press checks the PR head out into a detached worktree under
`~/Repos/.reviews/<repo>/pr-<n>` and runs `claude -p` there once, with read-only tools and no session to
attach to. Every other clone under the repo roots is fetched first and offered at its remote default
branch (`git -C <root> show origin/main:<file>`), so the review reads current code there, not whatever
branch happens to be checked out.

The tab then shows the diff with Claude's comments pinned to the lines they are about. Approve, reject or
rewrite each one, pick a verdict, and Submit posts a single GitHub review carrying exactly the comments
you approved — comments whose line has left the diff go in the review body rather than being dropped.
That press is the only thing in this app that writes to GitHub; Claude itself cannot reach it.

The one thing that does happen on its own costs nothing: when a PR gets new commits, the existing
comments are re-pointed at the new head, keeping the ones whose line only moved and marking the rest
outdated, and the row says "new commits". Re-running keeps every decision you have already made and adds
what is new. Drafts and bot PRs stay out of the queue altogether, and the app removes a review and its
worktree once the PR is merged.

Runs are capped at two at once so a review cannot starve the git and GitHub polls, each run has its own
dollar cap, and the tab shows what reviews have cost in the last 24 hours.

## Ticket sync

Desk reads the Jira key out of each PR's branch and title — never its description, which is prose about
other tickets — and says where the ticket should be: `👀 Review Ready` while a PR of its is open and
marked ready, `Done` once they have all merged and one of them landed on the repo's default branch. A
ticket that has fallen behind gets a chip on the Tickets screen naming the status it should move to, and
pressing that chip is the one thing here that writes to Jira (`acli jira workitem transition`). The Pull
Requests table shows the same disagreement as an orange arrow beside the ticket key.

It never moves a ticket backwards, never touches one assigned to somebody else, and never fires on a
poll — so a wrong key match costs an ignored chip, not a wrong transition. A PR merged into the branch
below it in a stack finishes nothing, and an open draft keeps the ticket out of both statuses. Set the two
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
`.claude/worktrees`, where `claude -w` puts its own. The session is seeded with the PR's url, which is
what ties it to the PR until it has read the PR itself.
