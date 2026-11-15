# 08 — Operator kit

The supervision roles need a few files **outside** the repository: the escalation adapter, the
role Stop hook and an optional health check. They live under `kit_dir`
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
  the installer reads `kit_dir` and the box from the channel config.
- `--apply` is what makes escalation work: it writes `.agents/team/escalation.local.json`, which
  the channel step skips while no adapter exists.
- **Lifetimes.** A template change reaches the live copy only on your next `--apply`;
  `--verify` reports the drift until then, and the preflight's `operator kit installed` row FAILs.
  This drift is intended: the live kit changes only by your hand.
- **No notifications.** The kit sends nothing to the Operator; the four Operator events go through
  `.claude/lib/notify.sh` ([02](02-decision-model.md), `.claude/team/notify-kit/README.md`).
  `sessions-health.sh` only records outages (a state file and its log). Without it scheduled, a
  dead tmux server is recorded by nobody; the role preflight prints that. `--print-scheduler launchd|cron`
  prints an entry for you to install. A scheduler starts it with a minimal `PATH`:
  `sessions-health.sh` appends only the Homebrew directories (`/opt/homebrew/bin`,
  `/usr/local/bin`), so when `tmux` or `jq` live anywhere else, set `PATH` in the entry itself
  (launchd `EnvironmentVariables`, or a `PATH=` line in the crontab).

Recorded deviations from the brief: the kit installs five files, not four (`kit.conf` was
added, and the hook settings file is `role-hooks.settings.json`; the platform `notify.sh` it once
installed is gone), and the
per-role mail command `/mail-role` is a repository command, not a kit file.

The file table, backups and what the installer never touches:
[`operator-kit/README.md`](../../.claude/team/sessions/operator-kit/README.md).
