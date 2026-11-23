---
description: Generate .agents/backlog.md — Epics and Tasks (user stories + technical tasks) with sizes M/H/XH, dependency DAG, Scope CORE / MUST / COULD (CORE first, then parallel sessions), developer work only with an outside-the-dev-backlog section, story map, and one Epic file per Epic with a one-line Summary per Task (acceptance criteria come from /setup:delivery-plan) — the delivery map the pipeline and /jira sync consume
argument-hint: "[path-to-prd | optional — defaults to docs/PRD.md]"
---

# Create Backlog: Operationalize the PRD into a Delivery Map

## Input: $ARGUMENTS

## What this produces — and why it is NOT the PRD

This command writes the backlog **structure**: `.agents/backlog.md` (the index — Epic map, Task table, story map, outside rows) and one Epic file per Epic, `.agents/backlog/E<n>-<slug>.md`, with a heading and a one-line `**Summary:**` per Task. It writes **no acceptance criteria and no Goal / scope lines** — `/setup:delivery-plan` details every Epic later. The backlog is the **planning source of truth** for delivery — a pipeline-steering meta-artifact, not another planning document and not a spec.

There are three levels of "what to build" in this template, and the backlog fills the gap between the other two:

| Level | Artifact | Scope | Read by |
|-------|----------|-------|---------|
| Product intent | `docs/PRD.md` (+ `docs/discovery.md`, `docs/architecture.md`) | *what & why*, ids `G-/R-/NFR-/BR-/FL-/AD-` | human, `/brainstorm` |
| **Delivery map** | **`.agents/backlog.md` + `.agents/backlog/E<n>-<slug>.md` ← this command** | *in what structure to ship it* — Epics, Tasks with sizes, DAG, `Scope` CORE / MUST / COULD (CORE first, then parallel sessions), developer work only, a Summary per Task; criteria come from `/setup:delivery-plan` | human, `/brainstorm` / `/quick-change` (per Task), `/jira sync` |
| Per-feature DAG | umbrella plan `## Execution Plan` | sub-steps of ONE Task (or a few) | `/orchestrate` |

The PRD says *what & why*. The backlog **operationalizes** it into Epics and Tasks with dependencies and sizes. It **does not** restate the PRD — it traces to its ids. Jira mirrors the backlog 1:1 via `/jira sync` (create-only) and, for synced Tasks, owns workflow status (umbrella D7: a Task with a `Jira` key takes its `Status` from Jira; without one the local cell is authoritative).

> **The backlog is the input to `/brainstorm`, not the output.** `/brainstorm` designs ONE Task (or an explicitly listed few); the backlog decides *which* Tasks exist, how big they are, what must be built first (`CORE`) before several sessions can work at once, and what is committed (`MUST`) or optional (`COULD`). Who builds what in which order is `/setup:delivery-plan`'s job.

<HARD-GATE>
This command produces a backlog — never code, never a spec, never a plan. Do NOT scaffold files, write implementation, or call `/brainstorm`, `/plan-feature`, `/quick-change` or `/jira`. It stops at `.agents/backlog.md` and the Epic files (plus the `backlog-check.mjs --write` gate on them). The backlog is **opt-in**: a project that never runs this command has an untouched pipeline.
</HARD-GATE>

---

## Where it sits in the pipeline

