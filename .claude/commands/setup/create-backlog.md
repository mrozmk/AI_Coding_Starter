---
description: Generate .agents/backlog.md — the delivery map (epics + tasks + DAG + work packages) that operationalizes the PRD into pipeline inputs
argument-hint: "[path-to-prd | optional — defaults to docs/PRD.md]"
---

# Create Backlog: Operationalize the PRD into a Delivery Map

## Input: $ARGUMENTS

## What this produces — and why it is NOT the PRD

This command writes **one** artifact: `.agents/backlog.md`. It is a **pipeline-steering meta-artifact**, not another planning document and not a spec.

There are three levels of "what to build" in this template, and the backlog fills the gap between the other two:

| Level | Artifact | Scope | Read by |
|-------|----------|-------|---------|
| Product intent | `docs/PRD.md` → "Implementation Phases" | *what & why*, coarse phases, narrative | human, `/brainstorm` |
| **Delivery map** | **`.agents/backlog.md` ← this command** | *in what dependency structure to ship it* — epics, task IDs, DAG, work packages, waves, DoD | human, `/brainstorm` (per-WP scope) |
| Per-feature DAG | umbrella plan `## Execution Plan` | sub-steps of ONE work package | `/orchestrate` |

The PRD says *what & why* in prose. The backlog **operationalizes** the PRD's "Implementation Phases" into a dependency-structured inventory. It **does not** restate the PRD's narrative — it references it. The per-feature `## Execution Plan` (emitted later by `/plan-feature`) is a finer DAG *inside* one work package; the backlog is the DAG *across* work packages.

> **The backlog is the input to `/brainstorm`, not the output.** `/brainstorm` designs ONE work package; the backlog decides *which* work packages exist, in what order, with what dependencies. Each work package row literally tells you the `/brainstorm <topic> → spec → /plan-feature <spec>` invocation to run next.

<HARD-GATE>
This command produces a backlog — never code, never a spec, never a plan. Do NOT scaffold files, write implementation, or call `/brainstorm`/`/plan-feature`. It stops at `.agents/backlog.md`. The backlog is **opt-in**: a project that never runs this command has an untouched pipeline.
</HARD-GATE>

---

## Where it sits in the pipeline

```
/setup:create-PRD → /maintain:refresh-brief → [/setup:create-backlog] → /brainstorm (per work package) → /plan-feature → /execute
```

- **Greenfield:** run after the PRD exists. The backlog records architectural **assumptions** and open questions itself (it sets the *order of discovery*, it does not wait for full architecture to be designed).
- **Brownfield (existing codebase):** run `/setup:map-codebase` **first** (it reconstructs `architecture.md` + a PRD). A DAG over an un-mapped codebase would be guesswork.

Run it **before** full architecture is designed but **after** the PRD: the backlog's job is to sequence discovery and planning, not to close the design.

---

## Process

### Phase 0: Locate the PRD and guard the output

> **Loader Convention.** This command assumes `/prime` already loaded `CLAUDE.md`, `index.md`, `project-brief.md`, `architecture.md`. Do **not** re-read those "for context". The PRD is this command's **source-of-truth for transformation** — read it directly (like `/maintain:refresh-brief` does). If context isn't primed, ask the user to run `/prime` first.

1. **Resolve the PRD path:** `$ARGUMENTS` if it points to an existing `.md`, otherwise `docs/PRD.md`.
2. **PRD missing** → STOP, do not write anything:
   > "PRD not found at `<path>`. Run `/setup:create-PRD` first (greenfield), or `/setup:map-codebase` (existing codebase — it reconstructs a PRD), then rerun `/setup:create-backlog`."
3. **Backlog already exists** (`.agents/backlog.md` present and non-empty) → STOP and ask, do not silently overwrite:
   > "`.agents/backlog.md` already exists. It is a living artifact with Status/Ref filled in by the pipeline — regenerating wholesale would discard that progress. To change the structure (new epic, re-shaped DAG), edit it directly. Re-run me only to rebuild from scratch — confirm you want that."
   Only regenerate if the user explicitly confirms.

### Phase 1: Read the PRD and extract the raw material

