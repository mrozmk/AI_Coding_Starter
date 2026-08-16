---
name: architecture-review
description: Codebase-wide architecture audit that hunts for deepening opportunities — shallow modules, pass-through layers, spaghetti coupling, and badly-located maintenance. On-demand (NOT in the feature pipeline). Produces an HTML report of refactor candidates ranked by depth/locality gain. Analyze-only — never mutates code. Uses the depth / locality / deletion-test method (Ousterhout "A Philosophy of Software Design" + Feathers "seams").
argument-hint: "[module or area to focus on | empty = whole codebase] [--codex = second independent sweep by Codex, merged into the report]"
---

# /architecture-review — Codebase-Wide Architecture Audit

Surface architectural friction across the **whole codebase** (or a named area) and propose **deepening opportunities** — refactors that turn shallow modules into deep ones. The aim is leverage, locality, testability, and AI-navigability. This review **reports and reasons; it never edits code.** The actual refactor, once a candidate is chosen, goes through `/brainstorm` → `/plan-feature` → `/execute`.

Resource files for this skill live under `.claude/skills/architecture-review/` — reference them by **full path** (this command file lives in `commands/`, so relative links would resolve wrong).

**Vocabulary is load-bearing.** Use the terms in [`.claude/skills/architecture-review/GLOSSARY.md`](../skills/architecture-review/GLOSSARY.md) **exactly** in every observation and card — module, interface, depth/deep/shallow, seam, adapter, leverage, locality. Don't drift into "component," "service," "API," or "boundary." Consistent language is the point.

---

## What this is NOT — scope boundaries (read first)

This command is deliberately distinct from three neighbours. Pick the right tool:

- **`/deep-review`** — per-diff structural audit of a *change*, runs *inside* the quality pipeline, and **mutates** code (it applies fixes). `/architecture-review` is **codebase-wide**, **on-demand** (outside any feature cycle), and **analyze-only**. The two are **composed, not merged**: this review hands `/deep-review` a target list via the Hotspots section (Phase 2b) and never applies its standards itself.
- **`/analysis`** — a scope-boxed thinking tool for one decision or question; writes **no files**. `/architecture-review` sweeps the whole base and **emits an HTML report** of multiple ranked candidates.
- **`/setup:map-codebase`** — brownfield bootstrap that **documents** an unfamiliar codebase into the knowledge layer; it describes what exists, it does not hunt for debt. `/architecture-review` assumes the map exists and goes looking for **shallow modules worth deepening**.

> In one line: **codebase-wide, on-demand, analyze-only.** It finds refactor candidates; it does not document, decide-in-isolation, or change code.

---

## Phase 0 — Second sweep by Codex (`--codex`, opt-in)

Strip a bare `--codex` token from `$ARGUMENTS` before treating the rest as the focus argument. **Without the flag, skip this phase entirely** and run the review exactly as it ran before — a full `xhigh` Codex sweep of a whole codebase is slow and expensive, and this command is already on-demand.

With the flag: launch Codex on **the same task, with the same method, over the same codebase**, at the very start — so it works while Phase 1 runs. Two sweeps in parallel, not one sweep and one critique.

**Why the same method, not a free-form second opinion.** The method *is* this command's product. A reviewer without `GLOSSARY.md` and `DEEPENING.md` does not return deepening candidates — it returns a generic list of code smells, which is `/deep-review`'s lens and is explicitly out of scope here (see Phase 2b). So Codex gets the full method. The independence we want lives elsewhere:

> **Never show Codex our findings.** Not the candidate list, not the hotspots, not a hypothesis, not "we think module X is shallow" — during this phase or after it. It reads the same method and the same code, and reaches its own conclusions. The difference between the two sweeps must come from *what each noticed*, never from one having been told what the other found. This is the whole reason the phase exists; seeding it turns a second sweep into an echo.

**Precondition.** `command -v codex` — if absent, say so in one line, continue without it, and note in the report that only one sweep ran. **Never fabricate a Codex sweep** (project rule: never fake it).

**Assemble the prompt** in this order:

