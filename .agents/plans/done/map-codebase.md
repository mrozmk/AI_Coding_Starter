# Feature: Brownfield Comprehension Orchestrator (`/setup:map-codebase`)

The following plan should be complete, but it's important that you validate codebase patterns and task sanity before you start implementing. Pay special attention to the existing command conventions (frontmatter, Loader Convention), the `Workflow` tool API, and the exact `architecture.md` section format that `/setup:create-CLAUDE_MD` produces. This is the **first** command in this repo to drive the `Workflow` tool — there is no in-repo precedent to copy, so follow the `Workflow` tool contract precisely.

**Source spec:** `.agents/specs/2026-06-13-brownfield-comprehension-orchestrator.md`
**External docs required:** no

## Feature Description

A single command, `/setup:map-codebase`, that bootstraps the entire AI knowledge layer for a large existing codebase that never had AI. The command (main agent) runs a deterministic Phase-0 scan, presents a scope checkpoint, launches a `Workflow` script that fans out `module-analyzer` sub-agents (each returning a distilled structured summary, never raw source) and synthesizes both `architecture.md` and a reconstructed `docs/PRD.md`, then — after a PRD-validation checkpoint — cascades into `/maintain:refresh-brief` and `/setup:create-CLAUDE_MD`. Net effect: "10k files, no docs" → full Phase-1 layer (`architecture.md`, `PRD.md`, `project-brief.md`, `CLAUDE.md`, `README`) in one guided run.

## User Story

As a developer adopting this template into a large legacy codebase (Scenario 3 / brownfield)
I want one command to comprehend the code at scale and produce the full AI knowledge layer
So that the rest of the workflow (`/prime`, `/brainstorm`, `/plan-feature`, `/execute`) becomes usable without me hand-writing architecture/PRD or flooding context.

## Problem Statement

None of the existing producers fit a large brownfield repo: `/setup:create-CLAUDE_MD` analyzes inline (context flooding), `/setup:createwikillm` is ingest-driven (chicken-and-egg), `/setup:create-PRD` is conversation-driven (a brownfield product already exists). There is no autonomous, scale-safe producer of the AI layer.

## Solution Statement

A thin command + a `Workflow` fan-out script. The anti-flooding mechanism: parallel `module-analyzer` agents return schema-validated ~1–2k summaries (never raw code); the aggregator holds only summaries, so size scales the number of agents, not the aggregator's context. Because `Workflow` is non-interactive, the two human checkpoints and the cascade live at the **command** level; the `Workflow` script does only the parallel compute and returns the two markdown bodies.

## Feature Metadata

**Feature Type**: New Capability
**Estimated Complexity**: High
**Primary Systems Affected**: `.claude/commands/setup/`, new `.claude/workflows/`, sync playbook, README, `create-CLAUDE_MD` (integration note)
**Dependencies**: None external — harness `Workflow`/`agent` primitives only. Understand-Anything is NOT a dependency.

---

## CONTEXT REFERENCES

### Relevant Codebase Files — IMPORTANT: READ BEFORE IMPLEMENTING

