# Draft pattern — backlog rows → local draft files (`/jira draft`, `drafts`, `edit`, `discard`, `export`)

The **local, reversible** half of publishing the backlog to Jira: one Markdown file per issue,
generated from `.agents/backlog.md`, groomed by the user, published later by `send`
([send-pattern.md](send-pattern.md)). **No MCP call is made anywhere in this file's flows.**

Why files: a chat confirmation that prints 40–80 descriptions is unreadable and leaves no trace of
grooming. A file per issue is the grooming table — edit it in the editor, re-check it with
`drafts`, publish it when it is right.

---

## Layout and identity

```
.agents/jira/                         # gitignored — local grooming history (see "Local only")
├── inprogress/E1/_epic.md            # "_" sorts the Epic first
├── inprogress/E1/E1-2--set-up-ssr.md # <Task id>--<slug>.md
├── sent/E1/…                         # written by send, one file at a time
└── sync-reports/…                    # written by resync
```

- **Folder = Epic id** (stable; an Epic rename does not orphan the folder).
- **Task file = `<Task id>--<slug>.md`.** The double dash separates the stable id from the mutable
  slug. **Identity is the frontmatter `backlog_row`, never the file name.**
- **One authoritative file per `backlog_row`** across `inprogress/` and `sent/`; a second one is an
  error and the run writes nothing. **Exception — reuse-Epic:** `inprogress/E1/_epic.md` with
  `status: reference` may sit next to `sent/E1/_epic.md` when both carry the same `backlog_row` and
  the same `jira_key` (a reference file is a pointer, not an issue snapshot). Different keys → error.

### Slug rules

1. Transliterate (default table — extend per project): `ą→a ć→c ę→e ł→l ń→n ó→o ś→s ź→z ż→z`
   (upper case alike).
2. Lowercase.
3. Every run of characters outside `[a-z0-9]` → one `-` (other non-ASCII letters drop out here; the
   full summary stays in the frontmatter).
4. Trim leading / trailing `-`.
5. Truncate to 60 characters; if that cuts a word, trim back to the previous `-`.

## Frontmatter

```yaml
---
issue_type: Task                 # Epic | Task — literal
summary: "…"                     # Task: the Task cell; Epic: "E<n> <Title>" (as sync Step 3)
project_key: PROJ
parent_epic_key: ""              # the Epic's key when its row has one; else resolved at send
backlog_row: E1-2
scope_rev: v1.3                  # the backlog's **Scope rev:** when drafted ("" when it has none)
components: []                   # defaults: $JIRA_DEFAULT_COMPONENTS
labels: []                       # type label + <namespace>:E1-2 (+ <namespace>:chain-<t>) + $JIRA_DEFAULT_LABELS
assignee: ""
priority: ""
due_date: ""
initial_jira_status: ""          # consumed by send (op `transition`)
relates: []                      # copied from the row
chain: ""                        # copied from the row
status: draft                    # draft | sent | reference
jira_key: ""
sent_at: ""
draft_created_at: "2026-11-04T10:15:00Z"
last_error: ""
ops: {}                          # per-operation intents — written by send only
ac_waivers: []                   # AC ids whose Jira wording may differ — written by resync only
---
```

The body below the frontmatter is the Jira description **after** send strips the draft-only
sections and every `[internal]` span. Templates: `description-templates.md` → **Draft Epic** /
**Draft Task**; style: → **Style rules**.

## AC rule

The `## Acceptance criteria` block comes **verbatim** from the AC resolver — the approved spec in
the Task's `Ref` with a `## Acceptance Criteria` section and the newest `YYYY-MM-DD` filename
prefix, filtered to the Task's ids; else the backlog block (`brainstorm.md` Step 5, `qa-verify.md`).
When `node .claude/lib/backlog-check.mjs --next-ids <row> --json` exists, use its `current`.

Prose is the user's to edit; **AC text under an existing id is read-only**. A changed AC text, a
missing id or a new unnumbered criterion is flagged by `drafts` and refused by `send` with: "add
criteria via `/update-backlog` (new id), then re-draft". Drafts never write AC back to the backlog.

---

## `/jira draft [E<n>]` (alias `sync draft`) — Flow H1

1. **Gate.** `node .claude/lib/backlog-check.mjs` — errors → print them, stop. `**Jira namespace:**`
   missing → stop (same message as sync). `project_key` per HARD-GATE invariant 2.
