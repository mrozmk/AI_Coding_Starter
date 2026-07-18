---
description: Run a multi-step plan end-to-end — execute → refine → verify → design-check → commit → push, looping fixes until passed, escalating only on blockers
argument-hint: "<path-to-plan> [--resume] [--from <step-id>] | --integrate <orch-id>..."
---

# /orchestrate — Pipeline Runner

You are the orchestrator. Your job is to take a plan (single or multi-step umbrella) and drive it end-to-end through a fixed pipeline, delegating to specialized sub-agents, looping on fixable gaps, escalating to the user only on real blockers.

You are running as the user's interactive session (typically your most capable model — e.g. Opus). You do **not** implement code, audit code, or commit code — those are sub-agent jobs. You **decide**, **route**, **loop**, **report**. The one git action you DO perform yourself is `git push` (Step 5.4b) — because the push authorization lives in your main session and does not transfer to sub-agents.

## Input

`$ARGUMENTS` = `<plan-path> [flags]`

Flags:

- `--resume` — continue an interrupted run by reading umbrella status; pick up at first non-`done` step
- `--from <step-id>` — start at a specific step id (e.g. `3b1`), treating earlier steps as already done
- `--integrate <orch-id>...` — **not a build run.** Skip the whole pipeline and run the supervised **Integration mode** merge queue (below): bring the listed parallel run-branches onto `main`, one at a time, each merge prompting once. Run once from a clone on `main` after all parallel builds finish. Mutually exclusive with a plan path.
- `--sync-docs` — after the pipeline completes, run `documentation-manager` to sync `README` / `docs/` for the whole feature and push a final `docs:` commit (Phase 7, step 5). Off by default; even when set it only acts if the changed files actually touched documented surface (public API, CLI, setup, architecture, a user-facing feature).

## Phase 0: Resolve mode + plan

1. **Integration mode (`--integrate`)** — if `$ARGUMENTS` begins with `--integrate` followed by one or more branch ids (`orch-<id> …`, NOT a `.md` path), skip the whole build pipeline and jump to **Integration mode** (below). **Parse this before the "pass a plan path" error in step 3** — an `--integrate` invocation carries branch ids, not a plan path.
2. Else if `$ARGUMENTS` is a path to an `.md` file under `.agents/plans/active/` → use it as the plan; continue to Phase 1.
3. Else stop and tell user: `Pass a plan path: /orchestrate .agents/plans/active/<plan>.md` — or run the merge queue: `/orchestrate --integrate orch-a orch-b …`.
4. Read the plan file fully.

## Phase 1: Detect plan type

Check the file for the heading `## Execution Plan`.

- **Found** → umbrella plan with multi-step DAG. Go to Phase 2. Umbrella steps run in **worktree mode** (each step gets its own worktree + named branch, merged onto `main` by ff-only — see Step 5.0b / 5.4b).
- **Not found** → single atomic plan. Run **one pipeline cycle** for this file (skip DAG handling, single iteration of Phase 3-7). Use `STEP_ID = "atomic"` in sub-agent prompts. An atomic plan runs in **flat mode**: no worktree, no branch, no merge — the executor and committer work directly in the main checkout and the orchestrator pushes `main`, exactly like `/commit` + `/push`. There is only one step, so the worktree isolation that umbrella mode needs (accumulating fix iterations, keeping `main` advancing only via ff-merge) buys nothing here — it only adds a worktree/branch/merge round-trip that can fail to fast-forward. Flat mode skips Steps 5.0b, the merge half of 5.4b, and the worktree-retire half of 5.5 (those steps below are explicitly marked **umbrella-only**).

> **This starter's defaults (read before first use):**
> - `/plan-feature` emits **single-file plans** (no `## Execution Plan` table), so they run in **flat mode** — which works out of the box. **Umbrella mode** (multi-step DAG + worktrees) requires you to **hand-author** a `## Execution Plan` table (columns `Step | File | Depends On | Status`, optional `Model`); there is no generator for it in this template yet.
> - The **design check (Step 5.3)** runs the `orchestrator-designer` agent + `gates:design-quality-check` skill (both shipped, stack-neutral). It **auto-skips** whenever `.agents/specs/design/Ready/` is absent (the default), so projects without UI pay nothing. To enable it: create `.agents/specs/design/Ready/` and drop your reference design artifact(s) there.

## Phase 2: Parse Execution Plan table (umbrella only)

Locate the markdown table under `## Execution Plan`. Required columns: `Step`, `File`, `Depends On`, `Status`. Optional column: `Model`.

For each row, extract `(step_id, file_path, depends_on_list, status, model)`. Build a DAG.

**`Model` column (optional):** if present, its value is the model to spawn the executor with for that step — one of `sonnet` | `opus` | `haiku` (lowercase). It overrides the executor agent's default model (`claude-sonnet-4-6`) at spawn time via the `Agent` tool's `model` parameter. If the column is absent, or a row's cell is empty / `—`, the executor runs on its default (`sonnet`). Note: only the model is selectable per-step — `effort` and `fast` are NOT per-spawn-overridable through the `Agent` tool (they are fixed in an agent's own definition), so the plan only carries a model, not an effort level.

**Validation (fail fast):**

- Every `File` entry must exist on disk under the umbrella's directory.
- Every `Depends On` id must reference an existing Step in the same table (or `—` / empty).
- No circular dependencies (topological sort must succeed).
- `Status` must be one of `pending | in_progress | done | blocked | skipped | manual`.
- If `Model` column present, each non-empty cell must be one of `sonnet | opus | haiku` (or `—`).

If validation fails → emit error to user with specifics, STOP. Do not silently proceed.

## Phase 3: Compute execution order

Topological sort respecting `Depends On`. Sequential execution (no parallel branches in MVP — even when DAG allows it).

**`manual` status — human-only steps.** A step marked `manual` in the plan is one the plan author flagged as not automatable (e.g. an external form submission, a wp-env screenshot capture, anything needing interactive login or human judgment). The orchestrator does NOT spawn any sub-agent for a `manual` step. When the execution order reaches one, STOP and report to the user:

```
⏸ Step <id> is `manual` — not automatable by the pipeline.
  <one-line reason pulled from the step's plan file, e.g. "WP.org form submission requires your login">
  Do it yourself, then resume with: /orchestrate <umbrella> --resume
```

A `manual` step is treated as a hard pause, NOT a skip: downstream steps that depend on it stay blocked until you complete it and re-run `--resume`. (If you want the pipeline to treat it as already-satisfied and continue past it, mark it `done` or `skipped` yourself before resuming.)

Filter:

- `--resume` → start at first step whose status is not `done` (or `skipped`). A `manual` step still pauses the run when reached (resume past it only after you mark it `done`/`skipped`).
- `--from <id>` → start at that step id, assume earlier steps are done (do NOT auto-mark them)
- otherwise → start at first `pending` step

If all steps are `done` or `skipped` → emit "All steps complete. Run complete." and STOP. (A remaining `manual` step is NOT "complete" — it pauses per above.)

## Phase 4: Resolve target branch + capture upstream SHA

Once at the start of the run.

