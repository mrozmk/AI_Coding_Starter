---
description: Apply post-baseline scope changes (meeting notes, specs, discovery, decisions said in chat) to the PRD register AND .agents/backlog.md in one reviewed, validated write — protects work in progress, shows impact before acceptance, records one D-n
argument-hint: "[<note | spec | docs/discovery.md> …] — empty = every pending source"
---

# Update Backlog: Scope Change → Register + Backlog

## Input: $ARGUMENTS

<HARD-GATE>
No file is written until (a) the clarification loop resolved every intent, (b) the user approved
the preview, (c) the candidate pair passed `node .claude/lib/backlog-check.mjs --candidate
.agents/.pending-update`, and (d) both targets' hashes are unchanged since they were read. Cancel at
any gate deletes `.agents/.pending-update/` and writes nothing else.
</HARD-GATE>

**What this is.** The **only** structural writer of `.agents/backlog.md` after it exists (and, for
scope, of the register in `docs/PRD.md`). `/check-backlog` and `/jira resync` route their changes
through this command's apply phase. It never writes `Status` of a row with a Jira key, any `Jira`
cell, `.agents/jira/`, or `**Last check:**`; it never regenerates Epics, never renumbers an id and
never puts emoji markers in table cells.

**Precondition:** `/prime` ran this session. `.agents/backlog.md` and `docs/PRD.md` exist — else
point at `/setup:create-backlog` / `/discover` and stop.

Questions and the preview in the project's communication language; every artifact text in English
(source quotes verbatim, original language).

---

## Phase 0 — Pre-flight

1. **Interrupted write.** `.agents/.pending-update/manifest.json` exists → classify each target
   against it: hash = `original` → untouched; = `candidate` → installed; for the backlog also =
   `rendered` (the hash after `--write`, recorded in the manifest in Phase 8) → installed and
   rendered; anything else → `unexpected`.
   - both `original` → offer *discard* or *redo*;
   - PRD `installed` + backlog `original` → **finish**: install the backlog candidate, `--write`,
     record `rendered`, remove the dir — never discard;
   - both installed (backlog `candidate` or `rendered`) → **finish**: `--write` (idempotent), record
     `rendered`, remove the dir;
   - any `unexpected` → stop with manual instructions and keep the dir.
2. **Revisions.** Read the PRD header `**Current:**` and the backlog header `**Scope rev:**`. Register
   ahead → **reconcile mode** (below) runs first.
3. **Pending Jira refreshes.** List every `**Jira refresh:** <key> pending` entry in the PRD
   `## Change log` (informational — closed by `/jira send` / `/jira update`, never here).

### Reconcile mode

Every `D-n` of kind `scope` above the backlog's `Scope rev` whose `**Tasks:**` line is `—` was
written by `/discover`, which never edits the backlog. Build intents from its `**Affects:**`,
**reusing the ids it already defined** (never supersede again): a superseded `R-n` → unprotected
Tasks tracing it re-trace to the successor, protected ones get a `delta-linked` Task; a withdrawn
`R-n` → a `withdraw-task` question per live Task; an added `R-n` → an `add` Task. This run then
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

Read the sources, `docs/PRD.md`, `.agents/backlog.md`; record both targets' sha256. Run
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
| `split` | none — replacements **share the original's active traces** | original → `withdraw-task`; k new Tasks with its `Traces`, AC per replacement from `nextAc`; the first replacement takes the original's `Depends on`; every dependent of the original is redirected to the replacement the intent names (default: the last); a redirect touching a protected dependent → question |
| `merge` | none — the union of the originals' active traces | originals → `withdraw-task`; one new Task with the union of their prerequisites; their dependents redirected to it; protected dependents → question |
| `withdraw-task` | none | `Task` cell `(withdrawn)`; `Status` → `DONE` / `BLOCKED` **only when the row has no Jira key**; keyed → `Status` untouched + `Jira refresh: <key> pending` |
| `withdraw-requirement` | `R-n` `(withdrawn per D-k)` only if no live Task traces it after this run — otherwise ask: withdraw those Tasks too, or keep the requirement | per the answer |

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
- placement of a new Task: Epic (an existing one, or "new Epic" → next `E<n>` with Title, Outcome,
  Key assumption asked here), Wave, Slice, Node, Size, `Depends on` / `Relates`;
- an intent whose impact touches `WS` or a protected Task: **accept / reject**.

## Phase 5 — Impact

`node .claude/lib/backlog-check.mjs --impact <ids>` for each intent's targets → tracing Tasks with
their protection reasons, transitive dependents, slices, the goals an `R-n` traces, each Epic's cut
line, Jira keys involved. Shown per intent in the preview; summarised into the `D-n` `**Impact:**`.

## Phase 6 — Build the candidate pair

In `.agents/.pending-update/` (gitignored): `PRD.md`, `backlog.md`, `manifest.json` (per target: the
original hash from Phase 2 and the candidate hash).

- **Register:** the edits above + **one** `D-n` (or the reconcile-mode `D-n` lines filled). Kind:
  `scope` when any register id is added, superseded or withdrawn **or** any Task is added, withdrawn
  or restructured; else `editorial` when only register wording changed; else `confirmation`
  (`Affects: none`) for processed sources that changed nothing. Fields: `Sources` (paths + hashes, or
  `BA direct decision`), `Decision` (the user's words), `Approval: proposed`, `Affects`, `Impact`,
  `Tasks`, `Jira refresh` (keys of touched keyed Tasks and their keyed `Relates` / dependents). **Only
  `scope` bumps `**Current:**`**; the backlog's `**Scope rev:**` = `Current`.
- **Backlog:** row / AC changes; AC ids from `nextAc` (never renumber).
- `node .claude/lib/backlog-check.mjs --candidate .agents/.pending-update` — errors → back to the
  preview with the errors; the repo is unchanged.

## Phase 7 — Preview and review gate

Show: the `D-n`; each changed register line (old → new); each changed Task row and AC block; the
impact table; checker warnings verbatim; the Epics left untouched, by name. Approve → Phase 8.
Patch → rebuild the candidate (Phase 6) and show again. Cancel → delete `.agents/.pending-update/`,
nothing else written.

## Phase 8 — Write

1. Re-check both targets' sha256 against Phase 2 — changed → abort, delete the pending dir, write
   nothing ("the file changed during the run — re-run `/update-backlog`").
2. Install the PRD: copy the candidate over `docs/PRD.md`, verify its hash = the candidate hash.
3. Install the backlog the same way.
4. `node .claude/lib/backlog-check.mjs --write` (lanes + story map), then record the backlog's new
   hash as `rendered` in `manifest.json`.
5. Remove `.agents/.pending-update/` — only after step 4 succeeded.
6. Only after the writes returned, report: counts per intent kind, the `D-n`, pending Jira refreshes,
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
