---
description: Prime agent with product context for the Business Analyst role (budgeted: index first, code map, no spec bodies)
argument-hint: [full]
---

# Prime BA: Load Product Context on a Budget

## Objective

Build a product-level understanding for Business-Analyst work — the scope register, the backlog,
the recorded decisions, what is still unprocessed and where the code is — on a **measured budget**,
so the session starts with room to work. This command loads **product** context, not implementation
context; for implementation-level priming use `/prime`.

`.claude/lib/prime-ba.mjs` does every measurement and extraction: it reserves the mandatory core,
selects the optional layers inside what remains, and prints one row per item. This command runs it,
reads exactly what it selects and reports facts.

## Constants

The tuning knobs, defined at the top of `.claude/lib/prime-ba.mjs` (the script prints them on its
`CONST` row). Raise one when a layer is too thin — never remove the selector.

| Constant | Value | Role |
|---|---|---|
| `DEFAULT_BUDGET` | 163840 (160 KB ≈ 40k tokens) | default-mode total of loaded content |
| `FULL_BUDGET` | 327680 (320 KB ≈ 80k tokens) | full-mode total |
| `PER_FILE_CAP` | 40960 (40 KB) | a file `LOAD`ed whole, default mode |
| `FULL_PER_FILE_CAP` | 81920 (80 KB) | the same in full mode (lets a long `decisions.md` load whole) |
| `PAGE_SIZE` | 24576 (24 KB) | one page of `plan` / `extract` output — stays one inline Bash result |
| `PENDING_BUDGET` | 49152 (48 KB) | default-mode sub-budget for pending-source content |
| `DECISIONS_NEWEST` | 10 | `decisions.md` entries in full |
| `CHANGELOG_NEWEST` | 5 | `D-n` entries in full |
| `SPECS_LISTED` | 10 | spec rows in the listing (the count is always given) |
| `MAXLOAD` | 25 | `LOAD` rows — a guardrail, never yields |
| `MAXSKIP` | 10 | skip rows named (counters uncapped) — a shaping cap; yields when the residue is the question (`rg --files .agents/specs`) |
| `FETCH_FRESH_HOURS` | 24 | code-root `FETCH_HEAD` age before "unknown" |
| `GIST_MAX` | 72 | characters of a register sentence on its index line |
| `PRD_HEAD_LINES` | 100 | PRD lines read when the brief is empty |

## Modes

- **`/prime-ba`** — *default*. Always loaded (the mandatory core, measured and reserved first, never
  skipped, paged when long):
  - `.agents/memory/index.md`
  - `.agents/memory/user-profile.md` (when present)
  - `.agents/memory/project-brief.md` (when `populated` / `seeded`; else the first 100 lines of `docs/PRD.md` and a warning)
  - the PRD scope register as an index + the newest 5 `D-n` (`extract register`, `extract changelog`)
  - `docs/discovery.md` coverage, open questions and critical flows (`extract discovery`)
  - `docs/architecture.md` status, subdomains and the `AD-n` table (`extract architecture`)
  - `.agents/memory/decisions.md` headings + the newest 10 in full (`extract decisions`)
  - the backlog state with the checker output (`extract backlog`)

  Then, inside what remains: `.agents/backlog.md` whole, each code root's
  `.agents/memory/architecture.md` and its `docs/map/system.yaml` nodes (`extract codemap`), and the
  pending meeting-note families and `docs/discovery.md`. Specs are **listed, never read**.
- **`/prime-ba full`** — the same, with `FULL_BUDGET` / `FULL_PER_FILE_CAP`: `decisions.md` whole,
  pending content up to the remaining budget, then pending specs and the newest specs.

**Mode detection:** full when `$ARGUMENTS` contains `full`. Any other argument → say once
"`/prime-ba` takes no topic — the command that works on the topic loads it" and load nothing for it
(`index.md` → Loader Convention).

## Process

### 1. Plan