```
/discover → /architect → /maintain:refresh-brief → /prime → [/setup:create-backlog] → (/check-backlog) → (/setup:delivery-plan) → (/jira sync) → /brainstorm | /quick-change (per Task) → /plan-feature → /execute
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
   > "`.agents/backlog.md` already exists. It is a living artifact with Status/Ref/Jira filled in by the pipeline, and its Epic files in `.agents/backlog/` may already carry acceptance criteria — regenerating wholesale would discard that progress. To change the structure (new Epic, re-shaped DAG), edit the files directly and run `node .claude/lib/backlog-check.mjs --write`. Re-run me only to rebuild from scratch: that replaces `.agents/backlog.md` and every `.agents/backlog/E*.md` (never `.agents/backlog/delivery-plan.md`) — confirm you want that."
   Only regenerate if the user explicitly confirms.
4. Read `docs/discovery.md`, `docs/architecture.md` and `docs/map/system.yaml` when they exist. Missing ones are not an error: note each gap in "Open questions" (a missing discovery means no story map; a missing architecture means no `AD-n` traces and no `Node` cells).
5. **Architecture still a draft** (`docs/architecture.md` header carries `**Status:** draft` — `/architect`'s publication gate has not released it) → STOP, do not import its `AD-n` or nodes:
   > "`docs/architecture.md` is a draft — finish `/architect` first (or proceed without architecture by explicit user choice)."
   Only on that explicit choice continue as if the architecture were missing (no `AD-n` traces, no `Node` cells, the gap noted in "Open questions"). `backlog-check.mjs` enforces the same rule: it loads no `AD-n` from a draft and warns `docs/architecture.md is draft — AD ids not loaded`.

### Phase 1: Extract the raw material

From the PRD: `G-n` goals, `R-n` requirements (EARS), `NFR-n`, MVP scope (In / Out), implementation phases (the seed for Epics). From `docs/discovery.md`: the flows `FL-n` with their backbone activities `FL-n.Ak` — the flow marked `**Critical:** yes` is the story-map backbone — and the `BR-n` rules. From `docs/architecture.md` + `system.yaml`: the active `AD-n` decisions and the node ids (`trunk`/`branch`/`twig`/`leaf`/`root`) that Tasks will target. Only `active` ids are raw material — a register id (`G` `R` `NFR`) is history when the text right after its `**ID** — ` prefix is `(withdrawn…)` or `(superseded by …)`, when its table row's `Status` cell is `withdrawn…` / `superseded by …`, or — legacy forms — when a list line carries a bare `(withdrawn)` outside its quoted `Quote:` text, or a row of a table without a `Status` column carries `(withdrawn)` outside a quoted `Source` cell; the same words inside `Quote:` or a quoted `Source` cell are content, not state; an `AD-n` row with `Status` `withdrawn` or `superseded by AD-m` is likewise out. History gets no new Task (an existing Task may keep tracing a superseded requirement; the checker warns).

Also load, on demand (per `index.md` → When to Read), only the domain memory the backlog will reference — not the whole memory layer.

### Phase 2: Decide the structure yourself; ask only about directional forks

**Default to deciding, not asking** (same contract as `/brainstorm`). Derive Epics, Tasks, sizes, the DAG and each Task's `Scope` from the sources and state your assumptions. Reserve questions for the few genuine forks:

**Ask the user only when ALL hold:** the answer is not discoverable from PRD/discovery/architecture/memory, AND it is a directional decision (changes *what* ships first or *how the work decomposes*), AND getting it wrong is expensive to reverse.

Concretely, the forks worth a question here are usually:
- **The CORE boundary** — which Tasks must exist before several sessions can build at once. (Lead with your recommendation: "I'd make CORE: X, Y, Z — what must exist before several sessions can build at once — agree?")
- **The MUST / COULD line** where the PRD leaves a requirement optional.
- **Epic decomposition** when the PRD bundles independent subsystems and there's more than one reasonable cut.

Everything else (Task granularity, sizes, naming, the `Scope` of Tasks the sources settle) — decide and write the assumption into the backlog. One question per message, multiple choice via `AskUserQuestion`, lead with your pick. Zero questions is the right count for a PRD with an obvious critical flow and a clean phase breakdown.

### Phase 2.5: Hand the writing to `@backlog-author`

After the questions, the main session spawns `@backlog-author` once (pinned model; it writes, it does not ask). The spawn prompt carries:

| Input | Value |
|---|---|
| `SOURCES` | the resolved PRD path, `docs/discovery.md`, `docs/architecture.md`, `docs/map/system.yaml` — the ones that exist, plus the gaps Phase 0 noted |
| `ANSWERS` | the operator's answers from Phase 2 (and the assumptions you stated), verbatim |
| `METHOD` | `.claude/commands/setup/create-backlog.md` — Phases 3–6 |
| `OUTPUT` | `.agents/backlog.md` and `.agents/backlog/E<n>-<slug>.md`, one per Epic |

The agent follows Phases 3–6 below and returns the list of files written and its open questions. The main session then runs the Phase 7 gate. Errors — and the quality warnings of Phase 4.5 — go back to the same agent (`SendMessage`) with the checker output verbatim, at most twice; still red after that → the main session fixes the files itself. Agent unavailable (not installed, rate or usage limit, pinned model unavailable) → the main session writes Phases 3–6 itself, and the report says `**Author:** main session — @backlog-author unavailable`.

### Phase 3: What a Task is

The hierarchy is **Epic → Task**, nothing in between. A Task is one of two things:

| Type | What it is | Must carry |
|------|-----------|------------|
| `story` | one **user story** — "As a <role> I want <capability> so that <outcome>", traced to the `R-n` / `FL-n.Ak` / `G-n` it delivers | a `**Summary:**` line naming the outcome a user can observe |
| `tech` | one **technical task** — scaffold, schema, contract, refactor, spike — traced to the `AD-n` / `NFR-n` that demands it | a `**Summary:**` line naming the observable result; a spike's Summary names the decision it produces |

**Three relations, one order.** `Depends on` is the hard order (Jira `Blocks`). `Relates` is shared context without order (Jira `Relates`) — one relation per pair: a pair is either a dependency or a relation, never both. `Chain` is an advisory name for "one developer, these Tasks, in this order": its members are already one line in `Depends on`, share the Epic and the `Node`, and the order is the `Depends on` path, never the table order. A chain of small Tasks on one file set is usually one Task.

**Size every Task** `M` (4 pts) · `H` (8 pts) · `XH` (16 pts) — a currency for planning, not hours. Anything bigger than `XH` is **split**, in this order of preference (Humanizing Work's patterns): **workflow steps** (one step of the flow each) → **CRUD operations** → **business-rule variations** → **data variations** → **data-entry methods** → **major effort first, the rest later** → **simple core now, complex cases later** → **defer performance** (make it work, then make it fast as its own Task) → **spike** (last resort — a timeboxed `tech` Task whose output is a decision). Epic points are the sum of their Tasks' points; the checker enforces it.

**Every Task gets a one-line `**Summary:**`** in its Epic file — what the Task delivers, in the PRD's words, as an outcome a user or system can observe; no technical approach. **This command writes no acceptance criteria.** `/setup:delivery-plan` details each Epic later: Goal, In scope, Out of scope and criteria with ids `E<n>-<m>.AC<k>` (Gherkin or EARS), stable from then on — `/brainstorm` copies them into the spec, `/plan-feature` into the plan, `/qa-verify` keys its verdicts by them.

**Developer work only.** Tasks are what developers build: application code, including auth, sessions and RBAC (security *is* a feature here; it goes through `/brainstorm` like any other Task), logging and metrics calls, caching code, queue consumers, and performance work with a concrete deliverable in the code.

1. **Work another team delivers goes to `## Outside the dev backlog`, never to a Task** — CI/CD and deploy pipelines, environments, monitoring / alerting setup, test plans and QA execution, designs. Each is an `X-n` row: `Owner` (the team — DevOps, QA, Design, …), `Item`, `Needed by` (the Task ids that need it, or `—`), `Starts after` (the Task ids the item itself waits for — developer work that must be done before the other team can begin, e.g. the flow an end-to-end run exercises — or `—`), `Traces` (the `R-` / `NFR-` / `AD-` ids it delivers, or `—`), `Notes`. An outside row carries no points and no status and is never scheduled; the delivery plan prints the day its `Needed by` Tasks first start and the day its `Starts after` Tasks end. A requirement it traces counts as covered.
2. **`E0 Foundation` stays the first Epic, and its scaffold Task (`E0-1`) MUST be the first Task with no dependencies** — on greenfield it is the literal entry point that creates the project skeleton everything else stands on. E0 holds no CI/CD: the pipeline is an outside row. The HARD-GATE still holds: the backlog *describes* `E0-1`, it does not scaffold files — `E0-1` produces the skeleton later, when it runs through the pipeline like any other Task. (Brownfield exception: a mapped codebase already has a skeleton, so `E0-1` is "adopt/normalize existing scaffold" or omitted — record which.)
3. **Conditions one waits for stay OUTSIDE the DAG in `External blockers`**, not work you implement: a dependency security audit → *blocks release*; a pen-test → *blocks prod*; a legal/product decision → *blocks an Epic*. Record what each one gates ("Security audit → blocks E5+"). You don't "design and implement" an audit — you commission it and wait. An audit the team runs itself with a workflow command (`/audit-security`, `/seo-geo-audit`, `/wcag`) is not such a condition: it is a quality Task (Phase 4.5); only an audit commissioned from outside stays a blocker.

