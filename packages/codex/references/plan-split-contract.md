# Plan split contract

Read only when the user chose to split a plan (`plan-feature` Phase 3 size question, or Phase 4/5 after fixes pushed a file over the cap). It defines what a *correct* split produces; the execution stage, the orchestrator and the verification gate (still the legacy release) all parse these shapes.

## The question — never decided by the model

A split changes the execution contract: one file runs flat (no worktree, branch or merge); an umbrella runs the full per-step machinery; parallel plans mean a multi-clone operator flow. Ask two gates, in this order, and present only the options that apply, recommendation first; **stop without an answer**:

- **Gate A — parallelism** (asked at any size): are there genuinely disjoint tracks — no shared files, no shared contracts? Passed → offer **(b)** whatever the size.
- **Gate B — size** (only when Gate A failed): over the hard cap (1 200 lines / 72 000 chars) → offer **(a)**, **(c)**, **(d)**.

| Option | Result | Cost to state |
|---|---|---|
| (a) densify in place | one file; cut restatement, never `PATTERN` / `GOTCHA` / `EXPECT` / `VALIDATE` / `VALIDATION COMMANDS` | if still over cap, re-ask and name what was already cut |
| (b) parallel top-level plans | N standalone plans, one clone each, one `--integrate` pass | shared decisions must live in the spec, not be copied N times |
| (c) sequential umbrella + sub-steps | context hygiene only, **no speedup** | per-step machinery; the `## Execution Plan` table below |
| (d) narrow scope / back to `brainstorm` | the spec was too broad | point at the spec's `Appetite & Cut Lines` cut order |

## Option (b) — parallel top-level plans

- Named for their track, not with ordinals: `<feature>-<track>.md`.
- Each is a **complete single-file plan** (own tasks, `EXPECT`/`VALIDATE`, testing strategy, `## VALIDATION COMMANDS`, header fields, `**Source spec:**` pointing at the shared spec).
- Each carries one line `**Parallel track:** <name> — owns <file globs>; does not touch <the other tracks' globs>`. The operator checks disjointness against it before running concurrently.
- **No `## Execution Plan` section** in any of them.
- If the tracks turn out to share a file, they are not parallel — fold back into (a) or (c).

## Option (c) — umbrella + sub-steps

Files: `<plan>.md` (umbrella) plus `<plan>-<step>-<descriptor>.md` per step (`1`, `2`, `3a`, `3b` …). The umbrella keeps goal, strategic decisions, risk register, step map, DoD, and the parsed table below; every sub-step is a complete plan for its slice (header: Parent / Status / Blocker / Pre-read / Tasks with `EXPECT`+`VALIDATE` / DoD).

**Umbrella status is opt-in, never inferred** from a "Step map" heading or a dependency graph in prose. A single-file plan **never** carries `## Execution Plan` — the orchestrator validates every `File` cell against disk and fails fast on a missing file.

`## Execution Plan` (parsed by header match + column names; place it before `## ACCEPTANCE CRITERIA`):

```markdown
## Execution Plan

| Step | File | Depends On | Status | Effort |
| ---- | ---- | ---------- | ------ | ------ |
| 1 | [<plan>-1-<descriptor>.md](./<plan>-1-<descriptor>.md) | — | pending | medium |
| 2 | [<plan>-2-<descriptor>.md](./<plan>-2-<descriptor>.md) | 1 | pending | medium |
```

- **Step** — the sub-file infix; DAG node id.
- **File** — a relative markdown link to the sub-step file, as in the example; the file must exist in the same directory.
- **Depends On** — comma-separated step ids that must be `done` first; `—` for none. Every id must exist in the table; no cycles; fan-in and fan-out allowed. Steps run **sequentially** in table order — the column records order, it is never exploited for concurrency.
- **Status** — `pending` | `in_progress` | `done` | `blocked` | `skipped` | `manual`. Set **`manual`** at plan time for any step a human must do (interactive login, external form, screenshot capture); the orchestrator pauses there and resumes on request.
- **Effort** — `medium` for every step by default, the same rule as the plan header (`planning-contract.md → Execution effort`): the orchestrator reads this cell, not the header, to pick the executor. `low` only where the user explicitly asked for it for that step (or for the whole plan); the model never downgrades a step on its own judgement of how mechanical it looks. No third level, no model name.

A human-readable DAG or complexity table may stay as a marked supplement; the table is the single source of truth — never keep a second dependency table.

## After any split, and after every later fix

A fix that adds, removes, merges or splits a step (grilling, independent review) **must update `## Execution Plan` in the same edit**: every `File` cell resolves on disk, every `Depends On` id exists, no cycle, statuses of untouched steps unchanged; parallel plans re-check their `**Parallel track:**` globs stay disjoint. A stale table stops the orchestrator before the first step.

Re-measure every resulting file. A sub-step still over the hard cap returns to the question (naming what the split already achieved); never split recursively on your own. Asked to split twice over, say the spec is too broad and recommend (d). Report both gates and the decision, also when nothing was split: "no split" is a decision the user can overrule.
