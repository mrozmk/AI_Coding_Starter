---
name: create-task
description: Open one well-formed task in the project's tracker — a GitHub issue on the Project, a Jira issue through /jira, or a refusal naming the way when the tracker is none. One task shape, drafted to a file and printed before any write; on GitHub every write goes through the tracker adapter with no permission prompt.
when_to_use: |
  Triggered by "/create-task …", "open a task / ticket / issue for …", "file this as a task",
  "załóż task", "otwórz ticket". First argument: free text or a draft file path; then flags.
argument-hint: "<text | draft file> [--type bug|enhancement|none] [--status todo|started] [--label <l>]… [--parent <key>] [--review] [--dry-run]"
allowed-tools: Bash(bash .claude/lib/team-tracker.sh which), Bash(bash .claude/lib/team-tracker.sh create-issue:*), Bash(bash .claude/lib/team-tracker.sh add-labels:*), Bash(bash .claude/lib/team-tracker.sh set-status:*), Bash(bash .claude/lib/team-tracker.sh add-sub-issue:*), Bash(bash .claude/lib/team-tracker.sh item-status:*), Write, Skill, AskUserQuestion
---

# create-task skill

One ad-hoc task, one shape (`references/task-shape.md`), drafted to a file and printed before any
write. The skill never runs `gh` itself: on GitHub every write goes through the tracker adapter
(`team-tracker.sh`, the one place the harness calls `gh`), allowed by this skill's frontmatter
while it runs, so neither the egress guard nor Claude Code prompts. Jira goes through `/jira`.

## 1. Refusals — stop before anything is written

Each refusal ends the skill: no draft, no adapter call.

- **A team clone** — `.agents/team/session.json` or `.agents/team/team.json` exists:
  - a TeamLead (`TEAM_SESSION_ROLE=TeamLead` — checked first, a running stage's `session.json` sits
    in the same clone — or no `session.json`):
    "ask the Supervisor or the Advisor (`.agents/reference/team-decision-model.md` §3)";
  - a stage (any other session, a `session.json` is there): "record it under `## Follow-ups` in the
    run notes" — the wrapup decides tickets.
- **A backlog Task** — the input names an `E<n>-<m>` id, quotes a row of `.agents/backlog.md`, or
  holds a standalone `<!-- backlog:` correlation marker line (Epic or Task, e.g. copied from a
  synced issue): "a backlog Task is created by `/github-sync` (github) or `/jira sync` (jira), which
  bind it to its row". A plain link to related work is not a marker. `/create-task` is the ad-hoc
  path.

## 2. Arguments

- First: free text, or a draft file path.
- `--type bug|enhancement|none` — default from the content (`references/task-shape.md`); `none` =
  no type label (a Supervisor / Advisor recommendation, whose labels come only from the profile).
- `--status todo|started` — default `todo`; `started` is a board edit only, no claim — for work
  started now, create at `todo` and run `/start-task <n>`.
- `--label <l>` — repeatable.
- `--parent <key>` — github: the new issue becomes its sub-issue; jira: the Epic.
- `--review` — one `AskUserQuestion` (approve / edit / cancel) before any write.
- `--dry-run` — draft and print only.

## 3. Resolve the tracker

```bash
bash .claude/lib/team-tracker.sh which
```

Local and read-only → `tracker=github|jira|none`, and for github `repo=<owner/repo>` and
`project=<n|none>`. Runs before the draft, so the intent records the destination.

## 4. Draft

Read `references/task-shape.md`, then write `<scratch>/create-task/<YYYY-MM-DD>-<slug>-<nonce>.md`
with the Write tool (`<scratch>` = the session's scratchpad directory, else `${TMPDIR:-/tmp}`):

```
<!-- create-task-intent: tracker=<t> repo=<r|-> type=<type> status=<s> labels=<l1,l2|-> parent=<p|-> -->
# <title>

## Problem
…
<!-- create-task:<YYYY-MM-DD>:<slug>:<nonce> -->
```

The marker is the last line, github only (`references/github.md` → Marker).

- **Retry** — a draft file is a retry only when its first line is a valid intent line **and** its
  last line a `<!-- create-task:` marker (the one rule, also in `references/github.md`). Then its
  intent wins over the ticket flags given now (`--type`, `--status`, `--label`, `--parent` — say
  so), while the execution controls of this invocation (`--dry-run`, `--review`) always apply; its
  `tracker`/`repo` must equal `which`'s, or the skill refuses ("this draft was written for <repo>");
  its `# ` title is stripped and its marker kept. Retry is github only: a draft file whose first
  line is a valid intent line with `tracker=jira` is refused whatever its last line (a Jira draft
  carries no marker) — "a Jira draft is not replayable — finish the follow-up step on the key the
  first run reported".
- **Any other draft file** is a new draft from that text — strip every `<!-- create-task:` line
  and every `<!-- create-task-intent:` line from it first.
- **Labels are validated before any write**: a label containing `,` or starting with `-` is refused
  up front, so the intent's comma-separated `labels=` is lossless and no label reaches the adapter's
  option parser. A label may hold spaces (`good first issue`): the intent's `labels=` value runs up
  to ` parent=` and splits at `,` only. On github `--parent` must be an issue number (an optional
  leading `#`), checked before any write — also when it comes from a retried intent.

## 5. Print

Print the title and the published body verbatim — github: the content of `<draft>.body.md` (without
the intent line); jira: the description handed to Flow A — and the calls:

- github: the exact `create-issue` command, then the follow-up commands with `<n>` for the number it
  returns, in their two variants — `created <n>`: status, labels, parent, read; `exists <n>`:
  labels, parent, read (no status);
- jira: the Flow A field table (`references/jira.md`).

`--dry-run` → stop here: nothing created on any tracker. `--review` → one `AskUserQuestion`:
approve → route; edit → apply, re-print, ask again; cancel → stop, nothing written (a retry too).

## 6. Route

- `tracker=github` → `references/github.md`.
- `tracker=jira` → `references/jira.md` — `/jira` Flow A; its confirmation, required fields and
  permission prompt stay (the no-prompt guarantee is github's).
- `tracker: none` → no write. With `.agents/backlog.md` and `docs/PRD.md`: "run `/update-backlog`
  and state the printed task as the decision in chat"; otherwise: "no tracker — keep the draft,
  start it with `/brainstorm <draft file>`".

## 7. Report

- **github** — the key, the URL, the board status (from the final `item-status`), the type label and
  labels, the parent, the draft path, and the line `created via team-tracker.sh create-issue`
  (`already existed (retry of <draft file>)` on `exists`); each partial failure with its retry
  `/create-task '<draft file>'`.
- **jira** — the key `/jira` returned and `created via /jira Flow A`; a failed follow-up step
  (attachment, transition) is reported with what to finish **on that key** — never a retry of the
  draft (it would create a second issue).

Never raw `gh` — no `gh` command appears in this skill; `team-tracker.sh` stays the one place the
harness calls `gh`.
