---
description: Prime agent with codebase understanding (quick by default, /prime full for full load)
argument-hint: [full]
---

# Prime: Load Project Context

## Modes

- **`/prime`** — *quick mode* (default). Loads only essentials: `CLAUDE.md`, `index.md`, `project-brief.md`, `architecture.md`, plus listings of plans/specs/reference and git state. Suitable for most sessions — additional memory files load on-demand via `index.md → When to Read`.
- **`/prime full`** — *full mode*. Adds `patterns.md`, `decisions.md`, `api.md`, `errors.md`, all populated `domain/*` files, and as much of `.agents/reference/` as fits a hard context budget (Step 5). **`.agents/specs/` is never auto-read** — it is listed, and the spec for the current task is read on demand. Use when returning to a project after a long break or starting a deep multi-area task.

> For product/BA priming (PRD details, specs, Jira backlog) use `/prime-ba` — independent command, different scope.

**Mode detection:** quick if `$ARGUMENTS` is empty; full if `$ARGUMENTS` contains `full`.

---

## Process

### 1. Frame — always

Read in order:
- `CLAUDE.md` — **already injected by the harness every session**; do not re-read it with a `Read` call, just count it as loaded
- `.agents/memory/index.md` — routing table for what to load later, on demand

Status probe for the three regenerated files. For each of:
- `.agents/memory/architecture.md`
- `.agents/memory/project-brief.md`
- `.agents/memory/domain/business-model.md`

use **`Read` with `limit: 10`** and note the `status:` value in the frontmatter (`populated`, `seeded`, `empty`, or — if there is no `status:` line — treat as `no-frontmatter`). Skip any file that does not exist. The `limit: 10` read of `architecture.md` and `project-brief.md` doubles as the status check for Steps 2–3 — read them in full only if `status: populated` or `seeded` (per the File Status Convention in `index.md`, a seeded file carries real content).

Use these values to decide what to read in Step 2 and Step 3.

### 2. Goal — always

If `project-brief.md` is `status: populated` or `seeded` → **Read it.**

If `status: empty` (or missing):
- Emit warning in the report: `⚠️ project-brief.md is empty — run /maintain:refresh-brief for faster primes.`
- Minimal fallback: read **first 100 lines** of `docs/PRD.md` (use `Read` with `limit: 100`).
- If `docs/PRD.md` does not exist → note `no PRD yet` and continue.

### 3. Map — always

If `architecture.md` is `status: populated` or `seeded` → **Read it.**

If `status: empty` (or missing):
- Emit warning: `⚠️ architecture.md is empty — run /setup:create-CLAUDE_MD.`
- Minimal fallback (no full tree dump). Prefer `rg --files` — it respects `.gitignore`, so generated/vendored dirs drop out for free without an ever-growing `-not -path` list:
  !`rg --files --max-depth 3 -g '!node_modules' -g '!dist' -g '!build' 2>/dev/null | awk -F/ 'NF>1{NF--; print}' OFS=/ | sort -u | head -40 || find . -maxdepth 2 -type d -not -path '*/node_modules*' -not -path '*/.git*' 2>/dev/null | head -30`

### 4. Engineering memory — full mode only

**Quick mode:** read nothing here — the `When to Read` table in `index.md` will tell the conversation what to load when a concrete task appears. The `MEMORY_TOTAL` measurement below still reports, because the report's `Context budget` section states it in both modes.

