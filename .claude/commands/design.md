---
name: design
description: Guided UI design with forced knowledge load, optional multi-variant generation, and a self-check quality gate before handing back. Use when the user wants to design or redesign UI — triggers "zaprojektuj", "zrób design", "popraw design", "nowy komponent", "redesign sekcji", "design X", EN "design", "redesign", "make a mockup". Force-loads emil-design + redesign + the dials method + the detected design-system tokens, can produce 1 or 3 variants (parallel sub-agents), and self-checks every output against tokens + motion + anti-AI rules before you see it.
---

# /design — Guided UI Design with Variants + Self-Check Gate

A disciplined design pipeline. It force-loads the design knowledge that otherwise sits unused,
optionally generates genuinely-different variants, and self-checks every mockup before the user
sees it. Resources live under `.claude/skills/design/` — reference them by FULL path (this file
is in `commands/`, so bare relative links won't resolve).

**Knowledge it force-loads** (Phase 1): `.claude/skills/design/emil-design.md` (motion/polish),
`.claude/skills/design/redesign.md` (anti-AI audit), `.claude/skills/design/dials.md`
(variant differentiation), `.claude/skills/design/hands.md` (greenfield aesthetics),
`.claude/skills/design/self-check.md` (the gate), **plus the project's design-system tokens**
(detected in Phase 0 — not a hardcoded file).

> **Stack-neutral.** This command makes no assumption about framework, styling system, or build
> tooling. Phase 0 *detects* the token source and the mockup directory; the optional index step
> in Phase 3 *probes* for an indexer and skips silently when there is none. Adapt the area names
> and token references to whatever the project actually uses.

---

## Phase 0 — Recognize

**Detect the token source** (first hit wins; this is what Mode A enforces):

1. `**/tokens.css` or a dedicated design-tokens file
2. global stylesheet with `:root { --... }` custom properties (e.g. `globals.css`, `app.css`)
3. Tailwind theme (`tailwind.config.*` `theme.extend`) or a `theme.ts`/`theme.js`
4. none of the above → **no DS** (greenfield)

**Detect the reference / mockup directory.** Default to `.agents/specs/design/Ready/` (the
convention the rest of this kit's design tooling — `/gates:design-quality-check`,
`@orchestrator-designer` — already uses). If the project keeps mockups elsewhere, use that.

- **DS present** = a token source was found (and, if the project uses one, a reference dir with
  existing component specs).

Pick the mode:

| Mode           | Condition                                                                  | Self-check mode          |
| -------------- | -------------------------------------------------------------------------- | ------------------------ |
| **NEW-to-DS**  | DS exists, user wants a new component/spec                                 | A (tokens enforced)      |
| **FIX**        | DS exists, user wants to edit an existing spec                             | A (tokens enforced)      |
| **BOOTSTRAP**  | No DS at all                                                               | B (internal consistency) |
| **greenfield** | DS exists but user explicitly wants a from-scratch exploration / moodboard | B (internal consistency) |

- For **NEW-to-DS / FIX**: establish `area` (the project's own grouping — e.g. `dashboard` /
  `landing` / `marketing` / `settings` / `shared`; infer it from the existing spec folders) and
  `Name` (PascalCase).
- For **BOOTSTRAP**: STOP and propose a minimal DS first (tokens + foundations) — propose +
  approve, do NOT auto-scaffold (never scaffold without an explicit OK).

## Phase 0.5 — Variant scope (ask)

`AskUserQuestion`: **"1 wariant (dopracowanie) czy 3 (różne podejścia)?"** (1 variant to refine, or
3 distinct approaches?)

- **1** → single path: Phase 1 → 2 → 3 once.
- **3** → fan-out. Pick 3 genuinely-distinct approaches:
  - **DS mode (A)** — same tokens, different composition: e.g. A = conservative (`DESIGN_VARIANCE`
    3, bento), B = balanced (variance 6, split-screen), C = bold (variance 8,
    editorial/asymmetric-hero). Read `.claude/skills/design/dials.md` for the dial→layout mapping.
  - **greenfield (B)** — different aesthetic per variant: A = minimalist hand, B = soft hand,
    C = a third hand or a WebFetched brand ref. Read `.claude/skills/design/hands.md`.

## Phase 1 — Design (forced knowledge, per variant)

**Always read first** (this is the point of the skill — the knowledge is force-loaded, not optional):
`.claude/skills/design/emil-design.md` + `.claude/skills/design/redesign.md` +
`.claude/skills/design/dials.md` (+ `.claude/skills/design/hands.md` in greenfield) +
**the token source detected in Phase 0**. Then, in DS mode, read 1–2 neighbour specs in the
reference dir for the same `area` and consume the actual token values.

- **Single path**: design one mockup HTML with the frontmatter contract (`name` + `priority` + `status`).
- **3-variant path**: **spawn 3 sub-agents in parallel** (Agent tool, parallel calls). Each agent gets:
  - its dial-set (DS mode) or hand (greenfield) + an explicit DIFFERENT layout pattern,
  - the explicit mode token **`MODE=A`** (DS) or **`MODE=B`** (greenfield) — so the agent runs
    self-check in the right mode without re-detecting,
  - the resolved token-source path (DS mode),
  - the forced-read list above,
  - the self-check requirement,
  - **a DISTINCT temp output path OUTSIDE any indexed/build-scanned tree**:
    `/tmp/design-variants/{Name}.variant-{a,b,c}.html`.

  **Path contract (anti-collision + index-safe):** NEVER write under the project's indexed
  reference dir before the pick. If the project auto-scans a mockup tree at build time (see
  Phase 3), an in-tree temp variant could get registered AND break the build, on top of a 3-way
  race on a shared path. `/tmp/design-variants/` is outside the repo → zero index/commit/build
  exposure. Each agent returns its `/tmp` path + self-check verdict.

  (No worktrees — these are standalone HTML artifacts, not committed code. Collect file paths from the agent reports.)

## Phase 2 — Self-check gate (per variant)

Run `.claude/skills/design/self-check.md` in the Phase-0 mode against EACH mockup.
APPROVE / WARN / BLOCK + fix loop **cap 2 iterations** (per the gate). Only
APPROVE-or-user-accepted variants are presented. Each variant is gated independently.

## Phase 3 — Present + persist (post-pick)

- **1 variant**: show it; on user OK → persist.
- **3 variants**: present all 3 with a brief diff of approach → user picks 1.

**Persist the picked variant** (FIRST time anything lands in the reference dir, only AFTER user OK):

1. Promote the chosen `/tmp/design-variants/{Name}.variant-{x}.html` into the tree as
   `<reference-dir>/{area}/{Name}.html` (write with the frontmatter contract).
   The two unpicked temps stay in `/tmp` and never touch the repo (optional `rm -rf /tmp/design-variants/` cleanup).
2. **Index (optional, auto-skip):** if the project exposes a mockup indexer — an
   `npm run design:index:build` script (or a `scripts/build-design-index.*`) — run it to
   regenerate the index. If no such script exists, skip this step silently.
3. **Token drift check (optional, auto-skip):** if the project exposes a token-drift check
   (e.g. `npm run design:tokens:check`), run it. Otherwise skip.

**Foreign-spec guard:** if an index step regenerates the index from disk and its diff includes
specs this run did NOT author (other sessions' untracked specs), surface them and stage ONLY our
own new spec + the index hunk it caused — never sweep foreign registrations (same rule as `/commit`).

Report the final path + self-check verdict. **Commit stays the user's decision** — do not auto-commit.

---

## GOTCHAS

- Reference all materials by FULL `.claude/skills/design/...` path — this file is in `commands/`.
- Sub-agents go samey unless forced: in the spawn prompt give each a DIFFERENT dial-set/hand AND a DIFFERENT layout pattern. This is the #1 risk.
- Pass `MODE=A|B` explicitly and a DISTINCT `/tmp/design-variants/{Name}.variant-{a,b,c}.html` path per agent — never an in-tree reference-dir path.
- BOOTSTRAP proposes, never auto-scaffolds.
- Do NOT add worktree/branch/merge machinery — that is `/orchestrate`'s job for committed code; `/design` produces HTML artifacts.
- Index / token-check scripts are **optional**: probe `package.json` (and `scripts/`) for them and run only what exists. Never hard-fail because a project has no mockup indexer.