- `.agents/specs/2026-06-13-brownfield-comprehension-orchestrator.md` — Why: the single source of truth for *what* and *why*. Read in full first.
- `.claude/commands/setup/create-CLAUDE_MD.md` (Phase 3.2, lines ~218-240) — Why: the **exact `architecture.md` section format** the `architecture-synthesizer` must emit (Source layout / Module roles table / Naming rules / Critical conventions) + `status: populated` frontmatter. The synthesizer output must be drop-in for this file.
- `.claude/commands/setup/create-CLAUDE_MD.md` (Phase 1, lines ~22-128) — Why: the cascade's final step; also the project-type / config / git-workflow / language detection it already does (do not duplicate in the scan — let create-CLAUDE_MD keep ownership).
- `.claude/commands/maintain/refresh-brief.md` — Why: the cascade's middle step; confirm it reads `docs/PRD.md` and produces `project-brief.md` (it does) so the cascade just invokes it.
- `.agents/memory/architecture.md` (currently `status: empty`) — Why: the literal template skeleton the synthesizer fills; mirror its headings exactly.
- `.claude/commands/maintain/cleanup-workflow.md` (lines 22, 36-39) — Why: pattern + the `--hidden` lesson (rg skips dot-dirs); relevant if the scan ever greps within `.claude`/`.agents`.
- `.claude/sync-from-starter.md` (Category A, lines ~20-28) — Why: where to register `.claude/workflows/*` as synced framework content.
- `.claude/commands/maintain/refresh-brief.md` frontmatter + `.claude/commands/setup/create-CLAUDE_MD.md` frontmatter — Why: command frontmatter convention (`description:`, optional `argument-hint:`).

### New Files to Create

- `.claude/commands/setup/map-codebase.md` — the command (preconditions → scan → Checkpoint 1 → Workflow → write artifacts → Checkpoint 2 → cascade → report).
- `.claude/workflows/map-codebase.js` — the `Workflow` orchestration script (Phases 1–3: fan-out analysis + architecture synthesis + reverse-PRD). Returns the two markdown bodies. Create the `.claude/workflows/` directory.

### Patterns to Follow

**Command frontmatter** (top of every command `.md`):
```markdown
---
description: <one-line>
---
```
`map-codebase` takes no args → no `argument-hint`.