1. **Orientation** — "First, orient yourself in this project: read `.claude/commands/prime.md` and follow its quick-mode steps. Do not run it as a slash command — just read that file and do what it says."
2. **The method** — "Then read `.claude/skills/architecture-review/GLOSSARY.md` and `.claude/skills/architecture-review/DEEPENING.md`. They define the vocabulary and the method: depth as leverage per unit of interface complexity, the deletion test, seam discipline, the four dependency categories. Use those terms exactly."
3. **The task** — "Sweep this codebase for **deepening opportunities**: shallow modules whose interface is nearly as complex as their implementation, pass-through layers, clusters worth merging into one deep module, and maintenance scattered across callers. Apply the deletion test to everything you suspect is shallow. For each candidate report: the files, the problem in GLOSSARY terms, the deepening you propose, and what callers and maintainers gain. Cite by `file:line`." Add the focus argument if the user gave one; otherwise say the whole base is in scope.
4. **The out-of-scope catch** — "If you notice areas that are simply large, branchy or untested but are *not* depth problems, list them separately at the end under `OUT-OF-LENS:`, one line each, files only. Do not mix them into the candidates." (These feed Hotspots in Phase 2b; the split keeps them from polluting the candidate list.)
5. **Anti-forcing, verbatim** — "Calibrate to what is actually there. A codebase with no strong deepening candidate is a valid, valuable result — say so plainly and stop; do NOT manufacture candidates, pad the list, or inflate a nit into a refactor. Each candidate must earn its place: would it actually change how someone maintains this code? Three real candidates beat fifteen padded ones."
6. **Heartbeat** — "Every ~3 minutes print one short line prefixed `STATUS:`. End with `REVIEW COMPLETE`."

Do **not** put our opinions, expected findings, or severity hints in the prompt. Orientation + method + scope + open task, nothing else.

**Launch** through the shared wrapper, in the background, read-only, prose (no `SCHEMA`) — the contract is [.agents/reference/codex-spawn.md](../../.agents/reference/codex-spawn.md):

```bash
PROMPT="<the assembled prompt>" \
OUT="$SCRATCH/architecture-codex.final.md" \
LOG="$SCRATCH/architecture-codex.log" \
REPO="<repo-root>" \
bash .claude/lib/codex-bg.sh
```

Never inline `codex exec`. Never pass `SANDBOX=workspace-write` — a review mutates nothing. Run with `run_in_background: true`, then **go straight into Phase 1** rather than waiting; that concurrency is the point of running it first.

**Done signal: a non-empty `architecture-codex.final.md`, never process exit alone.** A backgrounded launcher exits 0 while Codex is still thinking, and a hung or killed run also exits without writing. Heartbeats come from the `.log` (`rg '^STATUS:' … | tail -1`) — never read the whole log, it is hundreds of KB of orchestration noise. If Phase 1 finishes first, relay a heartbeat and wait; if Codex is still empty after a long silence, say so and either wait or proceed with one sweep — do not kill a slow-but-alive run, and do not read an empty `.final.md` as "Codex found nothing".

---

## Phase 1 — Explore (read-only)

**Read our knowledge layer first** so the review speaks our domain language and doesn't re-open settled choices:

1. [`.agents/memory/architecture.md`](../../.agents/memory/architecture.md) — our module map and naming rules. Use its domain vocabulary for *what the modules are*; use [`GLOSSARY.md`](../skills/architecture-review/GLOSSARY.md) for *how they're shaped* (depth/seam/adapter).
2. [`.agents/memory/decisions.md`](../../.agents/memory/decisions.md) — settled architectural decisions. **Do not re-litigate these.** If a candidate contradicts a recorded decision, only surface it when the friction is genuinely worth reopening the decision — and mark it clearly in the card as a warning callout (e.g. _"contradicts the 2026-xx-xx decision on X — but worth reopening because…"_). Don't list every refactor a decision forbids.

**Then walk the codebase.** Use the **`Explore`** subagent (read-only search agent) — spawn it via the Agent tool, in parallel calls when sweeping distinct areas (e.g. one per top-level module directory), so codebase size scales the number of agents, not the context. If the user passed a focus argument, scope the sweep to that area; otherwise sweep the whole base.

Don't follow rigid heuristics — explore organically and note where you feel **friction**:

