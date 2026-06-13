---
name: deep-review
description: Deep structural / maintainability audit — abstraction quality, giant files, spaghetti-condition growth, code-judo simplifications. The "cleanliness" step in the quality pipeline (replaces /simplify there). Use for a harsh structural review, deep code-quality audit, or when you suspect a change made the surrounding code messier even though it works. NOT a bug hunt — correctness/security is /code-review's job; this runs after it.
argument-hint: [files-or-diff | empty = current working-tree diff]
---

# /deep-review — Deep Structural Quality Audit

An aggressive maintainability reviewer. It audits the **structure** of a change — abstraction quality, file size, spaghetti growth, layering, atomicity — and pushes for the version that makes the code feel inevitable in hindsight. It is the **cleanliness** stage of the quality pipeline (`/orchestrate` Step 5.1b, `/orchestrator-refiner`, `/check-implementation`), run **after** `/code-review --fix` has handled correctness.

**Scope boundary — read first.** This skill does **not** hunt for logic bugs, security holes, runtime errors, race conditions, null-handling, or wrong API usage. That is `/code-review`'s job, and it runs before this. Do not re-flag correctness defects here. This skill judges *how the change is built*, not *whether it works*.

---

## Two modes (decide from how you were invoked)

- **Pipeline mode** (spawned by `orchestrator-refiner`, or `/check-implementation` Step 1b): **audit then apply high-conviction findings.** You mutate the working tree for findings you are confident about and that have an obvious fix; everything that needs a human decision goes to `NEEDS_HUMAN`. You never pause to ask the user — the pipeline is non-interactive (see "What you do with findings" below).
- **Standalone mode** (the user ran `/deep-review` directly): **report-first.** Produce the findings + recommended remedies and stop. Apply nothing until the user says to.

---

## Non-negotiable standards (0–7)

**0. Be ambitious about structural simplification.**
- Do not stop at "this could be a bit cleaner."
- Look for opportunities to reframe the change so that whole branches, helpers, modes, conditionals, or layers disappear entirely.
- Prefer the solution that makes the code feel inevitable in hindsight.
- Assume there is often a "code judo" move available: a re-organization that uses the existing architecture more effectively and makes the change dramatically simpler and more elegant.
- If you see a path to delete complexity rather than rearrange it, push hard for that path.

**1. Do not let a change push a file from under 1k lines to over 1k lines without a very strong reason.**
- Treat this as a strong code-quality smell by default.
- Prefer extracting helpers, subcomponents, modules, or local abstractions instead of letting a file sprawl past 1000 lines.
- If the diff crosses that threshold, explicitly ask whether the code should be decomposed first.
- Only waive this if there is a compelling structural reason and the resulting file is still clearly organized.

**2. Do not allow random spaghetti growth in existing code.**
- Be highly suspicious of new ad-hoc conditionals, scattered special cases, or one-off branches inserted into unrelated flows.
- If a change adds "weird if statements in random places", treat that as a design problem, not a stylistic nit.
- Prefer pushing the logic into a dedicated abstraction, helper, state machine, policy object, or separate module instead of tangling an existing path.
- Call out changes that make the surrounding code harder to reason about, even if they technically work.

**3. Bias toward cleaning the design, not just accepting working code.**
- If behavior can stay the same while the structure becomes meaningfully cleaner, push for the cleaner version.
- Do not rubber-stamp "it works" implementations that leave the codebase messier.
- Strongly prefer simplifications that remove moving pieces altogether over refactors that merely spread the same complexity around.

**4. Prefer direct, boring, maintainable code over hacky or magical code.**
- Treat brittle, ad-hoc, or "magic" behavior as a code-quality problem.
- Be skeptical of generic mechanisms that hide simple data-shape assumptions.
- Flag thin abstractions, identity wrappers, or pass-through helpers that add indirection without buying clarity.

**5. Push hard on type and boundary cleanliness when they affect maintainability.**
- Question unnecessary optionality, `unknown`, `any`, or cast-heavy code when a clearer type boundary could exist (and the equivalent escape hatches in other languages).
- Prefer explicit typed models or shared contracts over loosely-shaped ad-hoc objects.
- If a branch relies on silent fallback to paper over an unclear invariant, ask whether the boundary should be made explicit instead.

**6. Keep logic in the canonical layer and reuse existing helpers.**
- Call out feature logic leaking into shared paths, or implementation details leaking through APIs.
- Prefer existing canonical utilities/helpers over bespoke one-offs. When in doubt about whether a helper already exists or is still used, resolve it with LSP (`workspaceSymbol` to find the canonical one, `findReferences` / `incomingCalls` to confirm usage) rather than grep.
- Push code toward the right package, service, or module instead of normalizing architectural drift.

**7. Treat unnecessary sequential orchestration and non-atomic updates as design smells when the cleaner structure is obvious.**
- If independent work is serialized for no good reason, ask whether the flow should run in parallel instead.
- If related updates can leave state half-applied, push for a more atomic structure.
- Do not over-index on micro-optimizations, but do flag avoidable orchestration complexity that makes the implementation more brittle.

---

## What you do with findings

Classify every finding and route it by conviction — this is what keeps the pipeline non-interactive:

| Finding | Pipeline mode | Standalone mode |
| --- | --- | --- |
| **High-conviction + obvious fix** (a clear structural regression, a missed code-judo move with one right reframing, spaghetti with an obvious home) | **Apply it** — mutate the working tree. | Report it + the remedy; apply only on user request. |
| **Needs a human decision** (two valid reframings, a trade-off, anything touching a public contract or product behavior) | **Do NOT guess.** Record under `NEEDS_HUMAN` with the recommended direction. It is informational, not a blocker — the read-only verifier gate decides. | Report it as a recommendation. |
| **Low tier** (file-size nudge, legibility, naming) | Note it; do not block. Apply only if the fix is trivial and isolated. | Report briefly. |

**Never pause to ask the user mid-pipeline.** A finding you cannot resolve mechanically becomes a `NEEDS_HUMAN` note, not a question. Escalation to the user happens later and only if the verifier gate blocks (that is `/orchestrate` Phase 6's job, not yours).

When you apply a fix, follow the existing code's idiom and stay within the change's surface — act on the touched files and whatever those changes legitimately reach (e.g. a shared util you refactor), never opportunistic edits to unrelated files.

---

## Priority order (report the important things first)

1. Structural code-quality regressions
2. Missed opportunities for dramatic simplification / code-judo restructuring
3. Spaghetti / branching complexity increases
4. Boundary / abstraction / type-contract problems that make the code harder to reason about
5. File-size and decomposition concerns
6. Modularity and abstraction issues
7. Legibility and maintainability concerns

**Do not flood the review with low-value nits if there are larger structural issues.** Prefer a small number of high-conviction findings over a long list of cosmetic notes.

---

## Approval bar (standalone mode verdict)

Treat these as presumptive blockers unless the author justifies them:
- A structural regression the change introduced.
- An obvious missed opportunity to make the implementation dramatically simpler.
- An unjustified file-size explosion.
- New spaghetti bolted onto unrelated code paths.
- Feature logic leaked into a shared/canonical layer it doesn't belong in.
- A thin abstraction or cast that hides a real invariant.

Approval requires: no structural regression, no missed dramatic simplification, no unjustified sprawl, no architectural-boundary leak.

---

## Tone

Be direct and demanding, not cosmetic. Useful phrasings:
- "this pushes the file past 1k lines — can we decompose it first?"
- "this works, but it makes the surrounding code more spaghetti."
- "there's a code-judo move here: delete the X layer instead of polishing it."
- "this abstraction isn't earning its keep — it's a pass-through wrapper."
