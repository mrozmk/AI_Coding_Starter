# Herdr panels kit — side panels and a layout for the Operator's Herdr window

An optional, user-level kit: eleven Herdr mods and one layout (`harness`) that frame the harness's
sessions in Herdr. `install.sh` installs or updates them into a Herdr app home
(`~/.config/herdr-app` by default), never into a project.

## The panels

- `files-plus` — a lazy file browser for the focused pane's folder, with bounded read-only previews.
- `files-plus-menu` — the right-click menu of a `files-plus` row (copy path, open, new file or folder, rename, delete).
- `files-plus-name` — the name dialog of `files-plus` (rename, new file, new folder).
- `file-view` — a read-only file viewer in its own tab, opened by `files-plus`.
- `limits` — usage limits of every Claude and Codex profile on this computer.
- `machines` — load of each machine: CPU, memory, swap, disk, the heaviest and the orphaned processes.
- `machines-menu` — the right-click menu of an orphaned process in `machines`.
- `pane-plus` — a pane header with a "copy hc send" button, for layouts that frame their panes.
- `spaces-plus` — workspace spaces with stable coloured avatars and worktrees under their checkout.
- `spaces-plus-menu` — the "+" menu of `spaces-plus` (open a folder as a space, new folder).
- `tabs-plus` — tabs with pane layouts for the shown tab (zoom, columns, rows, main left, main top, grid).

The layout `harness` places them around the terminals. Switch to it in Herdr (`layout.switch`).

## Install or update

```bash
bash .claude/team/herdr-mod/panels/install.sh --dry-run   # what it would do; writes nothing
bash .claude/team/herdr-mod/panels/install.sh
```

`HERDR_APP_HOME` points it at another app home. A rerun after a starter update updates the kit.
Check a mod with `herdr-app check <mod folder>`.

## What it writes, and never writes

- It writes only `mods/<name>/` for the eleven names in `kit.json`, `layouts/harness.json` and its
  sidecar `layouts/.harness.installed-by-harness` (the digest of the layout it installed).
- Each mod folder it installed carries `.installed-by-harness`, the list of the files it owns. An
  update replaces those files, removes one a newer kit no longer ships, and keeps every other file
  in the folder (Herdr's `jsconfig.json`, `*.d.ts`, your own files).
- It never writes `settings.json`, `keys.json`, `installed.json`, another mod or another layout.
- Before any write it checks every target. A mod folder or a `harness.json` it did not install, a
  symlink, or a file of the kit's name you put into one of its folders makes it refuse (exit 3)
  with nothing written.

## A folder you copied by hand

The installer refuses a mod folder of the same name it did not install. Move it aside, then rerun:

```bash
mv ~/.config/herdr-app/mods/<name> ~/<name>.hand-copy
```

## A layout you changed

When `layouts/harness.json` changed since install (for example docked by
`herdr-mod/install.sh --dock harness`), an update leaves it as it is and says so. To take the kit's
version, move it aside and rerun.

## Keys

The kit ships no `keys.json`. To drive the `tabs-plus` layouts from the keyboard, merge these lines
by hand under `"global"` in your `keys.json`:

```json
"cmd-alt-1": "tabs-plus.layout-zoom",
"cmd-alt-2": "tabs-plus.layout-cols",
"cmd-alt-3": "tabs-plus.layout-rows",
"cmd-alt-4": "tabs-plus.layout-left",
"cmd-alt-5": "tabs-plus.layout-top",
"cmd-alt-6": "tabs-plus.layout-grid"
```

## Limits

- `limits` finds the profiles in your home folder: `.claude`, `.claude-*` (with `projects/`) and
  `.codex`, `.codex-*` (with `sessions/`), paired by suffix. Its Claude rows come from
  `rate-limits.json` in each profile folder, written by a status-line script this kit does not
  ship; without it the row says no data yet. Codex rows come from the newest session log.
- Checked against Herdr `0.1.16` (`kit.json`). A newer Herdr may change the mod API.
- Notices and licences: `NOTICE.md`.
