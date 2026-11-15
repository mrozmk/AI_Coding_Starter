# notify-kit — the iMessage channel's flush job

The harness notifies the Operator about four events only (a human decision, an abandon decision,
an unrepaired failure, a release step that waits for the Operator). There is one sender,
`.claude/lib/notify.sh`, and two opt-in channels. This kit is the iMessage channel's one moving
part outside the repo: a per-user launchd job that runs `notify.sh flush` when quiet hours end.

## How the channel works

- **Off by default.** It is switched on per machine in `~/.agent-comms/notify.json` (mode 0600; you
  write it, the harness never does):

  ```json
  {
    "version": 1,
    "imessage": {
      "enabled": true,
      "recipient": "<your iMessage address>",
      "quiet": { "start": "22:00", "end": "07:00", "tz": "Europe/Warsaw" }
    }
  }
  ```

- **Any backend.** It works for tmux and Herdr sessions alike. macOS only: it needs `osascript` and
  Messages signed in to iMessage.
- **One send per event.** `notify.sh` runs a fixed AppleScript and passes the recipient and the text
  only as arguments, with a 30 s timeout. The outcome is one of:
  - `submitted`;
  - `failed`, when nothing left the machine (no Automation permission, no iMessage account,
    Messages not running). It is retried at the next `notify.sh` call, up to 3 attempts;
  - `outcome_unknown`, for anything else, including the timeout. It is never retried, because a
    retry could send twice.
- **Quiet hours.** An event during quiet hours is held. The first flush after `quiet.end` (the end is
  exclusive) sends every held event as **one** message: `[harness] <n> held overnight`, then one
  line per event, oldest first, cut to at most 1,000 characters.
- **The message** is `[<project>] <label>: <team> <ticket> <d-n> — <summary> — answer: <hint>`. It
  holds the summary (one line, at most 200 characters) and where to answer, nothing else from the
  run.
- **Egress.** That line leaves the machine through Apple's iMessage. That is the reason it is opt-in.
- **The recipient is never printed.** `notify.sh --check` says `recipient set`.

## Install, update, remove

Run it yourself, from the **main checkout** (not a team clone), after writing the switch file:

```sh
bash .claude/team/notify-kit/install.sh --dry-run   # the plist and the launchctl commands
bash .claude/team/notify-kit/install.sh             # install or update, and load the job
bash .claude/lib/notify.sh --check                  # imessage on … flush job: installed
bash .claude/team/notify-kit/install.sh --rollback  # unload and remove (only the harness's plist)
```

- **What it writes.** `~/Library/LaunchAgents/harness.notify-flush.plist`, with a
  `StartCalendarInterval` at `quiet.end`. The job runs this checkout's `notify.sh flush` and logs to
  `~/.agent-comms/outbox/flush.log`.
- **What it reads.** Only `imessage.quiet.end` and `.tz` from the switch file, never the recipient.
- **What it refuses.** A plist of that name that it did not install is left as it is (exit 3).
- **One job for every project.** The outbox is per user, so one job serves every project on the
  machine. An install from another checkout replaces the path and says which one it replaced.
- **launchd uses the system time zone.** When `quiet.tz` differs from it, the installer and
  `--check` warn, and the job fires at the `quiet.end` clock in system time.
- **Re-run the installer** after you change `quiet.end` or move the checkout. `--check` then says
  `stale time` or `stale path`.
- **Without the job,** held events go out with the next event's call.

## Manual check (the owner, once)

1. Send one real event outside quiet hours. It arrives on the phone.
2. Send one during quiet hours. It is `held` in `notify.sh list`, and it arrives at `quiet.end`
   through the launchd job.
