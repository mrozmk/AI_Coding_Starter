---
name: architecture-review
description: Codebase-wide architecture audit that hunts for deepening opportunities — shallow modules, pass-through layers, spaghetti coupling, and badly-located maintenance. On-demand (NOT in the feature pipeline). Produces an HTML report of refactor candidates ranked by depth/locality gain. Analyze-only — never mutates code. Uses the depth / locality / deletion-test method (Ousterhout "A Philosophy of Software Design" + Feathers "seams").
argument-hint: "[module or area to focus on | empty = whole codebase]"
---

# /architecture-review — Codebase-Wide Architecture Audit

Surface architectural friction across the **whole codebase** (or a named area) and propose **deepening opportunities** — refactors that turn shallow modules into deep ones. The aim is leverage, locality, testability, and AI-navigability. This review **reports and reasons; it never edits code.** The actual refactor, once a candidate is chosen, goes through `/brainstorm` → `/plan-feature` → `/execute`.

Resource files for this skill live under `.claude/skills/architecture-review/` — reference them by **full path** (this command file lives in `commands/`, so relative links would resolve wrong).

**Vocabulary is load-bearing.** Use the terms in [`.claude/skills/architecture-review/GLOSSARY.md`](../skills/architecture-review/GLOSSARY.md) **exactly** in every observation and card — module, interface, depth/deep/shallow, seam, adapter, leverage, locality. Don't drift into "component," "service," "API," or "boundary." Consistent language is the point.

---

## What this is NOT — scope boundaries (read first)

This command is deliberately distinct from three neighbours. Pick the right tool:

- **`/deep-review`** — per-diff structural audit of a *change*, runs *inside* the quality pipeline, and **mutates** code (it applies fixes). `/architecture-review` is **codebase-wide**, **on-demand** (outside any feature cycle), and **analyze-only**.
- **`/analysis`** — a scope-boxed thinking tool for one decision or question; writes **no files**. `/architecture-review` sweeps the whole base and **emits an HTML report** of multiple ranked candidates.
- **`/map-codebase`** — brownfield bootstrap that **documents** an unfamiliar codebase into the knowledge layer; it describes what exists, it does not hunt for debt. `/architecture-review` assumes the map exists and goes looking for **shallow modules worth deepening**.

> In one line: **codebase-wide, on-demand, analyze-only.** It finds refactor candidates; it does not document, decide-in-isolation, or change code.

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

For candidates that involve **merging a cluster of shallow modules**, classify dependencies before recommending the merge — the four categories (in-process / local-substitutable / remote-owned / true-external) each set a different testing strategy. See [`.claude/skills/architecture-review/DEEPENING.md`](../skills/architecture-review/DEEPENING.md).

Do **not** propose interfaces yet — that's Phase 3.

---

## Phase 2 — Present candidates (HTML report)

Render the candidates into [`.claude/skills/architecture-review/report-template.html`](../skills/architecture-review/report-template.html), replacing the `{{placeholders}}`, and **save the rendered file to** `.agents/reference/architecture-review-YYYY-MM-DD.html` (use today's date from context). **Never write to `/tmp`, and never into the source tree** — the report is a reference artifact.

Each candidate is one card:

- **Files** — which modules/files are involved.
- **Problem** — why the current architecture causes friction, in GLOSSARY terms (shallow interface, scattered locality, leaky seam…).
- **Solution** — plain-English description of what would change (the deepening), no interface design yet.
- **Benefits** — explained as **leverage** (what callers gain) and **locality** (where change concentrates), plus how tests improve.
- **Before / After diagram** — two Mermaid graphs: "before" reads shallow/scattered (many thin nodes, caller-side complexity), "after" reads deep/local (one module, thin callers).
- **Recommendation badge** — `Strong` / `Worth exploring` / `Speculative`.

End the report with a **Top recommendation** section: which candidate to tackle first and why.

**Then reply in chat** — keep it short, the HTML carries the detail:

- A **clickable markdown link** to the saved report (`.agents/reference/architecture-review-YYYY-MM-DD.html`).
- **3–5 lines** summarizing the headline finding and the top recommendation.
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