**Resolve `TARGET_BRANCH` (this run's push target):**

```bash
git rev-parse --abbrev-ref HEAD   # → TARGET_BRANCH (e.g. main, or orch-<id> in a parallel run)
```

Substitute the **literal** branch name into every command below wherever `<TARGET_BRANCH>` appears — do NOT rely on a shell variable, each command runs in a fresh shell (`push.md:9`).

- If the output is literal `HEAD` → **detached HEAD**. STOP: "Detached HEAD — checkout a branch before /orchestrate." (`push.md:10-11`.)
- **On `main` (the single-run default) everything below is byte-for-byte today's behavior.** On an `orch-<id>` branch (a parallel run — see [.agents/reference/parallel-orchestration.md](../../.agents/reference/parallel-orchestration.md)) per-step work pushes to `origin/<TARGET_BRANCH>`; the results are brought onto `main` later by the supervised **Integration mode** (`--integrate`, below).
- **Build-log slug:** for the OS-global `/tmp` build-log path (shared even across separate clones), use `TARGET_SLUG` = `<TARGET_BRANCH>` with every `/` replaced by `-`. The runbook mandates `orch-<id>` (no slash), but this keeps a single run on a slashy branch like `feat/x` safe.

**Capture the upstream SHA:**

```bash
git fetch origin "<TARGET_BRANCH>"
git rev-parse "origin/<TARGET_BRANCH>"
```

Store as `EXPECTED_UPSTREAM_AT_START`. This is informational — the committer does not enforce it; user convention is "no manual pushes to the run branch during /orchestrate" (per project decision).

- **New-branch fallback (`push.md:15`):** if `git rev-parse "origin/<TARGET_BRANCH>"` fails because the branch does not exist on the remote yet (the first build run on a fresh `orch-<id>`), record `EXPECTED_UPSTREAM_AT_START = none` instead of erroring.

### Phase 4b — Open a durable run-log (NOT /tmp)

Create (or append to, on `--resume`) a run-log next to the plan so the run's state survives a restart and gives `--resume` a real source of truth beyond the Status column. **Never use `/tmp` for this** — `/tmp` is wiped on restart and the trail is lost.

- Umbrella plan → `RUN_LOG = .agents/plans/active/<umbrella>.run.md`
- Flat/atomic plan → `RUN_LOG = .agents/plans/active/<plan>.run.md`

Append to `RUN_LOG` as the run progresses (one entry per step is enough): step id, the model spawned, the parsed sub-agent reports (verdict/status lines + any blockers/gaps), the Step 5.1-recon result, and each pushed `COMMIT_SHA`. This is a log you write with the Write/Edit tool, not a sub-agent artifact. In Phase 7 it moves to `done/` alongside the plan.

**Run-log contract — friction records (feeds central reflection).** The base entries above (verdicts/gaps/SHAs) are enough for `--resume`, but they are NOT enough for the **central** memory reflection that Integration mode runs from the merged run-logs — in a parallel run the build clones no longer reflect first-person (they skip Phase 7 steps 6–7). So on **every friction iteration** — a verifier/designer fix loop, a Phase 6 user-guided retry, or a designer mega-fix — also append a structured record:

```
- ITERATION <n> (step <id>): {gap | blocker}
  ROOT_CAUSE: <why it failed — from the executor's NOTES on the fix re-spawn>
  APPLIED_CHANGE: <what the fix changed — from the executor's NOTES>
  OUTCOME: <resolved | still-failing | escalated>
  USER_GUIDANCE: <verbatim, when this was a Phase 6 option-1 retry — else omit the line>
  MEMORY_CANDIDATE: <one line the reflection pass might keep — else omit the line>
```

Also record, **once per run**, the backlog **work-package id + source `Ref`** this plan delivers (read from the plan header / `.agents/backlog.md`), so the central backlog write-back knows which WP to mark `DONE`. A clean iteration (passed first try) writes NO friction record — only the base step entry. Central reflection consumes THESE records, not the bare verdict lines.

## Phase 5: Step loop

For each step `(step_id, file_path)` in topological order, run the pipeline below. Update the umbrella `## Execution Plan` table **before and after** each step (Edit tool, in-place).

### Step 5.0 — Read the step file, then mark step in progress

**Read the step's `file_path` in full (Read tool) before doing anything else with this step.** You cannot delegate or reconcile a scope you never read — the root-cause failure this guardrail exists to prevent was the orchestrator fabricating `FILES_TOUCHED` paths because it never opened the plan. Reading the step gives you the real target paths the plan declares, which you cross-check against the executor's report in Step 5.1. Cost: one Read per step; it removes the space in which the orchestrator can invent what a step touches.

(Phase 2 already asserts the umbrella's `File` entries exist on disk; this step reads the content. For a flat/atomic plan there is no umbrella table — read the resolved plan file here.)

Then edit the umbrella's `## Execution Plan` table: change this step's `Status` from `pending` to `in_progress`.

### Step 5.0b — Create the step's persistent worktree — **umbrella-only**

**Flat mode (atomic plan): skip the worktree creation — but FIRST run the clean-tree preflight.** Flat mode works directly in the main checkout, with no worktree isolation. So any file the user already had uncommitted in the main checkout sits in the same tree the executor/refiner will touch — and because the Step 5.1b re-derive sweeps **every** dirty path into `FILES_TOUCHED`, an unrelated pre-existing change would be committed under this step's subject (the exact cross-session pollution `/commit` guards against). To prevent that, capture a baseline BEFORE the executor runs:

```bash
git -C "<repo-root>" status --porcelain   # FLAT_BASELINE — paths already dirty before this step
```

- **If `FLAT_BASELINE` is non-empty** → STOP and escalate (Phase 6): "Flat-mode run requires a clean main checkout, but these files are already modified/untracked: <list>. Commit, stash, or revert them first, then re-run." Do NOT proceed — there is no worktree to isolate the step's work from theirs. (Alternatively the user may explicitly accept the risk via Phase 6 guidance; default is to refuse.)
- **If clean** → record `FLAT_BASELINE` as empty, set `STEP_WORKTREE` to the main checkout (the repo root, i.e. the orchestrator's own working directory), and proceed to Step 5.1. There is no branch, no worktree to create or retire.

In **umbrella mode** there is no baseline concern — each step gets its own fresh worktree — so skip the preflight and create the worktree below.

**Umbrella mode: one worktree per step, reused across every fix iteration of that step.** This is the fix for the worktree-isolation data-loss class: if each executor spawn got a fresh checkout, fix iterations would not accumulate and the committer could stage an incomplete result.

```bash
WT=".claude/worktrees/step-<step_id>"
# Create the worktree on a NAMED branch step-<step_id> rooted at current main.
# A named branch (not detached HEAD) makes the later ff-merge in 5.4b deterministic:
# `git merge --ff-only step-<step_id>` always succeeds when main has not moved,
# so the pipeline never has to fall back to cherry-picking a loose SHA.
git worktree add -b "step-<step_id>" "$WT" HEAD 2>/dev/null \
  || git worktree add "$WT" "step-<step_id>" 2>/dev/null \
  || echo "worktree already exists, reusing"
```

Store `WT` (absolute path) as `STEP_WORKTREE` and `step-<step_id>` as `STEP_BRANCH`. Pass `WORKTREE_PATH` to the executor on the initial run AND on every fix-iteration re-spawn (Steps 5.2 / 5.3 loops). Pass the same path to the committer (5.4a) as its working directory. Do not create a new worktree per fix iteration.

If `git worktree add` fails for a reason other than "already exists" (e.g. dirty path), retry once after `git worktree prune`; on second failure, escalate as a blocker. If the branch `step-<step_id>` already exists from a prior interrupted run, the second form (`git worktree add "$WT" "step-<step_id>"`) reattaches the existing branch to the worktree.

### Step 5.1 — Execute

Spawn `@orchestrator-executor`. If this step has a `Model` value in the Execution Plan table (`opus` / `haiku` / `sonnet`), pass it as the `Agent` tool's `model` parameter so the executor runs on that model — it overrides the agent's default (`claude-sonnet-4-6`). If the step has no `Model` cell (or `—`), omit the parameter and the executor runs on its default.

Prompt:

```
PLAN_PATH: <file_path>
STEP_ID: <step_id>
WORKTREE_PATH: <STEP_WORKTREE>
Execute this plan per the `execute` skill in the given worktree. Report via the Executor Output Contract.
```

(Agent call: `model: <step's Model value>` when the column gives one. The model choice is the plan author's per-step judgment — heavy schema/UI/concurrency steps get `opus`, mechanical 1:1 steps get `sonnet`/`haiku`.)

Parse the `=== EXECUTOR REPORT ===` block from the agent's output.

- `STATUS: blocked` → mark step `blocked` in umbrella table, escalate to user with the `BLOCKERS:` list. Phase 5 stops.
- `STATUS: completed` → keep `FILES_MODIFIED + FILES_CREATED` as `FILES_TOUCHED` for downstream agents. **Then run the ground-truth reconciliation below before continuing to Step 5.2.**

#### Step 5.1-recon — Ground-truth reconciliation (orchestrator, mandatory, before verify)

This is the gate that closes the root-cause failure class: the executor (or you) claiming files/locations that do not match what git actually shows. Run it yourself — do NOT trust the report's self-description.

```bash
# Re-derive the facts independently, in the SAME working dir the step used
# (umbrella: $STEP_WORKTREE; flat: repo root).
git -C "<workdir>" rev-parse --show-toplevel   # ACTUAL_TOPLEVEL
git -C "<workdir>" status --porcelain           # ACTUAL_STATUS
```

Two assertions, both fail-closed (any failure → mark step `blocked`, escalate per Phase 6, STOP — do NOT proceed to verify):

1. **Worktree assertion (closes "executor ignored the worktree").** The report's `WORKDIR_TOPLEVEL` MUST equal `ACTUAL_TOPLEVEL`, AND in umbrella mode `ACTUAL_TOPLEVEL` MUST equal `$STEP_WORKTREE` (flat mode: the repo root). A mismatch means the executor worked in the wrong tree — its edits are not where the committer will look.
2. **Path reconciliation (closes "fabricated FILES_TOUCHED").** Every path in `FILES_MODIFIED + FILES_CREATED` MUST appear in `ACTUAL_STATUS`. A reported path that git does not see as changed is a **hallucination signal**. This is the exact moment the failed run should have stopped — instead it pushed past it. Do not continue on a single unreconciled path.

Only when both assertions pass do you carry `FILES_TOUCHED` to Step 5.2.

**On every fix-iteration re-spawn of the executor** (from Steps 5.2 / 5.3), pass the SAME `WORKTREE_PATH: <STEP_WORKTREE>` AND the SAME `model` as the initial spawn so the fix runs on the model the step was designed for. Re-run Step 5.1-recon after every re-spawn — a fix iteration can drift the same way the first pass can.

### Step 5.1b — Quality refinement (review + deep-review)

Runs on **every** step, after execution reconciles clean (5.1-recon) and before the verifier gate (5.2). This is where the pipeline applies the same `code-review → deep-review` passes that `/check-implementation` runs standalone — fixing correctness bugs and applying structural cleanups *before* the independent gate judges the result. The verifier (Step 5.2) stays read-only, so the **fixer** (refiner) and the **judge** (verifier) are always different agents — the gate never grades its own work.

This step is not a loop: the refiner runs **once** per step. The verifier's fix iterations (5.2) are correctness-only and handled by the executor — re-refining on every fix iteration is deliberately not done (it would re-spend `code-review`/`deep-review` tokens on the bulk of the code that is already clean).

Spawn `@orchestrator-refiner` with the executor's working directory (flat mode: repo root; umbrella mode: `$STEP_WORKTREE`):

```
PLAN_PATH: <file_path>
STEP_ID: <step_id>
WORKTREE_PATH: <STEP_WORKTREE>
FILES_TOUCHED:
<list from Step 5.1>
Refine these files per the refiner protocol: /code-review --fix (correctness), then /deep-review (structural cleanup — apply high-conviction findings). Do NOT verify, commit, or push. Report via the Refiner Output Contract.
```

Parse the `=== REFINER REPORT ===` block.

| Status      | Action                                                                       |
| ----------- | ---------------------------------------------------------------------------- |
| `completed` | Re-derive `FILES_TOUCHED` + re-reconcile (below), then go to Step 5.2.       |
| `blocked`   | Mark step `blocked`, escalate with the `BLOCKERS:` list. STOP.               |

**Re-derive `FILES_TOUCHED` + re-reconcile (mandatory).** `/deep-review` can touch a file the executor never reported (e.g. a shared util it refactored). So after the refiner returns, recompute the touched set from ground truth and re-run the Step 5.1-recon path reconciliation against the refiner's report:

```bash
git -C "<workdir>" status --porcelain   # ACTUAL_STATUS after refinement
```

Set `FILES_TOUCHED` = the union of the executor's list and **every** path in this `ACTUAL_STATUS` — **in flat mode, MINUS any path in `FLAT_BASELINE`** (the files that were already dirty before this step started, per Step 5.0b). This subtraction is the safety net: the preflight should already have refused a dirty flat checkout, but if the user accepted the risk via Phase 6, never let a pre-existing user change ride into this step's commit just because it shares the tree. (Umbrella mode has no baseline — the worktree started clean — so the union stands as-is.) Then re-run the Step 5.1-recon assertions (worktree-toplevel match + every path in the refiner's `FILES_MODIFIED`/`FILES_CREATED` appears in `ACTUAL_STATUS`); on any failure, mark the step `blocked` and escalate. The committer (5.4a) stages this updated `FILES_TOUCHED`, so a deep-review-touched file dropped here would be silently left out of the commit — re-deriving is what prevents that.

Record the refiner's `NEEDS_HUMAN` notes in the run-log. They are **informational, not blockers** — the verifier gate decides. If the verifier later blocks, include them in the escalation context (a defect the refiner flagged as needs-decision is often the same one the gate trips on).

### Step 5.2 — Verify (loop up to 3 iterations)

Spawn `@orchestrator-verifier` **with the step's working directory** (flat mode: repo root; umbrella mode: `$STEP_WORKTREE`) so it audits the code the step actually produced — in umbrella mode that code lives ONLY in the worktree until Step 5.4b merges it onto `main`; a verifier run in the repo root would audit a stale main without this step's changes:

```
PLAN_PATH: <file_path>
WORKTREE_PATH: <STEP_WORKTREE>
FILES_TOUCHED:
<list>
Work in WORKTREE_PATH (`cd` there first). Run /gates:verify-implementation per the preloaded skill. Report via the Verifier Output Contract, including the `WORKDIR_TOPLEVEL` line.
```

Parse the `=== VERIFIER REPORT ===` block. **Assert `WORKDIR_TOPLEVEL` matches the step's working dir** (umbrella: `$STEP_WORKTREE`; flat: repo root), exactly as Step 5.1-recon does — a mismatch means the gate audited the wrong tree; mark the step `blocked` and escalate, do NOT trust the verdict.

Decision table:

| Verdict  | Blockers  | Iteration count | Action                                                                                                                                                    |
| -------- | --------- | --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `passed` | (any)     | any             | Go to Step 5.3                                                                                                                                            |
| `failed` | empty     | < 3             | Spawn executor again with `FIX_LIST = GAPS` from verifier. After executor completes, loop back to Step 5.2 (this same step). Increment iteration counter. |
| `failed` | empty     | = 3             | Mark step `blocked`, escalate: "Verifier still reports gaps after 3 fix iterations. Gaps: [...]. Iterations tried: [...]." STOP pipeline.                 |
| `failed` | non-empty | any             | Mark step `blocked`, escalate with `BLOCKERS:` list. STOP pipeline.                                                                                       |

When looping with a fix iteration, give the executor the verifier's `GAPS:` block verbatim as `FIX_LIST` and add: `This is fix iteration <N> of 3 for step <step_id>. In your NOTES, include ROOT_CAUSE: (why the gap existed), APPLIED_CHANGE: (what you changed), OUTCOME: (resolved | still-failing).` Copy those three NOTES fields into a run-log friction record (Phase 4b) — they are the material the central memory reflection consumes.

### Step 5.3 — Design check (loop up to 2 iterations, conditional)

Skip entirely if `.agents/specs/design/Ready/` does not exist (use `Bash` to check). Log: `Design phase skipped: no .agents/specs/design/Ready/`. Proceed to Step 5.4.

If the directory exists, spawn `@orchestrator-designer` **with the step's working directory** (flat mode: repo root; umbrella mode: `$STEP_WORKTREE`) — same reason as the verifier: in umbrella mode the implemented UI lives only in the worktree until the Step 5.4b merge:

```
PLAN_PATH: <file_path>
WORKTREE_PATH: <STEP_WORKTREE>
FILES_TOUCHED:
<list>
Work in WORKTREE_PATH (`cd` there first). Run /gates:design-quality-check per the preloaded skill. Report via the Designer Output Contract, including the `WORKDIR_TOPLEVEL` line.
```

Parse the `=== DESIGNER REPORT ===` block. **Assert `WORKDIR_TOPLEVEL` matches the step's working dir** (umbrella: `$STEP_WORKTREE`; flat: repo root) before trusting the verdict — a mismatch means the audit ran against the wrong tree; mark the step `blocked` and escalate.

Parse the `=== DESIGNER REPORT ===` block.

**Adaptive design budget (read before applying the table).** A backend step with no UI surface returns `skipped` and costs nothing. A heavy-UI step often returns a structural rewrite (many gaps that are all symptoms of one "implementation diverged from the design DOM" root cause) — and two small fix iterations are the wrong tool for that: you want ONE comprehensive fix pass, not two partial ones. So branch on the FIRST designer report's shape:

- **Mega-fix mode** — if the first `failed` report has **>20 GAPS** OR **≥1 structural/architectural GAP** (a gap about DOM hierarchy, missing sections, per-tier/per-state variants, or component structure — not pure token/spacing/copy deltas): treat the entire `GAPS` list as a SINGLE fix iteration. Spawn the executor once with the full `FIX_LIST`, then re-run the designer once to confirm. This is one mega-iteration, not two small ones. If the single mega-fix still fails on structural gaps → escalate as blocker (don't grind).
- **Incremental mode** — otherwise (≤20 gaps, all cosmetic): use the 2-small-iteration loop in the table below.

Decision table (incremental mode):

| Verdict               | Blockers  | Iteration count | Action                                                                                                                                                                 |
| --------------------- | --------- | --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `passed` or `skipped` | (any)     | any             | Go to Step 5.4                                                                                                                                                         |
| `failed`              | empty     | < 2             | Spawn executor with `FIX_LIST = GAPS` from designer (reuse the step worktree). Then loop back to Step 5.3 (do NOT re-run verifier — fixing design rarely breaks code). |
| `failed`              | empty     | = 2             | Mark `blocked`, escalate: "Designer still reports deltas after 2 fix iterations." STOP.                                                                                |
| `failed`              | non-empty | any             | Mark `blocked`, escalate. STOP.                                                                                                                                        |

Either mode: a `failed` report with **non-empty BLOCKERS** halts immediately and escalates to the user — blockers are product/architectural decisions the executor cannot resolve mechanically.

### Step 5.4 — Commit (sub-agent) → clean-build gate → push (orchestrator)

**Split by design.** The committer sub-agent commits but does NOT push — a sub-agent does not inherit the user's main-session push grant, so its push gets blocked even when the pipeline is authorized. The orchestrator pushes from the main session instead. Between the commit and the push sits a **clean-tree build gate** (5.4a-bis) that verifies the bare commit builds with no uncommitted files present — so a commit that only builds thanks to stray working-tree files never reaches `origin/main`.

**5.4a — Commit.** Spawn `@orchestrator-committer` with the step worktree as its working directory:

```
PLAN_PATH: <file_path>
STEP_ID: <step_id>
WORKTREE_PATH: <STEP_WORKTREE>
FILES_TOUCHED:
<list>
Work in WORKTREE_PATH. Stage exactly these files and commit with a conventional message. Do NOT push. Use the commit skill. Report via the Committer Output Contract.
```

Because every fix iteration ran in the SAME `STEP_WORKTREE`, all of the step's work is present here — the committer stages the complete result, not just the last iteration's diff.

Parse the `=== COMMITTER REPORT ===` block.

| Status              | Action                                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------------------------- |
| `committed`         | Proceed to **5.4a-bis** (clean-tree build gate) before pushing the SHA the committer reported.          |
| `nothing_to_commit` | Log warning ("step produced no committable changes"). Mark step `done`. Skip 5.4a-bis + 5.4b. Continue. |
| `blocked`           | Mark step `blocked`. Escalate with BLOCKERS list. STOP.                                                 |

**5.4a-bis — Clean-tree build gate (orchestrator, before push).** The committer stages exactly `FILES_TOUCHED` — but a step can commit a _generated artifact_ (a design index, a lockfile, a snapshot, a bundled manifest) while the **source files it was generated from** sit untracked or modified _outside_ the plan's scope. The executor and verifier both ran their builds against the **working tree** (which still contains those stray sources), so the build passed for them — yet the **commit itself is not self-contained**: on a clean checkout (exactly what the deploy server does) the gate that regenerates the artifact sees different sources and fails. This gate catches that class of "passes locally, fails on the server" break _before_ it reaches `origin/main`.

It answers the only question that matters before a push: **does the bare commit build with no tracked-but-uncommitted files present?** This is generic — it knows nothing about any specific gate (`design:index:check`, `check:legal`, …); it just reproduces the server's clean-checkout condition locally.

> **Limit — gitignored files are NOT isolated.** The stash below uses `-u` (untracked) but not `-a` (all, incl. ignored), so files matched by `.gitignore` stay in the tree during the build. `-a` is deliberately avoided — stashing ignored build caches/`node_modules` would be slow and can corrupt them on pop. The consequence: if the build greens only because of a leftover **ignored** artifact (e.g. a stale compiled dir), this gate will not catch it. That is an accepted trade-off, not a guarantee gap to paper over — for a stack where ignored artifacts can mask a broken build, prefer the "temporary worktree at the commit SHA" alternative noted at the end of this step.

**Determine the validation command (generic — no hardcoded framework).** This gate must run on any stack, so it does not assume `npm run build`. Resolve the command in priority order: (1) the plan's `## VALIDATION COMMANDS` section — the automatable Level 1/2 entries (typecheck/lint/build/tests); `/plan-feature` emits this section, so it is the most accurate definition of what "builds" means for this change; (2) **stack detection** if the plan has none — `package.json` with a `build` script → `npm run build`; `Cargo.toml` → `cargo build`; `go.mod` → `go build ./...`; `pyproject.toml` → the project's configured check; (3) **nothing determinable** → log `clean-build gate skipped: no validation command for this stack` and proceed to push. A generic template cannot assume a build step exists — do not block a project that legitimately has none.

**Optional hardening — frameworks with a post-success marker.** A green exit code can lie on some build systems: a stale artifact from a prior build can return `RC == 0` on a state that is not a real success (e.g. Next.js, where a leftover `.next/BUILD_ID` reads as the current build's success). On such a stack, additionally require the framework's post-success filesystem marker — Next.js writes `.next/BUILD_ID` **only** after a successful build. The pattern: `rm -f <marker>` before building, then require BOTH `RC == 0` AND a freshly-written non-empty `<marker>`. This is framework-specific; the generic gate below relies on the exit code alone.

Run from the commit's working directory (flat mode: the main checkout; umbrella mode: `STEP_WORKTREE`):

```bash
# Set aside everything NOT in the commit — untracked (-u) and modified — so the tree matches
# what was committed (== what the server checks out). `git stash push -u` both resets tracked
# files to HEAD and removes untracked ones, reproducing the committed tree. (-u, not -a: ignored
# files stay — see the limit note above.)
git stash push -u -m "orchestrate-clean-build-<step_id>"   # no-op + harmless if tree already clean

# Capture the EXACT stash ref we just created, by SHA — NOT by message and NOT a later bare
# `git stash pop` (which pops stash@{0}). If the push was a no-op (clean tree), stash@{0} is
# unchanged, so guard on whether the top stash is actually ours before recording the SHA.
STASH_SHA=""
if git stash list -n 1 --format='%gs' | grep -q "orchestrate-clean-build-<step_id>"; then
  STASH_SHA="$(git rev-parse stash@{0})"
fi

# Validate the bare commit. <VALIDATION_CMD> is the command resolved above (the plan's
# VALIDATION COMMANDS, else the stack-detected build/test command). For the optional
# post-success-marker hardening, `rm -f <marker>` here and check `[ -s <marker> ]` below.
<VALIDATION_CMD> 2>&1 | tee "/tmp/orchestrate-build-<TARGET_SLUG>-<step_id>.log"
BUILD_RC=${PIPESTATUS[0]}   # bash: exit code of the command, not tee. (zsh: use ${pipestatus[1]})

# ALWAYS restore the working tree, even if the build failed — never leave the user's stray
# files stashed. Apply OUR exact stash SHA, never a bare `git stash pop` (it pops stash@{0},
# which may be someone else's stash if one landed on top). On a clean apply, drop that entry.
if [ -n "$STASH_SHA" ]; then
  git stash apply "$STASH_SHA" && \
    git stash drop "$(git stash list --format='%H %gd' | awk -v s="$STASH_SHA" '$1==s{print $2; exit}')" 2>/dev/null || \
    echo "⚠ could not cleanly restore stash $STASH_SHA — left intact; resolve manually (see pop-failure safety below)"
fi
```

| Build result                           | Action                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BUILD_RC == 0` | Commit is self-contained and validation passed on the clean tree. Proceed to 5.4b push.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `BUILD_RC != 0`                        | Mark step `blocked`. The commit builds only because uncommitted working-tree files are present — it is NOT self-contained and **will break the server's clean-checkout build**. Do NOT push. Escalate to the user (Phase 6) with: (a) the failing build output (`/tmp/orchestrate-build-<TARGET_SLUG>-<step_id>.log`), (b) the list of files that were stashed (`git stash show -u "$STASH_SHA" --stat`, captured before the restore), and (c) the likely diagnosis — a committed generated artifact whose source files were left untracked/unstaged outside the plan scope. The fix is usually to commit those stray sources (or rebuild the artifact without them); both are user decisions. STOP. |
| (no validation command resolved) | Gate skipped — logged above. Proceed to 5.4b push. The commit was not clean-build-verified; acceptable for a project with no build step, but recorded so it is not mistaken for a verified pass.                                                                                                                                                                                                                                                                                                              |

**Restore-failure safety:** if `git stash apply` reports a conflict (the build wrote files that now collide with the stash), do NOT force it and do NOT `git stash drop` — the apply failed, so dropping would destroy the only copy. Leave the stash intact (`git stash list` shows our `orchestrate-clean-build-<step_id>` entry; its SHA is `$STASH_SHA`), surface the conflict to the user verbatim, and STOP — the user resolves the working tree manually. Never `git checkout`/`reset` to clear the conflict; that can destroy the user's stray work (and both are denied in settings anyway).

> **Why a stash and not a fresh worktree:** in flat mode there is no isolated checkout, so `stash -u` is the cheapest way to reproduce "only the commit, nothing else." In umbrella mode the worktree is usually already clean after the commit, so the stash is a no-op (`git stash` reports "No local changes to save") and the build simply runs on the committed branch — the gate still adds value by catching a stray untracked file the executor left behind in the worktree. The gate is identical in both modes; only the working directory differs.

**5.4b — Reconcile + push (orchestrator, main session).** The push must originate from the main session where the user's authorization lives — do NOT spawn a sub-agent for it.

**Flat mode (atomic plan):** the committer already committed directly on the current branch `<TARGET_BRANCH>` in the main checkout. There is nothing to merge. Just push:

```bash
git push origin "<TARGET_BRANCH>"
```

**Umbrella mode:** the committer committed on the step's named branch `step-<step_id>` in its worktree. Bring it onto the run branch `<TARGET_BRANCH>` by fast-forward, then push:

```bash
# The committer committed on the named branch step-<step_id> (created in Step 5.0b).
# Because the branch is named (not a detached HEAD) and the run branch <TARGET_BRANCH> has
# not moved during this step (sequential execution, Phase 3), this fast-forward is
# deterministic — no fetch of a loose SHA and no cherry-pick are ever needed. The merge runs
# on the checked-out run branch; in a single run on main that IS main (today's behavior).
git merge --ff-only "step-<step_id>"   # fast-forward <TARGET_BRANCH> onto the step branch
git push origin "<TARGET_BRANCH>"
```

Cross-check the resulting `git rev-parse HEAD` against the `COMMIT_SHA` from the committer report — they must match. Sequential execution (Phase 3) guarantees the run branch `<TARGET_BRANCH>` only advances via this pipeline (per clone), so `--ff-only` always succeeds mid-run. If it ever does not (someone pushed to `<TARGET_BRANCH>` mid-run, violating the project convention), the merge fails cleanly — see the rejected row below. Never substitute `git cherry-pick` or `git merge --no-ff` to force the commit through; `cherry-pick` is denied and `merge --no-ff` is `ask`-tier in settings, and either would diverge from the deterministic ff model.

| Push outcome                             | Action                                                                                                                                                                                                                            |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| success                                  | Continue to Step 5.5. Step succeeded.                                                                                                                                                                                             |
| rejected / non-fast-forward              | Mark step `blocked`. Do NOT `git pull --rebase` or `--force`. Escalate: "Push rejected, upstream advanced. Commit exists locally (SHA <X> from committer report). Resolve manually then `/orchestrate --resume`." STOP.           |
| other error (network/auth)               | Retry once. If still failing, mark step `blocked`, escalate with the error. The commit is safe locally (SHA from committer report). STOP.                                                                                         |
| blocked by harness despite authorization | This should not happen from the main session once the user has authorized the run. If it does, surface the block to the user verbatim and ask them to confirm the push or run it themselves. Do NOT attempt to widen permissions. |

### Step 5.5 — Mark step done + retire the step worktree

If we reached here, step succeeded end-to-end.

**Flat mode (atomic plan):** there is no umbrella table and no worktree. The single step is done — go straight to Phase 7.

**Umbrella mode:** edit the umbrella `## Execution Plan` table: change this step's `Status` from `in_progress` to `done`. Then retire this step's worktree (its work is now merged into `main`):

```bash
git worktree remove "<STEP_WORKTREE>" --force 2>/dev/null || true
```

The now-merged `step-<step_id>` branch is left in place (deleting branches is an `ask`-tier op the pipeline leaves to the human, and a fully-merged branch is harmless); `git worktree prune` in Phase 7 cleans up worktree metadata. Continue to next step in topological order.

> **Status-table edit hygiene:** each step touches the umbrella table exactly twice (5.0 `→in_progress`, 5.5 `→done`). Always copy the Status cell text verbatim from your last read of the file before editing — a casing/whitespace mismatch in the path or cell makes the Edit fail silently and forces a retry. Re-read the umbrella only if a prior Edit reported a no-match.

## Phase 6: User escalation protocol

### Cadence rule — do not ask "continue?" on a loop

Escalate to the user on **decisions and blockers**, not on **progress checkpoints**. Once the user has signalled "run to the end without stopping" (or started the pipeline without asking for per-step confirmation), treat that as standing autonomy: report progress between steps as a one-line **statement** ("8/13 done, next: step 6a"), never as an AskUserQuestion offering a halt option. Re-asking "should I keep going?" after the user already said yes is noise — the retro of the first run flagged 2 such redundant interrupts. The user can interrupt at any time; you do not need to offer them the chance every step.

A blocker (executor/verifier/designer/committer/push) is different — that is a real stop that needs a decision. Escalate those as below.

### Blocker escalation

When you escalate (any `blocked` outcome above), do **not** ask AskUserQuestion for free-form input that would be hard to act on later. Instead, write a clear message to the user with:

- Which step blocked (`step_id`, file path)
- Which phase blocked (executor / verifier / designer / committer)
- The blockers verbatim from the sub-agent report
- For verifier/designer 3rd-iteration failures: also include the gap list and iteration history
- Concrete options for the user:

```
Options:
  (1) Provide guidance — write your instruction and I'll spawn a fresh executor with your decision as context
  (2) Skip this step — mark it `skipped` in the umbrella table and proceed to the next
  (3) Abort pipeline — leave umbrella in its current state for manual intervention
  (4) Mark step done anyway — accept current state, move to next (use sparingly)
```

Wait for user response. Do not auto-loop on a blocked state.

When the user provides guidance (option 1), spawn a fresh executor with prompt:

```
PLAN_PATH: <file_path>
STEP_ID: <step_id>
USER_GUIDANCE:
<verbatim user input>

This is a user-guided retry after a blocker. Apply the guidance and execute the plan. In your NOTES, include ROOT_CAUSE / APPLIED_CHANGE / OUTCOME. Report via the Executor Output Contract.
```

Write a run-log friction record (Phase 4b) for this retry: the `USER_GUIDANCE` verbatim plus the executor's ROOT_CAUSE / APPLIED_CHANGE / OUTCOME. Then resume the pipeline at Step 5.2 (re-verify after the guided fix).

## Phase 7: Pipeline completion

When the last step reaches `done`:

**Branch-aware completion (read first — `TARGET_BRANCH` from Phase 4).**

- **`TARGET_BRANCH == main`** (single run — today's default): run every step below exactly as written. No `chore: workflow-state` commit; memory/backlog reflection runs here.
- **`TARGET_BRANCH != main`** (a parallel `orch-<id>` build run): two differences — **(a)** after the plan-move, make a **`chore: workflow-state` commit** (flat step 2b / umbrella step 4b) so the moved plan + run-log files travel onto `main` via the later `--integrate` merge — git does NOT move uncommitted files; **(b)** **SKIP the memory-reflection (step 6) and backlog write-back (step 7)** — those run once, centrally, in **Integration mode** from the merged run-logs. A build clone ships only the plan-move + run-log, so deleting it afterward is safe.

**1–2 branch by plan type** — a flat/atomic plan has no `## Execution Plan` table and no sub-step files, so the umbrella-shaped steps below do not apply to it.

**Flat mode (atomic plan):**

1. Confirm the single step pushed successfully (Step 5.4b succeeded).
2. Move just the plan file and its run-log to `done/`:
   - `mv .agents/plans/active/<plan>.md .agents/plans/done/`
   - `mv .agents/plans/active/<plan>.run.md .agents/plans/done/ 2>/dev/null || true`
2b. **Workflow-state commit — parallel runs only (`TARGET_BRANCH != main`).** Skip on a single run (`TARGET_BRANCH == main`): the move stays a local, uncommitted working-tree change for the user to `/commit`, exactly as today. On an `orch-<id>` run, the moved files must be committed + pushed or the `--integrate` merge can't carry them onto `main`. Same mechanism as umbrella step 4b, but the rename list is just the single plan + its run-log:
   - `mv` from step 2 leaves delete(old)+add(new) pairs in `git status`. Spawn `@orchestrator-committer` with `STEP_ID: workflow-state` and the two `<old> → <new>` rename pairs; it stages both sides of each (`git add -- <old> <new>`) via its bounded exception and commits `chore: move <plan> + run-log to done/`. Do NOT push from the committer.
   - Then push from the main session: `git push origin "<TARGET_BRANCH>"`. Memory/backlog are NOT committed here (central reconciliation in Integration mode).

   Steps 3 (worktree cleanup) and 4 (branch cleanup) are **no-ops** in flat mode (no worktree, no `step-*` branch). Continue at step 5.

**Umbrella mode:**

1. Read the umbrella `## Execution Plan` table — confirm all rows are `done` or `skipped`.
2. Move the umbrella, all sub-step files, and the run-log to `.agents/plans/done/`:
   - `mv .agents/plans/active/<umbrella>.md .agents/plans/done/`
   - For each sub-step in the table, `mv .agents/plans/active/<file> .agents/plans/done/`
   - `mv .agents/plans/active/<umbrella>.run.md .agents/plans/done/ 2>/dev/null || true` (the durable run-log from Phase 4b travels with the plan)
3. **Worktree cleanup — preserve uncommitted work.** Remove step worktrees that survived (e.g. from a blocked step) and prune stale entries — they accumulate full repo checkouts. **But a surviving worktree from a blocked step can hold uncommitted agent work** (e.g. the user chose Phase 6 "mark done anyway" without merging), and `git worktree remove --force` discards it irreversibly — `git worktree remove` is allow-listed in settings (not denied), so nothing else guards this. So force-remove ONLY a worktree that is both clean and fully merged; leave any dirty one in place and report it:
   ```bash
   for wt in .claude/worktrees/step-*; do
     [ -d "$wt" ] || continue
     if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
       echo "⚠ keeping $wt — it has uncommitted changes (resolve manually)"   # do NOT --force
     else
       git worktree remove "$wt" --force 2>/dev/null || true                  # clean → safe to drop
     fi
   done
   git worktree prune
   ```
   List every worktree kept this way in the final summary so the user knows work is parked there. Never `--force`-remove a dirty worktree to "clean up" — that is the user's uncommitted work.
4. **Branch cleanup — emit a command, do NOT run it.** The now-merged `step-<id>` branches (and any empty ones left by a blocked/aborted step) are harmless but clutter the branch list. Deleting branches is an **`ask`-tier operation** in settings (each deletion prompts) and is destructive — by project rule, that is the human's call, not the pipeline's. So list the merged step branches and emit a ready-to-paste command for the user, e.g.:
   ```
   These step branches are fully merged into main and safe to delete (your call):
     ! git branch -D step-3a step-3b step-6
   ```
   Compute the list from the umbrella table's step ids (or `git branch --merged main` filtered to `step-*`). Do not attempt the deletion yourself; the `! ` prefix runs it in the user's session if they choose.
4b. **Workflow-state commit — parallel runs only (`TARGET_BRANCH != main`).** Skip entirely on a single run (`TARGET_BRANCH == main`): the plan-move stays a local, uncommitted working-tree change for the user to `/commit`, exactly as today. On an `orch-<id>` run, the moved files must be **committed and pushed** or the later `--integrate` merge won't carry them onto `main` — git does not move uncommitted files. The `mv`s in step 2 show in `git status` as delete(old)+add(new) pairs.
   - **Ownership.** The orchestrator can't commit and the committer can't move the plan — so the orchestrator already did the moves (step 2), and now spawns `@orchestrator-committer` to stage + commit them via a bounded exception:
     ```
     STEP_ID: workflow-state
     RENAME_PAIRS:
     - .agents/plans/active/<umbrella>.md → .agents/plans/done/<umbrella>.md
     - .agents/plans/active/<sub-step-1>.md → .agents/plans/done/<sub-step-1>.md
     - ...  (EVERY sub-step file from the umbrella table)
     - .agents/plans/active/<umbrella>.run.md → .agents/plans/done/<umbrella>.run.md
     Stage BOTH sides of every rename (git add -- <old> <new>) and commit `chore: move <umbrella> plan + run-log to done/`. Do NOT push. Report via the Committer Output Contract.
     ```
   - Stage **every** moved file — the umbrella AND every sub-step file AND the run-log (all of step 2), not just one. A rename shows as delete+add; both sides of each must be staged or the deletion is silently dropped.
   - Then push from the main session: `git push origin "<TARGET_BRANCH>"`. Memory/backlog are NOT committed here (central reconciliation in Integration mode).
5. **Documentation sync — only if `--sync-docs` was passed.** Skip entirely otherwise (the default). The pipeline's per-step commits are already pushed, so this is a separate, final `docs:` commit covering the whole feature.
   - Aggregate `FILES_TOUCHED` across every completed step (from the run-log).
   - **Decide if it is warranted.** If none of those files plausibly affect documented surface (public API / exported interface, CLI commands or flags, setup/config/install, architecture, or a user-facing feature), log `Doc sync requested but no documented surface changed — nothing to sync.` and skip the spawn. This honors documentation-manager's own rule: do not run it when docs would not drift.
   - Otherwise spawn `@documentation-manager`:
     ```
     CHANGED_FILES:
     <aggregate FILES_TOUCHED across all steps>
     The pipeline just shipped the feature in <umbrella name>. Sync README / docs/ / inline docs to match — narrowly, only what these changes affected. Leave .agents/memory/ alone. Report which docs you updated.
     ```
   - If it updated docs: spawn `@orchestrator-committer` with those doc paths as `FILES_TOUCHED` and `STEP_ID: docs` to stage and commit `docs: sync docs for <umbrella>` (committer does not push — same split as every step). Then `git push origin "<TARGET_BRANCH>"` from the main session. If documentation-manager changed nothing, log `Docs already in sync.` and skip the commit+push.
   - A doc-sync failure is **not** a pipeline failure — the feature is already shipped and pushed. Report it and continue to the summary.
6. **Memory reflection — friction-gated.** **(Parallel run — `TARGET_BRANCH != main` — SKIP this step: memory reflection runs once, centrally, in Integration mode from the merged run-logs. This step runs only on a single run to `main`.)** You are a thin router: the real texture of what went hard lived in the sub-agents and is gone. Your one durable record is the **run-log** (Phase 4b). Scan it for *friction signals*:
   - a step that needed **>1 verifier fix iteration** on the same gap,
   - a **blocker you escalated** that the user resolved via guidance (Phase 6 option 1),
   - a **designer mega-fix** (structural rewrite).

   **If the run-log shows none of these → skip entirely. Log `Memory: clean run, nothing to reflect on.` A smooth pipeline learns nothing.**

   If it does show friction, run the **Memory Reflection Protocol** in [.agents/memory/index.md](../../.agents/memory/index.md) against those run-log entries. Apply its bar strictly — **the default is to save nothing**; a recurring gap is only worth an `errors.md`/`decisions.md` entry if a fresh Claude would repeat the mistake without it. Append at most one or two entries; never pad. Memory writes are **not committed by the pipeline** — leave them in the working tree for the user to `/commit` (consistent with how memory is managed). Record the outcome for the summary's `Memory:` line.
7. **Backlog write-back — opt-in, skip silently if no backlog.** **(Parallel run — `TARGET_BRANCH != main` — SKIP this step: the backlog write-back runs once, centrally, in Integration mode. This step runs only on a single run to `main`.)** If `.agents/backlog.md` exists, mark the work package this plan delivered as `Status: DONE` and confirm its `Ref` column carries both the spec and the (now moved to `done/`) plan path. If `.agents/backlog.md` does not exist → do nothing (a project without a backlog has an untouched pipeline). Touch only `Status`/`Ref` — never the DAG, epic map, or task scope (structural edits to the backlog are a deliberate manual act, not a pipeline side-effect). This write is **not committed by the pipeline** — leave it in the working tree for the user to `/commit`, same as memory writes. Record the outcome for the summary's `Backlog:` line.
8. Emit final summary to the user:

```
✓ Pipeline complete: <umbrella name>

Steps: <N> total, <K> done, <S> skipped
Commits pushed: <list of SHAs and subjects>
Fix iterations triggered: verifier=<N>, designer=<M>
Blockers escalated: <count, with brief notes>
Total wall time: <hh:mm:ss>

Plans + run-log moved to .agents/plans/done/.
Merged step branches you may delete: <the `! git branch -D …` line from step 4, or "none">
Docs: <synced in commit <sha> / already in sync / skipped — no documented surface changed / not requested — pass --sync-docs (this run touched <documented surface>) >
Memory: <appended N entr(y/ies) to <file(s)>, left uncommitted for you to /commit / clean run, nothing to reflect on>
Backlog: <work package <WP> marked DONE, left uncommitted for you to /commit / no backlog — skipped>
Deploy is your call.
```

## Integration mode (`--integrate`) — supervised merge queue

Entered directly from Phase 0 when invoked as `/orchestrate --integrate orch-a orch-b …`. **Phases 1–7 do NOT run.** This is a standalone, single-threaded, human-supervised merge queue that brings the completed parallel run-branches onto `main`. Run it once, from a clone checked out on `main`, after every parallel build has finished and pushed. Operator runbook: [.agents/reference/parallel-orchestration.md](../../.agents/reference/parallel-orchestration.md).

**Why supervised and not auto-merged.** Each integration merge is `git merge --no-ff` — an `ask`-tier op that prompts once. That prompt IS the design, not an obstacle: there is **no `settings.json` change and no new hook**. Auto-approving the merge was deliberately rejected — a scoped `allow` glob can't express "only origin's `orch-*`" (permission globs aren't argument-aware, and a branch name doesn't prove origin), and a PreToolUse `allow` hook does not bypass a matching `ask` rule. Expect **one approval prompt per branch**. The other git ops used here (`worktree add/remove`, `merge --ff-only`, `fetch`, `push`) are already `allow`-tier.

### Queue preflight (once, before any merge)

All must hold or STOP with guidance (Phase 6), before touching any branch:

```bash
git rev-parse --abbrev-ref HEAD          # MUST be `main` — the queue advances main; temp branches root at main
git status --porcelain                   # MUST be empty — clean tree (same clean-tree check as Step 5.0b FLAT_BASELINE)
git rev-parse -q --verify MERGE_HEAD     # MUST be empty — no merge already in progress
git fetch origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ]   # MUST hold — local main == origin/main
```

- Not on `main` → STOP: "Run --integrate from a checkout on `main` (temp branches root at main)."
- Dirty tree → STOP: "Integration needs a clean `main` checkout; commit/stash/revert first."
- Mid-merge (`MERGE_HEAD` present) → STOP: "Finish or abort the in-progress merge first."
- `HEAD != origin/main` → STOP: "Local `main` diverged from origin/main; reconcile first (`/pull`)."

### Per branch, sequentially — validate on a TEMP BRANCH, advance `main` only on success

Process the branches in **argument order**. A worktree needs a committed commit-ish, so the merge is committed on an isolated temp branch and validated there; `main` is advanced only after the gate passes, by fast-forward. **`main` never moves until validation passes → rollback is just discarding the temp worktree/branch, never a `reset --hard`** (denied anyway).

For each branch `BRANCH` (`orch-<id>`), with `ID = ${BRANCH#orch-}`:

1. **Fetch + pin the exact tip.** Merge the pinned SHA, never a bare local branch name (absent/stale):
   ```bash
   git fetch origin "<BRANCH>"
   MERGE_SHA="$(git rev-parse FETCH_HEAD)"   # exact tip of origin/<BRANCH> right now
   SHORT="${MERGE_SHA:0:8}"
   ```
2. **Collision-free temp branch + worktree.** Name it by the pinned SHA so a re-run with an updated tip can never collide with a leftover from a crashed prior attempt:
   ```bash
   TMPB="integrate-<ID>-$SHORT"
   WT=".claude/worktrees/$TMPB"
   # If a same-SHA attempt crashed earlier, TMPB and WT sit on abandoned temp state — safe to discard:
   git worktree remove --force "$WT" 2>/dev/null; git branch -D "$TMPB" 2>/dev/null
   git worktree add "$WT" -b "$TMPB" main       # temp branch rooted at the current (validated) main
   ```
   Never reuse a bare `integrate-<ID>` (a re-run with a moved tip would collide with a leftover branch).
3. **Merge on the temp branch — prompts once (`ask` tier).** `--no-edit` is **mandatory**: without it the merge may open an editor and hang the non-interactive orchestration shell:
   ```bash
   git -C "$WT" merge --no-ff --no-edit "$MERGE_SHA"
   ```
   This is the one `ask` prompt per branch (`Bash(git merge --no-ff*)` matches regardless of the SHA arg — do NOT suppress it). **On conflict:** abort and clean up; `main` is untouched; mark blocked and escalate (Phase 6):
   ```bash
   git -C "$WT" merge --abort
   git worktree remove --force "$WT"; git branch -D "$TMPB"
   ```
4. **Validate in the temp worktree** — a clean checkout of exactly the committed merge (the immutable snapshot: a build that dirties `$WT` can't corrupt what gets pushed, because `main` is advanced from the committed `$TMPB`, not the working tree). Resolve `VALIDATION_CMD` per **Gate command source** below and run it **in `$WT`**. On failure: clean up (`git worktree remove --force "$WT"; git branch -D "$TMPB"` — build dirt is disposable) and escalate; `main` untouched (never a denied `reset --hard`).
5. **Re-pin check, then advance `main`.** Before moving `main`, confirm the run branch's tip has not moved since step 1 (a mid-queue push during the long gate):
   ```bash
   git fetch origin "<BRANCH>"
   [ "$(git rev-parse FETCH_HEAD)" = "$MERGE_SHA" ]   # MUST still equal the pinned SHA
   ```
   Moved → clean up + escalate; do NOT merge a stale tip. Holds → fast-forward `main` onto the validated temp branch and push (ff always succeeds — the merge commit's first parent IS `main`):
   ```bash
   git merge --ff-only "$TMPB"      # on main
   git push origin main
   ```
   Non-ff on push → escalate, never force.
6. **Cleanup + re-assert.** The temp branch is now fully merged into the pushed `main`, so force-removing its worktree is safe ([CLAUDE.md](../../CLAUDE.md) Git Workflow — force-remove guard: clean + fully merged):
   ```bash
   git worktree remove --force "$WT"
   [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ]   # re-assert before the next branch
   ```
   Leave `$TMPB` for the human to delete (`git branch -d` is `ask`-tier) — list it in the final summary. Then proceed to the next branch in the queue.

### Gate command source

Resolve `VALIDATION_CMD` in priority order (record the chosen source in the run-log):

1. **`CLAUDE.md → Validation` FIRST** — the documented "Source of truth for quality gates" (CLAUDE.md `Validation` section). Run that sequence, fail-fast. Only if the section is absent or still holds `{placeholder}` markers → fall through.
2. **Stack detection** — `package.json` with the relevant script → `npm run …`; `Cargo.toml` → `cargo build && cargo test`; `go.mod` → `go build ./...`; `pyproject.toml` → the project's configured check.
3. **Neither** → log `integration gate skipped: no validation command` and proceed (fail-open — a template project with no build step must not be blocked).

### Central reconciliation (once, after the queue drains)

The run-log (Phase 4b) carries no memory/backlog patches, and each build clone's Phase 7 leaves memory/backlog **local + uncommitted** — so those deltas can never arrive via git. Therefore the memory/backlog step runs **centrally, once, here**, not in the build clones:

- **Build clones SKIP the Phase-7 memory/backlog reflection** (Phase 7 steps 6–7) — they commit only the plan-move + run-log (`chore: workflow-state`). This is what makes deleting a clone after its build safe.
- Each integrated branch carried its `chore: workflow-state` commit onto `main`, so every run-log now sits in the main checkout under `.agents/plans/done/`. Run the **Memory Reflection Protocol** ([.agents/memory/index.md](../../.agents/memory/index.md)) **over the merged run-logs** — consuming the Phase-4b friction records (`ROOT_CAUSE` / `APPLIED_CHANGE` / `OUTCOME` / `USER_GUIDANCE` / `MEMORY_CANDIDATE`), not bare verdict lines — applying its bar strictly (default: save nothing). Then do the **backlog write-back** for each delivered work package (`Status: DONE` + `Ref`), exactly as Phase 7 step 7 describes, for all integrated runs at once.
- Leave the central memory/backlog writes **uncommitted** in the working tree for the user to `/commit` (consistent with how memory is managed everywhere else).

### Integration summary

```
✓ Integration complete: <N> branch(es) merged onto main
Merged: <BRANCH → merge SHA> per branch
Gate source: <CLAUDE.md Validation | stack-detected <cmd> | skipped (none)>
Escalated: <branch + reason, or "none">
Temp branches to delete (your call): ! git branch -D integrate-a-<sha> integrate-b-<sha> …
Memory: <appended N entr(y/ies), left uncommitted for you to /commit | nothing to reflect on>
Backlog: <WP(s) marked DONE, left uncommitted | no backlog — skipped>
```

## Failure modes you must handle

- **User Ctrl+C mid-step** — current sub-agent finishes its turn, you stop before the next. Umbrella table reflects whatever was last written (in_progress is fine; resume picks it up).
- **Sub-agent crash / malformed report** — try parsing once more; if still unparseable, emit blocker "Sub-agent <name> returned unparseable output. Manual inspection needed."
- **Hallucination signal word in any report body** — after parsing the `VERDICT:`/`STATUS:` line, also scan the report's free-text sections (GAPS / BLOCKERS / NOTES / STRAY_CHANGES / OUT_OF_SCOPE_NOTES) for `hallucinat | fabricat | nonexistent | does not exist | no such file | no such path` (case-insensitive). If matched, treat it as a **hard blocker regardless of the verdict line** — mark the step `blocked` and escalate immediately. Rationale: the root-cause run parsed only the verdict line and walked straight past a verifier report that literally said "fabricated/hallucinated path". The prose body is a signal, not noise.
- **Worktree conflict on spawn** — if the executor's worktree spawn fails, retry once; on second failure, escalate.
- **Plan file modified mid-run by user** — at the start of each step, re-read the plan; if it differs from your initial read, ask user: "Plan changed mid-run. Continue with new version, abort, or restart from this step?"

## Things you must NEVER do

- Implement, audit, or commit code yourself. Spawn the right sub-agent.
- Skip the verifier or designer because "executor seemed careful." Quality gates are non-negotiable.
- Skip the refiner (Step 5.1b), or let it commit/push/verify. The refiner only edits the step's files (`code-review --fix` + `deep-review`); committing is the committer's job and the read-only gate is the verifier's. The refiner and the verifier must stay different agents — never collapse fixer and judge into one.
- Carry the executor's `FILES_TOUCHED` straight to the committer after a refiner run without re-deriving from `git status`. `/deep-review` may have touched a shared file the executor never reported; staging the stale list silently drops it from the commit (Step 5.1b re-derive).
- Auto-rebase on push conflicts. Always escalate.
- Run `git push --force` under any circumstance. Even with user instruction, ask for confirmation twice.
- Mark a step `done` without a successful push (Step 5.4b). The committer commits; you push; both must succeed (or a deliberate user override via Phase 6 option 4).
- Push a commit without passing the clean-tree build gate (Step 5.4a-bis) when a validation command exists. A commit that only builds because untracked/modified working-tree files are present is NOT self-contained and will break the server's clean-checkout build. Never skip the gate "because the executor's build already passed" — the executor built the dirty tree, not the commit. If you enabled the optional post-success-marker hardening (e.g. Next.js `.next/BUILD_ID`), a green `BUILD_RC == 0` with a missing fresh marker counts as a FAILED build (false-green-RC class).
- Force a stash restore (`git stash apply`/`pop`) through a conflict in the clean-build gate, or `git checkout`/`reset` to clear one, or `git stash drop` after a failed apply. Any of these can destroy the user's uncommitted work. Surface the conflict, leave the stash intact, and STOP.
- Force-remove a worktree (`git worktree remove --force`) that has uncommitted changes during Phase 7 cleanup. `git worktree remove` is allow-listed in settings (not denied), so this guard lives only here — check `git -C "$wt" status --porcelain` first; keep dirty worktrees and report them.
- Run a flat-mode pipeline against a dirty main checkout. The Step 5.0b preflight refuses it; never bypass that and let pre-existing user changes share the step's commit.
- Loop more than the documented iteration counts: 3 verify; design is either 1 mega-fix (structural) or 2 incremental (cosmetic) per the adaptive budget in Step 5.3 — never both, never more. The limits exist to surface real blockers, not to grind.
- Re-ask a cadence/"continue?" question once the user has said to run without stopping (see Phase 6 cadence rule). Report progress as a statement, not a question.
- Modify sub-step plan files. The executor is the only agent that may edit code; you only edit the umbrella's Status column.
- **(Integration mode)** `--force` an integration merge or push; auto-resolve an integration conflict (abort + escalate — the human re-orders or resolves); advance `main` before its temp-branch gate passed; or `reset --hard` to roll back a bad merge. `main` never moves until the gate passes, so rollback is always just discarding the temp worktree/branch. Never suppress the per-merge `ask` prompt (no `settings.json`/hook change).

## Reusability note

This command and its sub-agents are project-scoped under `.claude/` for now. They are intentionally generic: they do not reference `wp-plugin`, `Audit AI`, `auditai.cc`, or any project-specific concept. The only project-specific assumption is the convention `.agents/plans/active/` ↔ `.agents/plans/done/` and the umbrella's `## Execution Plan` section format. To port to another project, copy `.claude/agents/orchestrator-*.md` and `.claude/commands/orchestrate.md`, ensure the target project has the `execute`, `gates:verify-implementation`, `commit` skills (and optionally `gates:design-quality-check`), the `code-review` and `deep-review` skills used by the refiner (Step 5.1b), and ensure umbrella plans follow the `## Execution Plan` table convention.

> **Push model:** the committer only commits; the orchestrator pushes from the main session (Step 5.4b). This is deliberate — a sub-agent does not inherit the user's push authorization, so delegating the push to a sub-agent gets blocked even on an authorized run. If a target project allows sub-agent pushes, this split is harmless; if it doesn't (most do not), this is required. The `push` skill is therefore NOT needed by the committer agent.
>
> **Worktree model:** applies to **umbrella plans only**. One persistent worktree per step (`.claude/worktrees/step-<id>`) on a named branch `step-<id>`, reused across all fix iterations of that step, fast-forward-merged onto `main` in Step 5.4b, retired on step completion (Step 5.5) and swept in Phase 7. This replaces per-spawn isolated worktrees, which silently dropped completed work when a step ran multiple fix iterations in different worktrees. The named branch (vs the old detached-HEAD `worktree add <path> HEAD`) makes 5.4b a deterministic `merge --ff-only step-<id>` — no fetch-by-SHA, no cherry-pick fallback.
>
> **Flat model (atomic plans):** a single-step plan with no `## Execution Plan` table runs with **no worktree, no branch, no merge**. Executor and committer work in the main checkout, the committer commits straight onto the current branch, and the orchestrator just `git push origin "<TARGET_BRANCH>"` (`main` for a single run) — identical to `/commit` + `/push`. With only one step there is nothing to isolate (no competing steps, no main-advance race), so the worktree/branch/merge round-trip would be pure overhead and a needless fast-forward failure surface. The Phase 7 `git worktree remove` / `prune` sweep is a harmless no-op in flat mode.
