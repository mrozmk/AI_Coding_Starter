---
description: Bootstrap the full AI knowledge layer for a large existing codebase — fan-out comprehension → architecture.md + reconstructed PRD → refresh-brief → create-CLAUDE_MD
---

# /setup:map-codebase — Brownfield Comprehension Orchestrator

Make this template's AI workflow usable inside a **large existing codebase that never had AI** (adoption Scenario 3). One run drives the entire brownfield Phase-1 bootstrap: it comprehends the code at scale via a parallel fan-out, then produces `architecture.md` + a reconstructed `docs/PRD.md`, and cascades into `/maintain:refresh-brief` and `/setup:create-CLAUDE_MD`.

**Anti-flooding principle:** the analysis sub-agents return **distilled structured summaries (~1-2k each), never raw source**. The aggregator only ever holds summaries — so codebase size scales the *number of agents*, not the context. The heavy parallel work runs inside the `Workflow` script [`.claude/workflows/map-codebase.js`](../../workflows/map-codebase.js); **this command owns interaction (two checkpoints) and sequencing (the cascade)** because `Workflow` is non-interactive and has no filesystem access.

> Running this command is itself the explicit opt-in to multi-agent orchestration — it is allowed to invoke the `Workflow` tool.

---

## Preconditions

- Must be a git repository. If not → stop: "Not a git repo — initialize first."
- **Worktree redirect.** If running inside an ephemeral git worktree (`git rev-parse --git-dir` ≠ `git rev-parse --git-common-dir`), redirect all output to the **main repo root** (parent of `--git-common-dir`). Otherwise `architecture.md`/`docs/PRD.md` land in a worktree destroyed when the session ends — taking the knowledge layer with it. (UA practice, issue #133.)
- **If the codebase is small** (rough guide: < ~50 source files after filtering) → stop and recommend: "Codebase is small enough — run `/setup:create-CLAUDE_MD` directly; fan-out is unnecessary." Do not spin up the Workflow for a tiny repo.
- **Loader Convention:** if project context isn't primed in this session, ask the user to run `/prime` first. Do NOT re-load `CLAUDE.md` / `architecture.md` / `project-brief.md` here.

---

## Phase 0 — Scan & filter (deterministic, no LLM)

Build the work-list cheaply with shell tools. *(These steps are deliberately NOT done by an LLM — pure rule-lookup over the file tree would be billed at LLM rates and add minutes of latency; this is the UA lesson. Determinism throughout: sort paths with a stable order; on any per-file read/stat failure, warn loudly and drop that file, never abort the scan.)*

1. **Enumerate (NUL-safe)** — `git ls-files -z -co --exclude-standard` (NUL-terminated; the `-z` matters — without it paths with emoji/CJK/accents get C-escaped and silently dropped). Respects `.gitignore`. If not a git repo, fall back to a recursive walk that hard-skips `node_modules/ .git/ .svn/ .hg/ __pycache__/` before any other filtering.
2. **Ignore config (auto-generate + review).** Ensure `.claude/map-codebase-ignore` exists. If absent, generate a **starter** from `.gitignore` (minus built-in defaults) plus detected excludable dirs (`tests/ __tests__/ fixtures/ docs/ examples/ scripts/ migrations/`), with all lines **commented out** and a header explaining `!`-negation. The user reviews/uncomments it at Checkpoint 1. Apply built-in defaults + this file (negation supported) to filter the enumeration.
3. **Detect stack(s), workspaces & deployable units** — read root manifests (`package.json`, `pyproject.toml`, `go.mod`, `pom.xml`/`build.gradle*`, `Cargo.toml`, `*.csproj`, `pubspec.yaml`, …). **Monorepo:** detect workspaces (`pnpm-workspace.yaml`, `turbo.json`, Nx, Cargo/Gradle multi-module) and partition by package FIRST. Note **deployable-unit signals** (`Dockerfile`, `docker-compose*.yml`, per-service manifests/entrypoints, `k8s/`) — feeds `serviceInterface.isService` + topology.
4. **Categorize every kept file** (priority-ordered, specific→general; UA taxonomy): `code | config | docs | infra | data | script | markup`. Rules: `LICENSE`→code · Dockerfile/`docker-compose.*`/`.github/workflows/`/`.circleci/`/`k8s|kubernetes/`→**infra** · `*.sql`/`.prisma`/`.graphql`/`.proto`/schema·model defs→**data** · `README*`/`docs/`/`*.md`/ADRs→**docs** · `.tf`/`.tfvars`→infra · shell→script · the rest of source→**code**.
5. **Drop the noise** (SKIP): tests (`*test*`,`*spec*`,`__tests__/`,`e2e/`), **migration history** (incremental `migrations/` files) + seeds, generated/vendored (`*.min.*`, lockfiles, `*_pb2.py`, `*.generated.*`, codegen), framework boilerplate, assets/binaries. Note: keep **consolidated** schema (`schema.prisma`, `db/schema.rb`) — that's `data`, not migration history.
6. **Route categories:** `code`+`data`(schema/model) → **modules**; `docs` → `docFiles`; `infra` → `infraFiles`.
7. **Coarse import graph + in-degree** (the light neighborMap). Grep import/require/use/include statements across `code` files and map each resolved target to its owning module → build `module → {imports:[modules], importedBy:[modules]}`. Compute **in-degree** (how many modules import it); flag the top modules (high in-degree) as `isCore=true`. Within each module, **prioritize** files by incoming-import count when capping.
8. **Partition into modules** — group by directory/package. **Cap files per module** (≤ ~25 high-signal); on overflow keep the top by in-degree and note the truncation (loud).
9. **Grounding capture** (UA practice): `readmeHead` = first ~3000 chars of `README*`; primary manifest content; `entryPoint` = first match of common patterns (`src/index.*`,`src/main.*`,`main.py`,`manage.py`,`app.py`,`main.go`,`cmd/*/main.go`,`src/main.rs`,`Program.cs`,`index.php`, …).
10. **Skip report** — counts + reasons (e.g. "4,180 skipped: 3,100 tests, 900 generated, 180 vendored").

Produce: `modules = [{ name, files, imports, importedBy, isCore }]`, `docFiles`, `infraFiles`, `readmeHead`, `entryPoint`, and the skip report.

---

## 🛑 Checkpoint 1 — confirm scope

Present, via `AskUserQuestion`:
- the modules to be analyzed (count + names; flag `isCore` hubs),
- the **skip-list with reasons** (loud — never let a silent cap read as "analyzed everything"),
- if `.claude/map-codebase-ignore` was just auto-generated, point the user at it to **review/uncomment** exclusions before the scan is final,
- options to **include** skipped categories/modules or **exclude** some,
- **recommended default = the computed partition**.

Wait for approval. Only then spend tokens on the fan-out.

---

## Phase 1-3 — Invoke the Workflow

Call the **`Workflow`** tool:

```
Workflow({
  name: 'map-codebase',
  args: {
    modules:     <approved partition — each { name, files, imports, importedBy, isCore }>,
    docFiles:    <discovered docs/ADRs>,
    infraFiles:  <discovered IaC/CI files>,
    readmeHead:  '<first ~3000 chars of README, for analyzer grounding>',
    entryPoint:  '<detected entry point, or empty>',
    today:       '<inject today's date, YYYY-MM-DD>',   // the script cannot call new Date()
    projectName: '<detected from manifest, else the repo dir name>',
  }
})
```

The script fans out one `module-analyzer` per module (parallel, capped concurrency, schema-validated summaries), then synthesizes — **from the summaries only, never re-reading source** — an architecture body and a reconstructed-PRD body. It returns `{ architectureBody, prdBody, unanalyzed, analyzed, total }`. Track progress in `/workflows`.

---

## Write artifacts

On return:

1. **`.agents/memory/architecture.md`** — write `architectureBody` with this frontmatter (matches `/setup:create-CLAUDE_MD`'s format), then the body:
   ```yaml
   ---
   status: populated
   populated_by: /setup:map-codebase
   description: Cross-cutting map of the repository — directory structure, file roles, naming rules
   ---
   ```
2. **`docs/PRD.md`** — write `prdBody` (create `docs/` if absent).
   - **Guard:** if `docs/PRD.md` already exists, write `docs/PRD.reconstructed.md` instead and flag it — never clobber an existing PRD.
3. **`.agents/memory/domain/data-model.md`** — only if `hasDataModel` (i.e. `dataModelBody` is non-empty): write it with frontmatter:
   ```yaml
   ---
   status: populated
   populated_by: /setup:map-codebase
   description: Database/persistence schema — entities, fields, relations extracted from the codebase
   ---
   ```
   Then add a brief **`## Data Model`** section to `architecture.md` that points to it: "Persistence schema: see [domain/data-model.md](domain/data-model.md)." If `hasDataModel` is false, skip both (the project has no detected persistence layer) and say so in the report.
4. **Seed knowledge layers from `docsAnalysis`** (only the non-empty parts):
   - **`.agents/memory/decisions.md`** — for each `documentedDecisions` entry, **append** (newest at top) an entry in the file's format (`## [<date>] <title>` + **Chosen/Why/Consequences**), tagged `(imported from ADR: <source>)`. These are real, sourced decisions — appropriate to seed at brownfield bootstrap; they are reviewable at Checkpoint 2.
   - **`.agents/memory/patterns.md`** — for each `documentedPatterns` entry, **append** in the patterns format, tagged with its `source`.
   - Infrastructure needs no separate write — it is already folded into `architecture.md` (`## Infrastructure` + the Service & Integration Map) by the synthesizer.
   - If `docsAnalysis` is null (no docs/ADRs found), skip and note it in the report.
5. If `unanalyzed` is non-empty, surface those module names **loudly** in the next step.

---

## 🛑 Checkpoint 2 — validate the PRD before it propagates

Present a short summary of `architecture.md` + the path to the written PRD. Ask the user to **review and edit the PRD on disk** (it is inferred from code — code shows *what*, not *why*; `project-brief.md` and `CLAUDE.md` will inherit its content). Confirm to proceed.

- **Decline / not now** → stop here. `architecture.md` and the PRD are already persisted; the user can resume by running the cascade commands manually.

---

## Phase 4 — Cascade

After approval, run in order:

1. **`/maintain:refresh-brief`** — distills the (now validated) `docs/PRD.md` → `project-brief.md` (+ `business-model.md` if the PRD has pricing).
2. **`/setup:create-CLAUDE_MD`** — consumes the produced `architecture.md` and generates `CLAUDE.md` + project `README.md` (it asks its own git-workflow / language questions).

If a cascade step fails, **stop and report** — the artifacts from earlier phases are already on disk, so nothing is lost; the user reruns the failed step.

---

## Final report

```markdown
## /setup:map-codebase — complete

**Phase-1 AI layer produced:**
- .agents/memory/architecture.md         (status: populated — incl. Topology, Service & Integration Map, Infrastructure)
- .agents/memory/domain/data-model.md    (if persistence detected; else skipped — noted below)
- .agents/memory/decisions.md            (+N entries imported from ADRs, if any)
- .agents/memory/patterns.md             (+N entries from docs, if any)
- docs/PRD.md                            (reconstructed — validated at Checkpoint 2)
- .agents/memory/project-brief.md        (via /maintain:refresh-brief)
- CLAUDE.md + README.md                  (via /setup:create-CLAUDE_MD)

**Coverage:** analyzed <analyzed>/<total> modules.
**Skipped:** <loud skip stats with reasons>.
**Unanalyzed (if any):** <module names> — rerun or inspect manually.

**Next:** run /prime, then the normal cycle — /brainstorm → /plan-feature → /execute.
```

---

## Critical rules

- **Never let the aggregator read source** — only the analyzers read files; synthesis works from summaries. This is the scale guarantee.
- **Both checkpoints are command-level** — they cannot live inside the `Workflow` (it is non-interactive).
- **Never overwrite an existing `docs/PRD.md`** — write `docs/PRD.reconstructed.md` instead.
- **Checkpoint 2 is mandatory before the cascade** — downstream inherits the PRD's inferences.
- **No silent caps** — always report what was skipped/truncated, with counts.
- **`today` must be injected into `args`** — the script cannot call `new Date()`.
