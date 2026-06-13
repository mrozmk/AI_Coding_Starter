# Design: Brownfield Comprehension Orchestrator (`/setup:map-codebase`)

**Date:** 2026-06-13
**Status:** Approved
**External docs required:** no

## Summary

A single command that bootstraps the **entire AI knowledge layer** for a large existing codebase that never had AI. It fans out analysis sub-agents over the code (each returning a distilled structured summary, never raw source), then drives the full brownfield Phase-1 chain: `architecture.md` + `docs/PRD.md` → `/maintain:refresh-brief` → `/setup:create-CLAUDE_MD`. Two human checkpoints guard the high-leverage moments (what to analyze, and validating the reconstructed PRD before it propagates).

## Problem

The template supports three adoption scenarios. **Scenario 3 (brownfield: huge existing app, no AI layer)** is blocked because none of our knowledge producers fit:

- `/setup:create-CLAUDE_MD` analyzes the codebase **inline in the main context** — it floods on a large repo.
- `/setup:createwikillm` is **ingest-driven** — chicken-and-egg: you must already understand the code to seed it.
- `/setup:create-PRD` assumes a **forward-looking conversation about intent** — a brownfield product already exists; there is nothing to "intend".

The missing piece is an **autonomous, scale-safe producer** that turns "10k+ files, no docs" into the complete AI layer (architecture map, PRD, brief, CLAUDE.md) — without requiring you to already know the code, and without overflowing context.

We evaluated the external tool **Understand-Anything** and rejected it as a dependency: its primary output (`knowledge-graph.json` + dashboard) is **human-facing**, while we need an **AI-facing** layer that `/prime` consumes cheaply (markdown). We keep only its architectural inspiration (parallel analyzers, role division, file-selection heuristics).

## Solution

`/setup:map-codebase` — a command that drives the whole brownfield Phase-1 bootstrap. It is the **interaction + sequencing layer**; the heavy parallel fan-out runs inside a `Workflow` script (Approach A — chosen for its hard concurrency cap, token budget, and deterministic structured-output pipeline).

**Core principle (this is what solves context flooding):** the parallel `module-analyzer` agents return **distilled, schema-validated summaries** (~1–2k each), **never raw file contents**. The aggregator holds only summaries, so codebase size scales the *number of agents*, not the aggregator's context.

**Division of labour (because `Workflow` is non-interactive):**
- **Command (main agent):** Phase 0 scan (deterministic bash), Checkpoint 1, launching the Workflow, Checkpoint 2, and the downstream cascade.
- **`Workflow` script:** Phases 1–3 — the parallel fan-out analysis + architecture synthesis + reverse-PRD synthesis. Returns the two artifacts; no interactive prompts inside it.

**Two human checkpoints** guard the high-leverage moments:
1. **After scan** — confirm scope: what will be analyzed, what is skipped and why, with include/exclude options and a recommended default. This is the cost/coverage decision.
2. **After PRD** — validate the reconstructed `docs/PRD.md` before the cascade, because `project-brief.md` and `CLAUDE.md` inherit its inferred-from-code guesses (code shows *what*, not *why*). A 30-second glance is cheap insurance for everything downstream.

The orchestrator **feeds**, does not replace, the existing producers — it writes `architecture.md` + `docs/PRD.md`, then orchestrates `/maintain:refresh-brief` and `/setup:create-CLAUDE_MD` as cascade steps.

**Resolved sub-decisions:**
- Agent prompts live **inline in the Workflow script** (single source of truth; YAGNI — extract to `.claude/agents/*.md` later only if reuse emerges).
- Reverse-PRD is a **phase of the same run** (it reuses the domain extraction the analyzers already produced).
- **No flags / no variants** — one invocation, whole repo. (Incremental re-analysis, path-scoping, and wiki seeding are explicitly out of scope.)
- Cascade is **automatic with the single PRD validation gate** between producing the PRD and propagating it.

## Architecture

Roles, realized as schema'd `agent()` calls inside `.claude/workflows/map-codebase.js`:

