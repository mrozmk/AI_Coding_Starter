---
description: Full implementation quality loop — code-review (fix) → simplify → verify-implementation, looping until the gate approves
argument-hint: [plan-name]
---

# /check-implementation — Full Implementation Quality Loop

Drive freshly-written code (from a spec/plan or a manual change) to **commit-ready**: fix correctness bugs, clean up, then gate — looping until the read-only gate approves, or a cap is hit and it escalates.

This command **applies fixes**, unlike [/verify-implementation](verify-implementation.md) (report-only gate). It does **not** commit or push, unlike [/orchestrate](orchestrate.md) — it leaves an approved, clean working tree for you to `/commit`.

The three pieces it composes (each a distinct role — see CLAUDE.md / the command docs):

| Step | Skill | Role | Mutates? |
|------|-------|------|----------|
| Correctness | `/code-review --fix` | find & fix logic bugs in the diff | ✅ yes |
| Cleanliness | `/simplify` | apply reuse / simplification / efficiency / altitude cleanups | ✅ yes |
| Gate | `/verify-implementation` | tests/lint/build + semantic review + checklist + design compliance | ❌ read-only |

> **Loader Convention.** Assumes `/prime` already loaded project context (`CLAUDE.md`, `architecture.md`, `patterns.md`, etc.). If context isn't primed, run `/prime` first. Do **not** re-read those here.

---

## Why this order (correctness → cleanliness → gate)

- **Bugs first.** Don't polish code you're about to rewrite — a bug fix often changes the shape that `/simplify` then harmonizes.
- **Cleanliness second.** `/simplify` refactors, which can introduce regressions — so it must be followed by the gate.
- **Gate last.** `/verify-implementation` is read-only, so it never invalidates itself; it judges the final state and re-runs tests/build, catching any regression a mutator introduced.
- **The loop absorbs order sensitivity:** if the gate blocks, its findings feed back into the next correctness pass.

---

## Step 0 — Resolve scope

1. If `$ARGUMENTS` is a plan name (e.g. `phase-3b-ui-hero`) → resolve the file under `.agents/plans/active/` or `.agents/plans/done/`.
2. If no argument → use the **most-recently-modified** plan in `.agents/plans/active/`.
3. If no plan is found → **diff-only mode**: scope is the current working-tree change set. Tell the user: `No plan found — running in diff-only mode (gate skips checklist/design, runs gates + semantic review only).`

Derive `SCOPE_FILES` = the plan's expected files (if any) **∪** the working-tree changes from `git status --porcelain`. The correctness and cleanliness steps act on the changed code; the gate validates against the plan when one exists.

If `git status --porcelain` is empty and there is no plan → STOP: `Nothing to check — working tree is clean and no plan given.`

---

## Step 1 — Iteration loop (max 3)

For `N = 1, 2, 3`:

**1a. Correctness — `/code-review`.**
Run `/code-review` at `high` effort over the current diff. Apply the confirmed-bug findings to the working tree (the skill's `--fix` behavior). On iteration `N > 1`, prepend the gate's unresolved findings from the previous round (Step 1c) to the review's focus list — treat them as bugs to fix.

**1b. Cleanliness — `/simplify`.**
Run `/simplify` over the changed code. It applies reuse / simplification / efficiency / altitude cleanups (quality only — it does not hunt bugs; that was 1a).

**1c. Gate — `/verify-implementation`.**
Run `/verify-implementation <plan>` (read-only). In diff-only mode, run it without a plan argument. Capture its verdict (`APPROVE` / `WARN` / `BLOCK`) and findings.

**1d. Decide:**

| Gate verdict | Action |
|--------------|--------|
| `APPROVE` | **DONE** — break the loop. |
| `WARN` (Medium-only) | **DONE** — break; surface the warnings in the final report. |
| `BLOCK`, `N < 3` | Feed the gate's Critical/High findings into the next iteration's Step 1a as the fix list. Loop. |
| `BLOCK`, `N = 3` | **STOP** — escalate to the user with the unresolved findings and iteration history. Do not grind. |

**1e. No-progress guard.** If a round applied **no** code changes (neither 1a nor 1b touched files) **and** the gate still `BLOCK`s, the remaining issue is not mechanically fixable (architecture, product decision, structural design) → **STOP** and ask the user. The mutators cannot resolve it; looping again would change nothing.

---

## Step 2 — Final report

```markdown
## Implementation Check: [plan-name | diff-only]

Iterations: <N> of 3
- Correctness (/code-review): <count> bugs fixed — [brief list]
- Cleanliness (/simplify):    <count> cleanups applied — [brief list]
- Gate (/verify-implementation): <APPROVE | WARN | BLOCK>

Files modified this run: [list]
Remaining warnings: [Medium issues, or "none"]

Verdict: <✅ Ready for /commit | ⚠️ Ready with warnings | ❌ Escalated — needs your decision>
```

- **Approved** → `Clean and verified — ready for /commit.` (This command does **not** commit.)
- **Escalated** → present the unresolved findings and the Phase-6-style options (provide guidance / accept anyway / abort), then stop.

---

## CRITICAL rules

- **The gate stays read-only.** `/verify-implementation` must never edit code — only `/code-review --fix` and `/simplify` mutate. Keeping the judge independent of the fixer is the whole point (no grading its own homework).
- **Cap at 3 iterations — escalate, don't grind.** Iteration limits exist to surface real blockers.
- **A mutation must be followed by the gate.** Never end on a `/simplify` or `/code-review --fix` without re-running `/verify-implementation` — a refactor can break tests.
- **Never commit or push.** This command produces a commit-ready tree; committing is `/commit`, the full pipeline is `/orchestrate`.
- **Non-mechanical blockers go to the human.** If the gate blocks on architecture, a product decision, or a structural design gap, stop and ask — fixers can't resolve those.
