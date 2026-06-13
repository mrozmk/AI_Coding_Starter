---
description: Explore requirements and design a solution before planning implementation
argument-hint: [topic or feature idea]
---

# Brainstorm: Design Before You Build

## Topic: $ARGUMENTS

<HARD-GATE>
Do NOT write any code, scaffold files, or take any implementation action until you have presented a design and the user has explicitly approved it. This applies regardless of how simple the feature seems.
</HARD-GATE>

<WHY-GATE>
Before proposing **how** to build anything (Step 3), you must understand **what** the user wants AND **why** — the problem it solves, not just the feature requested. A request names a solution; the "why" names the problem. If the why is unclear or implied, **ask for it first** — it is the single most load-bearing question. Without it you will design a technically-correct solution to the wrong problem, miss a simpler path, or miss that the feature isn't needed at all (YAGNI). Never skip straight from a feature request to approaches.
</WHY-GATE>

## Anti-Pattern: "This Is Too Simple To Need A Design"

Every feature goes through this process. A single new command, a config change, a refactor — all of them. "Simple" projects are where unexamined assumptions cause the most wasted work. The design can be short (a few sentences), but you MUST present it and get approval before moving to planning.

## Process

### Step 1: Read Memory and Explore Context

Before asking any questions:

- Read `.agents/memory/index.md`, then any relevant domain files
- Check recent commits: `git log --oneline -10`
- Explore files relevant to the topic — use **LSP `workspaceSymbol`** to find existing services/types in the topic area and **`documentSymbol`** to grasp a key file's shape without reading it whole (see CLAUDE.md → Code Navigation)
- Check CLAUDE.md for project-specific constraints

Note the current architecture, patterns in use, and any prior decisions that affect this feature.

### Step 2: Ask Clarifying Questions

Ask questions **one at a time**. Do not ask multiple questions in a single message.

- **Why first.** Your opening question establishes the problem (the WHY-GATE) — what outcome the user is really after — before anything about constraints or shape. Get this even if the request sounds concrete.
- Prefer multiple choice when possible — easier to answer than open-ended
- Then focus on: constraints, success criteria, edge cases
- If the request covers multiple independent subsystems, flag it immediately and help the user decompose it before proceeding
- Stop when you have enough to propose approaches

**Question discipline (balance, not interrogation).** This is a short clarifying step, not a relentless interview — usually 2–4 questions. Two rules keep it sharp:

- **Explore the codebase instead of asking** whatever the codebase can answer. Don't ask the user "what's the current auth flow" if you can read it — spend questions only on what's in the user's head.
- **One question per message**, with **your recommended answer attached** — "I'd default to X because Y; agree?" is faster to act on than an open question.

When a clarifying question is worth asking, reach for the type that fits — these are tools, not mandatory rounds:

- **Precision (what exactly):** the user used a fuzzy term — pin it down. "You said 'report' — the live HTML report, or a saved artifact?" Anchor terms to `.agents/memory/architecture.md` where one exists.
- **Conflict (intent vs the record):** the request seems to drift from a documented decision or the project's vocabulary. "Our `decisions.md` settled on X — does this intentionally revisit that, or did you mean something within X?"
- **Scenario stress-test (does the boundary hold):** invent a concrete edge case to force precision about scope. "What happens when two users hit this at once / the input is empty / the upstream call fails?"
- **Code-reality (does the plan match what exists):** the plan assumes behavior the code may not have. Check the code, then reconcile: "The current handler cancels the whole order, but this assumes partial — which is right?"

### Step 3: Propose 2–3 Approaches

Present distinct approaches with trade-offs. Lead with your recommendation and explain why.

For each approach cover:
- What it does and how it fits existing architecture
- Pros and cons
- Complexity and risk

### Step 4: Present Design Section by Section

Once you understand what to build, present the design incrementally:

- **Architecture** — how the feature fits into the existing module layout (entry points, services, core abstractions). The directory map and module roles live in `.agents/memory/architecture.md` (loaded by `/prime`). If context isn't primed, ask the user to run `/prime` first rather than re-walking the tree. Use LSP (`workspaceSymbol` to find the abstractions to plug into, `incomingCalls` on an integration point to see who depends on it) before proposing a new flow.
- **New files / modified files** — exact paths
- **Data flow** — how inputs, events, or timers trigger the feature
- **Edge cases and error handling** — what can go wrong
- **External integrations** — if the feature calls an external API/service, cite the relevant file in `.agents/reference/` (if one exists); otherwise flag that a reference doc should be added before implementation

Ask after each section, in the user's communication language (CLAUDE.md → Language Rules), whether it looks good and whether to continue.

Be ready to revise. Only advance when the user confirms.

### Step 5: Write Design Doc

Save the approved design to:

```
.agents/specs/YYYY-MM-DD-<kebab-case-topic>.md
```

Create `.agents/specs/` if it doesn't exist.

**Doc structure:**

```markdown
# Design: <Feature Name>

**Date:** YYYY-MM-DD
**Status:** Approved
**External docs required:** yes | no

## Summary

<1-2 sentence description of what this builds and why>

## Problem

<What gap or issue this addresses>

## Solution

<Chosen approach and rationale>

## Architecture

<How it fits into the existing codebase — components affected, data flow>

## Files

- **New:** `path/to/file.{ext}` — purpose
- **Modified:** `path/to/existing.{ext}` — what changes

## External dependencies

<If External docs required = yes, list each library / API / service that will need fresh web documentation during planning. One bullet per dep, with the specific area to look up (e.g. "Stripe SDK — webhook signature verification", "Next.js 15 — server actions"). If = no, write "None — all integrations covered by `.agents/reference/`".>

## Edge Cases

<Known edge cases and how they're handled>

## Out of Scope

<What this explicitly does NOT do>

## Open Questions

<Anything unresolved — if none, delete this section>
```

**Setting `External docs required`:**
- **yes** — the implementation needs documentation that is NOT already in `.agents/reference/`: a brand-new library, a new third-party API, an unfamiliar framework feature, or a version that introduces breaking changes.
- **no** — all external integrations are already documented in `.agents/reference/`, or the feature is purely internal (refactor, internal logic, UI polish on existing components).

This flag drives whether `/plan-feature` performs a web-research phase during planning — set it accurately so planning doesn't waste a phase, and doesn't skip docs that are actually needed.

### Step 6: Spec Self-Review

After writing the doc, review it with fresh eyes:

1. **Placeholder scan** — any "TBD", "TODO", incomplete sections? Fix them.
2. **Consistency** — do sections contradict each other? Does architecture match the feature description?
3. **Scope** — is this focused enough, or does it need decomposition into smaller specs?
4. **Ambiguity** — could any requirement be interpreted two ways? Pick one and make it explicit.

Fix inline. No need to re-review after fixing.

### Step 7: User Review Gate

After self-review, ask the user to confirm:

> Tell the user, in the project's communication language (CLAUDE.md → Language Rules): the spec is saved to `<path>`; review it and say if anything should change before moving on to implementation planning.

Wait for the user's response. If they request changes, make them and re-run Step 6. Only proceed when the user approves.

### Step 8: Transition to Planning

Hand off to `/plan-feature`. There is a single planning command — whether it performs a web-research phase is decided automatically from the `External docs required` flag in the spec (set in Step 5).

Tell the user:
- the path to the approved spec,
- the value of `External docs required` (yes/no) and what it means in practice ("planning will fetch web docs for X" or "planning skips external research — all deps covered by `.agents/reference/`").

---

## Key Principles

- **One question at a time** — never stack questions
- **Multiple choice preferred** — easier to answer than open-ended
- **YAGNI ruthlessly** — remove unnecessary complexity from all designs
- **Follow existing patterns** — consult `.agents/memory/architecture.md` and `.agents/memory/patterns.md` (loaded by `/prime`) plus relevant core/base modules before proposing new structure. Don't reinvent conventions the project already documented.
- **Scale to complexity** — a tiny feature gets a short design doc; a large feature gets a thorough one
- **Hard gate holds** — no code, no scaffolding, no file creation until design is approved
