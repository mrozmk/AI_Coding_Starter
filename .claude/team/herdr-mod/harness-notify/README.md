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
- The strip at the bottom keeps the toasts not yet clicked (a dot, then `2 waiting — …`). A click runs the
  same jump and drops the item. **clear**, at the strip's right end, drops every item: use it when
  you answered elsewhere (in the stage's window, by iMessage), since nothing tells the strip that.
  Items older than 24 hours fall off by themselves, also across a Herdr restart.
- Herdr keeps that list for the mod in `~/.config/herdr-app/data/harness-notify/store.json`
  (the mod's `localStorage`), outside the mod folder.
- It moves each entry to `~/.agent-comms/outbox/herdr/done/` with `mv`, so an entry is shown once.
  Entries older than 24 hours, and entries it cannot read, are moved without a toast.
- Every 60 seconds it touches `~/.agent-comms/outbox/herdr/.mod-alive`, so `notify.sh --check` can
  say whether a mod is watching.

## What it does not do

- It does not replace the `toast` mod, so Herdr's own alerts look and behave as before.
- It changes no Herdr setting or other mod, and it turns on no sound. A layout changes only when
  you dock the strip with `--dock <layout>` (below).
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
bash .claude/team/herdr-mod/install.sh --dry-run --dock my-layout   # what it would do
bash .claude/team/herdr-mod/install.sh --dock my-layout             # install or update, dock the strip
herdr-app check ~/.config/herdr-app/mods/harness-notify
bash .claude/team/herdr-mod/install.sh --undock my-layout           # take the strip out of that layout
bash .claude/team/herdr-mod/install.sh --rollback                   # undock everywhere it docked, remove the mod
```

The installer writes only `~/.config/herdr-app/mods/harness-notify/` (`$HERDR_APP_HOME` picks
another app home). It never overwrites a folder of that name that it did not install. Outside the
app home it creates only the spool, `~/.agent-comms/outbox/herdr/new/` and `done/` (mode 700), so
the strip's heartbeat works before the first event.

**What `--rollback` leaves:** the spool (`~/.agent-comms/outbox/herdr/`, which `notify.sh` owns
and prunes) and every layout it did not dock. It removes the strip's list,
`data/harness-notify/store.json`, so a reinstall starts with no item from before; another file in
that folder stays, and it says so. It does this even when the mod folder is already gone.

**Where the strip goes: only where you dock it.** `mod.json` says `"place": "none"`, so Herdr
docks the strip nowhere by itself, and without `--dock` no layout file changes. Name the layout
explicitly: `--dock <layout>` edits only `~/.config/herdr-app/layouts/<layout>.json`.
- It refuses a missing or unparsable file, a JSON that is no layout, and Herdr's own layouts
  (`main`, `terminals`, `win98`: Herdr restores them on its next start). Clone one first:
  `herdr-app do layout.clone '{"name":"main","as":"my-layout"}'`.
- It validates the file, backs it up as `<layout>.json.harness-bak-<UTC>`, writes the new one
  atomically and validates it again. A second `--dock` changes nothing.
- A root `column` gets the strip (`id: harness-notify-strip`, 26 px) as its last child. Any other
  root is wrapped in a new root column (`id: harness-notify-dock`). The keys Herdr reads from the
  root only — `titlebar`, `traffic_lights`, `preview`, the menu and toast mods, the look (`theme`,
  `colors`, fonts, `background`, …) and `cloned_from` — stay on the new root. Herdr's own first-load
  dock moved them into the inner node, which brought the system title bar back as a band over the
  window; this one does not.

`--undock <layout>` (and `--rollback`, for every layout `--dock` recorded) removes exactly that: the
strip, and the wrapper with its keys put back on the old root. When you edited the layout in
between, it removes only the strip and keeps your nodes (an emptied node of yours stays, with a
note). It refuses, and writes nothing, when the strip appears more than once, or when you set a
root key on both the wrapper and the inner node; `--rollback` then removes nothing at all.

Herdr writes editor files into the mod folder on first load (`jsconfig.json`, `*.d.ts`).
`--rollback` removes those with the mod, and still refuses on any other file it did not install.