Read the PRD **in full**. Pull, in priority order:

- **MVP Scope** (In Scope / Out of Scope) → the MVP sub-graph and the "Consciously out of scope" section.
- **Implementation Phases** → the seed for **epics** (each phase ≈ one or more epics; do not copy the prose, distill it into the epic map).
- **User Stories** → candidate tasks and their natural grouping into work packages.
- **Technology Stack / Architecture** → constraints that force ordering ("X must exist before Y").
- **Success Criteria** → input to per-epic **Definition of Done**.

Also load, on demand (per `index.md` → When to Read), only the domain memory the backlog will reference — do not load the whole memory layer. If `architecture.md` has `status: empty` (greenfield, not yet mapped), proceed on PRD alone and record the architectural unknowns in "Open questions".

### Phase 2: Decide the structure yourself; ask only about directional forks

**Default to deciding, not asking** (same contract as `/brainstorm`). Derive epics, work packages, the DAG, and the MVP boundary from the PRD and state your assumptions. Reserve questions for the few genuine forks:

**Ask the user only when ALL hold:** the answer is not discoverable from PRD/memory, AND it is a directional decision (changes *what* ships first or *how the work decomposes*), AND getting it wrong is expensive to reverse.

Concretely, the forks worth a question here are usually:
- **The MVP boundary** — which slice is the first milestone. (Lead with your recommendation: "I'd scope MVP to X because it's the thinnest end-to-end proof; Y and Z defer — agree?")
- **Epic decomposition** when the PRD bundles independent subsystems and there's more than one reasonable cut.

Everything else (task granularity, wave assignment, naming, difficulty sizing) — decide and write the assumption into the backlog. One question per message, multiple choice via `AskUserQuestion`, lead with your pick. Zero questions is the right count for a PRD with an obvious MVP and a clean phase breakdown.

### Phase 2.5: What a task IS — the abstraction level (read before building the DAG)

A backlog task sits at **one specific altitude**: a **coherent unit of technical delivery, roughly the size of one work package** — not a business requirement, not a single function. This is the line that keeps the backlog distinct from the PRD above it and the spec below it:

| Artifact | Language | Example |
|----------|----------|---------|
| PRD | business / product | "As a user I want to log in" (a User Story) |
| **Backlog task** | **technical, coarse-grained** | `E2-1 Auth: JWT login + refresh token` |
| Spec (from `/brainstorm`) | technical, detailed | the *how*: endpoints, token schema, edge cases |

The backlog **translates** the PRD's "what & why" into "in what structure to deliver it". So:

- ✅ A task is a **deliverable chunk of engineering work** — "Auth: JWT login + refresh", "Billing: Stripe webhook + idempotency", "Data layer: `.csv → DataFrame` adapter". `/brainstorm` later takes the whole work package and designs the *how*.
- ❌ **Not a User Story** ("as a user I want X") — that lives in the PRD; copying it here makes the backlog a second, drifting copy of the PRD.
- ❌ **Not an implementation detail** ("add `validateToken()` helper") — that's the spec/plan's job.
- The right granularity test: *"Is this one coherent thing I'd hand to one `/brainstorm` cycle?"* If it's three unrelated things → split into three tasks (maybe three work packages). If it's half a function → it's too small; fold it into its parent task.

**Cross-cutting concerns — security, infrastructure, observability, performance — belong in the backlog, two distinct ways:**

1. **As normal epics/tasks in the DAG** when they are *deliverable work* the pipeline will build:
   - `E0 Infra` — CI/CD, deploy pipeline, project scaffold (usually the **first** epic — everything stands on it).
   - `E2 Auth` — login, sessions, RBAC (security *is* a feature here; it goes through `/brainstorm` like any other WP).
   - `E4 Observability` — logging, metrics, alerting.
   - Performance work with a concrete deliverable (a caching layer, a query-optimization pass) — a normal task.
