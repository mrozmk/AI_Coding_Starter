---
description: Generate or refresh project-brief.md (and business-model.md if applicable) from PRD
argument-hint: [path-to-prd]
---

# Refresh Brief: Distill PRD into Fast-Load Context

## Objective

Generate or refresh `.agents/memory/project-brief.md` from a PRD so that `/prime` can load fast project context without reading the entire PRD. When the PRD contains pricing / monetization / billing content, also seed or refresh `.agents/memory/domain/business-model.md` with code-relevant operational facts.

**When it runs:** `/setup:create-CLAUDE_MD` invokes this automatically at **first bootstrap** (when `project-brief.md` is still empty), so you don't call it by hand in the bootstrap chain. Beyond that it is an **on-demand `maintain/` command** — invoke it yourself after the PRD changes substantially to re-distill the brief.

## Inputs

- `$ARGUMENTS` — optional path to PRD. Default: `docs/PRD.md`.

## Process

### 1. Locate and validate PRD

- Resolve PRD path: `$ARGUMENTS` if provided, otherwise `docs/PRD.md`.
- If the file does not exist → **stop** and tell the user:
  > "PRD not found at `<path>`. Run `/discover` first to generate one, or pass an explicit path: `/maintain:refresh-brief path/to/prd.md`."
- Do not write anything when the PRD is missing.

### 2. Read PRD

Read the full PRD. Identify which sections are present:

- Executive Summary / Mission / Target Users / MVP Scope → feed `project-brief.md`
- Tech Stack / Architecture → feed `project-brief.md`
- Scope → Out of scope (non-goals) (§4), Goals (§2), Core Architecture & Patterns (§7) → feed the brief's Non-goals and Change test sections
- Users & stakeholders → **Source precedence** (§3) → feeds one Key Conventions bullet
- Pricing / Plans / Monetization / Billing / Subscription / Stripe → feed `business-model.md`

When `docs/architecture.md` exists, the PRD's `Technology Stack` / `Core Architecture & Patterns` sections are its digest (written by `/architect`); take Stack/Architecture from them and add `docs/architecture.md` to the brief's Key Files.

### 3. Write `project-brief.md`

Path: `.agents/memory/project-brief.md`.

**Hard cap: 60 lines of body content** (excluding frontmatter) — one limit for the whole brief. Non-goals and Change test take their share of it (at most 10 lines with their headings); every other section keeps its own limit below. The brief is a TL;DR — if you are tempted to exceed 60 lines, condense further.

**Frontmatter:**
```yaml
---
status: populated
populated_by: /maintain:refresh-brief
description: Distilled TL;DR of the PRD — loaded by /prime instead of full PRD
---
```

**Body sections (in this order):**

1. **What** — one paragraph (≤4 lines). Product purpose and value proposition.
2. **Who** — one or two lines per primary persona. Maximum 3 personas.
3. **Non-goals** — the PRD's `Out of scope (non-goals)` list (§4), one bullet each: `<excluded thing> — <reason>`, in the PRD's wording. Keep a horizon qualifier the PRD gives (`in slice 1`, `this cycle`) — never widen a time-boxed exclusion into a permanent one. At most 5 bullets; a longer list → the 5 that most constrain day-to-day changes, then one line `+<N> more — <PRD path> §4` with the path Step 1 resolved. No §4 list, or an empty one → omit this section and Change test; never derive non-goals from other sections (Step 6 warns).
4. **Change test** — exactly two lines, written only when Non-goals is: `A change fits when …` — from the active goals (the active-ids rule of Step 5, **Scope rule — active ids only**, applies to `G-n` here too) and the in-scope list; `Resist a change when …` — from the non-goals and, when §7 holds binding `AD-n` decisions rather than *pending `/architect`*, from those. Keep the PRD's horizon qualifiers.
5. **Stack** — single line summary (e.g. "Next.js 14 + Prisma + Postgres + BullMQ + Redis"). No deep detail — that lives in `architecture.md`.
6. **Architecture** — 5-7 bullets. Top-level pattern, data flow, async/jobs, auth model, deployment shape.
7. **Status** — one line. Phase: bootstrapping / MVP build / post-MVP / mature. Optionally with current focus. When the PRD header carries `**Baseline:**`, add one sub-line `Scope register: Baseline v1.0 (<date>, approved by <who> | proposed) · Current v1.N (<date>) · newest: D-k <title> (<approval>), …` with the three newest `D-n` from `## Change log`. No baseline header → no sub-line.
8. **Key Conventions** — 3-5 bullets. The conventions a fresh contributor would hit on day one. When PRD §3 has a **Source precedence** block, one of these bullets is `Source precedence: <default>[; <subject> — <source>] — overrides by <who> in <where>`, in the PRD's wording; an open block (`Open — Q-n`) → `Source precedence: open — <Q-n>`; no block → no bullet and no warning.
9. **Key Files** — table. Always include: `docs/PRD.md`, `CLAUDE.md`, `README.md`, `.agents/memory/index.md`, `.agents/memory/architecture.md`, `.agents/plans/active/`. Add 2-4 project-critical files if they exist.

