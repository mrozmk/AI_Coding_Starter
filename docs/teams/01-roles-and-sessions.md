# 01 — Roles and sessions

> **Stub.** This page waits for the role-session layer (launcher, profiles, `/session-role`). Its
> names are not frozen yet, so it holds no prose. It is written when that layer merges.

TODO:

- the session table (Supervisor, TeamLead, Advisor, Reviewer, Operator): receives / decides / never
- identity: `TEAM_SESSION_ROLE`, tmux names from `teams.channel.tmux_prefix`, `--name` with the
  mail suffix
- launcher subcommands (`start`, `stop`, `status`, `up`, `here`, `answer`, `freeze`, `rollback`,
  `preflight`)
- the `/session-role` bootstrap steps
- models and effort as `teams.sessions` config (defaults, what `/setup:teams` prints)
- link the role-contract reference once it exists

Until then: [README](README.md) · [Decision model](02-decision-model.md) for who decides what.
