---
description: Generate .agents/backlog.md — Epics and Tasks (user stories + technical tasks) with sizes M/H/XH, dependency DAG, sequential foundation + parallel lanes for 2–4 developers, story map with walking skeleton, and acceptance criteria with ids — the delivery map the pipeline and /jira sync consume
argument-hint: "[path-to-prd | optional — defaults to docs/PRD.md]"
---

# Create Backlog: Operationalize the PRD into a Delivery Map

## Input: $ARGUMENTS

## What this produces — and why it is NOT the PRD

This command writes **one** artifact: `.agents/backlog.md`. It is the **planning source of truth** for delivery — a pipeline-steering meta-artifact, not another planning document and not a spec.

There are three levels of "what to build" in this template, and the backlog fills the gap between the other two:

| Level | Artifact | Scope | Read by |
|-------|----------|-------|---------|
| Product intent | `docs/PRD.md` (+ `docs/discovery.md`, `docs/architecture.md`) | *what & why*, ids `G-/R-/NFR-/BR-/FL-/AD-` | human, `/brainstorm` |
| **Delivery map** | **`.agents/backlog.md` ← this command** | *in what structure to ship it* — Epics, Tasks with sizes, DAG, waves, lanes, slices, AC ids | human, `/brainstorm` / `/quick-change` (per Task), `/jira sync` |
| Per-feature DAG | umbrella plan `## Execution Plan` | sub-steps of ONE Task (or a few) | `/orchestrate` |

The PRD says *what & why*. The backlog **operationalizes** it into Epics and Tasks with dependencies and sizes. It **does not** restate the PRD — it traces to its ids. Jira mirrors the backlog 1:1 via `/jira sync` (create-only) and, for synced Tasks, owns workflow status (umbrella D7: a Task with a `Jira` key takes its `Status` from Jira; without one the local cell is authoritative).

> **The backlog is the input to `/brainstorm`, not the output.** `/brainstorm` designs ONE Task (or an explicitly listed few); the backlog decides *which* Tasks exist, how big they are, in what order, and who can work on them at the same time.

<HARD-GATE>
This command produces a backlog — never code, never a spec, never a plan. Do NOT scaffold files, write implementation, or call `/brainstorm`, `/plan-feature`, `/quick-change` or `/jira`. It stops at `.agents/backlog.md` (plus the `backlog-check.mjs --write` gate on that file). The backlog is **opt-in**: a project that never runs this command has an untouched pipeline.
</HARD-GATE>

---

## Where it sits in the pipeline

```
/discover → /architect → /maintain:refresh-brief → /prime → [/setup:create-backlog] → (/jira sync) → /brainstorm | /quick-change (per Task) → /plan-feature → /execute
```

- **Greenfield:** run after `/discover` and `/architect`. The backlog traces every Task to the ids they produced; where architecture is still open it records the assumption and keeps going.
- **Brownfield (existing codebase):** run `/setup:map-codebase` **first** (it reconstructs `architecture.md` + a PRD). A DAG over an un-mapped codebase would be guesswork.

---

## Process

### Phase 0: Locate the inputs and guard the output

> **Loader Convention.** This command assumes `/prime` already loaded `CLAUDE.md`, `index.md`, `project-brief.md`, `architecture.md`. Do **not** re-read those "for context". The PRD, `docs/discovery.md`, `docs/architecture.md` and `docs/map/system.yaml` are this command's **sources of truth for transformation** — read them directly, in full, when present (like `/maintain:refresh-brief` does). If context isn't primed, ask the user to run `/prime` first.

1. **Resolve the PRD path:** `$ARGUMENTS` if it points to an existing `.md`, otherwise `docs/PRD.md`. The resolved path is written into the backlog header (`**Source PRD:**`) — `backlog-check.mjs` reads it from there.
2. **PRD missing** → STOP, do not write anything:
   > "PRD not found at `<path>`. Run `/discover` first (greenfield), or `/setup:map-codebase` (existing codebase — it reconstructs a PRD), then rerun `/setup:create-backlog`."
