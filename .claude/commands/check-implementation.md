---
description: Full implementation quality loop — code-review (fix) → deep-review (structural cleanup) → gates:verify-implementation (+ conditional design-parity audit), looping until the gates approve
argument-hint: [plan-name]
---

# /check-implementation — Full Implementation Quality Loop

Drive freshly-written code (from a spec/plan or a manual change) to **commit-ready**: fix correctness bugs, clean up, then gate — looping until the read-only gate approves, or a cap is hit and it escalates.

This command **applies fixes**, unlike [/gates:verify-implementation](gates/verify-implementation.md) (report-only gate). It does **not** commit or push, unlike [/orchestrate](orchestrate.md) — it leaves an approved, clean working tree for you to `/commit`.

The pieces it composes (each a distinct role — see CLAUDE.md / the command docs):

| Step | Skill / Agent | Role | Mutates? |
|------|---------------|------|----------|
| Correctness | `/code-review --fix` | find & fix logic bugs in the diff | ✅ yes |
| Structural cleanup | `/deep-review` | audit structure/maintainability (code-judo, file-size, spaghetti, layering, atomicity); apply high-conviction findings | ✅ yes |
| Code gate | `/gates:verify-implementation` | tests/lint/build + semantic review + checklist + **code-level** design-token compliance | ❌ read-only |
| Design gate *(conditional)* | `@orchestrator-designer` → `/gates:design-quality-check` | **pixel/structural parity** vs the reference design (Figma MCP or `.agents/specs/design/Ready/`) — spawned as a sub-agent to isolate its visual-tool output; runs **only** when the change touches UI **and** a reference exists | ❌ read-only |

> The design gate is spawned as the read-only `@orchestrator-designer` (not run inline) so its Figma-MCP / browser / screenshot output stays out of this loop's context — it returns only a compact verdict. This mirrors `/orchestrate`'s Step 5.3.

> **Loader Convention.** Assumes `/prime` already loaded project context (`CLAUDE.md`, `architecture.md`, `patterns.md`, etc.). If context isn't primed, run `/prime` first. Do **not** re-read those here.

---

## Why this order (correctness → cleanliness → code gate → design gate)

- **Bugs first.** Don't restructure code you're about to rewrite — a bug fix often changes the shape that `/deep-review` then harmonizes.
- **Structural cleanup second.** `/deep-review` refactors structure, which can introduce regressions — so it must be followed by the gate.
- **Code gate next.** `/gates:verify-implementation` is read-only, so it never invalidates itself; it judges the final state and re-runs tests/build, catching any regression a mutator introduced.
- **Design gate last (conditional).** Pixel/structural parity is the deepest, slowest check and only relevant for UI changes — so it runs after the code gate passes, and only when its preconditions hold (see Step 0). Its gaps feed the same fix channel as the code gate's.
- **The loop absorbs order sensitivity:** if either gate blocks, its findings feed back into the next correctness pass.

---

## Step 0 — Resolve scope

1. If `$ARGUMENTS` is a plan name (e.g. `phase-3b-ui-hero`) → resolve the file under `.agents/plans/active/` or `.agents/plans/done/`.
2. If no argument → use the **most-recently-modified** plan in `.agents/plans/active/`.
3. If no plan is found → **diff-only mode**: scope is the current working-tree change set. Tell the user: `No plan found — running in diff-only mode (code gate skips the checklist; design gate still runs if its preconditions hold).`

Derive `SCOPE_FILES` = the plan's expected files (if any) **∪** the working-tree changes from `git status --porcelain`. The correctness and cleanliness steps act on the changed code; the gate validates against the plan when one exists.

If `git status --porcelain` is empty and there is no plan → STOP: `Nothing to check — working tree is clean and no plan given.`

4. **Design-gate preconditions** — compute `RUN_DESIGN` (cheap; re-check each round since `SCOPE_FILES` can grow). The design gate runs only when **both** hold:
   - **Reference exists** — `.agents/specs/design/Ready/` is non-empty **OR** Figma MCP is connected (any `mcp__figma__*` tool is available this session).
   - **Change touches UI** — `SCOPE_FILES` intersects the UI globs: `*.{tsx,jsx,vue,svelte,astro,html,css,scss,sass,less}`, or a path under `components/`, `pages/`, `views/`, `app/`, `ui/`, `styles/`, or a Tailwind config.

   `RUN_DESIGN = referenceExists ∧ touchesUI`. If either is false → skip the design gate silently, logging one line: `Design gate skipped: <no reference design | change touches no UI files>`. **Default to skip when unsure.** The cost asymmetry is deliberate: a *missed* audit is cheap (the code gate still checks design tokens at code level, and you can run `/gates:design-quality-check` manually); a design audit fired on a **backend-only** change is the exact failure mode this precondition exists to prevent. Rare edge — server-rendered `.html`/email templates can trip `touchesUI`; if `referenceExists` is false (typical for a backend service) the gate still skips, and if it somehow runs, `@orchestrator-designer` returns `skipped` when it finds no reference for the touched sections (a third safety net).

