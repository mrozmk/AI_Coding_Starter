---
description: Apply post-baseline scope changes (meeting notes, specs, discovery, decisions said in chat) to the PRD register AND .agents/backlog.md in one reviewed, validated write — protects work in progress, shows impact before acceptance, records one D-n
argument-hint: "[<note | spec | docs/discovery.md> …] — empty = every pending source"
---

# Update Backlog: Scope Change → Register + Backlog

## Input: $ARGUMENTS

<HARD-GATE>
No file is written until (a) the clarification loop resolved every intent, (b) the user approved
the preview, (c) the candidate set passed `node .claude/lib/backlog-check.mjs --candidate
.agents/.pending-update --write`, and (d) every target's original hash (or absence) is unchanged
since it was read. Cancel at any gate deletes `.agents/.pending-update/` and writes nothing else.
</HARD-GATE>

**What this is.** The **only** structural writer of the Task table and the Epic map of
`.agents/backlog.md` after it exists (and, for scope, of the register in `docs/PRD.md`). It also
writes the Epic files `.agents/backlog/E<n>-<slug>.md` — Task headings, Summary lines, Goal / scope
lines and criteria; `/setup:delivery-plan`'s detail step writes Goal / scope lines and criteria
there too, never the table. `/check-backlog` and `/jira resync` route their changes through this
command's apply phase. It never writes `Status` of a row with a Jira key, any `Jira`
cell, `.agents/jira/`, or `**Last check:**`; it never regenerates Epics, never renumbers an id and
never puts emoji markers in table cells.

**Precondition:** `/prime` ran this session. `.agents/backlog.md` and `docs/PRD.md` exist — else
point at `/setup:create-backlog` / `/discover` and stop.

Questions and the preview in the project's communication language; every artifact text in English
(source quotes verbatim, original language).

---

## Phase 0 — Pre-flight

1. **Interrupted write.** `.agents/.pending-update/manifest.json` exists → remove every leftover
   `<target>.tmp` first, then classify each target the manifest lists by its current hash:
   = `original` → untouched (absence counts as the original of a new Epic file); = `candidate` →
   installed (absence counts as the candidate of an Epic file the run removed); anything else →
   `unexpected`. A target whose original and candidate hashes are equal (an Epic file the run did
   not change) counts as either.
   - all `original` → offer *discard* or *redo*;
   - all `candidate` → **finish** from Phase 8 step 5 (verify, checker, remove the dir);
   - a mix of `original` and `candidate` → **finish** the install: Phase 8 steps 2–6 for every
     target still `original` — never discard (the candidate set is complete, validated and
     rendered, so rolling forward always reaches one consistent state);
   - any `unexpected` → stop, name each such target with manual instructions and keep the dir.
2. **Revisions.** Read the PRD header `**Current:**` and the backlog header `**Scope rev:**`. Register
   ahead → **reconcile mode** (below) runs first.
3. **Pending Jira refreshes.** List every `**Jira refresh:** <key> pending` entry in the PRD
   `## Change log` (informational — closed by `/jira send` / `/jira update`, never here).

### Reconcile mode

Every `D-n` of kind `scope` above the backlog's `Scope rev` whose `**Tasks:**` line is `—` was
written by `/discover`, which never edits the backlog. Build intents from its `**Affects:**`,
**reusing the ids it already defined** (never supersede again): a superseded `R-n` → unprotected
Tasks tracing it re-trace to the successor, protected ones get a `delta-linked` Task, and every
`X-n` row of `## Outside the dev backlog` tracing it re-traces to the successor; a withdrawn `R-n`
→ a `withdraw-task` question per live Task and a question per `X-n` row tracing it (does the row
stay); an added `R-n` → an `add` Task (or an `outside-add` row when another team delivers it). This run then
fills that `D-n`'s `**Tasks:**` / `**Jira refresh:**` lines instead of writing a new `D-n` for it.

## Phase 1 — Sources

