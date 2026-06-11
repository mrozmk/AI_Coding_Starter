---
description: Run a multi-step plan end-to-end — execute → verify → design-check → commit → push, looping fixes until passed, escalating only on blockers
argument-hint: "<path-to-plan> [--resume] [--from <step-id>]"
---

# /orchestrate — Pipeline Runner

You are the orchestrator. Your job is to take a plan (single or multi-step umbrella) and drive it end-to-end through a fixed pipeline, delegating to specialized sub-agents, looping on fixable gaps, escalating to the user only on real blockers.

You are running as the user's interactive session (typically your most capable model — e.g. Opus). You do **not** implement code, audit code, or commit code — those are sub-agent jobs. You **decide**, **route**, **loop**, **report**. The one git action you DO perform yourself is `git push` (Step 5.4b) — because the push authorization lives in your main session and does not transfer to sub-agents.

## Input

`$ARGUMENTS` = `<plan-path> [flags]`

Flags:

- `--resume` — continue an interrupted run by reading umbrella status; pick up at first non-`done` step
- `--from <step-id>` — start at a specific step id (e.g. `3b1`), treating earlier steps as already done

## Phase 0: Resolve plan

1. If `$ARGUMENTS` is a path to an `.md` file under `.agents/plans/active/` → use it.
2. Else stop and tell user: `Pass a plan path: /orchestrate .agents/plans/active/<plan>.md`.
3. Read the plan file fully.

## Phase 1: Detect plan type

Check the file for the heading `## Execution Plan`.

- **Found** → umbrella plan with multi-step DAG. Go to Phase 2. Umbrella steps run in **worktree mode** (each step gets its own worktree + named branch, merged onto `main` by ff-only — see Step 5.0b / 5.4b).
- **Not found** → single atomic plan. Run **one pipeline cycle** for this file (skip DAG handling, single iteration of Phase 3-7). Use `STEP_ID = "atomic"` in sub-agent prompts. An atomic plan runs in **flat mode**: no worktree, no branch, no merge — the executor and committer work directly in the main checkout and the orchestrator pushes `main`, exactly like `/commit` + `/push`. There is only one step, so the worktree isolation that umbrella mode needs (accumulating fix iterations, keeping `main` advancing only via ff-merge) buys nothing here — it only adds a worktree/branch/merge round-trip that can fail to fast-forward. Flat mode skips Steps 5.0b, the merge half of 5.4b, and the worktree-retire half of 5.5 (those steps below are explicitly marked **umbrella-only**).

> **This starter's defaults (read before first use):**
> - `/plan-feature` emits **single-file plans** (no `## Execution Plan` table), so they run in **flat mode** — which works out of the box. **Umbrella mode** (multi-step DAG + worktrees) requires you to **hand-author** a `## Execution Plan` table (columns `Step | File | Depends On | Status`, optional `Model`); there is no generator for it in this template yet.
> - The **design check (Step 5.3)** runs the `orchestrator-designer` agent + `design-quality-check` skill (both shipped, stack-neutral). It **auto-skips** whenever `.agents/specs/design/Ready/` is absent (the default), so projects without UI pay nothing. To enable it: create `.agents/specs/design/Ready/` and drop your reference design artifact(s) there.

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

## Phase 4: Capture upstream SHA

Once at the start of the run:

```bash
git fetch origin main
git rev-parse origin/main
```

Store as `EXPECTED_UPSTREAM_AT_START`. This is informational — the committer does not enforce it; user convention is "no manual pushes to main during /orchestrate" (per project decision).

### Phase 4b — Open a durable run-log (NOT /tmp)

Create (or append to, on `--resume`) a run-log next to the plan so the run's state survives a restart and gives `--resume` a real source of truth beyond the Status column. **Never use `/tmp` for this** — `/tmp` is wiped on restart and the trail is lost.

- Umbrella plan → `RUN_LOG = .agents/plans/active/<umbrella>.run.md`
- Flat/atomic plan → `RUN_LOG = .agents/plans/active/<plan>.run.md`

Append to `RUN_LOG` as the run progresses (one entry per step is enough): step id, the model spawned, the parsed sub-agent reports (verdict/status lines + any blockers/gaps), the Step 5.1-recon result, and each pushed `COMMIT_SHA`. This is a log you write with the Write/Edit tool, not a sub-agent artifact. In Phase 7 it moves to `done/` alongside the plan.

## Phase 5: Step loop

For each step `(step_id, file_path)` in topological order, run the pipeline below. Update the umbrella `## Execution Plan` table **before and after** each step (Edit tool, in-place).

### Step 5.0 — Read the step file, then mark step in progress