---

## Step 1 — Iteration loop (max 3)

For `N = 1, 2, 3`:

**1a. Correctness — `/code-review`.**
Run `/code-review` at `high` effort over the current diff. Apply the confirmed-bug findings to the working tree (the skill's `--fix` behavior). On iteration `N > 1`, prepend the previous round's unresolved gate findings to the review's focus list, treating them as fixes to apply. Pull them from **both** gates' actual report contracts:
- **Code gate (Step 1c):** two sources, because the gate fail-fasts —
  - **Quality-gate failures first.** When a quality gate (typecheck/lint/test/build) fails, the gate emits `BLOCK` and **skips the semantic review entirely** (`verify-implementation.md` → CRITICAL Rules), so its issue table is empty. The failing command's output *is* the fix list: feed the typecheck/lint/test errors into 1a as the bugs to fix. Never treat an empty issue table on a `BLOCK` as "nothing to fix".
  - **Then the Critical/High rows** of the **semantic-review issue table** (`| Severity | File | Line | Issue | Fix |`) — that gate reports issues in a table, not in `GAPS:`/`BLOCKERS:` sections, so route by severity column.
- **Design gate (Step 1d):** every `GAPS:` line from the `@orchestrator-designer` report (all severities — see 1e; a designer GAP is a concrete token/class/value change the fixer can make).

**1b. Structural cleanup — `/deep-review`.**
Run `/deep-review` (pipeline mode) over the changed code. It audits structure/maintainability — code-judo simplifications, file-size, spaghetti growth, layering, type/boundary cleanliness, atomicity — and applies its high-conviction findings, recording anything that needs a human decision under `NEEDS_HUMAN`. Structure only — it does not hunt bugs; that was 1a.

**1c. Code gate — `/gates:verify-implementation`.**
Run `/gates:verify-implementation <plan>` (read-only). In diff-only mode, run it without a plan argument. Capture its verdict (`APPROVE` / `WARN` / `BLOCK`) and findings.

**1d. Design gate — `@orchestrator-designer` (conditional).**
Skip entirely if `RUN_DESIGN` is false (Step 0) — do not spawn. Otherwise spawn the read-only `@orchestrator-designer` sub-agent. Pass **all** inputs its contract requires (`orchestrator-designer.md` → Inputs), or it will stall asking for them mid-run:

```
PLAN_PATH: <plan path | diff-only>
WORKTREE_PATH: <repo root — `git rev-parse --show-toplevel`>
FILES_TOUCHED:
<the UI files in SCOPE_FILES>
SECTIONS: <section NAMES only, e.g. "hero, faq", derived from the UI files — or "derive from FILES_TOUCHED">
REFERENCE: <Figma node URL/ID when the source is Figma MCP; else the static artifact path; else omit to let the gate resolve from .agents/specs/design/Ready/>
Run /gates:design-quality-check per the preloaded skill. Report via the Designer Output Contract.
```

> `SECTIONS` and `REFERENCE` are **separate** inputs: `SECTIONS` is section names only (`orchestrator-designer.md` → Inputs), and the Figma node / artifact path goes in `REFERENCE` (the optional reference argument of `/gates:design-quality-check`). Never put a node link into `SECTIONS` — the sub-agent would treat the URL as a section name.

> **Figma-only reference — resolve the node *before* spawning, or skip.** `RUN_DESIGN` (Step 0) accepts Figma MCP alone, but `@orchestrator-designer` / `/gates:design-quality-check` need a resolvable **node link** for the section, and when one is missing the skill **asks the user** for it (`design-quality-check.md` → Resolve scope) — a prompt the spawned sub-agent runs unattended and cannot answer, so it would stall. Therefore: when the only reference is Figma MCP, you must have a concrete node link (from the plan, the user's current Figma selection, or asked **here in the main thread before spawning**) to pass in the `REFERENCE` input (**not** `SECTIONS` — see above). **If no node link is resolvable, do not spawn** — log `Design gate skipped: Figma reference but no resolvable node link` and treat the design gate as `passed`/`skipped` (same as `RUN_DESIGN = false`). Never spawn the designer into an unanswerable prompt. Default-to-skip from Step 0 keeps this rare.

Parse its `=== DESIGNER REPORT ===` block: verdict (`passed` / `failed` / `skipped`), `GAPS:`, `BLOCKERS:`. A `skipped` verdict (no resolvable reference for the touched sections) counts as a **pass**. Run this only after 1c so the design audit judges a tests-green tree.

**1e. Decide** — combine the code-gate verdict with the design-gate verdict (treat the design gate as `passed` when `RUN_DESIGN` is false):

| Combined state | Action |
|----------------|--------|
| code `APPROVE` **and** design `passed`/`skipped` | **DONE** — break the loop. |
| code `WARN` (Medium-only) **and** design `passed`/`skipped` (no gaps) | **DONE** — break; surface the warnings in the final report. |
| code `BLOCK` **or** design `failed` (GAPS only, no BLOCKERS), `N < 3` | Feed the next iteration's Step 1a fix list (per the two code-gate sources in 1a): the failing **quality-gate output** (typecheck/lint/test/build errors — present on a `BLOCK` whose issue table is empty because the gate fail-fasted) **and/or** the code gate's **Critical/High** issue-table rows, **plus _all_ design-gate GAPS** (every severity — a `failed` designer verdict means ≥1 gap, and a `MEDIUM`-only report still leaves real, fixable deltas; dropping them would strand the loop with nothing to fix). Loop. |
| either gate reports **BLOCKERS** (decision-required), or `N = 3` with **any** unresolved gate failure (a `BLOCK`, a quality-gate failure, or unresolved GAPS) | **STOP** — escalate to the user with the unresolved findings and iteration history. Do not grind. |

**1f. No-progress guard.** Fire this **only after** a round that *already had a fix list to act on* — i.e. it carried the previous round's gate findings into 1a (so `N > 1`) — applied **no** code changes (neither 1a nor 1b touched files), **and** a gate still fails with the **same** findings unchanged. Then the remaining issue is not mechanically fixable (architecture, product decision, structural design, an ambiguous design interpretation) → **STOP** and ask the user. The mutators cannot resolve it; looping again would change nothing.

> **Do not fire on a first-pass design failure.** On `N = 1`, 1a/1b act only on the diff, so a clean diff can leave them with nothing to change — yet the design gate may surface concrete, fixable token/class GAPS that were never fed to the fixer. That is **1e's "Loop" case, not a no-progress stop**: those GAPS enter the next round's 1a fix list (per 1e). 1f is the backstop for findings that *survived* a fix attempt, not for findings the fixer hasn't seen yet.

---

## Step 2 — Memory reflection

Unlike `/orchestrate`, this loop ran in your own context — you saw first-hand what `/code-review` fixed and how many iterations the gate took. That is high-quality reflection material, so run the **Memory Reflection Protocol** in [.agents/memory/index.md](../../.agents/memory/index.md) over this run **before** writing the final report, so the report's `Memory:` line states what actually happened.

Apply its bar strictly — **the default is to save nothing.** A clean loop (no real bugs, gate approved first try) almost never produces a memory-worthy lesson; do not invent one to justify the step. Save only when the run surfaced something a fresh Claude would get wrong without the note:
- a **non-obvious bug** `/code-review` had to fix (root-cause, not a typo) → `errors.md`
- an **undocumented quirk** that explained a failure → `api.md`
- a **deliberate fix-direction decision** worth its rationale → `decisions.md`

Append at most one or two entries, newest-first. This step does **not** commit — like the rest of the command, it leaves a ready-to-`/commit` tree (a memory write is just another working-tree change). Carry the outcome into the report's `Memory:` line in Step 3.

---

## Step 3 — Final report

```markdown
## Implementation Check: [plan-name | diff-only]

Iterations: <N> of 3
- Correctness (/code-review): <count> bugs fixed — [brief list]
- Structural cleanup (/deep-review): <count> findings applied — [brief list]
- Code gate (/gates:verify-implementation): <APPROVE | WARN | BLOCK>
- Design gate (@orchestrator-designer): <passed | failed | skipped | not run — [no reference | backend change]>

Files modified this run: [list]
Remaining warnings: [Medium issues, or "none"]
Memory: <appended N entr(y/ies) to <file(s)> / nothing worth remembering from this run>

Verdict: <✅ Ready for /commit | ⚠️ Ready with warnings | ❌ Escalated — needs your decision>
```

- **Approved** → `Clean and verified — ready for /commit.` (This command does **not** commit.)
- **Escalated** → present the unresolved findings and the Phase-6-style options (provide guidance / accept anyway / abort), then stop.

---

## CRITICAL rules

- **Both gates stay read-only.** `/gates:verify-implementation` and `@orchestrator-designer` must never edit code — only `/code-review --fix` and `/deep-review` mutate. Keeping the judges independent of the fixer is the whole point (no grading its own homework).
- **The design gate is conditional and defaults to skip.** Never run it on a change that touches no UI files or when no reference design exists (Step 0 `RUN_DESIGN`). A design audit on a backend change is a bug, not thoroughness.
- **Cap at 3 iterations — escalate, don't grind.** Iteration limits exist to surface real blockers.
- **A mutation must be followed by the gate(s).** Never end on a `/deep-review` or `/code-review --fix` without re-running the code gate (and the design gate if `RUN_DESIGN`) — a refactor can break tests or shift a token.
- **Never commit or push.** This command produces a commit-ready tree; committing is `/commit`, the full pipeline is `/orchestrate`.
- **Non-mechanical blockers go to the human.** If a gate blocks on architecture, a product decision, a structural design gap, or an ambiguous design interpretation, stop and ask — fixers can't resolve those.