- **Bouncing between modules** — understanding one concept requires hopping across many small modules (poor locality).
- **Shallow interfaces** — the interface is nearly as complex as the implementation (a thin wrapper / pass-through).
- **Pure-function extraction for testability only** — logic split out solely to be unit-testable, while the real bugs hide in *how it's called* (no locality at the call sites).
- **Tightly-coupled leaks** — modules that leak state or assumptions across their seams.
- **Untested / hard-to-test code** — code that's untested, or untestable through its current interface (the interface is the test surface).

**Apply the deletion test** to anything you suspect is shallow: imagine deleting the module. If complexity *vanishes*, it was a pass-through layer — a candidate to delete or merge. If complexity *reappears scattered across N callers*, it was earning its keep — leave it. "Yes, deleting it scatters complexity" is the signal that a module is genuinely deep.

**While sweeping, collect surface signals for the hotspot list** (Phase 2b) — they cost nothing extra, because the `Explore` agents are already walking these files. Record per file only what is *countable without reading for quality*: line count, branch density (`if`/`switch`/ternary/early-return count), fan-in, and whether a sibling test file exists. Nothing else.

> **Guardrail — do not audit content quality here, in any phase.** Naming, comment noise, duplication, hacky constructs, giant functions, spaghetti conditions and type sloppiness are `/deep-review`'s standards, and this command neither applies them nor reports them. A hotspot row says *"this file is large, branchy and untested"* — a measurement. It never says whether the code inside is good. Blurring that line reinstates the merge these two commands were split to avoid, and buries the deepening candidates under nits.

For candidates that involve **merging a cluster of shallow modules**, classify dependencies before recommending the merge — the four categories (in-process / local-substitutable / remote-owned / true-external) each set a different testing strategy. See [`.claude/skills/architecture-review/DEEPENING.md`](../skills/architecture-review/DEEPENING.md).

Do **not** propose interfaces yet — that's Phase 3.

---

## Phase 2 — Present candidates (HTML report)

**If Phase 0 ran, reconcile the two sweeps before rendering anything.** The report is written **once**, from the merged result — do not render ours and patch Codex in afterwards.

Sort every candidate from both sweeps into one of four buckets, and **verify before you accept**: a second model is confidently wrong as often as the first, so check each of its candidates against the real code (`file:line`) and run the deletion test yourself. A candidate that fails verification is dropped, with one line saying why.

- **Both found it** — merge into one card. Note the agreement; it is the strongest signal in the report.
- **Only Codex found it, and it survives verification** — full card, marked as such. **This is the highest-value output of the whole flag** — it is the thing we missed. Say so plainly; do not soften it or bury it below our own candidates because it implicates our sweep.
- **Only we found it** — full card, marked as such. Codex's silence is not a refutation; it may simply not have looked there.
- **Disagreement** — one sweep says merge, the other says leave it (or the deletion tests came out differently). Do not average them into a mushy card. State both readings, give your verdict with the evidence, and mark the card accordingly.

Codex's `OUT-OF-LENS:` lines are **not candidates**. Feed them into the Phase 2b hotspot signals, where they are re-measured like any other area — never promoted to a card on Codex's say-so.