| Role | Where | Reads | Returns |
|------|-------|-------|---------|
| Scan & partition | command (deterministic bash) | file tree via `rg`/`git`, manifests, workspaces | module partition + per-module high-signal file lists + skip report |
| `module-analyzer` | Workflow (N parallel, capped) | one module's prioritized files (capped N/size) | schema'd `{module, purpose, keyFiles, publicAPI, deps, domainConcepts, dataModel, externalIntegrations, serviceInterface}` |
| `architecture-synthesizer` | Workflow (1, barrier) | **all module summaries** (not code) | `architecture.md` body — incl. `## Topology` (monolith/microservices/hybrid), `## Service & Integration Map` (Mermaid + external-integrations catalog) |
| `reverse-prd-writer` | Workflow (1) | `domainConcepts` across summaries | reconstructed PRD body |
| `data-model-synthesizer` | Workflow (1, only if persistence detected) | `dataModel` across summaries | `domain/data-model.md` body (entities, fields, relations) |
| `docs-analyzer` | Workflow (1, if docs/ADRs found) | README, `docs/`, ADRs, CONTRIBUTING | `{documentedDecisions, documentedPatterns, whyContext}` — the "why" |
| `infra-analyzer` | Workflow (1, if IaC found) | Terraform/k8s/Helm/compose/CI | `{hosting, environments, deployables, externalServices, infraNotes}` |

Scan/partition is deterministic bash (no LLM) — cheap, exhaustive. LLM agents are reserved for reading-and-distilling. Neither the Workflow body nor the command ever holds source files — only summaries.

**Integration seam:** map-codebase owns the scale-safe *analysis* and the Phase-1 *sequencing*; `/setup:create-CLAUDE_MD` keeps ownership of CLAUDE.md/README *generation* and consumes the produced `architecture.md` instead of re-analyzing inline; `/maintain:refresh-brief` consumes `docs/PRD.md` as it already does.

## Files

- **New:** `.claude/commands/setup/map-codebase.md` — the command: preconditions → Phase-0 scan → Checkpoint 1 → invoke Workflow → Checkpoint 2 → cascade → report. Follows the Loader Convention (does NOT re-load primed context).
- **New:** `.claude/workflows/map-codebase.js` — the Workflow orchestration script: `meta` + Phases 1–3 (`pipeline()`/`parallel()` with concurrency cap, `budget` guard, structured-output schemas). Returns the `architecture.md`, `docs/PRD.md`, and (when persistence is detected) `domain/data-model.md` bodies.
- **New (produced artifact):** `.agents/memory/domain/data-model.md` — consolidated DB schema (entities, key fields, relations) extracted from schema/model files; written only when persistence is detected, and pointed to from a `## Data Model` section in `architecture.md`.
- **Seeded at bootstrap:** `.agents/memory/decisions.md` (entries imported from ADRs, sourced) + `.agents/memory/patterns.md` (documented conventions, sourced) — appended newest-first when docs/ADRs are found. Infrastructure is folded into `architecture.md` (`## Infrastructure` + Service & Integration Map), not a separate file.
- **Modified:** `.claude/sync-from-starter.md` — add `.claude/workflows/*` to Category A (framework content, synced).
- **Modified:** `.claude/commands/setup/create-CLAUDE_MD.md` — note: on a very large repo this runs as the final cascade step of `/setup:map-codebase` and consumes the produced `architecture.md` rather than re-analyzing inline.
- **Modified:** `README.md` — daily-workflow table row + the Scenario-3 / brownfield path now points at `/setup:map-codebase` as the Phase-1 driver.

## External dependencies

None — all orchestration is internal, over the local filesystem, using the harness's own `Workflow`/`agent` primitives. Understand-Anything is NOT a dependency. No web research needed during planning.

## Data flow