3. **Backlog already exists** (`.agents/backlog.md` present and non-empty) → STOP and ask, do not silently overwrite:
   > "`.agents/backlog.md` already exists. It is a living artifact with Status/Ref/Jira filled in by the pipeline — regenerating wholesale would discard that progress. To change the structure (new Epic, re-shaped DAG), edit it directly and run `node .claude/lib/backlog-check.mjs --write`. Re-run me only to rebuild from scratch — confirm you want that."
   Only regenerate if the user explicitly confirms.
4. Read `docs/discovery.md`, `docs/architecture.md` and `docs/map/system.yaml` when they exist. Missing ones are not an error: note each gap in "Open questions" (a missing discovery means no story map; a missing architecture means no `AD-n` traces and no `Node` cells).
5. **Architecture still a draft** (`docs/architecture.md` header carries `**Status:** draft` — `/architect`'s publication gate has not released it) → STOP, do not import its `AD-n` or nodes:
   > "`docs/architecture.md` is a draft — finish `/architect` first (or proceed without architecture by explicit user choice)."
   Only on that explicit choice continue as if the architecture were missing (no `AD-n` traces, no `Node` cells, the gap noted in "Open questions"). `backlog-check.mjs` enforces the same rule: it loads no `AD-n` from a draft and warns `docs/architecture.md is draft — AD ids not loaded`.

### Phase 1: Extract the raw material

From the PRD: `G-n` goals, `R-n` requirements (EARS), `NFR-n`, MVP scope (In / Out), implementation phases (the seed for Epics). From `docs/discovery.md`: the flows `FL-n` with their backbone activities `FL-n.Ak` — the flow marked `**Critical:** yes` is the story-map backbone — and the `BR-n` rules. From `docs/architecture.md` + `system.yaml`: the active `AD-n` decisions and the node ids (`trunk`/`branch`/`twig`/`leaf`/`root`) that Tasks will target. Withdrawn ids (`(withdrawn)` on the line, `Status` `withdrawn` or `superseded by AD-m`) are never traced.

Also load, on demand (per `index.md` → When to Read), only the domain memory the backlog will reference — not the whole memory layer.

### Phase 2: Decide the structure yourself; ask only about directional forks

**Default to deciding, not asking** (same contract as `/brainstorm`). Derive Epics, Tasks, sizes, the DAG and the walking skeleton from the sources and state your assumptions. Reserve questions for the few genuine forks:

**Ask the user only when ALL hold:** the answer is not discoverable from PRD/discovery/architecture/memory, AND it is a directional decision (changes *what* ships first or *how the work decomposes*), AND getting it wrong is expensive to reverse.

Concretely, the forks worth a question here are usually:
- **The walking-skeleton boundary** — which Tasks form slice `WS`. (Lead with your recommendation: "I'd make `WS` the thinnest end-to-end path through `FL-1` — X, Y, Z; W defers to `R2` — agree?")
- **Epic decomposition** when the PRD bundles independent subsystems and there's more than one reasonable cut.

Everything else (Task granularity, sizes, wave assignment, naming, slices) — decide and write the assumption into the backlog. One question per message, multiple choice via `AskUserQuestion`, lead with your pick. Zero questions is the right count for a PRD with an obvious critical flow and a clean phase breakdown.

### Phase 3: What a Task is

The hierarchy is **Epic → Task**, nothing in between. A Task is one of two things:

| Type | What it is | Must carry |
|------|-----------|------------|
| `story` | one **user story** — "As a <role> I want <capability> so that <outcome>", traced to the `R-n` / `FL-n.Ak` / `G-n` it delivers | ≥1 happy-path AC **and** ≥1 unwanted-behaviour AC (the failure, the forbidden action, the empty state) |
| `tech` | one **technical task** — scaffold, schema, contract, infrastructure, refactor, spike — traced to the `AD-n` / `NFR-n` that demands it | ≥1 AC stating the observable result; a spike's AC is the decision it produces |

**Size every Task** `M` (4 pts) · `H` (8 pts) · `XH` (16 pts) — a currency for planning, not hours. Anything bigger than `XH` is **split**, in this order of preference (Humanizing Work's patterns): **workflow steps** (one step of the flow each) → **CRUD operations** → **business-rule variations** → **data variations** → **data-entry methods** → **major effort first, the rest later** → **simple core now, complex cases later** → **defer performance** (make it work, then make it fast as its own Task) → **spike** (last resort — a timeboxed `tech` Task whose output is a decision). Epic points are the sum of their Tasks' points; the checker enforces it.

**Every Task gets acceptance criteria with ids** `E<n>-<m>.AC<k>`, written as Gherkin (`Given … When … Then …`) or EARS (`WHEN … the system shall …`). These ids are stable: `/brainstorm` copies them into the spec, `/plan-feature` into the plan, `/qa-verify` keys its verdicts by them. Never renumber — a dropped criterion keeps its id with `(withdrawn)`.

**Cross-cutting concerns — security, infrastructure, observability, performance — belong in the backlog, two distinct ways:**

1. **As normal Epics/Tasks in the DAG** when they are *deliverable work* the pipeline will build:
   - `E0 Foundation` — CI/CD, deploy pipeline, project scaffold. **MUST be the first Epic, and its scaffold Task (`E0-1`) MUST be the first Task with no dependencies** — on greenfield it is the literal entry point that creates the project skeleton the whole `WS` stands on. The HARD-GATE still holds: the backlog *describes* `E0-1`, it does not scaffold files — `E0-1` produces the skeleton later, when it runs through the pipeline like any other Task. (Brownfield exception: a mapped codebase already has a skeleton, so `E0-1` is "adopt/normalize existing scaffold" or omitted — record which.)
   - Auth, sessions, RBAC — security *is* a feature here; it goes through `/brainstorm` like any other Task.
   - Logging, metrics, alerting; performance work with a concrete deliverable (a caching layer, a query pass).
2. **As gates / external blockers OUTSIDE the DAG** when they are a *condition*, not work you implement: a dependency security audit → *blocks release*; a pen-test → *blocks prod*; a legal/product decision → *blocks an Epic*. Record them in **External blockers** with what each one gates ("Security audit → blocks E5+"). You don't "design and implement" an audit — you commission it and wait.

> If the PRD has a "Security & Configuration" or "Deployment" section, mine it here: deliverable items become Tasks; sign-off-style items become external blockers.

### Phase 4: Parallel-first decomposition — the owner's rule, absolutely key

Tasks are cut so that **2, 3 or 4 developers can work at the same time**. Not always possible — but it is the planning default everywhere it is.

1. **Wave 0 = only what must be sequential.** `E0-1` scaffold first; then the schema, the auth skeleton, the contracts other Tasks code against (an interface, an event schema, an API shape). Wave-0 Tasks form one sequential chain — a Wave-0 Task never depends on a later wave (checker error). Keep Wave 0 as small as honesty allows: every Task you put there is a Task nobody can parallelize.
2. **After Wave 0, cut for parallel lanes.** One Task per `Node` (bounded context / leaf of `system.yaml`) where possible, so two developers never edit the same module in the same wave. **Contracts first:** when a producer and a consumer must both change, make the contract its own `tech` Task; it unblocks both sides to run in parallel. Prefer two `M` Tasks on different nodes over one `H` Task spanning both.
3. **Avoid two same-wave Tasks on one `Node`.** The checker warns when two Tasks in the same wave share a `Node` and land in different lanes — sequence them (dependency) or split the node.
4. **`Wave` is a priority band, not a total order.** Duplicate wave numbers are intentional: same-wave Tasks with no mutual dependency run in parallel. Never encode the DAG in the wave column; encode it in `Depends on` — the checker derives the lanes from the DAG and the points, not from the waves.
5. **Each Epic carries its *why*** — **Outcome** (the product effect, traced to a `G-n` / PRD section) and **Key assumption** (the most load-bearing thing you're *not yet sure of*). One sentence each. Below the Epic map, each Epic also gets **appetite** (how much it is *worth* — the budget, not the estimate) and **cut first** (what drops first when the Epic grows). An AI agent has no "that's enough" instinct; the cut line is the hand-brake.

### Phase 5: Story map and slices

- **Backbone** = the `FL-n.Ak` activities of the critical flow(s), left to right. Every `story` Task that realises an activity traces it (`Traces: FL-1.A2`).
- **`WS` (walking skeleton)** = the thinnest set of Tasks that covers **every** backbone activity of every critical flow end-to-end — plus the Wave-0 foundation it needs. A critical activity with no `Slice: WS` Task is a checker error: the skeleton has a gap.
- **Later slices** `R2`, `R3`, … are outcome-tied releases (each named by the `G-n` it moves), not leftovers.
- **Slices ≠ waves.** A slice says *what ships together*; a wave says *who builds what when*. A `WS` Task can sit in Wave 2; an `R2` Task can sit in Wave 1 if it unblocks something.

### Phase 6: Write `.agents/backlog.md`

Create `.agents/` if needed (it exists in this template). Write **exactly** this structure — tables over prose, references over restatement. The header's `**Source PRD:**` is the path resolved in Phase 0; the two marker-comment pairs are mandatory and their bodies are generated in Phase 7 — never hand-write them. Sections not applicable to the project stay as a one-line "none" rather than disappearing, so readers and tooling find the same headings everywhere.

```markdown
# <Project> — Backlog (Epics + Tasks)
**Date:** YYYY-MM-DD · **Source PRD:** `<resolved PRD path, default docs/PRD.md>` · **Architecture:** `docs/architecture.md` · **Jira namespace:** `<kebab slug>` · **Sizes:** M=4 · H=8 · XH=16 points (currency, not hours)

## Epic map
| Epic | Title | Outcome | Key assumption | Pts | Depends on | Jira |
|------|-------|---------|----------------|-----|------------|------|
| E0 | Foundation | … | … | 24 | — | — |
(each Epic below the table: `**E1** — appetite: … · cut first: …`)

## Task table
| ID | Epic | Task | Type | Size | Pts | Depends on | Wave | Slice | Node | Traces | Status | Jira | Ref |
|----|------|------|------|------|-----|------------|------|-------|------|--------|--------|------|-----|
| E0-1 | E0 | Project scaffold | tech | H | 8 | — | 0 | WS | platform-core | AD-1 | TODO | — | — |

## Acceptance criteria
### E0-1 — Project scaffold
- **E0-1.AC1** — Given … When … Then …

## Story map
<!-- storymap:begin -->
(generated by backlog-check --write)
<!-- storymap:end -->

## Parallel plan
<!-- lanes:begin -->
(generated by backlog-check --write)
<!-- lanes:end -->

## External blockers · ## Open questions · ## Consciously out of scope
```

**Cell rules** (the checker enforces them): `Depends on` / `Traces` — comma-separated ids or `—`; `Type` `story|tech`; `Size` `M|H|XH`; `Pts` = size points; `Wave` integer, `0` = sequential foundation; `Slice` `WS|R2|R3…`; `Node` a `system.yaml` node id or `—`; `Traces` — `G-/R-/NFR-/BR-/FL-n.Ak/AD-` ids from the sources (every active `R-`/`NFR-` must be traced by some Task); `Status` `TODO|WIP|DONE|BLOCKED`; `Jira` key or `—`; `Ref` spec/plan paths or `—`. Ids are case-sensitive and never renumbered. The last three headings are separate `##` sections in the real file (one line each when empty).

### Phase 7: Gate — `backlog-check.mjs --write`

```bash
node .claude/lib/backlog-check.mjs --write
```

Run from the project root. It reads the PRD path from the header written in Phase 6 and `docs/discovery.md`, `docs/architecture.md`, `docs/map/system.yaml` when present; validates ids, the DAG, sizes, AC ids, trace coverage, `Node` cells and the system tree; then — only when there are **no errors** — fills the `storymap` and `lanes` marker regions (foundation chain, lanes for N = 2, 3, 4 with makespan and critical path). **Fix every error in the file and rerun until it exits 0.** Quote every warning verbatim in the report — a warning is a judgment call for the human, not something to silence by editing the checker's input into shape. Never hand-edit the marker regions; `--write` owns them. If the script is missing (a workflow older than this command) record `backlog: not validated — backlog-check.mjs missing` in the report and continue; that line is never dropped.

### Phase 8: Report

```markdown
## Backlog created

**Source PRD:** `<path>` · **Written:** `.agents/backlog.md`
**Epics:** <N> · **Tasks:** <K> (<stories> story · <tech> tech) · **Points:** E0 <p> · E1 <p> · … · total <P>
**Walking skeleton (WS):** <T> Tasks, <p> pts — <one line: the flow it proves>
**Makespan after foundation:** N=2 → <p> pts · N=3 → <p> pts · N=4 → <p> pts (foundation <p> pts, sequential)
**backlog-check warnings:** <each one verbatim, or "none">

**Next steps:**
1. Review the backlog — correct the WS boundary, sizes or DAG if you disagree (edit the file, then `node .claude/lib/backlog-check.mjs --write`).
2. Jira project? `/jira sync` mirrors Epics and Tasks (create-only, writes keys back).
3. Start the first Task: `/brainstorm <Task id>` for H/XH Tasks, `/quick-change <Task id>` for M Tasks.
   When a backlog exists, the pipeline writes `Status`/`Ref` back into it automatically.
```

Keep the report to this skeleton — add lines only for a blocker the user must act on (a missing source file, an unresolved fork), which is never compressed.

---

## Maintenance contract (how the backlog stays honest)

- **`Status`, `Ref` and `Jira` cells are written by the pipeline** — `/plan-feature` (Status → `WIP`, Ref → spec + plan), `/execute` and `/orchestrate` (Status → `DONE` per the whole-Task rule: only when no active plan still lists the Task), `/quick-change` (`DONE` on completion), `/brainstorm` Step 0 (read-only status refresh from Jira for Tasks with a key), `/jira sync` (keys) — **but only if `.agents/backlog.md` exists.** No backlog → those steps are silent no-ops. This is the *only* automation on the file's content; it is mechanical and safe.
- **Structural change (new Epic, new or re-sized Task, re-shaped DAG) is a deliberate, human edit** — edit `.agents/backlog.md` by hand, then run `node .claude/lib/backlog-check.mjs --write` so the lanes and story map follow. Do not let an automated step rewrite the DAG; that is how a backlog starts "pretending to be the truth".
- **Ids are append-only.** A removed Task keeps its row with `(withdrawn)` in the `Task` cell and `Status` `DONE` or `BLOCKED`; its AC ids stay. The checker still validates its ids but leaves it out of lanes, the story map and trace coverage. Jira issues are never deleted by the pipeline.
- The backlog is **short, tabular, referential**. If it grows narrative, it has drifted from its job — prune it back to tables + references.

## Notes

- Same language policy as the PRD (technical content in English per repo conventions).
- Do not invent content with no source. If a Task has no `R-`/`FL-`/`AD-` to trace, either the sources have a gap (record it in "Open questions") or the Task should not exist.
- This command does not call `/brainstorm`, `/quick-change`, `/plan-feature` or `/jira` — it only produces the map that feeds them.
