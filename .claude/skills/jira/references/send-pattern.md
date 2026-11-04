# Send pattern — draft files → Jira, every post-create operation recorded (`/jira send`)

Publishes the draft files `/jira draft` wrote ([draft-pattern.md](draft-pattern.md)). Creation reuses
the safety primitives of [sync-pattern.md](sync-pattern.md) — the correlation label, Step 0 recovery,
the Step 2 estimate resolver, the Step 4 metadata check, the Step 6 create → write back → verify
primitive, Step 7 link reconciliation. On top of them every **post-create operation** is a separate,
previewed, **recorded** intent in the draft's frontmatter `ops` map, so an interrupted run resumes
without duplicates.

`/jira sync [E<n>]` = `draft` (silent for already-drafted rows) + `send`, one confirm per Epic group.

Invocation: `/jira send E<n> | --all [--ops-only]`.

---

## Operation model

```yaml
ops:
  epic_scope_links: pending | done | waived      # _epic.md only
  attachments: { upload: pending | done, rewrite: pending | done }   # only when the body has image refs
  transition: pending | done | waived            # only when initial_jira_status is set
  open_questions_comment: pending | done | waived  # only when ## Open questions is non-empty
  links: pending | done | waived
  ac_repair: pending | done                      # set by /jira resync only
```

Each op: write `pending` **before** the MCP call → dry-run (one table per op, all issues) → execute →
**verify by reading Jira** → `done`. `n` at an op's dry-run → `waived` for this run (visible in the
report). A failure leaves `pending`; the run continues; the report names `/jira send E<n> --ops-only`.

**Every `jira_update_issue` in send re-asserts the issue's current `components`** (read in the same
op) — an update with only `fields` wipes them.

---

## Steps (per Epic folder)

### 1. Validate locally — before any MCP call

- **Revisions:** the PRD's `**Current:**` > the backlog's `**Scope rev:**` → stop "backlog trails the
  register (vX.Y < vZ.W) — run `/update-backlog`, then `/jira draft E<n>`" (the checker only warns about
  this — send stops on it itself). A draft's `scope_rev` < the backlog's `**Scope rev:**` → stop
  "stale against scope vX.Y — re-draft".
- **Per file:** frontmatter parses (else file + line); `backlog_row` exists and is not withdrawn;
  `summary`, Node, `relates`, `chain` match the row (else "re-draft (`/jira draft E<n>`) first");
  duplicate `backlog_row` → stop (the reference/snapshot `_epic.md` pair is not a duplicate); a Task
  file with no `_epic.md` in `inprogress/E<n>/` **and** none in `sent/E<n>/` → stop.
- **AC vs the resolver** (`node .claude/lib/backlog-check.mjs --next-ids` → `tasks.<row>.current`):
  a missing id or an unnumbered criterion → stop; changed text under an id → stop unless the id is
  in `ac_waivers` — "add criteria via `/update-backlog` (new id), then re-draft". **Exception —
  `ops.ac_repair: pending`** (set by resync after the change went through `/update-backlog`): the
  snapshot's AC — and its `scope_rev` — are expected to trail; the check becomes "the resolver's
  `current` is what will be sent"; every other guard still runs.

### 2. Checker

`node .claude/lib/backlog-check.mjs` — errors stop.

### 3. Recover

sync Step 0 (labels `<namespace>:<row id>`; adopt 1 hit, stop on >1; the estimate setting resolved
first) — and reconcile every recovered or re-verified key with its draft by `backlog_row`: the
backlog `Jira` cell and the file's `jira_key` must carry the same key and verification state. Then,
for every file with a `jira_key`, re-verify each `pending` op against Jira and mark it `done` or
keep it `pending`.

**Recovery results are staged in memory**, shown in the Step 6 confirm, and written (backlog cells,
frontmatter) only after `y` — `n` leaves every file unchanged; the next run recovers the same facts
again.

| Op | Verified when |
|---|---|
| `epic_scope_links` | the live Epic description's `## Epic Scope` `Jira link` cells hold the keys |
| `attachments.upload` | every referenced file name is in the issue's `attachment` field |
| `attachments.rewrite` | the live description holds no relative image link any more |
| `transition` | the issue's status is `initial_jira_status` |
| `open_questions_comment` | a comment starting `<!-- ops:open_questions:<row id> -->` exists |
| `links` | sync Step 7 finds no missing link |
| `ac_repair` | the live AC section equals the resolver's `current` **and** the `sent/` snapshot's `## Acceptance criteria` section equals it too (rewrite the snapshot first when only Jira is repaired) |

### 4. Preprocess (in memory)

Strip `## Initial Jira status`, `## Dependencies`, `## Notes`, `## Open questions` (captured for its
op) and every `[internal]` span (to the end of its line). Replace backlog Task ids in prose by keys
where known (ids in `## Chain`, the Epic Scope cell and AC ids are exempt — Style rules → Transport).

### 5. Metadata

sync Step 4 for Epic and Task; estimates per the Step 2 resolver (`jira.estimates`).

### 6. Confirm (HARD-GATE invariant 1)

Per Epic group (≤20 rows; larger groups in tens): the field table (Type · Summary · Parent · Labels
· Estimate), the file list (path, size, AC count, `[internal]` spans stripped), and the **exact
outgoing text** of every section that will leave. `n` → nothing created, no file changed. `edit` →
apply, re-print, re-ask.

### 7. Create the Epic (create-epic branch only)

