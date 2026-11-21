---
name: deep-review
description: Deep structural / maintainability audit — abstraction quality, giant files, spaghetti-condition growth, code-judo simplifications. The "cleanliness" step in the quality pipeline (replaces /simplify there). Use for a harsh structural review, deep code-quality audit, or when you suspect a change made the surrounding code messier even though it works. NOT a bug hunt — correctness/security is /code-review's job; this runs after it.
argument-hint: [files-or-diff | empty = current working-tree diff] [report-only — a consumed mode token, never treated as a path]
---

# /deep-review — Deep Structural Quality Audit

An aggressive maintainability reviewer. It audits the **structure** of a change — abstraction quality, file size, spaghetti growth, layering, atomicity — and pushes for the version that makes the code feel inevitable in hindsight. It is the **cleanliness** stage of the quality pipeline (`/orchestrate` Step 5.1b, `@orchestrator-refiner`, `/check-implementation`), run **after** `/code-review --fix` has handled correctness.

**Scope boundary — read first.** This skill does **not** hunt for logic bugs, security holes, runtime errors, race conditions, null-handling, or wrong API usage. That is `/code-review`'s job, and it runs before this. Do not re-flag correctness defects here. This skill judges *how the change is built*, not *whether it works*.

---

## Three modes (decide from how you were invoked)

**Strip a literal `report-only` token from `$ARGUMENTS` before anything else. If it was present → Report-only mode, whatever the caller — it overrides caller-based detection.** That strip-first rule is what guarantees two bullets never match at once.

- **Report-only mode** (the `report-only` token was passed): **audit, report, apply nothing.** Output shape — one entry per finding: `file:line` · the problem · the remedy, grouped by the routing table's tiers, with human-decision items under a literal `NEEDS_HUMAN` heading (the caller filters on that label and on the anchors); the Approval bar verdict applies. A standard-9 finding ends with the tags that apply — `rule: CS-<n>`, `duplicate of: <path:line>` — and the report closes with standard 9's `Standards:` line and `Duplicate search:` record (every mode prints both). The caller routes the findings to its own fixer — today the only such caller is `/check-implementation codex`, where Codex is the mutator and this skill must stay a finder.
- **Pipeline mode** (spawned by `orchestrator-refiner`, or `/check-implementation` Step 1b **without** the token, or `/quick-change` Phase 4): **audit then apply high-conviction findings.** You mutate the working tree for findings you are confident about and that have an obvious fix; everything that needs a human decision goes to `NEEDS_HUMAN`. You never pause to ask the user — the pipeline is non-interactive (see "What you do with findings" below).
- **Standalone mode** (the user ran `/deep-review` directly): **report-first.** Produce the findings + recommended remedies and stop. Apply nothing until the user says to.

---

## Non-negotiable standards (0–9)

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
- **String-coded control flow is a type-boundary defect.** A branch the change adds that depends on the content of a free-text string — a prefix, substring, regex or equality test on a message, reason or label (`startsWith("unknown:")`, a status read from a text prefix, a comparison against a persisted message, `!== 'Priv'` while an enum exists) — where an enum, a typed result or an existing type would carry the same fact, is a finding. Remedy: branch on the type. The type exists and is reachable from the changed files → high-conviction + obvious fix; it has to be introduced, or the string crosses a public contract or a persisted value → `NEEDS_HUMAN` with the recommended type. Parsing an external payload's text into a type once, at the boundary, is the fix, not the smell.

**6. Keep logic in the canonical layer and reuse existing helpers.**
- Call out feature logic leaking into shared paths, or implementation details leaking through APIs.
- Prefer existing canonical utilities/helpers over bespoke one-offs. When in doubt about whether a helper already exists or is still used, resolve it with LSP (`workspaceSymbol` to find the canonical one, `findReferences` / `incomingCalls` to confirm usage) rather than grep.
- Push code toward the right package, service, or module instead of normalizing architectural drift.

**7. Treat unnecessary sequential orchestration and non-atomic updates as design smells when the cleaner structure is obvious.**
- If independent work is serialized for no good reason, ask whether the flow should run in parallel instead.
- If related updates can leave state half-applied, push for a more atomic structure.
- Do not over-index on micro-optimizations, but do flag avoidable orchestration complexity that makes the implementation more brittle.

**8. Treat comment noise as a structural smell, and delete it.**
- Narration comments — restating the adjacent statement, echoing a variable / constant / function name, or repeating what the signature already says — are noise, not documentation; **remove them**.
- A multi-line justification attached to a one-line change is a smell: the reasoning belongs in `.agents/memory/` or the spec with a one-line pointer from the code, or it is not needed at all.
- Comment noise is a **high-conviction + obvious-fix** finding — in pipeline mode **apply the deletion**, do not merely note it. It is explicitly **not** a low-tier legibility note; without this line the routing table below files it under "Low tier" and nothing ever removes it.
- **Keep** every comment that records a genuine *why* — a vendor quirk, a rejected alternative, a non-obvious invariant, or a workaround with a ticket reference. Deleting one of those is a regression, not a cleanup, and this clause is what stops the standard from over-correcting.

> This is the step with **write authority** in the comment loop. `guard-comments.sh` only nudges at write time, and `/gates:verify-implementation` only warns — this standard is reached from two independent paths (`orchestrator-refiner` inside `/orchestrate`, and `/check-implementation` Step 1b), which is why the deletion lives here rather than in either of those — except in report-only mode, where the deletion is reported and the caller's fixer applies it.