2. **Plan.** For the selected Epic (or every Epic): the Epic row and its Task rows **without** a Jira
   key and **not** withdrawn. Rows that already have a key are skipped (reported). A withdrawn row
   that already has a draft → reported "row withdrawn — discard?" (the file is kept).
3. **Epic file.** `inprogress/E1/_epic.md`: create from **Draft Epic** when absent. When the Epic
   row has a key (already sent) → `status: reference` + `jira_key`, and every new Task gets
   `parent_epic_key` filled.
4. **Task files.** Absent → create from **Draft Task**. Present (matched by `backlog_row`) →
   **refresh** (below). Renamed in the backlog → `mv` to the new slug, reported.
5. **Refresh of an existing draft** — only the **machine-owned** parts are rewritten, so grooming
   survives:
   - machine-owned: frontmatter `summary`, `scope_rev`, `relates`, `chain`, the generated labels
     (type / correlation / chain — user-added labels kept), `parent_epic_key` when it was empty; body
     sections `## Acceptance criteria`, `## Size`, `## Traces`, `## Node`, `## Chain`,
     `## Dependencies`; in `_epic.md` the Task ids in the `## Epic Scope` rows;
   - user-owned: every other section and field — never touched.

   Per changed file show the diff of the machine-owned parts and ask once (`apply all / per file /
   skip`). No machine-owned change → "already drafted". Files under `sent/` are never refreshed.
6. **Report:** created · refreshed · already drafted · renamed · skipped (has key) · conflicts.

`mkdir -p` creates `.agents/jira/inprogress/<E>/` lazily.

## `/jira drafts` — list and validate

Per folder under `inprogress/`: the Epic (summary, status), the files, and per file:

- AC validity — the `## Acceptance criteria` block vs the resolver: a missing id or an unnumbered
  criterion → always flagged; changed text under an id → flagged unless the id is in `ac_waivers`
  (a waiver permits different **wording**, never a missing or extra criterion);
- `scope_rev` lower than the register's `**Current:**` (or the backlog's `**Scope rev:**`) → "stale
  against scope vX.Y — run `/update-backlog` if needed, then `/jira draft E<n>`" (listed first);
- duplicate `backlog_row`, orphan Task file without an Epic file in `inprogress/` or `sent/`,
  malformed frontmatter (file + line).

Empty or missing `inprogress/` → "No drafts in `.agents/jira/inprogress/`."

## `/jira edit <path>`

Local only. The path must be under `.agents/jira/inprogress/` — under `sent/` → stop (post-send
changes go through `/jira update <KEY>`). Ask what to change (a field, a section, the body), show the
diff, apply on confirm. Editing AC text is refused with the AC-rule message.

## `/jira discard <E<n>>`

Path under `inprogress/` only (never `sent/`). Show the files, ask `[y/n]`; on `y` remove each file
with `rm .agents/jira/inprogress/<E>/<file>` and then `rmdir` the folder — `rm -rf` is denied by the
harness, so iterate.

## `/jira export <dir>` — backup

Copy `.agents/jira/` to `<dir>/jira-YYYY-MM-DD-HHMM/` (`cp -R`; `<dir>` must be outside the repo and
never under `.agents/`), then report the file count. **Restore** is the reverse copy into
`.agents/jira/` (stop if `.agents/jira/` is not empty and ask first).

---

## Local only

`.agents/jira/` is in `.gitignore`: drafts carry `[internal]` notes and grooming history that must
not be committed by accident. `export` is the backup. `jira.commit_drafts` in the profile is
reserved — committing drafts is unsupported in v1.

## Invariants

- No MCP call in `draft`, `drafts`, `edit`, `discard`, `export`.
- Never write AC into the backlog; never write any backlog cell.
- Never modify a file under `sent/` here.
- Identity by `backlog_row`; one authoritative file per row (reference-Epic exception above).

## Edge cases

- **Backlog fails the checker** → nothing drafted.
- **Epic row withdrawn** → no folder; an existing folder is reported, not touched.
- **Task added to an Epic already drafted or sent** → its file goes into `inprogress/E1/` alone; for
  a sent Epic a `reference` `_epic.md` is (re)created there.
- **Malformed frontmatter** in an existing file → stop, name the file and line, never auto-fix.
- **Orphan Task file** → `drafts` reports it; `draft` recreates `_epic.md` from the Epic row.
- **Two Tasks with the same slug** → cannot collide on disk (the name starts with the unique Task id).
