# Resync pattern — groomed Jira text → `sent/`, drift reports, grooming patterns (`/jira resync`)

After `send`, issues keep being groomed in Jira; the `sent/` snapshots drift and the draft templates
keep the pre-grooming style. Resync reads Jira **read-only**, shows per-issue diffs and applies only
the approved ones to `sent/`, reports **structural** and **AC** drift as actions (never adopted —
the backlog owns structure, Jira owns workflow status), and turns recurring grooming edits into
memory entries and, once confirmed twice, a proposed diff to the editable style defaults.

Invocation: `/jira resync <E<n> | --all> [--dry-run] [--export <dir>]`.

**No mutating `mcp__atlassian__*` call anywhere in this flow.** A Jira repair is queued as a
`send --ops-only` operation; a scope change is prepared as an `/update-backlog` intent.

---

## In scope

- **Compared and syncable:** every Draft Epic / Draft Task body section except the draft-only ones.
- **Compared, never written back:** `## Acceptance criteria` (→ AC drift).
- **Never synced:** frontmatter (except the two flags below), `## Notes`, `## Initial Jira status`,
  `## Open questions`, `## Dependencies`.
- **Files:** `sent/E<n>/*`. Keyed files still in `inprogress/E<n>/` (a send with pending ops) are
  **report-only** — listed as "deferred — send not finished", never written.

## Normalisation (conservative)

Before comparing, normalise only demonstrably equivalent formatting **outside code**: `*` vs `-`
list markers, trailing spaces, runs of blank lines, ADF escaping of `_` / `*`. Inline-code and fenced
code are compared byte for byte; `+` vs `and` is always a content change.

---

## Steps (per Epic)

1. **Fetch** — `jira_get_issue` for the Epic and each keyed file: `description`, `issuelinks`,
   `labels`, `status`, `components`, `parent`. Not found → "not found in Jira" in the report; the file
   is untouched.
2. **Section diff** — compare Jira with the snapshot's **outgoing representation**, not the raw file:
   render the snapshot in memory exactly as send would (Step 4 preprocessing — draft-only sections and
   `[internal]` spans stripped, ids replaced by keys — plus the completed `epic_scope_links` and
   `attachments` rewrites), split both sides by `##` headings, normalise, compare the in-scope
   sections; record changed / added / removed sections per issue. Applying an approved remote edit
   writes the new text into the snapshot section while **keeping its `[internal]` lines** in place.
3. **Structural drift** (`## Structural drift`) — never written into the backlog:
   - **links:** rebuild each issue's remote Blocks / Relates set (direction as in sync Step 7) and
     compare with the backlog's `Depends on` / `Relates`; a remote link missing locally → suggested
     `/update-backlog` intent text; a local relation missing remotely → `/jira send E<n> --ops-only`;
     a link to an issue outside the backlog → "external link — no local Task";
   - **parent:** a Task whose Jira `parent` is not its local Epic's key → "reparented in Jira: <KEY>
     under <other Epic>" with the suggested intent or a manual move back.
4. **AC drift** (`## AC drift`) — compare the Jira AC section with
   `node .claude/lib/backlog-check.mjs --next-ids` → `tasks.<row>.current`. Changed text under an id,
   a new or a removed criterion → an entry. Per Task with drift, one `AskUserQuestion`:
   - **(a) adopt** — prepare the `/update-backlog` intent (withdraw the id + a new one, through a
     `D-n`) and set `ops.ac_repair: pending` in the `sent/` file. Run `/update-backlog`, then
     `/jira send E<n> --ops-only`, which **branches on what `/update-backlog` did** (send-pattern
     Step 1 exception + Step 10): the original Task's resolved criteria changed → the Jira AC is
     rewritten with the new ids, the snapshot's AC section and `scope_rev` are refreshed, `done`;
     the Task was protected and `/update-backlog` created a `delta-linked` Task instead → nothing is
     rewritten on the original issue, the op closes `done — delivered as delta <id>`, and the delta
     ships through `/jira draft` → `send` like any new row;
   - **(b) Jira wording only** — add the ids to the file's `ac_waivers` (send honours them for
     wording, never for a missing or extra criterion);
   - **(c) defer** — stays in the report.
5. **Write the report** — `.agents/jira/sync-reports/YYYY-MM-DD-HHMMSS-E<n>.md`; when that path exists
   add `-2`, `-3`, … — a report is **never overwritten**. Sections: header (Epic, run id, drafts'
   `scope_rev` vs the register's `**Current:**`), compared / changed counts, per-issue section diffs,
   deferred files, `## Structural drift`, `## AC drift`, `## Pattern candidates`, `## Decision log`
   (filled in step 8). `--dry-run` stops here.
6. **Approve content** — one `AskUserQuestion` per `sent/` file with a changed in-scope section,
   showing the diff: **apply / decline**. Only approved sections are written; declined files stay
   byte-identical.
7. **Approve patterns** — a candidate = the same kind of edit seen in ≥2 issues of this run, or in
   ≥50% of the Epic's Tasks, whichever is smaller (each listed with its issues). Per candidate:
   **confirm / drop / refine** (edit title or wording).
   - Confirmed candidates are appended at the **END** of `.agents/memory/domain/jira.md` as one
     block `## <date> — Grooming patterns (resync E<n>)`, one bullet per pattern with a normalised
     title.
   - A confirmed candidate whose normalised title already appears in an **earlier** run's block
     becomes a proposed diff to `description-templates.md` → Style rules → **Editorial defaults**,
     shown for **accept / decline**. The transport rules are never touched.
8. **Decision log** — append every choice to the report, then apply the approved `sent/` edits, the
   `ac_waivers` / `ops.ac_repair` flags, the memory block and any accepted template diff.
9. **Summary** — compared / updated / deferred · structural drift handled / deferred · AC drift
   a / b / c · patterns confirmed · template diffs proposed / accepted · skipped.

## `--export <dir>`

Copy the run's report and the touched `sent/` files to `<dir>/resync-<run id>/` (outside the repo,
never under `.agents/`) — local history backup.

## Invariants

- Read-only toward Jira; never adopt remote structure or AC into the backlog.
- Never write frontmatter except `ac_waivers` and `ops.ac_repair`; never write draft-only sections.
- Never overwrite a report; memory blocks are appended at the END.
- Template changes only to the editorial defaults, only after acceptance.
