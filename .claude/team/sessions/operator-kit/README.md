# Operator kit — the supervision roles' files outside the repo

These are templates for the files that live **outside** the checkout, under `<kit_dir>` (the `kit_dir` field of the gitignored `.agents/team/channel.local.json`, default `<box dir>/kit`), plus their installer. Everything here is an **Operator action only**: run it yourself with `! bash …`. An agent never installs, edits or rolls back these files, and a project's settings put `install.sh` on `ask`.

| Template | Live path | What it is |
|---|---|---|
| `escalate.sh` | `<kit_dir>/escalate.sh` | the escalation adapter that `escalation.local.json` points at: `send`, `wait`, `peek`, `opinion` (contract: `.agents/reference/team-questions.md`) |
| `notify.sh` | `<kit_dir>/notify.sh` | the one platform notifier: `osascript`, `notify-send` or `none` (`teams.channel.notifier`) |
| `sessions-health.sh` | `<kit_dir>/sessions-health.sh` | optional: one notification per outage of a role session or a team-watch loop, run by a scheduler; never restarts anything |
| `hooks/mail-guard.sh` | `<kit_dir>/hooks/mail-guard.sh` | the role Stop hook: no turn ends with unread `turn` mail or unacked team-watch batches |
| `hooks/role-hooks.settings.json.tmpl` | `<kit_dir>/hooks/role-hooks.settings.json` | rendered: the `Notification` (notifier) and `Stop` (mail guard) hooks the role sessions take |
| `kit.conf.tmpl` | `<kit_dir>/kit.conf` | rendered: names the out-of-repo health check needs (it cannot read the checkout) |

```bash
! bash .claude/team/sessions/operator-kit/install.sh --dry-run                # what would change
! bash .claude/team/sessions/operator-kit/install.sh --apply                  # backups, copy/render, render escalation.local.json
! bash .claude/team/sessions/operator-kit/install.sh --verify                 # live == templates (the role preflight runs this once P5 adds it)
! bash .claude/team/sessions/operator-kit/install.sh --rollback               # restore, delete backups, drop the generated escalation config
! bash .claude/team/sessions/operator-kit/install.sh --print-scheduler launchd   # or: cron — install the printed entry yourself
```

- **Lifetimes.** A change to a template takes effect only after your `--apply`, and `--verify` shows the drift until then. `escalate.sh` and `mail-guard.sh` read the channel through the checkout's `team-channel.sh` and `team-mail.sh` at run time, so a change to those libraries is live at once, while the kit's own logic waits for `--apply`.
- **Backups.** `--apply` keeps the first install's original (`*.bak-team-kit`, or a `.absent` marker). `--rollback` restores it and deletes the backup.
- **Never touched:** `mail.sqlite*`, `recipients.json`, delivery logs, `*.lock` files, the decisions notes, any launchd job or crontab line.
- **Two declared losses.** With `notifier: none`, alarms about the Supervisor itself and a dead tmux server reach nobody. Without a scheduled `sessions-health.sh`, a dead tmux server is noticed by nobody. Both are allowed, but they are losses; the role preflight prints them once the role-session layer (P5) adds it, until then `install.sh --verify` and `notify.sh --check` are the checks.
- **Two projects on one machine:** set `teams.channel.mail_suffix`. The health check recognises a running Supervisor by its `--name`, which carries that suffix.
