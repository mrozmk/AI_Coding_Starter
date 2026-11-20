---
description: Install or update the Herdr panels kit from the starter into your Herdr app home — opt-in, per developer; shows the installer's dry run and writes only after your yes
argument-hint: [<ref>]
---

# /maintain:sync-herdr-kit — Install or update the Herdr panels kit

The Herdr panels kit (the side panels and the `harness` layout) is user-level: it goes to your Herdr
app home (`$HERDR_APP_HOME`, else `~/.config/herdr-app`), never into the project, and nothing
installs it without this command. `/maintain:sync-from-starter` only names this command when the
kit changed upstream. Nothing to commit.

## Step 1 — Plan

Run `bash .claude/lib/herdr-kit-sync.sh plan` (add `--ref <ref>` when `$ARGUMENTS` names one). Read
`kit-source:` and `kit-rev:` from its stdout.

- Exit 0 with the `nothing to do` line → report that line and stop (no clone was made).
- Exit 4 → report git's reason, remove the folder (Step 4), stop.
- Exit 3 → show the output verbatim, including the `mv` lines. Say plainly that nothing was written
  or moved, and that the user moves the named folders aside and reruns. Remove the folder (Step 4),
  stop. **Never run the `mv` lines yourself.**
- Exit 0 with dry-run lines → Step 2.

## Step 2 — Confirm

Show the dry-run lines, the ref and the short `kit-rev`. Ask one `AskUserQuestion`:
**Install / update (Recommended)** · **Cancel**. Cancel → remove the folder (Step 4), report
`nothing written`, stop.

## Step 3 — Apply

Run `bash .claude/lib/herdr-kit-sync.sh apply <kit-source> <kit-rev>` and report its lines verbatim
(installed/updated counts, the layout line, the `layout.switch` hint).

- Exit 3 (the app home changed since the plan, or the clone changed) → show it, stop.
- Exit 1 → show it; a rerun recovers (the installer owns what it copied).

## Step 4 — Clean up

Remove the clone: `find "<kit-source>" -depth -delete` (`rm -rf` is ask-tier). A leftover temp
folder is harmless — never let cleanup block the run.

## Rules

- Never writes without the Step 2 yes, and only from the revision Step 1 showed.
- Never moves or deletes the user's folders; the `mv` lines are for the user.
- Never edits Herdr's `keys.json` or `settings.json`.
- No commit: nothing in the project changes.