**Read the step's `file_path` in full (Read tool) before doing anything else with this step.** You cannot delegate or reconcile a scope you never read — the root-cause failure this guardrail exists to prevent was the orchestrator fabricating `FILES_TOUCHED` paths because it never opened the plan. Reading the step gives you the real target paths the plan declares, which you cross-check against the executor's report in Step 5.1. Cost: one Read per step; it removes the space in which the orchestrator can invent what a step touches.

(Phase 2 already asserts the umbrella's `File` entries exist on disk; this step reads the content. For a flat/atomic plan there is no umbrella table — read the resolved plan file here.)

Then edit the umbrella's `## Execution Plan` table: change this step's `Status` from `pending` to `in_progress`.

### Step 5.0b — Create the step's persistent worktree — **umbrella-only**

**Flat mode (atomic plan): skip this step entirely.** Set `STEP_WORKTREE` to the main checkout (the repo root, i.e. the orchestrator's own working directory) and proceed to Step 5.1. There is no branch, no worktree to create or retire.

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

### Step 5.2 — Verify (loop up to 3 iterations)

Spawn `@orchestrator-verifier` with prompt:

```
PLAN_PATH: <file_path>
FILES_TOUCHED:
<list>
Run /verify-implementation per the preloaded skill. Report via the Verifier Output Contract.
```

Parse the `=== VERIFIER REPORT ===` block.

Decision table:

| Verdict  | Blockers  | Iteration count | Action                                                                                                                                                    |
| -------- | --------- | --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `passed` | (any)     | any             | Go to Step 5.3                                                                                                                                            |
| `failed` | empty     | < 3             | Spawn executor again with `FIX_LIST = GAPS` from verifier. After executor completes, loop back to Step 5.2 (this same step). Increment iteration counter. |
| `failed` | empty     | = 3             | Mark step `blocked`, escalate: "Verifier still reports gaps after 3 fix iterations. Gaps: [...]. Iterations tried: [...]." STOP pipeline.                 |
| `failed` | non-empty | any             | Mark step `blocked`, escalate with `BLOCKERS:` list. STOP pipeline.                                                                                       |

When looping with a fix iteration, give the executor the verifier's `GAPS:` block verbatim as `FIX_LIST` and add: `This is fix iteration <N> of 3 for step <step_id>.`

### Step 5.3 — Design check (loop up to 2 iterations, conditional)

Skip entirely if `.agents/specs/design/Ready/` does not exist (use `Bash` to check). Log: `Design phase skipped: no .agents/specs/design/Ready/`. Proceed to Step 5.4.

If the directory exists, spawn `@orchestrator-designer`:

```
PLAN_PATH: <file_path>
FILES_TOUCHED:
<list>
Run /design-quality-check per the preloaded skill. Report via the Designer Output Contract.
```

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

It answers the only question that matters before a push: **does the bare commit build with no uncommitted files present?** This is generic — it knows nothing about any specific gate (`design:index:check`, `check:legal`, …); it just reproduces the server's clean-checkout condition locally.

**Determine the validation command (generic — no hardcoded framework).** This gate must run on any stack, so it does not assume `npm run build`. Resolve the command in priority order: (1) the plan's `## VALIDATION COMMANDS` section — the automatable Level 1/2 entries (typecheck/lint/build/tests); `/plan-feature` emits this section, so it is the most accurate definition of what "builds" means for this change; (2) **stack detection** if the plan has none — `package.json` with a `build` script → `npm run build`; `Cargo.toml` → `cargo build`; `go.mod` → `go build ./...`; `pyproject.toml` → the project's configured check; (3) **nothing determinable** → log `clean-build gate skipped: no validation command for this stack` and proceed to push. A generic template cannot assume a build step exists — do not block a project that legitimately has none.

**Optional hardening — frameworks with a post-success marker.** A green exit code can lie on some build systems: a stale artifact from a prior build can return `RC == 0` on a state that is not a real success (e.g. Next.js, where a leftover `.next/BUILD_ID` reads as the current build's success). On such a stack, additionally require the framework's post-success filesystem marker — Next.js writes `.next/BUILD_ID` **only** after a successful build. The pattern: `rm -f <marker>` before building, then require BOTH `RC == 0` AND a freshly-written non-empty `<marker>`. This is framework-specific; the generic gate below relies on the exit code alone.

Run from the commit's working directory (flat mode: the main checkout; umbrella mode: `STEP_WORKTREE`):

```bash
# Set aside everything NOT in the commit — untracked (-u) and modified — so the
# tree matches exactly what was committed (== what the server will check out).
git stash push -u -m "orchestrate-clean-build-<step_id>"   # no-op + harmless if tree already clean

# Validate the bare commit. <VALIDATION_CMD> is the command resolved above (the plan's
# VALIDATION COMMANDS, else the stack-detected build/test command). For the optional
# post-success-marker hardening, `rm -f <marker>` here and check `[ -s <marker> ]` below.
<VALIDATION_CMD> 2>&1 | tee "/tmp/orchestrate-build-<step_id>.log"
BUILD_RC=${PIPESTATUS[0]}   # bash: exit code of the command, not tee. (zsh: use ${pipestatus[1]})

# ALWAYS restore the working tree, even if the build failed — never leave the user's
# stray files stashed. Only pop if we actually stashed (avoid popping an unrelated entry).
git stash list | grep -q "orchestrate-clean-build-<step_id>" && git stash pop
```

| Build result                           | Action                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BUILD_RC == 0` | Commit is self-contained and validation passed on the clean tree. Proceed to 5.4b push.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `BUILD_RC != 0`                        | Mark step `blocked`. The commit builds only because uncommitted working-tree files are present — it is NOT self-contained and **will break the server's clean-checkout build**. Do NOT push. Escalate to the user (Phase 6) with: (a) the failing build output (`/tmp/orchestrate-build-<step_id>.log`), (b) the list of files that were stashed (`git stash show -u --stat` before the pop), and (c) the likely diagnosis — a committed generated artifact whose source files were left untracked/unstaged outside the plan scope. The fix is usually to commit those stray sources (or rebuild the artifact without them); both are user decisions. STOP. |
| (no validation command resolved) | Gate skipped — logged above. Proceed to 5.4b push. The commit was not clean-build-verified; acceptable for a project with no build step, but recorded so it is not mistaken for a verified pass.                                                                                                                                                                                                                                                                                                              |

**Pop-failure safety:** if `git stash pop` reports a conflict (the build wrote files that now collide with the stash), do NOT force it. Surface the conflict to the user verbatim, leave the stash intact (`git stash list` shows it), and STOP — the user resolves the working tree manually. Never `git checkout`/`reset` to clear a pop conflict; that can destroy the user's stray work.

> **Why a stash and not a fresh worktree:** in flat mode there is no isolated checkout, so `stash -u` is the cheapest way to reproduce "only the commit, nothing else." In umbrella mode the worktree is usually already clean after the commit, so the stash is a no-op (`git stash` reports "No local changes to save") and the build simply runs on the committed branch — the gate still adds value by catching a stray untracked file the executor left behind in the worktree. The gate is identical in both modes; only the working directory differs.

**5.4b — Reconcile + push (orchestrator, main session).** The push must originate from the main session where the user's authorization lives — do NOT spawn a sub-agent for it.

**Flat mode (atomic plan):** the committer already committed directly on `main` in the main checkout. There is nothing to merge. Just push:

```bash
git push origin main
```

**Umbrella mode:** the committer committed on the step's named branch `step-<step_id>` in its worktree. Bring it onto `main` by fast-forward, then push:

```bash
# The committer committed on the named branch step-<step_id> (created in Step 5.0b).
# Because the branch is named (not a detached HEAD) and main has not moved during this
# step (sequential execution, Phase 3), this fast-forward is deterministic — no fetch
# of a loose SHA and no cherry-pick are ever needed.
git merge --ff-only "step-<step_id>"   # fast-forward main onto the step branch
git push origin main
```

Cross-check the resulting `git rev-parse HEAD` against the `COMMIT_SHA` from the committer report — they must match. Sequential execution (Phase 3) guarantees `main` only advances via this pipeline, so `--ff-only` always succeeds mid-run. If it ever does not (someone pushed to main mid-run, violating the project convention), the merge fails cleanly — see the rejected row below. Never substitute `git cherry-pick` or `git merge --no-ff` to force the commit through; those are denied in settings and would diverge from the deterministic ff model.

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

The now-merged `step-<step_id>` branch is left in place (deleting branches is denied in settings, and a fully-merged branch is harmless); `git worktree prune` in Phase 7 cleans up worktree metadata. Continue to next step in topological order.

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

This is a user-guided retry after a blocker. Apply the guidance and execute the plan. Report via the Executor Output Contract.
```

Then resume the pipeline at Step 5.2 (re-verify after the guided fix).

## Phase 7: Pipeline completion

When the last step reaches `done`:

1. Read the umbrella `## Execution Plan` table — confirm all rows are `done` or `skipped`.
2. Move the umbrella, all sub-step files, and the run-log to `.agents/plans/done/`:
   - `mv .agents/plans/active/<umbrella>.md .agents/plans/done/`
   - For each sub-step in the table, `mv .agents/plans/active/<file> .agents/plans/done/`
   - `mv .agents/plans/active/<umbrella>.run.md .agents/plans/done/ 2>/dev/null || true` (the durable run-log from Phase 4b travels with the plan)
3. **Worktree cleanup.** Remove any step worktrees that survived (e.g. from a blocked step) and prune stale entries — they accumulate full repo checkouts and pollute the repo if left:
   ```bash
   for wt in .claude/worktrees/step-*; do git worktree remove "$wt" --force 2>/dev/null || true; done
   git worktree prune
   ```
4. **Branch cleanup — emit a command, do NOT run it.** The now-merged `step-<id>` branches (and any empty ones left by a blocked/aborted step) are harmless but clutter the branch list. Deleting branches is **denied in settings** and is destructive — by project rule, that is the human's call, not the pipeline's. So list the merged step branches and emit a ready-to-paste command for the user, e.g.:
   ```
   These step branches are fully merged into main and safe to delete (your call):
     ! git branch -D step-3a step-3b step-6
   ```
   Compute the list from the umbrella table's step ids (or `git branch --merged main` filtered to `step-*`). Do not attempt the deletion yourself; the `! ` prefix runs it in the user's session if they choose.
5. Emit final summary to the user:

```
✓ Pipeline complete: <umbrella name>

Steps: <N> total, <K> done, <S> skipped
Commits pushed: <list of SHAs and subjects>
Fix iterations triggered: verifier=<N>, designer=<M>
Blockers escalated: <count, with brief notes>
Total wall time: <hh:mm:ss>

Plans + run-log moved to .agents/plans/done/.
Merged step branches you may delete: <the `! git branch -D …` line from step 4, or "none">
Deploy is your call.
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
- Auto-rebase on push conflicts. Always escalate.
- Run `git push --force` under any circumstance. Even with user instruction, ask for confirmation twice.
- Mark a step `done` without a successful push (Step 5.4b). The committer commits; you push; both must succeed (or a deliberate user override via Phase 6 option 4).
- Push a commit without passing the clean-tree build gate (Step 5.4a-bis) when a validation command exists. A commit that only builds because untracked/modified working-tree files are present is NOT self-contained and will break the server's clean-checkout build. Never skip the gate "because the executor's build already passed" — the executor built the dirty tree, not the commit. If you enabled the optional post-success-marker hardening (e.g. Next.js `.next/BUILD_ID`), a green `BUILD_RC == 0` with a missing fresh marker counts as a FAILED build (false-green-RC class).
- Force a `git stash pop` through a conflict in the clean-build gate, or `git checkout`/`reset` to clear one. That can destroy the user's uncommitted work. Surface the conflict and STOP.
- Loop more than the documented iteration counts: 3 verify; design is either 1 mega-fix (structural) or 2 incremental (cosmetic) per the adaptive budget in Step 5.3 — never both, never more. The limits exist to surface real blockers, not to grind.
- Re-ask a cadence/"continue?" question once the user has said to run without stopping (see Phase 6 cadence rule). Report progress as a statement, not a question.
- Modify sub-step plan files. The executor is the only agent that may edit code; you only edit the umbrella's Status column.

## Reusability note

This command and its sub-agents are project-scoped under `.claude/` for now. They are intentionally generic: they do not reference `wp-plugin`, `Audit AI`, `auditai.cc`, or any project-specific concept. The only project-specific assumption is the convention `.agents/plans/active/` ↔ `.agents/plans/done/` and the umbrella's `## Execution Plan` section format. To port to another project, copy `.claude/agents/orchestrator-*.md` and `.claude/commands/orchestrate.md`, ensure the target project has the `execute`, `verify-implementation`, `commit` skills (and optionally `design-quality-check`), and ensure umbrella plans follow the `## Execution Plan` table convention.

> **Push model:** the committer only commits; the orchestrator pushes from the main session (Step 5.4b). This is deliberate — a sub-agent does not inherit the user's push authorization, so delegating the push to a sub-agent gets blocked even on an authorized run. If a target project allows sub-agent pushes, this split is harmless; if it doesn't (most do not), this is required. The `push` skill is therefore NOT needed by the committer agent.
>
> **Worktree model:** applies to **umbrella plans only**. One persistent worktree per step (`.claude/worktrees/step-<id>`) on a named branch `step-<id>`, reused across all fix iterations of that step, fast-forward-merged onto `main` in Step 5.4b, retired on step completion (Step 5.5) and swept in Phase 7. This replaces per-spawn isolated worktrees, which silently dropped completed work when a step ran multiple fix iterations in different worktrees. The named branch (vs the old detached-HEAD `worktree add <path> HEAD`) makes 5.4b a deterministic `merge --ff-only step-<id>` — no fetch-by-SHA, no cherry-pick fallback.
>
> **Flat model (atomic plans):** a single-step plan with no `## Execution Plan` table runs with **no worktree, no branch, no merge**. Executor and committer work in the main checkout, the committer commits straight onto `main`, and the orchestrator just `git push origin main` — identical to `/commit` + `/push`. With only one step there is nothing to isolate (no competing steps, no main-advance race), so the worktree/branch/merge round-trip would be pure overhead and a needless fast-forward failure surface. The Phase 7 `git worktree remove` / `prune` sweep is a harmless no-op in flat mode.