**Loader Convention** (from `.agents/memory/index.md`): the command MUST NOT re-load `CLAUDE.md`/`project-brief.md`/`architecture.md` "for context". Add a one-line precondition: "If project context isn't primed, run `/prime` first." It legitimately reads only what is uniquely its job (the target repo's source, via the scan).

**`Workflow` tool contract** (authoritative — from the tool definition):
- Script begins with `export const meta = { name, description, phases }` — **pure literal**, no computed values, no interpolation.
- Body uses `agent(prompt, {schema, label, phase, agentType})`, `pipeline(items, ...stages)`, `parallel(thunks)`, `phase(title)`, `log(msg)`, and `args` (the value passed via the tool's `args`).
- `agent()` with a `schema` returns a validated object; without schema returns final text.
- Concurrency is auto-capped at `min(16, cores-2)`; pass all modules to `pipeline`/`parallel` and they queue.
- **No filesystem / Node API** in the script body; `Date.now()`/`Math.random()`/`new Date()` THROW — pass `today` via `args`.
- The script's `return` value comes back to the command — return the two markdown bodies, the command writes the files.
- Invoking `Workflow` is legitimate here: a slash command whose instructions tell Claude to call it counts as explicit opt-in.

**`architecture.md` body format** (mirror exactly, `status: populated`): `## Source layout` (tree), `## Module roles` (`Path | Responsibility` table), `## Naming rules`, `## Critical conventions`.

**File-selection heuristics** — SKIP: tests (`*test*`,`*spec*`,`__tests__/`,`e2e/`), migrations/seeds, generated/vendored (`node_modules/`,`vendor/`,`dist/`,`build/`,`.next/`,`target/`,`*.min.*`,lockfiles,`*_pb2.py`,`*.generated.*`,codegen), framework boilerplate, assets/binaries. PRIORITIZE: entry points, config/manifests, route/API/controller defs, schemas, domain models, high in-degree files. Always `log()` skipped counts.

---

## IMPLEMENTATION PLAN

### Phase 1: Foundation

Create `.claude/workflows/` and scaffold the `Workflow` script's `meta` block and the structured-output schema(s). Establish the args contract between command and Workflow.

### Phase 2: Core Implementation

Implement the Workflow phases (fan-out `module-analyzer` → barrier → `architecture-synthesizer` + `reverse-prd-writer`) and the command's deterministic Phase-0 scan + heuristics.

### Phase 3: Integration

Wire the command end-to-end: Checkpoint 1 → launch Workflow → write `architecture.md` + `docs/PRD.md` (with the PRD-exists guard) → Checkpoint 2 → cascade (`/maintain:refresh-brief` → `/setup:create-CLAUDE_MD`) → final report. Register `.claude/workflows/*` in the sync playbook, add the integration note to `create-CLAUDE_MD`, and update README.

### Phase 4: Validation

Structural checks (script parse, reference integrity, frontmatter) + a manual smoke run on a small sample repo. No unit-test framework applies to prose-command + workflow-script artifacts in this template.

---

## STEP-BY-STEP TASKS

IMPORTANT: Execute every task in order, top to bottom.

### CREATE `.claude/workflows/map-codebase.js` (scaffold: meta + schema + args contract)

- **IMPLEMENT**: `export const meta = { name: 'map-codebase', description: 'Fan-out comprehension of a codebase into architecture.md + reconstructed PRD', phases: [{title:'Analyze'},{title:'Synthesize'}] }` (pure literal). Define `const MODULE_SUMMARY = { type:'object', required:[...], properties:{ module, purpose, keyFiles, publicAPI, deps, domainConcepts } }` as the analyzer schema. Read the args contract: `args = { modules: [{ name, files: [paths] }], today: 'YYYY-MM-DD', projectName }`.
- **PATTERN**: `Workflow` tool definition — `export const meta` pure literal; schema is JSON Schema.
- **IMPORTS**: none (script globals: `agent`, `pipeline`, `parallel`, `phase`, `log`, `args`, `budget`).
- **GOTCHA**: `meta` must contain NO variables/calls/interpolation. No `Date.now()` — `today` arrives via `args`. No filesystem access in the body.
- **VALIDATE**: `test -f .claude/workflows/map-codebase.js && rg -n --hidden "export const meta" .claude/workflows/map-codebase.js`

### ADD fan-out analysis phase to `.claude/workflows/map-codebase.js`

- **IMPLEMENT**: `phase('Analyze')`; fan out one `module-analyzer` per module via `parallel(args.modules.map(m => () => agent(analyzerPrompt(m), {label:`analyze:${m.name}`, phase:'Analyze', schema: MODULE_SUMMARY})))`. `analyzerPrompt(m)` instructs: read ONLY the listed files, extract module purpose / key files+roles / public API / dependencies / domain concepts, return the schema — and explicitly "return distilled summary, NOT raw code". `.filter(Boolean)` the results (drop null/dead agents); for any null, collect the module name for the report.
- **PATTERN**: `Workflow` `parallel()` barrier with `schema` per the tool's canonical examples.
- **IMPORTS**: n/a.
- **GOTCHA**: a thunk that throws resolves to `null` — always `.filter(Boolean)`. Keep each analyzer's file list capped upstream (in the command's scan) so no single agent over-reads; if a module still exceeds the cap, the analyzer prompt says to summarize top files by in-degree and note truncation.
- **VALIDATE**: `rg -n --hidden "parallel\(|module-analyzer|schema: MODULE_SUMMARY" .claude/workflows/map-codebase.js`

### ADD synthesis phase to `.claude/workflows/map-codebase.js`

- **IMPLEMENT**: `phase('Synthesize')`. Barrier already gave all summaries. Run two agents (can be `parallel`): (1) `architecture-synthesizer` — prompt includes ALL summaries (not code), instruct to emit an `architecture.md` BODY matching the exact sections (`## Source layout` tree, `## Module roles` table, `## Naming rules`, `## Critical conventions`); returns text. (2) `reverse-prd-writer` — prompt includes aggregated `domainConcepts` + `args.today`, instruct to emit a PRD body marked "Reconstructed from code — requires human validation" with per-section confidence; returns text. `return { architectureBody, prdBody, unanalyzed }`.
- **PATTERN**: agents WITHOUT schema return final text → assign to the two body vars.
- **IMPORTS**: n/a.
- **GOTCHA**: the synthesizer must NOT read files — it works only from the summaries passed in the prompt (that is the whole anti-flooding contract). The script body cannot write files — it RETURNS the bodies for the command to persist.
- **VALIDATE**: `rg -n --hidden "architectureBody|prdBody|return \{" .claude/workflows/map-codebase.js`

### CREATE `.claude/commands/setup/map-codebase.md` (frontmatter + preconditions + Phase-0 scan)

- **IMPLEMENT**: frontmatter `description: Bootstrap the full AI knowledge layer for a large existing codebase — fan-out comprehension → architecture.md + reconstructed PRD → refresh-brief → create-CLAUDE_MD`. Body sections: **Preconditions** (git repo; if repo is trivially small → bail: "run /setup:create-CLAUDE_MD directly"; Loader-Convention one-liner). **Phase 0 — Scan & filter (deterministic):** use `rg`/`git ls-files` to inventory; detect languages/frameworks/workspaces (monorepo → partition by package first); apply the SKIP/PRIORITIZE heuristics; produce module partition with per-module high-signal file lists (capped per module) + a skip report with counts and reasons.
- **PATTERN**: command structure from `create-CLAUDE_MD.md`; heuristics from this plan's "Patterns to Follow".
- **IMPORTS**: n/a (markdown command).
- **GOTCHA**: the scan targets the TARGET project's source (not hidden); but if you ever `rg` inside `.claude`/`.agents`, pass `--hidden` (see `errors.md` lesson — dot-dirs are skipped by default). Do NOT duplicate `create-CLAUDE_MD`'s project-type/git/language detection — that stays in the cascade step.
- **VALIDATE**: `rg -n --hidden "^description:" .claude/commands/setup/map-codebase.md && rg -n --hidden -i "prime first|preconditions" .claude/commands/setup/map-codebase.md`

### ADD Checkpoint 1 + Workflow invocation to `.claude/commands/setup/map-codebase.md`

- **IMPLEMENT**: **🛑 Checkpoint 1** — present modules-to-analyze + skip-list with reasons via `AskUserQuestion`; options to include/exclude categories/modules; recommended default = the computed partition; wait for approval. Then **invoke the Workflow**: instruct Claude to call the `Workflow` tool with `{ name: 'map-codebase', args: { modules: <approved partition>, today: <inject today's date>, projectName: <detected> } }`. State explicitly that running this command is the opt-in to multi-agent orchestration.
- **PATTERN**: `AskUserQuestion` usage as in the brownfield-scenario checkpoints; `Workflow({name, args})`.
- **IMPORTS**: n/a.
- **GOTCHA**: checkpoints CANNOT live inside the Workflow (it is non-interactive) — they are command-level. `today` must be injected by the command into `args` (the script can't call `new Date()`).
- **VALIDATE**: `rg -n --hidden -i "Checkpoint 1|AskUserQuestion|Workflow\(" .claude/commands/setup/map-codebase.md`

### ADD artifact-write + Checkpoint 2 + cascade to `.claude/commands/setup/map-codebase.md`

- **IMPLEMENT**: on Workflow return, **write** `.agents/memory/architecture.md` (the `architectureBody`, with `status: populated` frontmatter) and `docs/PRD.md` (the `prdBody`; create `docs/` if absent). **Guard:** if `docs/PRD.md` already exists, write `docs/PRD.reconstructed.md` instead and flag it. Report any `unanalyzed` modules loudly. **🛑 Checkpoint 2** — present the architecture summary + the PRD path; user reviews/edits on disk; confirm to proceed (decline → stop; artifacts persist). **Cascade:** run `/maintain:refresh-brief`, then `/setup:create-CLAUDE_MD`. If a cascade step fails, stop and report (artifacts already persisted; user reruns that step).
- **PATTERN**: invoking other skills/commands as steps; frontmatter `status: populated` from `create-CLAUDE_MD` Phase 3.2.
- **IMPORTS**: n/a.
- **GOTCHA**: never overwrite an existing `docs/PRD.md`. The PRD gate is mandatory before the cascade — downstream (`project-brief.md`, `CLAUDE.md`) inherits the PRD's inferences.
- **VALIDATE**: `rg -n --hidden -i "PRD.reconstructed|Checkpoint 2|refresh-brief|create-CLAUDE_MD" .claude/commands/setup/map-codebase.md`

### ADD final report section to `.claude/commands/setup/map-codebase.md`

- **IMPLEMENT**: report the full Phase-1 layer produced (architecture.md, PRD.md, project-brief.md, CLAUDE.md, README), **loud** scanned/skipped stats, unanalyzed modules (if any), and next steps (`/prime`, then `/brainstorm → /plan-feature → /execute`).
- **PATTERN**: report sections as in `create-CLAUDE_MD` Phase 4 / `cleanup-workflow` final report.
- **IMPORTS**: n/a.
- **GOTCHA**: no silent caps — explicitly state skip counts so "skipped 4,180 tests" doesn't read as "analyzed everything".
- **VALIDATE**: `rg -n --hidden -i "report|skipped|next step" .claude/commands/setup/map-codebase.md`

### UPDATE `.claude/sync-from-starter.md` (register workflows as Category A)

- **IMPLEMENT**: add a Category A bullet: `` - `.claude/workflows/*.js` — Workflow orchestration scripts (framework content). Overwrite wholesale. ``
- **PATTERN**: existing Category A bullets (commands/agents/skills/hooks).
- **IMPORTS**: n/a.
- **GOTCHA**: place under Category A (overwrite), not B/C.
- **VALIDATE**: `rg -n "\.claude/workflows" .claude/sync-from-starter.md`

### UPDATE `.claude/commands/setup/create-CLAUDE_MD.md` (integration note)

- **IMPLEMENT**: add a short note (near Phase 1 DISCOVER) that on a very large/brownfield repo, `/setup:map-codebase` runs first and produces `architecture.md`; this command then consumes it rather than re-analyzing inline, and is invoked as the final cascade step of `/setup:map-codebase`.
- **PATTERN**: existing inline notes/blockquotes in that file.
- **IMPORTS**: n/a.
- **GOTCHA**: do not restructure the command — just a pointer note.
- **VALIDATE**: `rg -n "map-codebase" .claude/commands/setup/create-CLAUDE_MD.md`

### UPDATE `README.md` (daily-workflow row + Scenario-3 pointer)

- **IMPLEMENT**: add a `/setup:map-codebase` row to the daily-workflow table (one invocation, drives the brownfield Phase-1 chain); and where the brownfield/Scenario-3 adoption is described, point at it as the Phase-1 driver.
- **PATTERN**: existing daily-workflow table rows.
- **IMPORTS**: n/a.
- **GOTCHA**: keep the row concise; link to the spec.
- **VALIDATE**: `rg -n "map-codebase" README.md`

---

## TESTING STRATEGY

This is a template-workflow repo: the artifacts are a prose command (`.md`) + a `Workflow` script (`.js`). There is **no application test runner** and no unit-test target for these. Testing is therefore **structural + manual smoke**, which matches project size (workflow definitions, no CI test suite).

### Structural checks (automatable)
- Workflow script: `meta` present and is a pure literal; uses `parallel`/`agent`/`phase`/`return`.
- Command: valid frontmatter; contains both checkpoints, the Workflow call, the PRD-exists guard, the cascade, the report.
- Reference integrity: all new `/<command>` and file links resolve (use `rg --hidden`).

### Manual smoke (the authoritative validation)
- Run `/setup:map-codebase` against a **small sample repo** (e.g. a 30–50 file project) and confirm: scan produces a sensible partition + skip report; Checkpoint 1 fires; fan-out runs and returns summaries; `architecture.md` matches the expected sections; `docs/PRD.md` is written with the "reconstructed/validate me" marker; Checkpoint 2 fires; cascade runs `refresh-brief` then `create-CLAUDE_MD`.

### Edge cases to smoke
- `docs/PRD.md` already exists → writes `docs/PRD.reconstructed.md`.
- Trivial repo → bails at preconditions.
- An analyzer "dies" → module listed as unanalyzed in the report (simulate by pointing at an unreadable path).

---

## VALIDATION COMMANDS

### Level 1: Syntax & Style
```bash
# Workflow script parses as ESM (note: plain `node --check` treats .js as CJS and will flag `export`;
# the authoritative parse is the Workflow tool loading it. This is a best-effort check.)
node --input-type=module --check < .claude/workflows/map-codebase.js 2>/dev/null && echo "syntax OK" || echo "verify via Workflow tool load"

# Command frontmatter present
rg -n --hidden "^---$" .claude/commands/setup/map-codebase.md | head -2
```

### Level 2: Tests
```bash
# No unit-test runner applies. Reference-integrity sweep across all touched docs (note --hidden — .claude/.agents are dot-dirs):
rg -n --hidden -o '\[[^\]]+\]\(([^)]+\.md[^)]*)\)' .claude/commands/setup/map-codebase.md
rg -l --hidden "map-codebase" .claude/ README.md
```

### Level 3: Manual Validation
- Execute the manual smoke run above on a small sample repo; confirm both checkpoints, the two artifacts, and the cascade. This is the real gate — do it before considering the feature done.

---

## ACCEPTANCE CRITERIA

- [ ] `/setup:map-codebase` exists with valid frontmatter and follows the Loader Convention.
- [ ] `.claude/workflows/map-codebase.js` has a pure-literal `meta`, fans out `module-analyzer` agents (schema'd), and returns `{architectureBody, prdBody, unanalyzed}` without reading files in the synthesis stage.
- [ ] Command runs Phase-0 scan with the SKIP/PRIORITIZE heuristics and a loud skip report.
- [ ] Checkpoint 1 (scope) and Checkpoint 2 (PRD validation) both fire and are command-level (not inside the Workflow).
- [ ] `architecture.md` output matches `create-CLAUDE_MD`'s section format with `status: populated`.
- [ ] `docs/PRD.md` written directly when absent; `docs/PRD.reconstructed.md` + flag when it already exists.
- [ ] Cascade runs `/maintain:refresh-brief` then `/setup:create-CLAUDE_MD`; failure stops with a clear report.
- [ ] `.claude/workflows/*` registered in the sync playbook (Category A); `create-CLAUDE_MD` note + README updated.
- [ ] Manual smoke run on a sample repo passes.
- [ ] No regressions: existing commands' links still resolve.

---

## COMPLETION CHECKLIST

- [ ] All tasks completed in order
- [ ] Each task validation passed immediately
- [ ] Structural validation commands executed successfully
- [ ] Manual smoke run confirms the full flow + the two checkpoints
- [ ] Acceptance criteria all met

---

## NOTES

- **Why Workflow over a markdown `/orchestrate`-style command:** chosen in the spec for hard concurrency cap, token budget, and deterministic structured-output pipeline at true scale. Trade-off accepted: it is a different primitive than the rest of `.claude/commands/`.
- **Division of labour is load-bearing:** checkpoints + file writes + cascade are command-level *because* `Workflow` is non-interactive and has no filesystem access. Do not try to move them into the script.
- **Anti-flooding contract:** the synthesis agents work only from the passed-in summaries; if implementation lets them re-read source, the whole scale guarantee is lost.
- **First Workflow-driven command in this repo** — if the `Workflow` invocation pattern needs a tweak, capture it in `.agents/memory/patterns.md` during the execute/check phase.