- **Arguments** → those paths. Allowed: `.agents/meeting-notes/*.md` (corrections included),
  `.agents/specs/*.md`, `docs/discovery.md`. Raw `.agents/sources/` files are never a direct source
  here — they enter through notes or `/discover`.
- **No arguments** → the **pending sources**: the effective source set (notes with their
  corrections applied, `/discover`'s rule) plus `.agents/specs/*.md` and `docs/discovery.md`,
  **minus** every file whose hash (`shasum -a 256 <file> | cut -c1-12`) appears in a `D-n`
  `**Sources:**` line **whose `**Tasks:**` line is filled**. A source only `/discover` recorded is
  still pending (reconcile mode covers it). A changed file is pending again — say which `D-n`
  processed its earlier version.
- **"BA direct decision"** — a decision the user states in chat is a source too; quote it.
- Nothing pending and no chat decision → "nothing to process", stop.

## Phase 2 — Load

Read the sources, `docs/PRD.md`, `.agents/backlog.md` and every Epic file in `.agents/backlog/`
(`E<n>-<slug>.md`; `delivery-plan.md` is not one); record every target's sha256. Run
`node .claude/lib/backlog-check.mjs --next-ids` and keep the JSON (next free ids; per Task the
current AC, its source and `nextAc`).

## Phase 3 — Intents

Scan each source for backlog-actionable statements and build
`{kind, target, proposed, requirement, source, source_quote, confidence}`:

- a statement that merely mentions a Task as context is not an intent;
- two sources on one target merge; contradicting values → `confidence: low` + a question with both
  quotes;
- a note decision marked `→ scope` raises confidence; unmarked decisions are scanned the same way;
  a parked item never becomes an `add` without a question.

| Kind | Register (`docs/PRD.md`) | Backlog |
|---|---|---|
| `add` (story) | new `R-n` (next id, `Added: <new Current>`, `Source` / `Quote`) unless the source names an existing **untraced** active `R-n` | new Task (next id), `Traces` incl. that `R-n`, `Status: TODO`, `Jira: —`, AC from `nextAc` |
| `add` (tech) | none (traces `AD-n` / `NFR-n`) | new Task |
| `edit` — same meaning | none, or an `editorial` `D-n` for a register wording fix | **unprotected** Task: prose / AC edited — AC text under an existing id is never edited: withdraw it and add a new id |
| `edit` — meaning changed | old `R-n` `(superseded by R-m per D-k)`, new `R-m` | unprotected Task: `Traces` → `R-m`, AC withdraw + new; **protected Task untouched** + a `delta-linked` intent |
| `delta-linked` | the `R-m` from the row above | new Task, `Relates: <protected id>`, `Traces: R-m` (a delta of a delta relates to the original protected Task) |
| `split` | none — replacements **share the original's active traces** | original → `withdraw-task`; k new Tasks with its `Traces`, AC per replacement from `nextAc`; the first replacement takes the original's `Depends on`; every dependent of the original is redirected to the replacement the intent names (default: the last); a redirect touching a protected dependent → question; an `X-n` row naming the original follows it — in `Starts after` → every replacement, in `Needed by` → the first replacement |
| `merge` | none — the union of the originals' active traces | originals → `withdraw-task`; one new Task with the union of their prerequisites; their dependents redirected to it; protected dependents → question; an `X-n` row naming an original in `Needed by` or `Starts after` → the new Task |
| `withdraw-task` | none | `Task` cell `(withdrawn)`; `Status` → `DONE` / `BLOCKED` **only when the row has no Jira key**; keyed → `Status` untouched + `Jira refresh: <key> pending`; an `X-n` row naming the Task in `Needed by` or `Starts after` drops the id (the checker warns on a withdrawn id left there — the plan would read it as done) |
| `withdraw-requirement` | `R-n` `(withdrawn per D-k)` only if no live Task traces it after this run — otherwise ask: withdraw those Tasks too, or keep the requirement | per the answer |
| `outside-add` / `outside-edit` / `outside-remove` | none (an `edit` meaning change of a traced `R-n` follows the rows above) | an `X-n` row in `## Outside the dev backlog` (next free `X-n`; never renumbered): `Owner`, `Item`, `Needed by` (Task ids or `—`), `Starts after` (the Task ids the item waits for, or `—`; never a wait cycle with `Needed by`), `Traces` (active `R-` / `NFR-` / `AD-` ids or `—`), `Notes`. Removing a row that is the only trace of an active `R-n` / `NFR-n` needs a Task or another row to take the trace, else the checker fails the candidate |
| `move-outside` | none | a non-developer Task leaves the plan by the removal rule above (`withdraw-task` for a protected or an unprotected Task alike); its dependents swap the dependency on it for the Task's own prerequisites, so the order between the remaining Tasks is kept (a swap touching a protected dependent → question), and the withdrawn row's `Chain` cell becomes `—`, so a chain it sat in stays one path; a new `X-n` row lists them under `Needed by`, the Task's own prerequisites under `Starts after`, and takes over the Task's `R-` / `NFR-` / `AD-` traces; the Epic's `Pts` follows the rows that remain |

**Epic files.** A criterion edit (a withdrawn id, a new id) lands in the Task's block of its Epic
file. A new Task gets its `## <id> — <title>` block with a `**Summary:**` line in its Epic's file
and — when the backlog header reads `**Detail:** full` — its criteria in the same run (ids from
`nextAc`); under `**Detail:** structure` a Summary is enough (`/setup:delivery-plan` details it
later). A new Epic gets a new Epic file `<id>-<slug>.md`, the slug by the rule of `epicSlug` in
`backlog-check.mjs` (lowercase, diacritics dropped, non-alphanumerics → `-`, at most 40
characters); an existing file is never renamed, even when its Epic's title changes.
`withdraw-task` and `move-outside` keep the Task's block — the table row marks it; nothing is
deleted from an Epic file.

**Outside rows and requirement edits.** An `X-n` row's `Traces` follow the same register edits as a
Task's: a superseded `R-n` → the row re-traces to the successor `R-m` (an outside row has no build
history, so it is never protected); a withdrawn `R-n` → a question whether the row stays.

