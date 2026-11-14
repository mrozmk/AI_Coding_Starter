---
description: Mirror .agents/backlog.md into GitHub issues — Epics as issues, Tasks as their sub-issues, every issue on the profile's Project; one-way, create-only, idempotent, previewed and confirmed per Epic
argument-hint: "[E<n>] [--preview]"
allowed-tools: Bash(node .claude/lib/github-sync.mjs:*), Bash(node .claude/lib/backlog-check.mjs:*), AskUserQuestion
---

# /github-sync — the backlog as GitHub issues

The GitHub counterpart of `/jira sync`, for `tracker: github`. The backlog stays the planning source
of truth; GitHub mirrors it. **One-way and create-only:** an issue that exists is never edited,
closed or deleted, no Project status is moved, and grooming done on GitHub is never overwritten.
All the work — and every GitHub call, through `.claude/lib/team-tracker.sh` — is done by
`.claude/lib/github-sync.mjs`; this command previews, asks, and runs it.

Argument: **$ARGUMENTS** — an Epic id limits the run to that group; `--preview` stops after the
preview.

## What it does

- **Bodies are generated, not written by hand.** Epic: Outcome · Key assumption · appetite / cut
  first · Depends on. Task: Type · Size/Pts · Wave · Slice · Traces · Depends on (issue numbers when
  known) · the Task's **current** acceptance criteria verbatim (the approved spec named in `Ref`,
  else the backlog block — the resolver `/brainstorm` uses). Titles are `<row id> — <title>`.
- **Identity** — every body carries `<!-- backlog:<namespace>:<row id> -->` on a line of its own
  (any position: a note added under it on GitHub does not break it) and the hash of what was
  mirrored. The namespace is the backlog header's `**Jira namespace:**`.
- **The issue number goes into the row's `Jira` cell** as `#42 (unverified)` the moment the issue
  exists, and `#42` once the markers are read back. (The column keeps its historic name; a GitHub
  number there is told from a Jira key by its `#`.)
- **Recovery** — a row whose cell is empty but whose marker is already on an issue (a crashed run)
  is adopted, never created twice. A marker on two issues, or a cell that names another issue than
  the marker's, **stops the group** before any write: fix it by hand.
- **"Changed since sync"** — a synced row whose backlog content differs from what was mirrored is
  reported, never pushed.
- **Limits checked first** — more than 100 sub-issues under one Epic (GitHub's cap) stops the group.

## Steps

1. **Preview** — `node .claude/lib/github-sync.mjs --preview` (add `--epic E<n>` when the argument
   names one). It validates the backlog (`backlog-check.mjs` must pass, the backlog must not trail
   the PRD), reads GitHub, and prints per Epic: what will be created, recovered or is already
   synced, the sub-issue links, the Project additions and **the exact text of every issue to
   create**. It writes nothing. A non-zero exit → show its message and stop:
   1 = refused (fix the backlog or the conflict it names) · 3 = the tracker is not `github` ·
   4 = GitHub failed partway through a read (retry later).
2. **Show the preview** to the user in full — the bodies are what will be published. `--preview`
   in the argument → stop here.
3. **Confirm per Epic group** with `AskUserQuestion`: "Create/link these for `E<n>`?" — Yes · Skip
   this Epic · Stop. Only a group with something to create, recover, link or verify needs asking;
   a fully synced group is reported and skipped.
4. **Apply each confirmed group** — `node .claude/lib/github-sync.mjs --epic E<n> --apply --yes`.
   Never pass `--yes` without that group's Yes. Non-zero exit → show it and stop the remaining
   groups; the cells written so far stay (`#n (unverified)` rows are adopted by the next run).
5. **Report** — per group: created · recovered · verified · changed since sync (not pushed) ·
   skipped. Remind once: the backlog file changed (`Jira` cells) — commit it with `/commit`.

## Never

- Never call `gh` yourself, never edit an issue, never move a status, never re-create an issue a
  cell already names.
- Never run `--apply --yes` for a group the user did not confirm in this run.