`status: reference` → skip. Otherwise the sync Step 6 primitive: `jira_create_issue` → `KEY
(unverified)` into the backlog Epic-map `Jira` cell **and** `_epic.md` (`jira_key`) → verify →
`KEY`, `sent_at`.

### 8. Propagate

The Epic key into every Task's `parent_epic_key`.

### 9. Create Tasks — sequentially

The sync Step 6 primitive per file: backlog `Jira` cell + frontmatter `KEY (unverified)` → verify →
`KEY`, `status: sent`, `sent_at`. A 4xx stops that row (`last_error`); the user decides whether to
continue. **Never `jira_batch_create_issues`.**

### 10. Post-create operations — in this order

- **`epic_scope_links`** — fetch the live Epic description and components; locate `## Epic Scope`;
  change only the `Jira link` cells of rows whose Task ids this run resolved
  (`[KEY]($JIRA_URL/browse/KEY)`), add rows for Tasks new to the Epic, keep every other byte; mirror
  the cells in `_epic.md`; `jira_update_issue` (components re-asserted). Table missing or its rows
  do not match the Task ids → keep `pending` and ask — never overwrite the live description with the
  local file.
- **`attachments`** — relative image links in the draft body (`![alt](screenshots/<f>.png)`, files
  inside the draft folder): `upload` per [attachments.md](attachments.md) (stage into
  `.jira-attachments/` → `jira_update_issue(fields="{}", attachments=…)` → verify `uploaded[]` /
  `failed[]`, never the `success` flag; a retry sends only the files not yet uploaded); then
  `rewrite` — each image ref → `_(screenshot: <file> — see Attachments)_` in the live description,
  components re-asserted, verified. **`curl` is never used.**
- **`transition`** — `initial_jira_status` via [transition-pattern.md](transition-pattern.md)
  (transitions resolved once per run).
- **`open_questions_comment`** — one `jira_add_comment`: first line
  `<!-- ops:open_questions:<row id> -->`, then the captured bullets.
- **`links`** — sync Step 7: `Depends on` → Blocks (direction verified after the first link),
  `Relates` → Relates.
- **`ac_repair`** (only when `pending`) — **branch on the resolver**: when the row's `current`
  differs from the issue's live AC (the original Task was changed by `/update-backlog`):
  `jira_update_issue` rewriting the AC section with `current` (components re-asserted); after
  verification rewrite **that** `sent/` file's `## Acceptance criteria` section and `scope_rev` —
  the one sanctioned refresh of a `sent/` file — and set `done`. When `current` still equals the old
  criteria because the Task was protected and `/update-backlog` created a `delta-linked` Task: change
  nothing, set `done — delivered as delta <id>` (the delta ships through `draft` → `send`).

### 11. Move per issue

`inprogress/E<n>/<file>` → `sent/E<n>/<file>` when `jira_key` is set and every op is `done` or
`waived`. A `status: reference` `_epic.md` is **never** moved (the `sent/` snapshot it points at
stays as it is); it is removed once no draft of the Epic remains in `inprogress/E<n>/`. Files with a `pending` op stay (listed "pending ops"). When `_epic.md` moves while Tasks
of the Epic remain in `inprogress/E<n>/`, write a `reference` `_epic.md` in its place (same
`backlog_row`, same `jira_key`) so `--ops-only` finds the parent.

### 12. Refresh markers

An entry in a `D-n`'s `**Jira refresh:**` line is a pair (`D-n`, key). Close it (`done <date>`, a
previewed edit of that line only) only when an update this run made to that key **realises the
decision** — the issue's live AC / description now carries the resolver's current text for the
Tasks the `D-n` names — verified by a read; or by an explicit per-entry waive in the confirm. An
unrelated update (priority, labels, a transition) never closes it; a newly created issue never
closes another key's marker.

### 13. Report

The sync Step 8 shape plus: an ops table (issue × op: done / pending / waived), the `Estimates:`
line, refresh markers closed / still pending, and the skipped / deferred / failed buckets — always
printed, `0` included.

---

## `--ops-only`

Steps 1–3, the **capture and sanitising half of Step 4** (open-question bullets re-captured from
the draft, `[internal]` spans stripped from anything that will be sent), and Steps 10–13: nothing is
created; each pending op is previewed (an open-questions comment shows its reconstructed text) before
it runs; the files are moved when their ops finish.

## Invariants

- Nothing is created before the metadata check (Step 5) and the confirm (Step 6).
- Creation is sequential, idempotent and create-only; post-create operations are separate, recorded
  in `ops` before execution and marked `done` only after verification.
- Send never edits an issue's summary or description outside those recorded operations.
- Send writes only `Jira` cells in the backlog — never `Status`, never AC, never structure.
- Never batch create; never `curl`; never inline image previews.
- A whole folder never moves while any file has a pending op.

## Edge cases

- **`n` at confirm** → nothing in Jira, no file changed.
- **Killed after a Task create, before write-back** → Step 3 adopts it by label.
- **Killed after the comment, before `done`** → Step 3 finds the marker comment; nothing posted twice.
- **Epic created, Tasks aborted at a later confirm** → `_epic.md` has a `jira_key`; the next run
  treats it as `reference`.
- **Epic done, one Task's attachments pending** → `_epic.md` to `sent/`, a `reference` copy stays.
- **Epic description edited in Jira after send** → `epic_scope_links` changes only the scope cells.
- **Transition name not in the workflow** → op `pending`; the report lists the valid names.
- **Withdrawn row with a draft** → not sent; reported.