**Protection.** A Task is **protected** when `Status ≠ TODO`, or `Ref` is non-empty (a spec or plan
exists), or its `Jira` key's live status is not in the project's backlog / waiting set — read
read-only with the refresh `brainstorm.md` Step 0 a′ uses; tracker unreachable → every keyed Task
counts as protected (say so once). A protected Task is never edited in place.

## Phase 4 — Clarification loop

One `AskUserQuestion` per question, multiple choice, your recommendation first. Rules as in
`/meeting-notes` Phase 4: "you choose" → pick and state the assumption; bounced back → propose with a
reason; "don't know" → `[Assumption — to verify]`; more than 8 questions → offer to finish in the
preview. Always asked, even when the source is clear:

- every removal and withdrawal;
- placement of a new item: developer work (a Task) or work another team delivers (an `X-n` row in
  `## Outside the dev backlog`, with `Owner`, `Needed by` and `Starts after` asked here); for a Task: Epic (an
  existing one, or "new Epic" → next `E<n>` with Title, Outcome, Key assumption asked here),
  `Scope` (`CORE` / `MUST` / `COULD`), Node, Size, `Depends on` / `Relates`;
- an intent whose impact touches `CORE` or a protected Task: **accept / reject**.

## Phase 5 — Impact

`node .claude/lib/backlog-check.mjs --impact <ids>` for each intent's targets → tracing Tasks with
their protection reasons, transitive dependents, `scopes`, the `outside` rows (`X-n`, owner,
`Needed by`) that trace the id, the goals an `R-n` traces, each Epic's cut line, Jira keys involved
(an `X-n` id is itself a valid target: its `Needed by` Tasks and their dependents; a Task id
lists the rows that name it in `Needed by` or `Starts after`). Shown per intent
in the preview — the `outside` rows next to the Tasks; summarised into the `D-n` `**Impact:**`.