**Full mode:** read all of these (skip any whose file doesn't exist or is < 5 non-empty lines):
- `.agents/memory/patterns.md`
- `.agents/memory/decisions.md`
- `.agents/memory/api.md`
- `.agents/memory/errors.md`

Then domain files — list and read each populated one:

!`find . -maxdepth 4 -path './.agents/memory/domain/*.md' 2>/dev/null`

For each listed file: read it. For `domain/business-model.md` specifically, honor the `status: populated` check from Step 1 (skip if empty).

Measurement (runs in both modes; only full mode reads the files):

!`find . -maxdepth 4 -path './.agents/memory/*.md' -not -path '*/archive/*' -not -name 'reflection-protocol.md' -exec wc -c {} + 2>/dev/null | awk '$NF != "total" { t+=$1; n++ } END { print "MEMORY_TOTAL\t"n+0" files / "t+0" bytes ≈ "int((t+0)/4000)"k tokens (on-disk upper bound)" }'`

`MEMORY_WARN = 200 KB`. The memory layer is **never gated** — every file above is read regardless of this number. When `MEMORY_TOTAL` exceeds `MEMORY_WARN`, add a warning to the report naming `/maintain:cleanup-workflow`. Skipping a memory file to save context is worse than the context it saves: the agent then repeats a bug the project already recorded, and nothing tells it the file was missing.

Report the figure as an **on-disk upper bound**, not as "context loaded". It counts every non-archive memory `.md`, including `status: empty` placeholders the loader skips (`index.md` → File Status Convention). `reflection-protocol.md` is excluded by name because it is the one *large* file `/prime` never loads; the remaining placeholders are ~500 B each and cannot move a 200 KB threshold, so filtering them by frontmatter is not worth the pipeline.

> `-maxdepth 4`, not 3 — `./.agents/memory/domain/*.md` sits four levels deep and vanishes at depth 3. The `reference/` and `specs/` probes in Step 5 are correctly `-maxdepth 3`; do not unify the numbers.

### 5. Reference & specs — measured selection, not "read everything"

**Constants — the only tuning knobs:** `REFERENCE_BUDGET = 120 KB (122880)` · `PER_FILE_CAP = 40 KB (40960)` · `MAXLOAD = 25` · `MAXSKIP = 10` · `MAXROWS = 15`. If full mode feels thin, **raise `REFERENCE_BUDGET`** — do not remove the selector. The selector is what makes the cost visible at all.

**Reference selector** — loads ascending by size; each file is `LOAD`, or skipped with its reason (`CAP` → `MAXLOAD` → `BUDGET`, in that precedence):

!`find . -maxdepth 3 -path './.agents/reference/*.md' -exec wc -c {} + 2>/dev/null | awk '$NF != "total" { match($0, /[0-9]+/); size=substr($0, RSTART, RLENGTH); path=substr($0, RSTART+RLENGTH+1); print size"\t"path }' | sort -n | awk -F'\t' -v CAP=40960 -v BUDGET=122880 -v MAXLOAD=25 -v MAXSKIP=10 '{ path = substr($0, index($0,"\t")+1); if ($1 > CAP) { r="CAP"; cn++; cb+=$1 } else if (n >= MAXLOAD) { r="MAXLOAD"; mn++; mb+=$1 } else if (used+$1 > BUDGET) { r="BUDGET"; bn++; bb+=$1 } else { used+=$1; n++; print "LOAD\t"$1"\t"path; next } s++; if (s<=MAXSKIP) print "SKIP_"r"\t"$1"\t"path } END { print "REFERENCE_LOADED\t"n+0" files / "used+0" bytes ≈ "int((used+0)/4000)"k tokens"; print "SKIPPED_CAP\t"cn+0" files / "cb+0" bytes"; print "SKIPPED_MAXLOAD\t"mn+0" files / "mb+0" bytes"; print "SKIPPED_BUDGET\t"bn+0" files / "bb+0" bytes"; if (s > MAXSKIP) print "…"s-MAXSKIP" more skipped (names only) — rg --files .agents/reference" }'`

The three `SKIPPED_*` totals are **uncapped by design** — `MAXSKIP` suppresses pathname rows, never the per-reason counters. Otherwise a reason whose files all sort after the first ten skips would be invisible, and the report would recommend raising the wrong constant.

**Specs listing** — never auto-read:

!`find . -maxdepth 3 -path './.agents/specs/*.md' -exec wc -c {} + 2>/dev/null | awk '$NF != "total" { match($0, /[0-9]+/); size=substr($0, RSTART, RLENGTH); path=substr($0, RSTART+RLENGTH+1); print size"\t"path }' | sort -rn | awk -F'\t' -v MAXROWS=15 '{ n++; s+=$1; if (n<=MAXROWS) print } END { print "SPECS_TOTAL\t"n+0" files / "s+0" bytes (listing only — never auto-read)"; if (n > MAXROWS) print "…"n-MAXROWS" more — rg --files .agents/specs" }'`

**Non-Markdown reference artifacts** — discoverable, never loaded (`/architecture-review` writes HTML reports here):

!`find . -maxdepth 3 -path './.agents/reference/*' -not -name '*.md' -type f 2>/dev/null | head -10 | sed 's/^/NOT_LOADED\t/'`

**Rules:**

- **Full mode:** read exactly the paths on `LOAD` rows. Nothing else. Do not read a `SKIP_CAP` or `SKIP_BUDGET` file "because it looks relevant" — that is the budget being re-litigated by the reader it exists to constrain. Read one on demand later if a concrete task needs it, and say that you did.
- **Quick mode:** read nothing from either probe. The output is a listing.
- **Both modes:** `.agents/specs/` is never auto-read. When a task targets a spec, read that one file deliberately.
- `NOT_LOADED` rows are non-Markdown artifacts in `reference/` (generated HTML reports and the like). Never auto-read; listed so an agent can find one and open it deliberately.
- **`MAXLOAD` is an absolute guardrail, not a shaping cap — it never yields.** It bounds what gets *selected and read*, not how the report looks. Investigating the residue may print more names; it may never turn a `SKIP_MAXLOAD` into a `LOAD` or raise the Read-call count. Per the Output-Discipline Convention (`index.md` → Output-Discipline Convention), only shaping rules carry a yield; a guardrail that grows an escape hatch stops being one.
- The **shaping** caps — `MAXSKIP`, `MAXROWS`, and the `head -10` on non-`.md` — bound the *inventory*, which is context too. **These yield when the residue is the subject of the question**: a session investigating why context is full prints the full list via the `rg --files` pointer.
- **Why `MAXLOAD` exists alongside the byte budget:** a byte budget alone bounds *content*, not *rows or Read calls*. 400 files of 300 bytes fit inside 120 KB and would produce 400 `LOAD` rows and 400 tool calls — the same failure in a different currency.

> **Known limitation:** the pipeline is line-delimited, so a filename containing a **newline** splits into two rows and both the counts and the paths go wrong. Deliberately not fixed — a NUL-safe pipeline costs real complexity in a probe that must stay readable and exit `0` by construction, against a filename nobody creates accidentally in `.agents/reference/`. Repeated spaces and tabs in filenames **are** handled correctly.

### 6. Plans — listing only (both modes)

!`ls .agents/plans/active/ 2>/dev/null || echo "(no active plans)"`
!`ls .agents/plans/done/ 2>/dev/null | tail -5 || echo "(no completed plans)"`

Do not read plan files in `/prime` itself. Read them only when the user's concrete task targets one (or run `/execute <plan>`).

### 7. Repo state — always

!`git log -10 --oneline`
!`git status`

Branch sync (ahead/behind origin):
!`up=$(git rev-parse --abbrev-ref --symbolic-full-name 'HEAD@{upstream}' 2>/dev/null) && git rev-list --left-right --count "$up"...HEAD 2>/dev/null | awk '{print "behind origin: "$1"  |  ahead of origin: "$2}' || echo 'no upstream tracking branch'`

### 8. Skipped deliberately

- `.agents/sources/` — raw inputs for `/setup:create-PRD` and `/prime-ba`, never loaded by engineering `/prime`.
- `.agents/memory/archive/` — historical pruned entries (created by `/maintain:cleanup-workflow` Phase 2). **Never auto-loaded.** Read on demand only when investigating past decisions.
- `.agents/memory/reflection-protocol.md` — write-time material (the save-or-not bar, entry formats, domain template). Loaded by the reflection callers at the end of a run, **never** by `/prime` in either mode.
- `README.md` — typically duplicates brief; load on demand if needed.
- Subdirectory `README.md` files — on-demand only.

---

## Output Report

**Style: facts-only listing. No interpretation. No duplication of brief content** (the brief is already in context — re-summarizing it wastes output tokens).

**No procedural narration.** Do NOT narrate your own process — no "Zacznę od…", "Czytam pliki…", "Wszystkie pliki populated…", no preamble before tool calls, no recap after them. The `Read` tool calls visible in the UI ARE the proof that loading happened; restating it in prose adds nothing. Narrate only when there is an actual problem to report (→ `Warnings`).

Use this exact structure:

### Loaded
- One dot-separated line of the file names actually read this prime, with the mode as prefix, e.g. `Loaded (quick): CLAUDE.md · index.md · project-brief.md · architecture.md`. This is the glance-check of *which* files entered context — keep it.

### Memory — facts

Run a cheap stat listing (filesystem size + mtime — no per-file shell loop, no command substitution):
!`find . -maxdepth 4 -path './.agents/memory/*.md' -not -path '*/archive/*' -exec ls -la {} + 2>/dev/null`

Render the output as a bulleted list of `<file> — <size>, modified <date>`, one line per memory file the listing returned. (Filesystem size/mtime stand in for line count / commit date — a cheap orientation cue, not a precise metric.)

### Context budget — facts
- Memory layer: <MEMORY_TOTAL from Step 4>
- Reference: <REFERENCE_LOADED>, skipped <per-reason totals> — name the skipped files, capped at `MAXSKIP`
- Specs: <SPECS_TOTAL> (listing only — not loaded)

In quick mode, render the same three lines with reference/specs marked `(listing only)`.

### Pipeline — facts
- `plans/active/`: <N> files: <filenames>
- `plans/done/` (last 5): <filenames>
- `specs/`: <N> top-level `*.md` documents — <up to 5 names>, +<residue> more (`rg --files .agents/specs`)
- `reference/`: <N> top-level `*.md` documents — <up to 5 names>, +<residue> more (`rg --files .agents/reference`)

Say `*.md` documents, not `files` — the probes count only top-level Markdown, so a bare "N files" misreports the directory (both dirs hold a `.gitkeep`; `reference/` also holds generated HTML, visible as `NOT_LOADED` rows). **No byte figures here** — bytes live only in the Context budget section above. The 5-name sample yields when the residue is the subject of the question, same as the probe caps.

### Repo — facts
- Branch: <name>
- **Branch sync** — explicitly flag if local is ahead of / behind origin (e.g. "7 commits unpushed"), or if the tree is dirty
- Last commit: <short hash> — <subject> (<age>)
- Uncommitted: <count> files

### Warnings (omit section if no warnings)
- ⚠️ `project-brief.md` empty — run `/maintain:refresh-brief`
- ⚠️ `architecture.md` empty — run `/setup:create-CLAUDE_MD`
- ⚠️ memory layer is <N> KB (over `MEMORY_WARN` 200 KB) — run `/maintain:cleanup-workflow`
- ⚠️ <N> reference file(s) skipped — `REFERENCE_BUDGET` exhausted; raise `REFERENCE_BUDGET` or read on demand
- ⚠️ <N> reference file(s) skipped — larger than `PER_FILE_CAP`; raise `PER_FILE_CAP` or read on demand
- ⚠️ <N> reference file(s) skipped — `MAXLOAD` reached; the residue is a file-count limit, not a byte limit

One warning **per skip reason**, with its own count and bytes — never collapsed. A reader told "over budget" when the real constraint was `PER_FILE_CAP` will raise `REFERENCE_BUDGET` and watch the file stay unloaded.

**No closing summary, no "Ready to start". The facts speak for themselves.**

---

## Notes

- Quick mode is the default because it covers ~90% of sessions cheaply. Full mode pulls in 4-7 extra memory files plus whatever of `reference/` fits `REFERENCE_BUDGET` — only worth it when context budget is generous.
- Full mode pre-loads the **memory layer in full** and `reference/` **up to `REFERENCE_BUDGET`** — so a large reference dir will leave documents unloaded, by design, and the report names them. They come back on demand via the `When to Read` table in `index.md`, which is the **runtime routing** (what to load after `/prime`, mid-conversation) that quick mode trusts entirely.
- **Why the cap exists:** unbudgeted full mode was measured consuming 950k of a 1M window in one project and ~400k in another, leaving nothing to work with after priming. Raising `REFERENCE_BUDGET` is the supported response; deleting the selector reinstates the incident.
- If both `architecture.md` and `project-brief.md` are empty, `/prime` is operating in *bootstrap mode* — show both warnings and minimal fallbacks. Recommend running `/setup:create-CLAUDE_MD` then `/maintain:refresh-brief` (in that order) before further work.
