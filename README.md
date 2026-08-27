# Fhenix Desk

Menu bar app that tracks the Fhenix development cycle. It reads, you do not type.

Sources: GitHub PRs (`gh`), local git worktrees, Claude Code sessions (`~/.claude`), Jira.

```sh
make doctor   # print all data as text
make run      # run from the build tree
make install  # build .app, copy to ~/Applications, open
```

Jira needs an API token: Desk window → Settings → paste token. Create one at
https://id.atlassian.com/manage-profile/security/api-tokens.