1. User runs **`/setup:map-codebase`** (no args).
2. **Preconditions** — git repo; non-trivial size (else bail: "codebase is small — run `/setup:create-CLAUDE_MD` directly").
3. **Phase 0 — Scan & filter (command, deterministic — never an LLM):** enumerate NUL-safe via `git ls-files -z -co --exclude-standard` (fallback walk with hard-skip dirs); auto-generate + apply `.claude/map-codebase-ignore` (reviewed at Checkpoint 1); detect stack/workspaces/deployable-units; **categorize** every file (`code|config|docs|infra|data|script|markup`); route (code+schema→modules, docs→docFiles, infra→infraFiles); build a **coarse import graph + in-degree** → `isCore` hubs + high-in-degree prioritization; partition into capped modules; capture grounding (`readmeHead`, `entryPoint`); emit skip report.
4. **🛑 Checkpoint 1 — confirm scope (`AskUserQuestion`):** present modules-to-analyze + skip-list with reasons (e.g. "4,180 skipped — tests/generated/vendored"); offer include/exclude of categories or specific modules; **recommended default = the computed partition**. Wait for approval before spending tokens on fan-out.
5. **Phase 1 — Fan-out analysis (Workflow):** `pipeline`/`parallel` of `module-analyzer` agents (hard concurrency cap, ~20–30 files/batch), each capped on file count/size, returning the schema'd summary. In parallel, a `docs-analyzer` reads the discovered docs/ADRs (→ decisions, patterns, "why" context) and an `infra-analyzer` reads IaC/CI (→ hosting, environments, deployables, external services). Both are skipped if their file sets are empty.
6. **Phase 2 — Architecture synthesis (Workflow, barrier):** `architecture-synthesizer` reads all summaries → `architecture.md` body (source layout, module-roles table, **`## Topology`** = monolith/modular-monolith/microservices/hybrid with reasoning, **`## Service & Integration Map`** = a Mermaid diagram of internal service comms + external systems plus an external-integrations catalog table, layers, naming/conventions), matching `create-CLAUDE_MD`'s format, `status: populated`. Diagram marked "inferred — verify"; never fabricate a service/integration absent from the summaries.
7. **Phase 3 — Reverse-PRD (Workflow):** `reverse-prd-writer` synthesizes `domainConcepts` → PRD body, marked `Reconstructed from code — requires human validation`, with per-section confidence.
8. **Write artifacts:** command writes `.agents/memory/architecture.md` and `docs/PRD.md` (creating `docs/` if absent). Guard: if `docs/PRD.md` already exists, write `docs/PRD.reconstructed.md` instead and flag it. If `hasDataModel`, also write `.agents/memory/domain/data-model.md` (`status: populated`) and add a `## Data Model` pointer section to `architecture.md`; otherwise note "no persistence detected" in the report.
9. **🛑 Checkpoint 2 — validate PRD (gate):** present the architecture summary + `docs/PRD.md`; the user reviews/edits the PRD on disk; confirm to proceed. (Decline → stop here; the two artifacts persist.)
10. **Phase 4 — Cascade (command):** run **`/maintain:refresh-brief`** (PRD → `project-brief.md`, + `business-model.md` if pricing), then **`/setup:create-CLAUDE_MD`** (architecture → `CLAUDE.md` + README; asks its own git-workflow / language questions).
11. **Final report:** the complete Phase-1 layer produced (architecture.md, PRD.md, project-brief.md, CLAUDE.md, README); **loud** scanned/skipped stats; pointers to next steps (`/prime`, then the normal `/brainstorm → /plan-feature → /execute` cycle).

### File-selection heuristics (info-per-token; inspired by Understand-Anything)

- **SKIP:** tests (`*test*`, `*spec*`, `__tests__/`, `e2e/`), **migration history** (incremental `migrations/` files) and seeds, generated/vendored (`node_modules/`, `vendor/`, `dist/`, `build/`, `.next/`, `target/`, `*.min.*`, lockfiles, `*_pb2.py`, `*.generated.*`, codegen), framework boilerplate, assets/binaries.
- **PRIORITIZE:** entry points (`main`/`index`/`app`/`cmd/`), config/manifests, route/API/controller definitions, **schema/model definitions** (`schema.prisma`, `db/schema.rb`, ORM models/entities, consolidated DDL — read these, not migration history), domain models, and **high in-degree files** (most incoming imports = core).
- **No silent caps:** always `log()` how much was skipped/truncated — feed it into Checkpoint 1.

