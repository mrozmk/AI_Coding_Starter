# 08 — Operator kit

The supervision roles need a few files **outside** the repository: the escalation adapter, the
platform notifier, the role Stop hook and an optional health check. They live under `kit_dir`
(the `kit_dir` field of the gitignored `.agents/team/channel.local.json`, default
`<box dir>/kit`), so one install serves every clone of the project and no clone can edit them.

The templates and their installer ship in the project at `.claude/team/sessions/operator-kit/`.
Installing them is an **Operator action**: you run it yourself with `!`, an agent never does, and
the project's settings put `install.sh` on `ask`.

```bash
bash .claude/team/sessions/operator-kit/install.sh --dry-run    # what would change
bash .claude/team/sessions/operator-kit/install.sh --apply      # back up, copy/render, render escalation.local.json
bash .claude/team/sessions/operator-kit/install.sh --verify     # live files == templates
bash .claude/team/sessions/operator-kit/install.sh --rollback   # restore the backups
```

- Run it after the channel step of `/setup:teams` ([09 → Fresh machine](09-setup.md#fresh-machine-no-agent-mailprojectsjson)):
  the installer reads `kit_dir`, the box and the notifier from the channel config.
- `--apply` is what makes escalation work: it writes `.agents/team/escalation.local.json`, which
  the channel step skips while no adapter exists. The dry-run still says `skip` for that file.
- **Lifetimes.** A template change reaches the live copy only on your next `--apply`;
  `--verify` reports the drift until then.
- **Declared losses.** With `notifier: none`, alarms about the Supervisor itself and a dead tmux
  server reach nobody. Without a scheduled `sessions-health.sh`, a dead tmux server is noticed by
  nobody. Both are allowed; the role preflight prints them. `--print-scheduler launchd|cron`
  prints an entry for you to install.

The file table, backups and what the installer never touches:
[`operator-kit/README.md`](../../.claude/team/sessions/operator-kit/README.md).