**9. Measure the change against the project's written standards and against the rest of the repository.**
Two duties, both in every mode. They read beyond the diff; nothing here widens what a mutator may edit.
- **Standards.** If `docs/coding-standards.md` exists at the root of the checkout under review, read it once per review. Its `## Rules` hold `### CS-<n> — <rule>` blocks with `Enforced by:`, `Applies to:`, `Example:` and `Why:`.
  - A change that breaks a rule marked `Enforced by: review` whose `Applies to` covers the changed file is a finding: tag it `rule: CS-<n>` and quote the rule's sentence. When `Applies to` does not clearly cover the file, raise nothing.
  - Rules marked `Enforced by: tool (…)` are not re-checked — the tool owns them.
  - A change that solves a problem listed under `## One shape per problem` in another shape, or re-implements a row of `## Shared helpers`, is a finding that names the row (its `Problem` or `Need` cell) in its text.
  - A convention finding with no `CS-<n>` and no row to cite is not raised from this duty. Items under `## Open — pick one` are never findings.
  - Record `Standards: checked <n> review rules` (n = the `Enforced by: review` rules read), or `Standards: skipped — no docs/coding-standards.md` when the file is absent. The duplicate duty runs either way.
- **Duplicates.** For every function, class, component or module-level helper the change **adds**, search the whole repository — not only the changed files — for an existing equivalent, two ways: *by name* (the new name and its obvious synonyms; LSP `workspaceSymbol` where a language server runs, else `rg`) and *by what it does* (its distinctive call, literal, regex or path — always a text search over the whole repository, `rg --hidden -g '!.git' <pattern>`, LSP or not: plain `rg` from the root skips dot-directories and symbol lookup cannot find a body). The change's own removed side is not a duplicate (a rename or a move), and a `.gitignore`d copy does not count. An equivalent found is a finding naming both paths: `duplicate of: <path:line>`. Record every search in a `Duplicate search:` block, one line per added symbol — `<symbol> — name: <queries> · behaviour: <patterns> · <none | path:line>` — or `Duplicate search: no added symbols`.
- **Routing — the conviction table first, then the remedy's edit scope; never where the existing code lives.** The table under "What you do with findings" still decides first: a remedy that changes a public contract (an exported name or signature other code calls, a route, a persisted value) or product behaviour, or trades one valid reframing against another, is `NEEDS_HUMAN` even when every edit is local. Otherwise a remedy that edits only the changed files — replace the new helper with a call to (an import of) the existing one wherever it lives, follow the documented shape, comply with the broken `CS-<n>` rule — is **high-conviction + obvious fix**. A remedy that needs the existing code moved to a shared place, generalised or changed, touches any file outside the change, or picks between two near-equivalents with no clear canonical one is **`NEEDS_HUMAN`** with the recommended direction.
- **Tags.** A finding from this standard ends with the tags that apply — `rule: CS-<n>` for a broken review rule, `duplicate of: <path:line>` for a duplicate. Never invent a tag to fill the shape.

---

## What you do with findings

Classify every finding and route it by conviction — this is what keeps the pipeline non-interactive:

| Finding | Pipeline mode | Standalone mode | Report-only mode |
| --- | --- | --- | --- |
| **High-conviction + obvious fix** (a clear structural regression, a missed code-judo move with one right reframing, spaghetti with an obvious home) | **Apply it** — mutate the working tree. | Report it + the remedy; apply only on user request. | Report it + the remedy, `file:line`; the caller's fixer applies it. |
| **Needs a human decision** (two valid reframings, a trade-off, anything touching a public contract or product behavior) | **Do NOT guess.** Record under `NEEDS_HUMAN` with the recommended direction. It is informational, not a blocker — the read-only verifier gate decides. | Report it as a recommendation. | Report under `NEEDS_HUMAN` — the caller escalates it to the human, never to its fixer. |
| **Low tier** (file-size nudge, legibility, naming) | Note it; do not block. Apply only if the fix is trivial and isolated. | Report briefly. | Report briefly. |

**Never pause to ask the user mid-pipeline.** A finding you cannot resolve mechanically becomes a `NEEDS_HUMAN` note, not a question. Escalation to the user happens later and only if the verifier gate blocks (that is `/orchestrate` Phase 6's job, not yours).

When you apply a fix, follow the existing code's idiom and stay within the change's surface — act on the touched files and whatever those changes legitimately reach (e.g. a shared util you refactor), never opportunistic edits to unrelated files.

---

## Priority order (report the important things first)

1. Structural code-quality regressions — a broken `Enforced by: review` rule and a re-written existing helper (standard 9) count here
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
- A broken `Enforced by: review` rule, or an existing helper written again (standard 9).

Approval requires: no structural regression, no missed dramatic simplification, no unjustified sprawl, no architectural-boundary leak.

---

## Tone

Be direct and demanding, not cosmetic. Useful phrasings:
- "this pushes the file past 1k lines — can we decompose it first?"
- "this works, but it makes the surrounding code more spaghetti."
- "there's a code-judo move here: delete the X layer instead of polishing it."
- "this abstraction isn't earning its keep — it's a pass-through wrapper."