> If the PRD has a "Security & Configuration" or "Deployment" section, mine it here: application work becomes Tasks; work another team delivers becomes outside rows; sign-off-style items become external blockers.

### Phase 4: CORE first — the owner's rule, absolutely key

`CORE` is the project-specific pool of Tasks that must exist before many sessions can work at once: the `E0-1` scaffold, the shared data shapes and contracts other Tasks code against (a schema, an interface, an event schema, an API shape), and the one or two key capabilities everything hangs on.

1. **A CORE Task depends only on CORE Tasks** (checker error otherwise).
2. **Keep CORE sufficient** — after it, enough independent Tasks are ready for every session; `/setup:delivery-plan` measures it. **Keep CORE small** — every CORE Task delays the moment the team scales. A CORE Task nothing outside CORE depends on is not CORE (the checker warns).
3. **After CORE, cut for parallel work.** One Task per `Node` (bounded context / leaf of `system.yaml`) where possible, so two developers never edit the same module at the same time. **Contracts first:** when a producer and a consumer must both change, make the contract its own `tech` Task; it unblocks both sides to run in parallel. Prefer two `M` Tasks on different nodes over one `H` Task spanning both.
4. **`MUST` = committed scope, `COULD` = optional scope awaiting a decision.** A `MUST` Task never depends on a `COULD` Task (checker error). `Scope` is not an order inside a phase: Tasks with no mutual dependency run in parallel; encode every ordering need in `Depends on`.
5. **Each Epic carries its *why*** — **Outcome** (the product effect, traced to a `G-n` / PRD section) and **Key assumption** (the most load-bearing thing you're *not yet sure of*). One sentence each. Below the Epic map, each Epic also gets **appetite** (how much it is *worth* — the budget, not the estimate) and **cut first** (what drops first when the Epic grows). An AI agent has no "that's enough" instinct; the cut line is the hand-brake.
6. **The DAG is the only order.** `Chain` names a sequence for a human; nothing schedules by it. Encode a real ordering need in `Depends on`.

### Phase 4.5: Quality & upkeep — on every backlog

Every backlog plans the project's closing audits and its recurring upkeep as Tasks of one fixed
last Epic, `Quality & upkeep`, so they are sized, ordered and never forgotten. The markers,
sizes, applicability tests, cadence, placement, Summary lines and detail templates live in
[`.claude/skills/backlog/quality-tasks.md`](../../skills/backlog/quality-tasks.md) — read it and
apply it; do not restate it here. In short:

1. `[audit:security]` (`H`) and numbered occurrences of `[upkeep:architecture-review]` and
   `[upkeep:cleanup-workflow]` (`M`) are always planned; `[audit:seo-geo]` and `[audit:wcag]`
   (`H`) when the sources describe a public website / a user interface — otherwise one line each
   under `## Consciously out of scope` with the reason.
2. Every quality Task is `tech` · `MUST` · `Node` `—` · `Traces` `—` — the one Task a backlog
   writes without a source id: the reference is its source.
3. Order is `Depends on` only: a closing audit waits for every live `CORE`/`MUST` product Task;
   occurrence `k` of `n = max(2, ceil(P / 160))` waits for its share of the product points.
   A release outside row waits for the closing audits.
4. `backlog-check.mjs` checks the markers, sizes, audit waits and the occurrence count; on a
   fresh backlog its quality warnings are fixed like errors (Phase 2.5, Phase 7). Placement it
   does not check: after it passes, recompute `P`, `n`, the prefixes and their sinks yourself
   and send any occurrence whose `Depends on` differs back to the author with the errors.

### Phase 5: Story map

- **Backbone** = the `FL-n.Ak` activities of the critical flow(s), left to right. Every `story` Task that realises an activity traces it (`Traces: FL-1.A2`).
- **Every backbone activity of a critical flow is traced by a `CORE` or `MUST` Task.** A critical activity covered only by `COULD` Tasks (or by none) is a checker error.
- The story map's rows are the `Scope` values (`CORE`, `MUST`, `COULD`); the checker generates it.

### Phase 6: Write `.agents/backlog.md` and the Epic files

Create `.agents/` and `.agents/backlog/` if needed. Write `.agents/backlog.md` **exactly** in this structure — tables over prose, references over restatement. The header's `**Source PRD:**` is the path resolved in Phase 0; the marker-comment pair is mandatory and its body is generated in Phase 7 — never hand-write it. Sections not applicable to the project stay as a one-line "none" rather than disappearing, so readers and tooling find the same headings everywhere.

```markdown
# <Project> — Backlog (Epics + Tasks)
**Date:** YYYY-MM-DD · **Detail:** structure · **Source PRD:** `<resolved PRD path, default docs/PRD.md>` · **Scope rev:** `<the PRD's **Current:** version — omit this field when the PRD has none>` · **Architecture:** `docs/architecture.md` · **Jira namespace:** `<kebab slug>` · **Sizes:** M=4 · H=8 · XH=16 points (currency, not hours)
**Last check:** — (written by `/check-backlog`, always on its own line)

## Epic map
| Epic | Title | Outcome | Key assumption | Pts | Depends on | Jira |
|------|-------|---------|----------------|-----|------------|------|
| E0 | Foundation | … | … | 24 | — | — |
(each Epic below the table: `**E1** — appetite: … · cut first: …`)

## Task table
| ID | Epic | Task | Type | Size | Pts | Depends on | Relates | Chain | Scope | Node | Traces | Status | Jira | Ref |
|----|------|------|------|------|-----|------------|---------|-------|-------|------|--------|--------|------|-----|
| E0-1 | E0 | Project scaffold | tech | H | 8 | — | — | — | CORE | platform-core | AD-1 | TODO | — | — |
| E9-5 | E9 | [audit:security] Run /audit-security | tech | H | 8 | E3-4, E5-2 | — | — | MUST | — | — | TODO | — | — |

## Story map
<!-- storymap:begin -->
(generated by backlog-check --write)
<!-- storymap:end -->

## Outside the dev backlog
| ID | Owner | Item | Needed by | Starts after | Traces | Notes |
|----|-------|------|-----------|--------------|--------|-------|
| X-1 | DevOps | Deployment pipeline | E0-1 | — | NFR-1 | — |

## External blockers · ## Open questions · ## Consciously out of scope
(`## Consciously out of scope` also holds the rule-out line of a conditional audit, e.g. `- [audit:seo-geo] — no public website (PRD §2)`)
```

**Cell rules** (the checker enforces them): `Depends on` / `Traces` — comma-separated ids or `—`; `Relates` — Task ids or `—`, not itself, not a pair already in `Depends on` (either direction); `Chain` — a kebab token or `—`, members one linear `Depends on` path within one Epic and one `Node` (the two columns are optional for older backlogs — absent reads as `—`); `Type` `story|tech`; `Size` `M|H|XH`; `Pts` = size points; `Scope` `CORE|MUST|COULD`; `Node` a `system.yaml` node id or `—`; `Traces` — `G-/R-/NFR-/BR-/FL-n.Ak/AD-` ids from the sources (every active `R-`/`NFR-` must be traced by some Task or outside row); `Status` `TODO|WIP|DONE|BLOCKED`; `Jira` key or `—`; `Ref` spec/plan paths or `—`. Ids are case-sensitive and never renumbered. Outside rows: `ID` `X-n`; `Needed by` — Task ids or `—`; `Starts after` — Task ids or `—`, never closing a wait cycle: a Task waits for its `Depends on` Tasks and for the items that list it under `Needed by`, an item for its `Starts after` Tasks (so not a Task named in the row's own `Needed by`, nor one that depends on such a Task); `Traces` — active `R-`/`NFR-`/`AD-` ids or `—` (an active `R-`/`NFR-` traced only here counts as covered). The section is optional for the checker, but write it — with an empty table when nothing falls outside. The last three headings are separate `##` sections in the real file (one line each when empty). `**Detail:** structure` says the Epic files carry Summary lines only; `/setup:delivery-plan` sets it to `full` once every live Task has criteria.

Then write **one Epic file per Epic**, `.agents/backlog/E<n>-<slug>.md` — the slug is the Epic title in lowercase kebab-case ASCII (diacritics dropped, at most 40 characters, cut at a `-`), written once and never renamed; the file's identity is its `E<n>` prefix. Per Task: its heading and a one-line `**Summary:**`, in Task-table order, nothing else:

```markdown
# E0 — Foundation

## E0-1 — Project scaffold
**Summary:** <one line — what the Task delivers, in the PRD's words>
```

No `**Goal:**`, `**In scope:**` or `**Out of scope:**` lines and no acceptance-criteria subsection here — `/setup:delivery-plan` writes them. No `>` meta line either — `backlog-check.mjs --write` generates it under each Task heading from the table. A withdrawn Task keeps its block.

### Phase 7: Gate — `backlog-check.mjs --write`

```bash
node .claude/lib/backlog-check.mjs --write
```

Run from the project root. It reads the PRD path from the header written in Phase 6, the Epic files in `.agents/backlog/`, and `docs/discovery.md`, `docs/architecture.md`, `docs/map/system.yaml` when present; validates ids, the DAG, sizes, trace coverage, `Node` cells, the system tree and the Epic files (every live Task has its block in its Epic's file with a `**Summary:**` — under `**Detail:** structure` criteria may be missing, and any that exist are validated); then — only when there are **no errors** — fills the `storymap` marker region and the `>` meta line under each Task heading in the Epic files (ordering and parallel work are `/setup:delivery-plan`'s job). **Fix every error and rerun until it exits 0** — through `@backlog-author` first, as Phase 2.5 says. Quote every warning verbatim in the report — except the quality warnings (Phase 4.5): they go back to `@backlog-author` with the errors first, and only one still there after that is quoted — a warning is a judgment call for the human, not something to silence by editing the checker's input into shape. Never hand-edit the marker region or a `>` meta line; `--write` owns them. If the script is missing (a workflow older than this command) record `backlog: not validated — backlog-check.mjs missing` in the report and continue; that line is never dropped.

### Phase 7.5: Independent check — `/check-backlog` (recommended)

Offer `/check-backlog` now (`AskUserQuestion`: **run it now** (Recommended) / later): an independent
critic grades the judgement calls the checker cannot (CORE sufficiency and minimality, size
honesty, Summary quality, developer-only scope; in structure mode it defers the rules that grade criteria) and routes accepted fixes through `/update-backlog`, with its own approval gates.
Run → its verdict goes into the Phase 8 report as `**Check:** <verdict> (<D-n> if fixes were
applied)`; later → `**Check:** not run — /check-backlog before the first /jira draft`.

### Phase 8: Report

```markdown
## Backlog created

**Source PRD:** `<path>` · **Written:** `.agents/backlog.md` + <N> Epic files in `.agents/backlog/` · **Detail:** structure
**Author:** @backlog-author <or "main session — @backlog-author unavailable">
**Epics:** <N> · **Tasks:** <K> (<stories> story · <tech> tech) · **Points:** E0 <p> · E1 <p> · … · total <P>
**Scope:** CORE <T> Tasks / <p> pts · MUST <p> pts · COULD <p> pts
**Outside the dev backlog:** <N> rows (<owners>)
**Chains:** <token: E1-2 → E1-3 (12 pts), … — or "none">
**Quality & upkeep:** <E<n>> — audits <ids> · <n> occurrences of each recurring command (<P> product pts) · ruled out: <marker — reason, or "none">
**Check:** <verdict from Phase 7.5, or "not run — /check-backlog before the first /jira draft">
**backlog-check warnings:** <each one verbatim, or "none">

**Next steps:**
1. Review the backlog — correct the CORE boundary, the MUST / COULD line, sizes or DAG if you disagree (edit the file, then `node .claude/lib/backlog-check.mjs --write`).
2. `/check-backlog` (if Phase 7.5 did not run it) — the structure review.
3. `/setup:delivery-plan` — details the Epics (Goal, scope and acceptance criteria per Task) and computes who builds what in which order and how many working days it takes.
4. Jira project? `/jira sync` mirrors Epics and Tasks (create-only, writes keys back); a Task needs its criteria first.
5. Start the first Task: `/brainstorm <Task id>` for H/XH Tasks, `/quick-change <Task id>` for M Tasks. The size is a suggestion — the destination command's own guard decides (`/quick-change` Phase 0 may still send an `M` Task to `/brainstorm`).
   When a backlog exists, the pipeline writes `Status`/`Ref` back into it automatically.
```

Keep the report to this skeleton — add lines only for a blocker the user must act on (a missing source file, an unresolved fork), which is never compressed.

---

## Maintenance contract (how the backlog stays honest)

- **`Status`, `Ref` and `Jira` cells are written by the pipeline** — `/plan-feature` (Status → `WIP`, Ref → spec + plan), `/execute` and `/orchestrate` (Status → `DONE` per the whole-Task rule: only when no active plan still lists the Task), `/quick-change` (`DONE` on completion), `/brainstorm` Step 0 (read-only status refresh from Jira for Tasks with a key), `/jira sync` (keys) — **but only if `.agents/backlog.md` exists.** No backlog → those steps are silent no-ops. This is the *only* automation on the file's content; it is mechanical and safe.
- **Structural change (new Epic, new or re-sized Task, re-shaped DAG) goes through `/update-backlog`** (and `/check-backlog` through it): it previews every change, shows its impact, protects work in progress, records one `D-n` in the PRD change log and validates the candidate before writing. A hand edit stays allowed — then run `node .claude/lib/backlog-check.mjs --write`; the next `/update-backlog` (or the checker's `Scope rev` warning) surfaces it. No other automated step rewrites the DAG; that is how a backlog starts "pretending to be the truth".
- **Quality Tasks follow `.claude/skills/backlog/quality-tasks.md`.** `/update-backlog` keeps open closing audits waiting for new product work and the occurrence count in step with the product points; the checker warns when they drift.
- **Ids are append-only.** A removed Task keeps its row with `(withdrawn)` in the `Task` cell and `Status` `DONE` or `BLOCKED`; its block in the Epic file and its AC ids stay. The checker still validates its ids but leaves it out of the story map, the delivery plan and trace coverage. Jira issues are never deleted by the pipeline.
- The backlog is **short, tabular, referential**. If it grows narrative, it has drifted from its job — prune it back to tables + references.

## Notes

- Same language policy as the PRD (technical content in English per repo conventions).
- Do not invent content with no source. (Quality Tasks, Phase 4.5, are the one exception.) If a Task has no `R-`/`FL-`/`AD-` to trace, either the sources have a gap (record it in "Open questions") or the Task should not exist.
- This command does not call `/brainstorm`, `/quick-change`, `/plan-feature` or `/jira` — it only produces the map that feeds them.