## Phase 6 — Build the candidate set

In `.agents/.pending-update/` (gitignored): `PRD.md`, `backlog.md` and `backlog/` with a **full copy
of every Epic file** — changed or not; an Epic file the run removes is absent, a new one is present.
`manifest.json` is written last (below).

- **Register:** the edits above + **one** `D-n` (or the reconcile-mode `D-n` lines filled). Kind:
  `scope` when any register id is added, superseded or withdrawn **or** any Task is added, withdrawn
  or restructured **or** any `X-n` row is added, edited or removed; else `editorial` when only register wording changed; else `confirmation`
  (`Affects: none`) for processed sources that changed nothing. Fields: `Sources` (paths + hashes, or
  `BA direct decision`), `Decision` (the user's words), `Approval: proposed`, `Affects`, `Impact`,
  `Tasks`, `Jira refresh` (keys of touched keyed Tasks and their keyed `Relates` / dependents). **Only
  `scope` bumps `**Current:**`**; the backlog's `**Scope rev:**` = `Current`.
- **Backlog:** row changes and `## Outside the dev backlog` row changes in `backlog.md`; Task
  blocks and criteria in the Epic files (above); AC ids from `nextAc` (never renumber).
- `node .claude/lib/backlog-check.mjs --candidate .agents/.pending-update --write` — validates the
  set and, when it passes, renders the story map and the `>` meta lines inside the candidate
  directory (the repo files are never touched). Errors → back to the preview with the errors; the
  repo is unchanged.
- Then `manifest.json`: per target — `docs/PRD.md`, `.agents/backlog.md` and every
  `.agents/backlog/E<n>-<slug>.md` present in the repo or in the candidate — the original sha256
  from Phase 2 or `absent`, and the sha256 of the rendered candidate file or `absent`. The candidate
  hashes are the final hashes: nothing is generated after the install.

## Phase 7 — Preview and review gate

Show: the `D-n`; each changed register line (old → new); each changed Task row; per Epic file
(new files by name), each changed Task block; each changed `X-n` row; the impact table; checker warnings verbatim; the Epics left untouched, by name. Approve → Phase 8.
Patch → rebuild the candidate (Phase 6) and show again. Cancel → delete `.agents/.pending-update/`,
nothing else written.

## Phase 8 — Write

Each install is atomic: copy the candidate file to `<target>.tmp` in the target's own directory,
then rename it over the target.

1. Re-check every target against Phase 2 — its sha256, or its absence for a target that did not
   exist — changed → abort, delete the pending dir, write nothing ("the file changed during the run
   — re-run `/update-backlog`").
2. Install the PRD.
3. Install the Epic files — the new and the changed ones, then remove the ones the candidate
   dropped.
4. Install `backlog.md`.
5. Verify every target against its candidate hash (or its absence), then run
   `node .claude/lib/backlog-check.mjs` (read-only) once. A mismatch or a checker error → stop,
   name the target or print the errors, keep the dir (Phase 0 resumes from it).
6. Remove `.agents/.pending-update/` — only after step 5 passed.
7. Only after the writes returned, report: counts per intent kind, the `D-n`, pending Jira refreshes,
   drafted-but-unsent Tasks that changed ("draft stale — `/jira draft E<n>` refreshes it").
   **Offer (never run):** `/check-backlog --since D-k` (when it exists), `/jira draft` when new rows
   exist, and **`/maintain:refresh-brief` — always**.

---

## Notes

- One `D-n` per run by default; split into several only when the user asks to separate unrelated
  sources.
- `[internal]` spans in quotes stay in the `D-n` (the register is internal); outbound steps strip
  them.
- Hand edits of the backlog stay allowed; the next run (or the checker's `Scope rev` warning)
  surfaces them.
