---
name: plan-feature
description: Turn an approved spec into an implementation plan with EXPECT/VALIDATE tasks and an explicit execution effort (medium by default), grill it, get an independent cross-model review, and hand the plan back. Writes a plan file; never executes it.
argument-hint: "<approved spec path>"
---

# plan-feature — plan from an approved spec

**Input:** the exact path of an approved spec under `.agents/specs/`. Required — never pick a spec by modification time or name similarity. Optional `--effort low` from the user is honoured only when they say it explicitly.

**Prerequisite:** `prime` ran and reported the harness bound; `planning` group enabled. Otherwise stop as `brainstorm` does.

<HARD-GATE>
This skill writes a plan file. It never runs the plan, never edits application code, never commits. Naming the execution stage in the report is a pointer for the user, not an instruction to yourself.
</HARD-GATE>

Contracts: `references/planning-contract.md` (the plan file contract the verification gate parses; effort semantics; approval identity), `references/review-contract.md`, and — only when the user chose to split — `references/plan-split-contract.md`. Template: `templates/plan-feature-plan.template.md`. Scripts: `scripts/approval.mjs`, `scripts/backlog.mjs`, `scripts/rules.mjs`.

## Phases

### 0. Spec identity

Run `node <plugin_root>/scripts/approval.mjs verify --project-root <project_root> --spec <spec path>`. It requires `**Status:** Approved`, the receipt `.agents/approvals/<spec>.approval.json`, and that the receipt's SHA-256 equals the current file bytes — a spec never carries its own hash, so never compare `shasum -a 256 <spec>` against a line inside the file. `ok: false` (Draft, missing receipt, bytes changed after approval, interrupted stamp, or no usable `**External docs required:** yes | no` line — the verifier refuses that spec too) → stop with the printed errors; return to `brainstorm` Step 9 or have the user add the field by hand, then re-approve. Never pick a spec by modification time. Record the verified `sha256` in the plan header (`**Spec SHA-256:**`). Note `External docs required`, `Appetite & Cut Lines`, `Out of Scope`.

### 0.5 Backlog write-back — opt-in, only when unambiguous

Run `node <plugin_root>/scripts/backlog.mjs match --project-root <project_root> --spec <spec path>`:

- `no-backlog` → nothing to do; never create one.
- `matched` → re-run with `writeback … --consent yes`: the matched work package and its `TODO` tasks become `WIP` and their `Ref` gains the spec path. Only `Status` and `Ref` cells change; the DAG, scope and other packages are never touched.
- `ambiguous` / `none` → write nothing; report the candidates and ask the user which package (or none). Ambiguous ownership must not write another package's state.
- Surface every `stale` signal (a `TODO` task that already has a plan, a `WIP` task whose plan is gone) and every `competing` plan in `plans/active/` that names this spec — warn, do not resolve silently.

### 1. Codebase intelligence

Trust primed context; read only topic-specific files (memory routing, similar modules, existing tests, naming). Collect `file:line` anchors — from a symbol tool if the host has one, otherwise by reading; a cited symbol that does not resolve does not exist.

### 2. External research — conditional

Only when `External docs required: yes`: fetch the current documentation for each listed dependency (a docs tool if available, else the web) and record the URLs and sections in `### Relevant Documentation`. Never from memory alone.

### 3. Draft the plan

Write `.agents/plans/active/<kebab-feature>.md` from `templates/plan-feature-plan.template.md`:

- Header: `**Source spec:**`, `**Spec SHA-256:**`, `**External docs required:**`, **`**Execution effort:** medium`** — always written explicitly. Use `low` only on the user's explicit instruction; never invent another level or a model name.
- `## STEP-BY-STEP TASKS`: each task `### {ACTION} {file}`, a `- [ ]` anchor line, `IMPLEMENT`, `PATTERN`, `IMPORTS`, `GOTCHA`, one or more `EXPECT: present|absent|contains|not-contains — path[ :: literal]`, one `VALIDATE:` command that exits non-zero on failure. Every task is mandatory.
- `## Architecture and contracts` — owned modules, dependency direction, interfaces/invariants, reuse targets (`file:line`), prohibited changes, migration constraints. Compact; these are project constraints, not a coding tutorial for the executor.
- `## UI structural contract` — only when the spec names a design reference: section inventory + order, variant/state matrix, verbatim copy strings, semantic/accessibility requirements, runtime validation (runtime smoke or an explicit `SKIPPED` reason). Delete the section for backend-only plans.
- `## Independent tracks` — one or two sentences on genuinely disjoint tracks (Gate A of `references/plan-split-contract.md`); splitting is the user's decision, never automatic.
- `## TESTING STRATEGY` sized by the project's stated test policy — read the rules authority `node <plugin_root>/scripts/rules.mjs authority --project-root <project_root>` reports (brownfield `CLAUDE.md → Validation`, greenfield `.agents/project-rules.md → Validation`), else the existing suite. Sensitive paths MUST have tests.
- `## VALIDATION COMMANDS` present and executable even when one line.
- Size: target ≤600 lines / 36k chars; over 1 200 lines / 72k chars → stop and ask the user whether to densify or split (a split changes the execution contract; it is never automatic). Disjoint tracks under `## Independent tracks` are offered as a parallel split at any size. **If the user chooses a split, read `references/plan-split-contract.md` and produce exactly that shape** — parallel plans with a `**Parallel track:**` line and no `## Execution Plan`, or an umbrella whose `## Execution Plan` table carries Step / File / Depends On / Status (`manual` for human steps) / Effort per step. Re-measure every resulting file.

### 4. Grill — mandatory self-audit

Look for holes that would actually stop an executor at Opus/medium: missing anchors, unresolvable `VALIDATE` commands (a zero-task run exiting 0 reads as a pass), `EXPECT` that a template could satisfy, untested sensitive paths (payment, auth, webhook, license, locale/redirect routing, permission isolation, subprocess supervision — each names a test file or carries a verbatim `DEFER — manual validation only, why: …`), latent product decisions, contradictions with the spec's out-of-scope, an `Architecture and contracts` block with empty lines, and — when a design reference exists — a UI contract missing any of section inventory, variant matrix, copy strings or semantics (🟠 MAJOR: the executor will diverge from the design DOM). Then one self-critique pass over your own findings (anchored? changes the outcome? honest severity?). Present the surviving findings once and ask the user for the fix scope: **apply all** · **apply selected** · **none**. Apply and re-check size (over the cap → the Step 3 split question again, never a silent split). If the plan is split and a fix added, removed, merged or split a step, update the `## Execution Plan` table (or the `**Parallel track:**` lines) in the same edit and re-check files, dependencies and cycles per `references/plan-split-contract.md`.

### 5. Independent review

`review` group enabled → run the orchestrator with `--author-host <this host> --kind plan --artifact <plan> --dep <spec>` exactly as in `brainstorm` Step 8, following `references/review-contract.md`. Print the result's `summary_line` verbatim before anything else about the review; a `not-executed` result is a blocked opinion with no second model involved, and is reported as such. Rounds: the first opinion stands; a second or third round only after a **material** change to the plan (scope, acceptance criteria, approach, module boundaries, API, data model, permissions, integration, side effects, concurrency, contract) — never for a round counter; maximum three substantive rounds; an unresolved material issue at the cap is a user decision, not `ship`. Editorial changes use local checks. Apply surviving `patchable` findings; `fundamental` ones go to the user with your recommendation. **After the last applied finding, re-measure every plan file once more** — review fixes grow plans too; over the cap → the Step 3 split question, never a silent split. A finding that added, removed, merged or split a step of a split plan also updates `## Execution Plan` (files on disk, dependencies, no cycles) or the `**Parallel track:**` globs in the same edit — a stale table stops the orchestrator. Record `## Independent Review` in the plan (host/model/effort requested and confirmed, `review_id`, reviewed SHA-256, verdict, accepted/rejected findings, rounds, repeat reason). Blocked opinion → advancement stops; only an explicit, recorded user waiver lifts it.

### 6. Report

In the project language: plan path · spec path and SHA-256 · task count · `External docs required` · the review's `summary_line` verbatim, then rounds or waiver · and the line you wrote: `**Execution effort:** medium` (or the user's explicit `low`) with one sentence of rationale. If Step 0.5 matched a package, run `backlog.mjs writeback … --ref <plan path> --consent yes` so the tasks' `Ref` also names the plan; report the changed cells. A blocked or failed plan (review blocked without waiver, size cap, unresolved spec) is reported as **not executable** and writes no plan `Ref` and no completion to the backlog. Point to the execution stage as the user's next decision. Do not run it. Stop.