Render the candidates into [`.claude/skills/architecture-review/report-template.html`](../skills/architecture-review/report-template.html), replacing the `{{placeholders}}`, and **save the rendered file to** `.agents/reference/architecture-review-YYYY-MM-DD.html` (use today's date from context). **Never write to `/tmp`, and never into the source tree** — the report is a reference artifact.

Each candidate is one card:

- **Files** — which modules/files are involved.
- **Problem** — why the current architecture causes friction, in GLOSSARY terms (shallow interface, scattered locality, leaky seam…).
- **Solution** — plain-English description of what would change (the deepening), no interface design yet.
- **Benefits** — explained as **leverage** (what callers gain) and **locality** (where change concentrates), plus how tests improve.
- **Before / After diagram** — two Mermaid graphs: "before" reads shallow/scattered (many thin nodes, caller-side complexity), "after" reads deep/local (one module, thin callers).
- **Recommendation badge** — `Strong` / `Worth exploring` / `Speculative`.

---

## Phase 2b — Hotspots (triage hand-off, same report)

The candidate cards above cover **depth**. They deliberately say nothing about the other half of "this codebase is a mess" — file size, spaghetti conditions, duplication, naming, comment noise. That half belongs to `/deep-review`, which is per-file and can apply fixes. This section is the **hand-off between the two**: it names *where* to point that command, using only the signals collected in Phase 1.

Render the hotspots into the `{{#each hotspots}}` block of the template. Each row carries:

- **Area** — the file or small file cluster.
- **Signals** — the countable facts only (e.g. `1 240 lines · 47 branches · no test file · 19 callers`). No adjectives, no verdict.
- **Why it is listed** — one clause naming which signal crossed which threshold. Never a quality judgement.
- **Command** — a copy-ready `/deep-review <paths>` invocation for that row.

**Ranking and thresholds.** Sort by a combination of the signals rather than any single one — a 1 500-line file with 3 branches and full test coverage is not a hotspot, and a 200-line file with 40 branches and no tests is. Absence of tests is the strongest multiplier, because it is the one signal that makes a `/deep-review` fix risky to apply. State the thresholds you used in the section's intro line so the reader can disagree with them.

**Cap the list at 10 rows** — beyond that it stops being a triage and becomes the flood this split exists to prevent. *Yields when* the user asked for the full inventory, or when the report is scoped to a focus argument small enough that the residue is the answer; say explicitly how many rows were withheld and give the ranking rule so the residue is reproducible.

**Emit no hotspot section at all** when nothing crosses the thresholds. An empty table reads as "we checked and it is fine"; the omission plus one line in the chat reply says the same thing without a table to scan.

Hotspots are **not ranked against candidates and never merge into them** — they are a different question with a different owner. A file may legitimately appear in both, and when it does, say so in the row: the deepening comes first, since it may delete the code a `/deep-review` pass would otherwise have cleaned.

---

## Phase 2c — Close the report

End the report with a **Top recommendation** section: which candidate to tackle first and why.

**Then reply in chat** — keep it short, the HTML carries the detail:

- A **clickable markdown link** to the saved report (`.agents/reference/architecture-review-YYYY-MM-DD.html`).
- **3–5 lines** summarizing the headline finding and the top recommendation.
- **One line on the second sweep**, when `--codex` ran — how many candidates each sweep found alone, and *what Codex caught that we didn't*, named. If Codex was unavailable or never produced a result, say that instead, in one line: the report rests on one sweep.
- **One line on hotspots** — how many were listed and the single worst one, with its `/deep-review` command inline so it can be run without opening the report. Omit the line when no hotspot crossed the thresholds, and say that instead.
- A question: **which candidate would you like to drill into?**

Do not repeat the full cards in chat.

---

## Phase 3 — Grilling loop (interactive)

Once the user picks a candidate, design its interface deliberately using **Design It Twice**: see [`.claude/skills/architecture-review/INTERFACE-DESIGN.md`](../skills/architecture-review/INTERFACE-DESIGN.md). Frame the problem space, generate 2–3 radically different interface variants (in parallel via the Agent tool, the way `/design` fans out variants), then compare them by depth / locality / seam-placement and give an **opinionated** recommendation (or a hybrid).

Walk the design tree with the user — constraints, dependency category (per [`DEEPENING.md`](../skills/architecture-review/DEEPENING.md)), the shape of the deepened module, what sits behind the seam, which tests survive.

**Side effects only happen with the user's explicit consent:**

- **Naming a deepened module after a concept that isn't in our map?** Offer to add or sharpen the term in [`.agents/memory/architecture.md`](../../.agents/memory/architecture.md) so future reviews speak the same language. Ask first.
- **User rejects a candidate with a load-bearing reason** — one a future explorer would need to avoid re-suggesting the same refactor? Offer to record it in [`.agents/memory/decisions.md`](../../.agents/memory/decisions.md), framed as: _"Want me to record this so future architecture reviews don't re-suggest it?"_ Skip ephemeral reasons ("not worth it right now") and self-evident ones. Ask first.

**Never rewrite code here.** This phase produces a chosen, interface-designed deepening — the actual implementation is handed off to `/brainstorm` → `/plan-feature` → `/execute`.
