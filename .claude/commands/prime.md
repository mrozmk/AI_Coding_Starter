---
description: Prime agent with codebase understanding (quick by default, /prime full for full load)
argument-hint: [full]
---

# Prime: Load Project Context

## Modes

- **`/prime`** — *quick mode* (default). Loads only essentials: `CLAUDE.md`, `index.md`, `project-brief.md`, `architecture.md`, plus listings of plans/specs/reference and git state. Suitable for most sessions — additional memory files load on-demand via `index.md → When to Read`.
- **`/prime full`** — *full mode*. Adds `patterns.md`, `decisions.md`, `api.md`, `errors.md`, all populated `domain/*` files, all `.agents/reference/` and `.agents/specs/`. Use when returning to a project after a long break or starting a deep multi-area task.

> For product/BA priming (PRD details, specs, Jira backlog) use `/prime-ba` — independent command, different scope.

**Mode detection:** quick if `$ARGUMENTS` is empty; full if `$ARGUMENTS` contains `full`.

---

## Process

### 1. Frame — always

Read in order:
- `CLAUDE.md`
- `.agents/memory/index.md` — routing table for what to load later, on demand

Status probe for the three regenerated files. For each of:
- `.agents/memory/architecture.md`
- `.agents/memory/project-brief.md`
- `.agents/memory/domain/business-model.md`

use **`Read` with `limit: 10`** and note the `status:` value in the frontmatter (`populated`, `empty`, or — if there is no `status:` line — treat as `no-frontmatter`). Skip any file that does not exist. The `limit: 10` read of `architecture.md` and `project-brief.md` doubles as the status check for Steps 2–3 — read them in full only if `status: populated`.

Use these values to decide what to read in Step 2 and Step 3.

### 2. Goal — always

If `project-brief.md` is `status: populated` → **Read it.**

If `status: empty` (or missing):
- Emit warning in the report: `⚠️ project-brief.md is empty — run /maintain:refresh-brief for faster primes.`
- Minimal fallback: read **first 100 lines** of `docs/PRD.md` (use `Read` with `limit: 100`).
- If `docs/PRD.md` does not exist → note `no PRD yet` and continue.

### 3. Map — always

If `architecture.md` is `status: populated` → **Read it.**

If `status: empty` (or missing):
- Emit warning: `⚠️ architecture.md is empty — run /setup:create-CLAUDE_MD.`
- Minimal fallback (no full tree dump). Prefer `rg --files` — it respects `.gitignore`, so generated/vendored dirs drop out for free without an ever-growing `-not -path` list:
  !`rg --files --max-depth 3 -g '!node_modules' -g '!dist' -g '!build' 2>/dev/null | awk -F/ 'NF>1{NF--; print}' OFS=/ | sort -u | head -40 || find . -maxdepth 2 -type d -not -path '*/node_modules*' -not -path '*/.git*' 2>/dev/null | head -30`

### 4. Engineering memory — full mode only

**Quick mode:** skip this step entirely. The `When to Read` table in `index.md` will tell the conversation what to load when a concrete task appears.

**Full mode:** read all of these (skip any whose file doesn't exist or is < 5 non-empty lines):
- `.agents/memory/patterns.md`
- `.agents/memory/decisions.md`
- `.agents/memory/api.md`
- `.agents/memory/errors.md`

Then domain files — list and read each populated one:

!`ls .agents/memory/domain/*.md 2>/dev/null`

For each listed file: read it. For `domain/business-model.md` specifically, honor the `status: populated` check from Step 1 (skip if empty).

### 5. Reference & specs — listing always, read in full mode

**Always (listing only):**
!`ls .agents/reference/ 2>/dev/null || echo "(none)"`
!`ls .agents/specs/ 2>/dev/null || echo "(none)"`

**Full mode only:** read each file in `.agents/reference/` and `.agents/specs/`.

### 6. Plans — listing only (both modes)

!`ls .agents/plans/active/ 2>/dev/null || echo "(no active plans)"`
!`ls .agents/plans/done/ 2>/dev/null | tail -5 || echo "(no completed plans)"`

Do not read plan files in `/prime` itself. Read them only when the user's concrete task targets one (or run `/execute <plan>`).

### 7. Repo state — always

!`git log -10 --oneline`
!`git status`

Branch sync (ahead/behind origin):
!`git rev-list --left-right --count @{u}...HEAD 2>/dev/null | awk '{print "behind origin: "$1"  |  ahead of origin: "$2}' || echo 'no upstream tracking branch'`

### 8. Skipped deliberately

- `.agents/sources/` — raw inputs for `/setup:create-PRD` and `/prime-ba`, never loaded by engineering `/prime`.
- `.agents/memory/archive/` — historical pruned entries (created by `/maintain:cleanup-workflow` Phase 2). **Never auto-loaded.** Read on demand only when investigating past decisions.
- `README.md` — typically duplicates brief; load on demand if needed.
- Subdirectory `README.md` files — on-demand only.

---

## Output Report

**Style: facts-only listing. No interpretation. No duplication of brief content** (the brief is already in context — re-summarizing it wastes output tokens).

Use this exact structure:

### Loaded
- One line listing the files actually read this prime.

### Memory — facts

Run a cheap stat listing (filesystem size + mtime — no per-file shell loop, no command substitution):
!`ls -la .agents/memory/*.md .agents/memory/domain/*.md 2>/dev/null`

Render the output as a bulleted list of `<file> — <size>, modified <date>`, one line per memory file the listing returned. (Filesystem size/mtime stand in for line count / commit date — a cheap orientation cue, not a precise metric.)

### Pipeline — facts
- `plans/active/`: <N> files: <filenames>
- `plans/done/` (last 5): <filenames>
- `specs/`: <N> files: <filenames>
- `reference/`: <N> files: <filenames>

### Repo — facts
- Branch: <name>
- **Branch sync** — explicitly flag if local is ahead of / behind origin (e.g. "7 commits unpushed"), or if the tree is dirty
- Last commit: <short hash> — <subject> (<age>)
- Uncommitted: <count> files

### Warnings (omit section if no warnings)
- ⚠️ `project-brief.md` empty — run `/maintain:refresh-brief`
- ⚠️ `architecture.md` empty — run `/setup:create-CLAUDE_MD`

### Mode
- Quick | Full

**No closing summary, no "Ready to start". The facts speak for themselves.**

---

## Notes

- Quick mode is the default because it covers ~90% of sessions cheaply. Full mode pulls in 4-7 extra files plus reference/specs — only worth it when context budget is generous.
- The `When to Read` table in `index.md` is the **runtime routing** (what to load after `/prime`, mid-conversation). Quick mode trusts that table; full mode pre-loads aggressively to skip later read calls.
- If both `architecture.md` and `project-brief.md` are empty, `/prime` is operating in *bootstrap mode* — show both warnings and minimal fallbacks. Recommend running `/setup:create-CLAUDE_MD` then `/maintain:refresh-brief` (in that order) before further work.
