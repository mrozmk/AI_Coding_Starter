# Operator kit — the supervision roles' files outside the repo

These are templates for the files that live **outside** the checkout, under `<kit_dir>` (the `kit_dir` field of the gitignored `.agents/team/channel.local.json`, default `<box dir>/kit`), plus their installer. Everything here is an **Operator action only**: run it yourself with `! bash …`. An agent never installs, edits or rolls back these files, and a project's settings put `install.sh` on `ask`.

| Template | Live path | What it is |
|---|---|---|
| `sessions-health.sh` | `<kit_dir>/sessions-health.sh` | optional: records which role sessions are down (a state file and one log line per outage), run by a scheduler; notifies nobody and never restarts anything |
| `hooks/mail-guard.sh` | `<kit_dir>/hooks/mail-guard.sh` | the role Stop hook: no turn ends with unread `turn` mail |
| `hooks/role-hooks.settings.json.tmpl` | `<kit_dir>/hooks/role-hooks.settings.json` | rendered: the `Stop` hook (mail guard) the role sessions take |
| `kit.conf.tmpl` | `<kit_dir>/kit.conf` | rendered: names the out-of-repo health check needs (it cannot read the checkout) |

```bash
! bash .claude/team/sessions/operator-kit/install.sh --dry-run                # what would change
! bash .claude/team/sessions/operator-kit/install.sh --apply                  # backups, copy/render
! bash .claude/team/sessions/operator-kit/install.sh --verify                 # live == templates (the role preflight runs this once P5 adds it)
! bash .claude/team/sessions/operator-kit/install.sh --rollback               # restore, delete backups
! bash .claude/team/sessions/operator-kit/install.sh --print-scheduler launchd   # or: cron — install the printed entry yourself
```

- **Lifetimes.** A change to a template takes effect only after your `--apply`, and `--verify` shows the drift until then. `mail-guard.sh` reads the channel through the checkout's `team-channel.sh` and `team-mail.sh` at run time, so a change to those libraries is live at once, while the kit's own logic waits for `--apply`.
- **Backups.** `--apply` keeps the first install's original (`*.bak-team-kit`, or a `.absent` marker). `--rollback` restores it and deletes the backup.
- **Never touched:** `mail.sqlite*`, `recipients.json`, delivery logs, `*.lock` files, the decisions notes, any launchd job or crontab line.
- **No notifications here.** The kit sends nothing to the Operator. The four Operator events go through `.claude/lib/notify.sh` and its opt-in channels (`~/.agent-comms/notify.json`; see `.claude/team/notify-kit/README.md`). Without a scheduled `sessions-health.sh`, a dead tmux server is recorded by nobody; `bash .claude/lib/supervisor-sessions.sh preflight` prints that (the `health check:` row), and its `operator kit installed` row runs `install.sh --verify`.
- **Upgrading a kit installed before the notification model.** `--verify` reports the old `hooks/role-hooks.settings.json` as `differs` (it still wires the removed `Notification` hook) until you re-run `--apply`. The old `<kit_dir>/notify.sh` and its `notify.sh.bak-team-kit` are no longer installed or restored; nothing calls them, so delete them by hand.
- **Two projects on one machine:** set `teams.channel.mail_suffix`. The health check recognises a running Supervisor by its `--name`, which carries that suffix.
