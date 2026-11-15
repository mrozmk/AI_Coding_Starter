# harness-notify — the Herdr channel of the harness's Operator notifications

The harness tells the Operator about four events only: a TeamLead decision, an abandon question, a
failure the Supervisor could not repair, and a release step waiting for them. `.claude/lib/notify.sh`
is the only sender. With `herdr.enabled: true` in `~/.agent-comms/notify.json`, it writes one entry
per event into `~/.agent-comms/outbox/herdr/new/`, but only when the answering session runs in Herdr.

## What this mod does

- It watches `~/.agent-comms/outbox/herdr/new/`, with `watchFolder` and a 30-second timer as a
  fallback. The timer also restarts the watch when it stopped (the folder was missing).
- For each entry younger than 24 hours it posts **one** toast with Herdr's `notify()`. Clicking the
  toast runs `agent.focus` on the answering session's terminal.
- The strip at the bottom keeps the toasts not yet clicked (`● 2 waiting — …`). A click runs the
  same jump and drops the item. Items older than 24 hours fall off.
- It moves each entry to `~/.agent-comms/outbox/herdr/done/` with `mv`, so an entry is shown once.
  Entries older than 24 hours, and entries it cannot read, are moved without a toast.
- Every 60 seconds it touches `~/.agent-comms/outbox/herdr/.mod-alive`, so `notify.sh --check` can
  say whether a mod is watching.

## What it does not do

- It does not replace the `toast` mod, so Herdr's own alerts look and behave as before.
- It changes no Herdr setting, layout or other mod, and it turns on no sound.
- It reads and moves files only under `~/.agent-comms/outbox/herdr/`. File names are checked before
  any `mv`, and nothing from an entry's text reaches a path or a command.
- It runs no other program and makes no network call.

Mods are trusted code in Herdr, and this one runs `mv` and `touch` through `exec`.

## Limits

- A mod runs only while its strip is in the shown layout. If you switch to a layout without it,
  entries wait in `new/` until a layout with the strip is shown again, or until they go stale.
  `notify.sh --check` then says `mod not seen`.
- The toast's lifetime is Herdr's. The strip is what keeps an item visible until you click it.

## Install, update, remove

```sh
bash .claude/team/herdr-mod/install.sh --dry-run   # what it would do
bash .claude/team/herdr-mod/install.sh             # install or update
herdr-app check ~/.config/herdr-app/mods/harness-notify
bash .claude/team/herdr-mod/install.sh --rollback  # remove (only the folder it installed)
```

The installer writes only `~/.config/herdr-app/mods/harness-notify/` (`$HERDR_APP_HOME` picks
another app home). It never overwrites a folder of that name that it did not install. Outside the
app home it creates only the spool, `~/.agent-comms/outbox/herdr/new/` and `done/` (mode 700), so
the strip's heartbeat works before the first event; `--rollback` leaves the spool.
