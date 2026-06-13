---
description: Deep analysis of a problem, decision, or codebase area — no code written, no files created
---

# /analysis — deep analytical pass

`/analysis` is a **thinking tool**, not a doing tool. Use it when the answer matters enough that a surface-level response would be risky: architectural trade-offs, root-cause investigations, "should we do X or Y", non-trivial decisions before they harden into code.

The fact that the user invoked `/analysis` is itself a signal — **the topic carries weight**. A shallow response is a failed `/analysis`.

---

## Hard rules (never violate)

1. **Never write or edit code during `/analysis`.** No `Edit`, `Write`, `MultiEdit`, `NotebookEdit`, no "tiny fix along the way", no refactor, no staged patches. If implementation is warranted, surface it as a next step for the user to run explicitly (e.g. `/plan-feature`, `/execute`) — do not start it yourself.
2. **Never create `.md` files unless the user explicitly asks.** No auto-generated reports, summaries, specs, or scratch notes in `.agents/**`, `docs/**`, or anywhere else. The analysis lives in the chat response. If the user says "zapisz to" / "save this to file" — then and only then write a file, and **save the analysis verbatim (1:1 with the chat output)** — do not redact, compress, or rewrite it. The user asked for the analysis they saw; trimming it on the way to disk destroys the evidence trail.
3. **Always go deep.** Minimum: read the relevant files in full (not skim), check the project knowledge layers, verify claims against the current code — not against memory alone. If you cannot go deep (missing access, ambiguous scope) — stop and ask, don't paper over it.

---

## The 99% certainty rule

Before producing a recommendation you must have **at least 99% certainty** about:

- The **goal** of the question / problem
- The **expected output format** (bullet list? comparison table? narrative?)
- The **scope** being analyzed (which module, which layer, which boundary)
- The **specific technical constraints and requirements**
- Whether **verification or testing** of any factual claim is required

If certainty is below 99% on **any** of these — **stop and ask the user first.** Do not guess, do not "fill in reasonable defaults silently". Assumptions that slip into an analysis without being called out are how bad decisions get anchored.

---

## How to ask (when certainty is below 99%)

When you must ask for clarification:

1. **Prefer the `AskUserQuestion` tool** whenever the question has a finite, enumerable set of reasonable answers (e.g. "Which module — A, B, or both?"). It renders an interactive picker for the user and keeps the exchange compact. Use it over free-form prose questions by default.
2. Fall back to plain-text questions only when the question is genuinely open-ended (e.g. "Describe the failure mode you observed").
3. **List all uncertainties up-front, then ask.** Before firing any tool, write a short block:

   > Before I start, I need to confirm:
   > 1. …
   > 2. …

   This prevents drip-fed questions that waste the user's time.

4. **Never ask for information you can derive.** Read the file, grep the symbol, check the spec — don't offload work the tools can do.

---

## Investigation depth (baseline)

Before forming findings, at minimum:

1. **Read the relevant files fully.** If the question is about a function, read the whole module plus direct callers — find those callers with **LSP `incomingCalls` / `findReferences`** (a complete, real caller list; grep misses some and adds comment/string noise). If it is about a decision, read every file the decision touches.
2. **Check the project knowledge layers:**
   - [.agents/memory/](../../.agents/memory/) — `decisions.md`, `patterns.md`, `errors.md`, `api.md` (and domain files) may already resolve the question.
   - [.agents/specs/](../../.agents/specs/) and [.agents/plans/](../../.agents/plans/) — an active or past feature may have already analyzed this.
   - [.agents/reference/](../../.agents/reference/) — stable domain / API references.
3. **Verify against current code, not memory alone.** Memory records are point-in-time. Before leaning on a memory entry, confirm it still matches the file it describes — update the memory if it drifted.
4. **Map impact.** If the analysis touches a potential change, enumerate what the change would ripple into: callers, tests, docs, configs, migrations. For code callers, derive the list from **LSP `findReferences` / `incomingCalls`** rather than grep — an under-counted impact map is how an analysis anchors a wrong decision.
5. **Scope-box your investigation.** If the set of files you need to read keeps growing past roughly 15–20, or the investigation branches into multiple unrelated subsystems — **stop, surface the current findings, and check in with the user** before continuing. Rabbit-holing is a failure mode of `/analysis`: a partial answer with a clear stop signal is more useful than an endless dive. When you stop, explain *what* you would investigate next and *why*, so the user can decide whether to greenlight it.

The appropriate depth scales with the question. A small scoping question may need 3 files. An architectural question may need a full sweep. **Err on the side of reading one more file** — but not one more subsystem.

---

## Output structure

Adapt to the size of the question, but keep the order:

1. **Understanding** — 2–3 sentences restating the question / problem in your own words. Surfaces misreads immediately.
2. **Scope of investigation** — the files and layers you actually inspected, as markdown links. Gives the user a handle to disagree ("you missed X").
3. **Findings** — facts and observations, each tied to a concrete code reference (`path:line`). Keep findings and opinions separated.
4. **Options considered** — 2–4 alternatives where relevant, each with honest trade-offs (pros **and** cons — never pros-only).
5. **Recommendation** — one recommendation, with the reason in one or two sentences. If the trade-off is close, say so explicitly; do not fake confidence.
6. **Devil's advocate** — one short paragraph stress-testing your own recommendation: *"This could be the wrong call if …"*, *"This breaks down when …"*. Name the concrete scenario, assumption, or future state that would invalidate it. Never skip this, even when you are confident — confident recommendations are exactly the ones most worth stress-testing.
7. **Confidence, open questions & blind spots** — for each non-trivial claim, tag confidence (`99% / 80% / 60%`). End with three short lists:
   - **Open questions** — what is still unknown
   - **Assumptions** — what you treated as given, and why
   - **What I did NOT check** — files, layers, scenarios, or test paths you consciously skipped (with a one-line reason: out of scope, time-boxed, requires access you don't have). This gives the user a handle to say "go back and check X" instead of silently trusting an incomplete view.

This last block is the single most valuable part of `/analysis`. Never skip it.

---

## What `/analysis` is NOT

| This is not… | Use instead |
|--------------|-------------|
| An implementation plan | `/plan-feature` |
| A feature specification | `/brainstorm` |
| A PR review | `/review` |
| A "quick tweak" opportunity | A normal conversation — not `/analysis` |
| A scratch document | The chat response itself |

---

## At the end

Close with a short "Next steps" block so the user can act on the analysis:

- Suggested next command (if any), e.g. *"If you want to proceed, run `/brainstorm` to turn this into a design doc."*
- Any remaining questions the user should answer before committing to a direction.

Never silently transition from analysis to implementation. The handoff is the user's choice.
