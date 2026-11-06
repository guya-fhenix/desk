# Fhenix Desk

Menu bar app that tracks the Fhenix development cycle and carries your own work from a ticket to its merge.
Everything it writes is either a press of yours — starting a background session, and the flow's Approve, Fix it and
Merge — or the one move it makes on its own: moving a Jira ticket that has fallen behind its PRs.

Sources: GitHub PRs (`gh`), local git worktrees, Claude Code sessions (`~/.claude`), Jira. What it shows is read
off them on every refresh; under `~/Library/Application Support/Fhenix Desk` it keeps only your settings
(`config.json`) and which nudges it has already notified (`notified.json`).

```sh
make doctor   # print all data as text
make run      # run from the build tree
make install  # build .app, copy to ~/Applications, open
```

Jira goes through the Atlassian CLI: run `acli jira auth login --web` once, then Settings (⌘,) → Jira →
Recheck. Desk stores no Jira token.

The window opens on Up Next: every nudge (CI failed, changes requested, needs rebase, ready to merge, review
waiting, quiet PRs) and every ticket the app could not move to where its PRs say, each
with the button that deals with it. Pull Requests and Jira show a details panel on the right for the selected row, and Settings (⌘,) open inside the same window. Search (⌘K) finds any open PR by `repo#number`, title or branch, and any screen by name: ↩ opens it on its screen here, ⌘↩ on GitHub.

Reviews: the Reviews tab lists the PRs waiting on your review — ones you have not reviewed, and ones re-requested
since your last review. By default it keeps to the ones that still **need an approval**, read off the
`review-gate/approvals` status on each PR's head commit: fewer approvals on the latest commit than the risk tier needs,
CodeRabbit not done reviewing it yet, or a repo that posts no such status at all. "low risk: no approval needed" and
a met count drop out; All, one click away, shows them, and Up Next, the sidebar badge and the menu bar follow the same
choice. The tier shows as a Risk chip on each row, and PRs CodeRabbit labels `needs-human` come first. Drafts and bot
PRs stay out of the queue altogether.

Desk does not review for you. By the time a PR is ready, /pre-pr and CodeRabbit have run the review checklist on it;
what is left is the person's part — does it do what the ticket asks, is the approach right, is the risk tier right and
would How to revert work, does Testing prove it, and do you agree with each thread under "Resolved by the author" in
the /pre-pr evidence. A PR's page shows its description, checks and risk; Review on GitHub opens its Files tab, where
you read the evidence and CodeRabbit's walkthrough, the diff, and submit. The row says where your review stands —
`draft · 7` while you have a pending review, or the verdict you sent. Nothing of it is stored: every poll reads your
pending and submitted reviews off the PR.

## Ticket sync

Desk reads the Jira key out of each PR's branch and title — never its description, which is prose about
other tickets — and says where the ticket should be: `👀 Review Ready` while a PR of its is open and
marked ready, `Done` once they have all merged and one of them landed on the repo's default branch. A
ticket that has fallen behind is moved there on its own (`acli jira workitem transition`) once every
source has answered, and the board shows a chip naming the status while the move is in flight. Each
ticket and status is tried once per launch: a move Jira refuses turns the chip red with the reason and
lists the ticket on Up Next, and a ticket you move back by hand stays where you put it. The Pull Requests
table shows the same disagreement as an orange arrow beside the ticket key.

It never moves a ticket backwards and never touches one assigned to somebody else. A PR merged into the
branch below it in a stack finishes nothing, and an open draft keeps the ticket out of both statuses. Set the two
status names in Settings → Jira, exactly as Jira spells them; empty turns that half off.

## Background sessions

The Agent column on the Pull Requests screen, and the same button on a review's page, say whether one of
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
the plan in the session, it builds in a worktree of its own and opens the PR as a draft. A PR of yours is in the
flow while a background session works on it — the newest that mentions it, whether it came from a ticket or from
Start on the PR — and it has a stage of the app's own, shown in the Stage column and on the PR's page. Nothing of
it is saved: every refresh works it out again from GitHub and the session, so a relaunch shows the same stage.

| Stage | When |
|---|---|
| Working | the ticket's session has not opened its PR yet |
| Draft | a draft without /pre-pr's evidence comment; Approve sends the session the self-review: one `/fhenix-workflow:pre-pr` run where the repo has adopted the review flow, one `reviewing-code` pass elsewhere, posted as threads; it changes no code, and its findings come back as threads on the PR, each with a suggested fix |
| Self-reviewed | a draft with the author's evidence comment (it starts `<!-- pre-pr:start -->`); Approve, once the session is done, marks it ready and asks the review team. Without /pre-pr's `local-reviewed` label an Important finding is still open: the page says so, and Approve asks before it marks the PR ready |
| In review | ready, until it has the approvals it needs and nothing open |
| Ready to merge | approved with nothing open; Merge squashes it |
| Merged, Closed | as GitHub says |

Beside the stage, at any stage: what the session is doing (working, asking you something, or done — the self-review
shows as working), and the PR's open threads, counted on its page. A PR that
conflicts with its base branch, or whose CI failed, shows Fix it on its page: it sends the session the matching
prompt (Settings → Prompts), which fixes and pushes. Nothing is sent on its own.

Approved means the `review-gate/approvals` status on the head commit says so — "no approval needed", or as many
approvals on the latest commit as the tier needs — and, in a repo that posts no such status, GitHub's review
decision. The review team is a setting (GitHub → Flow, `protocol-team` by default). Settings → Repos, the PR
page and the ticket's repo menu say whether a repo's sessions can run `reviewing-code` at all — it ships in
`fhenix-workflow` 0.5.0 — and Approve on a draft stays off where they cannot.

Your PR's page shows its description; beside it, an Open threads card counts the open threads by who started them —
/pre-pr (the `<!-- pre-pr:finding -->` marker on the first comment), CodeRabbit (its login), and each person by name —
with a link to read them on GitHub. They are answered there, or by telling the PR's session what to do with them; the
app never writes to a thread.

The app talks to the session the only way a background session takes outside input: once it has finished its
turn, it is stopped and resumed under the same id with the instruction, so the conversation carries on. It never
sends anything to a session that is working or asking you something — Approve and Fix it wait for it to be idle —
and it sends nothing on its own: a conflict or red CI is yours to hand to the session. Each instruction ends with
the session writing a small result file in its own scratch folder. A PR you did not start from a ticket joins the
flow at its current stage once you Start a session on it.

## Prompts

Every text the app sends Claude is editable in Settings → Prompts, one text each: starting a ticket, the PR
session, and the flow's self-review and its Fix it prompts. `{name}` placeholders are filled when the prompt is
sent, and `{#name}…{/name}` wraps what only applies sometimes — a ticket description, unresolved threads, a
conflict — with `{else}` for the other case. Only edits are stored, in
`config.json`, so an untouched prompt follows the app's own text; Reset to default removes an edit.