## Edge Cases

- **Monorepo / mixed-stack** → partition by workspace/package first; per-module language detection; analyzer adapts to the module's stack.
- **Module larger than the per-agent cap** → sub-batch within the module, or summarize top-N by in-degree with a **loud** truncation note (surfaced at Checkpoint 1).
- **Generated/vendored false-positives** → heuristics + `.gitignore` + optional project override `.claude/map-codebase-ignore`.
- **Trivial / small repo** → bail at preconditions: defer to `/setup:create-CLAUDE_MD`.
- **`docs/PRD.md` already exists** → do not clobber; write `docs/PRD.reconstructed.md` and flag it at Checkpoint 2.
- **Reverse-PRD low confidence** → explicit "reconstructed, validate me" marker + per-section confidence; Checkpoint 2 is the mandatory human gate before it propagates.
- **Token budget exceeded mid-fan-out** → stop and report which modules completed vs pending (no silent truncation); the user can re-run on the remaining scope.
- **Secrets** → analyzers honor the skip list + `settings.json` deny patterns; `.env*`/`*secret*`/`*credentials*` never read.
- **Analyzer agent returns null (died/skipped)** → re-queue once; if still null, mark the module unanalyzed in the report (loud).
- **Cascade step fails** (`refresh-brief` or `create-CLAUDE_MD`) → stop and report; `architecture.md` + `docs/PRD.md` are already persisted, so nothing is lost — the user re-runs the failed step manually.

## Out of Scope

- Human-facing visualization / dashboard / knowledge graph (Understand-Anything's territory).
- **Incremental re-analysis** and a hash manifest (dropped — every run is a full pass).
- **Path-scoping** and **`--seed-wiki`** flags (dropped — one invocation, whole repo; wiki stays a separate `/setup:createwikillm` concern).
- Runtime product-LLM wiki integration (`createwikillm` Scenario B).
- Replacing `/setup:create-CLAUDE_MD` or `/maintain:refresh-brief` — this feeds and sequences them.
- Auto-promoting the reconstructed PRD without the Checkpoint-2 human gate.
- Extracting agent prompts into standalone `.claude/agents/*.md` files (deferred; inline-in-script for v1).

## Borrowed practices (from Understand-Anything, source-reviewed)

Adopted (do NOT re-derive — these are battle-tested):
- **Deterministic scan, not LLM** — file enumeration/categorization is a script-level rule pass (cost + latency).
- **`git ls-files -z`** NUL-safe enumeration (unescaped emoji/CJK paths else silently dropped); hard-skip dirs in the walk fallback.
- **Auto-generated, review-gated ignore file** (`.claude/map-codebase-ignore`) seeded from `.gitignore` + detected dirs, `!`-negation.
- **Category taxonomy** `code|config|docs|infra|data|script|markup`, priority-ordered (specific→general) — drives routing to the analyzers.
- **Coarse import graph + in-degree** → `isCore` hub flagging + high-in-degree file prioritization; each `module-analyzer` receives its `imports`/`importedBy` neighbor context (the light `neighborMap` — module-level, no tree-sitter).
- **Grounding injection** — `readmeHead` + `entryPoint` passed into every analyzer so summaries align with the project's own narrative.
- **Worktree redirect** — write outputs to the main repo root, never an ephemeral worktree.
- **Determinism + per-file resilience + loud warnings; never silently drop errors.**

Deferred (follow-up specs): full tree-sitter import resolution + Louvain community batching + cross-batch symbol-level `neighborMap`; incremental re-analysis (commit-hash + changed-files + preserved scan manifest + structural fingerprints).

Rejected (out of scope): JSON knowledge graph, dashboard, guided tours, per-language/framework context files, hard dependency on `@understand-anything/core`.

## Open Questions

None — scope (no flags), the two checkpoints, direct `docs/PRD.md` creation, and the cascade target (`create-CLAUDE_MD`, not `create-PRD`) are all resolved above.