2. **As gates / external blockers OUTSIDE the DAG** when they are a *condition*, not work you implement:
   - Security audit of dependencies → *blocks release*. Pen-test → *blocks prod*. A legal/product decision → *blocks a phase*.
   - These are not tasks (you don't "design and implement" an audit — you commission it and wait). Record them in an **"External blockers"** section with what each one gates (e.g. "Security audit → blocks E5+"), exactly as a reference build's port would.

The split keeps the backlog honest: the DAG holds what you push through the pipeline; the blockers hold what conditions *when* an epic can close. A `/brainstorm` on any work package handles that feature's own security / perf / edge-case detail at the feature's altitude — the backlog only needs the cross-cutting concerns that have **project-wide ordering or gating** significance.

> If the PRD has a "Security & Configuration" or "Deployment" section, mine it here: deliverable items (auth model, config system, deploy target) become epics/tasks; sign-off-style items (audit, compliance review) become external blockers.

### Phase 3: Build the DAG

- **Epics** = coarse milestones from the PRD phases. Order them by dependency, not by PRD listing order.
- **Tasks** = concrete units under each epic, each with an ID (`E0-1`, `E1-2`, …) — at the altitude defined in Phase 2.5 (a deliverable chunk, not a User Story, not a one-liner).
- **`Dependencies` is the source of truth for the DAG** — fill it precisely (which task IDs must complete first). Get this right; everything else is derived.
- **`Wave` (a.k.a. order/priority) is NOT a total order** — it is a priority band. **Duplicate wave numbers are intentional**: tasks in the same wave with no mutual dependency can run in parallel. Never encode the DAG in the wave column; encode it in `Dependencies`.
- **Work packages** group tasks into coherent themes. **One work package = one `/brainstorm` → one spec → one `/plan-feature`.** A task ID does **not** map 1:1 to a command invocation — a work package does. Each WP row carries the exact pipeline entry to run.
- **MVP is a sub-graph, not a linear list.** Identify the thinnest set of tasks that proves the product end-to-end, draw their dependency graph, and define DoD as a **fan-in** of specific task IDs (e.g. "DoD = E1-1b AND E2-5"), not "all MVP tasks done".
- **Each epic carries its *why* (Outcome + Key assumption).** A backlog generated once from a PRD easily keeps the *how* (tasks) but loses the *why* — and an AI agent picking up a work package weeks later will turn an unvalidated assumption into a confident-sounding task. So every epic gets two short fields: **Outcome** (the product effect / whose problem it solves, traced to the PRD) and **Key assumption** (the most load-bearing thing you're *not yet sure of*). The assumption field is an explicit "don't-know-yet" marker the agent can see. Adapted from Torres's opportunity→outcome→assumption mapping and Cagan's discovery/delivery split; it is also the backlog's backward-traceability (why does this exist?). One sentence each — not a discovery essay.
- **Every work package must pass a readiness check (mini-INVEST) before it enters the pipeline.** Not the full six criteria — the three that actually save the AI flow:
  - **Independent** — runnable without waiting on another WP (or the dependency is explicit in the DAG).
  - **Small** — closeable in *one* `/brainstorm → spec → /plan-feature` cycle. If it's three unrelated things ("login + password reset + 2FA"), split into three WPs.
  - **Testable** — there is a concrete "done" criterion, so the agent knows when to stop.

  This guards **scope creep**, the concrete failure mode of AI agents — given "Auth", an agent will happily build login + reset + 2FA + OAuth + audit log in one pass because "it all fits Auth". The readiness check forces atomicity *before* the pipeline runs. This matters more than story points: points size the work, readiness checks whether it's *one coherent thing*. (Bill Wake's INVEST, used here as a per-WP gate, not a team Definition of Ready.)
- **Every work package declares an appetite + cut-lines (bounded scope).** Three lines per WP:
  - **Appetite** — how much this WP is *worth* (not "how long it takes" — that's an estimate; appetite is the budget you're willing to spend). Coarse: e.g. "small — it's a foundation, not a differentiator".
  - **No-go (now)** — what you deliberately exclude from this WP for now.
  - **Cut first** — what gets dropped *first* if the WP turns out too big, in priority order.

  Where the readiness check guards size *on entry*, appetite/cut-lines guard size *during the work*. An AI agent has no innate "that's enough — we shipped 80% of the value" instinct; it will polish forever or pile on edge cases nobody asked for. The cut-line is an explicit hand-brake: "if this grows, drop X first, then Y." (Basecamp's Shape Up — "fixed time, variable scope": work must be *bounded*, with explicit exclusions and a cut order.)

### Phase 4: Generic core vs domain adapters

The backlog has a **universal core** that every project needs, and **optional domain adapters** that only some projects need. Emit the core always; add an adapter **only** when the project's nature calls for it — do not force a greenfield app to invent a taxonomy that only makes sense for a legacy port.

**Universal core (always):** epic map (each epic with **Outcome + Key assumption**) · task inventory with IDs · dependency DAG · waves · work packages as pipeline inputs (each with a **readiness check** + **appetite / no-go / cut-first**) · MVP as a sub-graph · DoD per epic · critical path · open questions · consciously-out-of-scope · Status + Ref columns.

**Optional domain adapters (add only when relevant):**

| Adapter | Add when… | Shape |
|---------|-----------|-------|
| **Layer / type tag** (e.g. `[R]`/`[X]`/`[I]`, or `frontend`/`backend`/`infra`) | tasks split cleanly into layers that gate testability or ownership | extra `Type` column + a short "Layer classification" legend |
| **Reference source / oracle** | porting or migrating from an existing build whose behavior is the ground truth | a "Reference build" line in the header + a per-task "validate against" note |
| **Parity / fidelity gate** | correctness is defined as matching a reference (port, re-implementation, golden fixtures) | a fidelity epic + DoD phrased as measured error below a threshold |
| **Index / cross-reference** | heavy domain detail lives in `.agents/memory/domain/*` and must not be duplicated in the backlog | a "Skorowidz / Index" table pointing to the domain files (backlog references, never copies) |

When you add an adapter, say in one line *why* (so a reader knows it was deliberate). When you don't, the core stands alone — that is the common case.

### Phase 5: Write `.agents/backlog.md`

Create `.agents/` if needed (it exists in this template). Write the file with this structure. Keep it **short, tabular, referential — not narrative**. Tables over prose; reference the PRD/memory, do not restate them.

```markdown
# <Project> — Backlog (Epics + Tasks)

**Date:** YYYY-MM-DD · **Status:** draft pending acceptance · **Source PRD:** `docs/PRD.md`
<!-- optional adapter: **Reference build:** `path/to/legacy` -->

> **What this is:** the delivery map — how the PRD ships as a dependency-structured set of work
> packages, MVP first. It does NOT restate the PRD; it operationalizes its "Implementation Phases".
> Scope for slash commands comes from "Work packages" below, NOT from individual task IDs.

## Base assumptions (decided — see `.agents/memory/decisions.md`)

- <architectural / stack assumptions the backlog rests on; the forks you resolved yourself>

<!-- optional adapter (port/migration only): ## Layer classification — [R]/[X]/[I] legend -->

<!-- optional adapter: ## Index — where the source inventory lives (domain memory), referenced not copied -->

## Epic map (delivery order)

| Epic | Title | Outcome (why — traced to PRD) | Key assumption to validate | Depends on | Why in this order |
|------|-------|-------------------------------|----------------------------|------------|-------------------|
| **E0** | <foundation> | <product effect / whose problem> | <the most load-bearing unknown> | — | <everything stands on this> |
| **E1** | … | … | … | E0 | … |

## Work packages — pipeline inputs

> **Source of truth for command scope.** The Task table below is the inventory + DAG (what exists,
> what depends on what) — NOT a "how to run it" map. One *work package* = one coherent theme = one
> `/brainstorm` → one spec → one `/plan-feature`. Each WP carries a **readiness check** (is it ready to
> enter the pipeline?) and an **appetite + cut-lines** (is its scope bounded?) directly below the table.

| Package | Task scope | Depends on | Entry (how to run) | Status |
|---------|-----------|-----------|--------------------|--------|
| **MVP-CORE** | E0-1, E0-3, … | — | `/brainstorm <topic> → spec → /plan-feature <spec>` | TODO |

**MVP-CORE** — readiness: ✓ Independent (DAG deps only) · ✓ Small (one cycle) · ✓ Testable (<concrete done criterion>)
- Appetite: <small / medium — what it's worth, not how long it takes>
- No-go (now): <what this WP deliberately excludes>
- Cut first: <what gets dropped first if it grows too big, in order>

<!-- repeat the readiness + appetite block for every work package -->

## Task table (inventory + DAG — take command scope from "Work packages" above)

> **`Wave` = priority band, NOT total order** — duplicates are intentional (same-wave tasks may run in
> parallel). **The DAG's source of truth is the `Dependencies` column.** **Status:** `TODO` · `WIP` ·
> `DONE` · `BLOCKED`. **Ref:** spec from `/brainstorm` + plan from `/plan-feature` — filled when the task
> enters design/planning (the pipeline writes this back when a backlog exists).

| ID | Epic | Task | Description | Dependencies | Difficulty | Type | Wave | Status | Ref |
|----|------|------|-------------|--------------|------------|------|------|--------|-----|
| E0-1 | Foundation | … | … | — | S | <core/—> | 1 | TODO | — |

## ★ MVP (first milestone)

**Goal:** <thinnest end-to-end proof>. **DoD = <fan-in of specific task IDs, e.g. E1-1b AND E2-5>.**

    <dependency graph of the MVP tasks — NOT a linear chain; show parallel branches and the fan-in,
     as an indented code block or a fenced block in the actual backlog file>

> Which tasks are independent (parallel) vs which fan in to the DoD.

## Definition of Done — per epic

- **E0** — <observable completion criterion, from PRD Success Criteria>
- **E1** — …

## Critical path (TL;DR ordering)

    E0 → E1 → E2 → …

## External blockers (gates outside the DAG)

> Conditions you don't *implement* but must *pass* — security audit, pen-test, a legal/product
> sign-off, an external dependency. Each one names what it gates. Omit the section if there are none.

- **<blocker>** — gates <epic/phase> (e.g. "Dependency security audit → blocks E5+ (anything that ships to prod)")

## Open questions

- <unresolved directional decisions, architectural unknowns deferred to their epic's threshold>

## Consciously out of scope

- <what the PRD's "Out of Scope" plus your own YAGNI calls exclude, and why>
```

### Phase 6: Report

Output a short summary:

```markdown
## Backlog created

**Source PRD:** `<path>`
**Written:** `.agents/backlog.md` — <N> epics, <M> work packages, <K> tasks

**MVP:** <one-line scope> · DoD = <fan-in>
**Adapters used:** <none / layer tag / reference build / …>

**Next steps:**
1. Review the backlog — correct the MVP boundary or DAG if you disagree (edit the file directly).
2. Start the first work package: `/brainstorm <topic from the first MVP work package row>`.
   Brainstorm writes a spec to `.agents/specs/`; `/plan-feature` then writes a plan. **When a backlog
   exists, those commands write `Ref`/`Status` back into it automatically** (no-op if you skip the backlog).
```

---

## Maintenance contract (how the backlog stays honest)

- **`Ref` + `Status` are written back automatically** by `/plan-feature` (Status → `WIP`, Ref → spec) and `/orchestrate` (Status → `DONE`, Ref → spec + plan) — **but only if `.agents/backlog.md` exists.** No backlog → those steps are silent no-ops. This is the *only* automation; it is mechanical and safe.
- **Structural change (new epic, re-shaped DAG, re-scoped work package) is a deliberate, manual edit** — edit `.agents/backlog.md` by hand. Do not let an automated step rewrite the DAG; that is how a backlog starts "pretending to be the truth". (A dedicated `/maintain:update-backlog` for guided structural edits is a possible future addition — out of scope here.)
- The backlog is **short, tabular, referential**. If it grows narrative, it has drifted from its job — prune it back to tables + references.

## Notes

- Same language policy as the PRD (technical content in English per repo conventions).
- Do not invent content with no PRD source. If a section has no basis, record the gap in "Open questions" rather than fabricate tasks.
- This command does not call `/brainstorm` or `/plan-feature` — it only produces the map that feeds them.