Run `node .claude/lib/prime-ba.mjs plan` (`node .claude/lib/prime-ba.mjs plan --mode full` in full
mode). Its first row says `pages=<n>`; a page that is not the last ends with
`… continued — run: node .claude/lib/prime-ba.mjs … --page <n+1>` — run that line verbatim, every
page, before acting on any row.

### 2. Load exactly what the plan selects

- **`LOAD` rows** — `Read` the path (with `limit` when the row has `limit=100`). A `family=` row is
  one member of a meeting-note family: apply the corrections the way `meeting-notes.md` → "How
  readers apply corrections" prescribes (suffix order, `## Metadata` first); a `was:` text you cannot
  find is a conflict to report, never a choice.
- **`EXTRACT` rows** — run `node .claude/lib/prime-ba.mjs <the row's cmd= field>` verbatim, every
  page (the row's `pages=` says how many).
- **Never** read a `SKIP_*`, `SPEC`, `PENDING` (not loaded), `RAW` or `INDEX` path "because it looks
  relevant" — that is the budget being re-litigated by the reader it exists to constrain. A file you
  read later on demand, for a concrete task, is said so.
- `CLAUDE.md` is injected — never read. `README.md` is not read (it duplicates the brief).
- The backlog freshness check needs no extra call: `extract backlog` runs
  `node .claude/lib/backlog-check.mjs` and `/prime-ba` recomputes the fingerprint
  (`backlog-check.mjs --fingerprint`'s value) to mark the `**Last check:**` fresh or stale. Never fix
  the backlog from here — structural edits go through `/update-backlog` (`/setup:create-backlog` →
  Maintenance contract). A missing checker, a legacy work-package backlog, a pre-Scope backlog
  (`node .claude/lib/backlog-migrate.mjs --write`) or a pre-detail backlog is reported with the
  checker's own message.

### 3. Jira (optional)

Jira is optional: BA priming is complete without it — the local backlog and the listings are the full
picture when no tracker is connected. Skip this whole step when the probe fails and say so once in
the report.

Jira config lives in environment variables that the MCP server reads directly — **do not** echo them
from the shell (printing a token would leak it into `audit.log`). Probe connectivity by attempting a
read-only MCP call and reacting to the result.

**Step 3a — Probe connectivity:**

Call `mcp__atlassian__jira_get_all_projects` (read-only, no confirmation needed).
- **Succeeds** → Jira is configured and reachable. Continue to 3b.
- **Fails** (auth / connection / not-configured error) → Jira is offline. Skip 3b and note
  `Jira offline — MCP not configured or unreachable` in the report (the BA can still work without it).

**Step 3b — Fetch live backlog (read-only, no confirmation needed):**

Determine the target project key (prefer the project the BA names; otherwise pick from the projects
returned in 3a, or ask). Then call, substituting the literal project key:

```
mcp__atlassian__jira_search(
    jql="project = <PROJECT_KEY> AND type = Epic ORDER BY created DESC",
    fields="summary,status,assignee,priority",
    limit=10
)
```

If no project key can be determined → skip the fetch and note that the default project is not
configured (the BA can still query manually via `/jira search`). No whole-project scan.

### 4. Local Jira workspace

From the plan's `JIRA_*` rows (no MCP, also when Jira is offline): drafts in progress per Epic
(`JIRA_DRAFTS` — files with pending `ops` named), the newest resync report per sent Epic
(`JIRA_RESYNC`, matched by its exact `E<n>`), and the two newest `Grooming patterns` blocks of
`.agents/memory/domain/jira.md` (`JIRA_GROOMING`). The drift counts inside a resync report are read
on demand, not per prime. No overdue thresholds — just the dates.

---

## Output Report

**Style: facts-only listing.** No procedural narration ("Czytam…", "Uruchamiam…"), no re-summary of
the PRD or the brief (already in context), no closing summary. Narrate only an actual problem
(→ Warnings).

### Loaded
- One dot-separated line with the mode as prefix, naming every file read and every extract run,
  e.g. `Loaded (default): index.md · project-brief.md · extract register · extract changelog · extract decisions · extract backlog · backlog.md`.

### Context budget — facts
- One line per `LAYER` row: `<layer> — <bytes> (<mandatory|optional>)`
- `TOTAL` vs the budget, as the plan printed it
- Skipped per reason (`SKIPPED_CAP` / `SKIPPED_MAXLOAD` / `SKIPPED_BUDGET`), naming the skipped items up to `MAXSKIP`

### Register & backlog — facts
- The register header line, the counts per kind and state, the newest `D-n` titles with their `**Approval:**`
- `backlog-check` output verbatim (errors and warnings), or "clean"
- `**Detail:**`, `**Last check:**` fresh / stale / never checked, `Current` vs `Scope rev` (behind → `/update-backlog`)
- The Epic map with Task counts per `Status` when the extract carried it (the backlog over its cap or out of budget)

### Pending sources
- Count, then names + sizes from the `PENDING` rows, with `changed since D-k` where given
- Raw sources no note fully covers (`RAW` rows: names + sizes) — listed, never read
- Notes: count, the three newest titles, each note's corrections (`FAMILY` rows); any `ERROR` correction conflict or orphan

### Open `Q-n`
- From the discovery extract's `## Open questions` (id + question); absent → "no `docs/discovery.md` — run `/discover`"

### Code roots
- One line per `CODE_ROOT` row (name, branch, HEAD, ahead/behind, dirty, last fetch, verdict), or the `NO_CODE_ROOT` line

### Jira
- Live: table of the 10 newest Epics — `Key | Summary | Status | Priority | Assignee`, each key linked to `$JIRA_URL/browse/<KEY>`; or `Jira offline — …` once
- Local workspace: from step 4

### Warnings (omit section if none)
- One line per `WARN` row, and one per skip reason with its own count and bytes — never collapsed
- One line per `ERROR` and `MISSING` row (what is absent and the command that creates it)

### Next steps
At most 3, the earliest that apply in this route order:
- `/discover` — no PRD yet, product direction unclear
- `/discover --import <file>` — requirements exist outside the repo (doc, CSV, spreadsheet) and carry no ids yet
- `/architect` — PRD exists but no `docs/architecture.md` (no subdomains, no `AD-n`, no stack decision)
- `/setup:create-backlog` — PRD + architecture exist but no `.agents/backlog.md`
- `/jira sync` — local backlog exists, its `Jira` cells are empty and `tracker=jira`
- `/brainstorm <Task>` — a sized H/XH Task with no spec yet
- `/jira create epic` — spec exists but no Jira epic (only when no local backlog — with one, `/jira sync` owns Epic creation)
- Refresh PRD — raw sources present but PRD seems outdated

The rest that apply go in one trailing line. Nothing applies → say the backlog looks consistent and is
ready for user-story work (in the user's communication language — CLAUDE.md → Language Rules).

---

## Role Framing for This Session

After the report, remind yourself (and the user) of the BA role posture:
- Focus on **what** and **why**, not **how** (leave implementation detail to `/plan-feature` and developers)
- Prefer user-story format: "As a [user], I want [action], so that [benefit]"
- Tasks are stories or technical tasks, sized M/H/XH, with acceptance criteria carrying ids (`E<n>-<m>.AC<k>`)
- When creating tasks in Jira, always under a parent Epic (no free-floating tasks — per `jira` skill hard-gate)
- When in doubt about scope or product intent, ask — do not guess
- Not 99 % sure → ask, never guess.
- Verify against the code and the recorded decisions before proposing a change to an existing system.

## Stage end marker (token usage)

At this command's definitive end — its work is done, or it stops for good (STOP, refusal, blocker) —
run exactly this once, as its own Bash call from the repo root with nothing chained before or after
it, as the last step **before** the final report (or handback):

`bash .claude/lib/costs/runtime-mark.sh stage end prime-ba`

Never at a pause that waits for the user (a question, an approval): the stage goes on after the
answer, and a plain reply records no new start. The call writes nothing itself; when the team
harness has registered the stage hook, the hook records it as this stage's end for
`cost.py report --by-stage` (`.agents/reference/token-usage.md` → Stages). Without the hook, and
inside a sub-agent, it does nothing.