**Overwrite policy:** the file is regenerated wholesale — preserve no prior content. Brief is derived state from PRD.

**Non-goals about to vanish:** when the existing brief has a `## Non-goals` section and this PRD has no §4 list, stop before writing: show that section and ask the user — move the still-valid items into PRD §4 and refresh again, or confirm they are dropped. Never carry the old section over: the command cannot tell a hand-written list from one it generated earlier, so carrying it would republish an exclusion the PRD has since removed.

### 4. Decide on `business-model.md`

Scan PRD for any of: "pricing", "plan", "subscription", "tier", "monetiz", "billing", "Stripe", "quota", "rate limit", "feature gate", "free / pro / enterprise".

- **None present** → leave `domain/business-model.md` untouched. Do not change its `status`.
- **Present** → write/refresh `.agents/memory/domain/business-model.md` per Step 5.

### 5. Write `business-model.md` (only if Step 4 triggered)

Path: `.agents/memory/domain/business-model.md`.

**Frontmatter:**
```yaml
---
status: populated
populated_by: /maintain:refresh-brief
description: Operational facts about pricing, plans, billing — what the code needs to know about the business model
---
```

**Scope rule — active ids only:** extract prices, quotas and feature gates from active requirements; a register id (`G` `R` `NFR`) is history when the text right after its `**ID** — ` prefix is `(withdrawn…)` or `(superseded by …)`, when its table row's `Status` cell is `withdrawn…` / `superseded by …`, or — legacy forms — when a list line carries a bare `(withdrawn)` outside its quoted `Quote:` text, or a row of a table without a `Status` column carries `(withdrawn)` outside a quoted `Source` cell; the same words inside `Quote:` or a quoted `Source` cell are content, not state. A superseded value is history and must never become current memory.

**Scope rule — code-relevant only:**
- ✅ Plan IDs, prices, quotas, feature gates, Stripe event names, webhook handlers, rate limits
- ❌ Marketing copy, positioning, GTM strategy, market size, competitor analysis (those stay in PRD)

**Body sections (include only those backed by PRD content):**

1. **Plans** — table: `Plan | Price | Limits | Feature gate`
2. **Billing events** — `event → effect on user/account state`
3. **Feature gates** — `feature → plans that unlock it`
4. **Quotas & rate limits** — `resource → limit per plan`
5. **Webhooks** — `provider event → handler / job`

**Overwrite policy:** regenerate wholesale, same as brief.

### 6. Report

Output a short summary:

```markdown
## Brief refreshed

**Source PRD:** `<path>`

**Files written:**
- `.agents/memory/project-brief.md` (status: populated, <N> lines)
- `.agents/memory/domain/business-model.md` (status: populated, <N> lines)  ← only if seeded

**Skipped:**
- `business-model.md` — no pricing/billing content in PRD  ← only if skipped

**Warnings:**
- ⚠️ PRD has no Out of scope (non-goals) list (§4) — Non-goals and Change test omitted; add §4 and refresh.  ← only when §4 is absent or empty

**Next:** `/prime` will now load brief instead of full PRD.
```

## Notes

- Brief is **append-overwrite**, not append-only — opposite of `errors.md` / `decisions.md`. It mirrors PRD state at the moment of refresh.
- Do not invent content. If a section has no source in PRD, omit the section rather than fill it with placeholders.
- Keep brief in the same language as PRD (typically English for technical content per repo conventions).
