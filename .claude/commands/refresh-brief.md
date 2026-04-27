---
description: Generate or refresh project-brief.md (and business-model.md if applicable) from PRD
argument-hint: [path-to-prd]
---

# Refresh Brief: Distill PRD into Fast-Load Context

## Objective

Generate or refresh `.agents/memory/project-brief.md` from a PRD so that `/prime` can load fast project context without reading the entire PRD. When the PRD contains pricing / monetization / billing content, also seed or refresh `.agents/memory/domain/business-model.md` with code-relevant operational facts.

This is an **on-demand** command. It does not run automatically as part of `/create-PRD` — you invoke it when you want a fresh distilled view.

## Inputs

- `$ARGUMENTS` — optional path to PRD. Default: `docs/PRD.md`.

## Process

### 1. Locate and validate PRD

- Resolve PRD path: `$ARGUMENTS` if provided, otherwise `docs/PRD.md`.
- If the file does not exist → **stop** and tell the user:
  > "PRD not found at `<path>`. Run `/create-PRD` first to generate one, or pass an explicit path: `/refresh-brief path/to/prd.md`."
- Do not write anything when the PRD is missing.

### 2. Read PRD

Read the full PRD. Identify which sections are present:

- Executive Summary / Mission / Target Users / MVP Scope → feed `project-brief.md`
- Tech Stack / Architecture → feed `project-brief.md`
- Pricing / Plans / Monetization / Billing / Subscription / Stripe → feed `business-model.md`

### 3. Write `project-brief.md`

Path: `.agents/memory/project-brief.md`.

**Hard cap: 50 lines of body content** (excluding frontmatter). The brief is a TL;DR — if you are tempted to exceed 50 lines, condense further.

**Frontmatter:**
```yaml
---
status: populated
populated_by: /refresh-brief
description: Distilled TL;DR of the PRD — loaded by /prime instead of full PRD
---
```

**Body sections (in this order):**

1. **What** — one paragraph (≤4 lines). Product purpose and value proposition.
2. **Who** — one or two lines per primary persona. Maximum 3 personas.
3. **Stack** — single line summary (e.g. "Next.js 14 + Prisma + Postgres + BullMQ + Redis"). No deep detail — that lives in `architecture.md`.
4. **Architecture** — 5-7 bullets. Top-level pattern, data flow, async/jobs, auth model, deployment shape.
5. **Status** — one line. Phase: bootstrapping / MVP build / post-MVP / mature. Optionally with current focus.
6. **Key Conventions** — 3-5 bullets. The conventions a fresh contributor would hit on day one.
7. **Key Files** — table. Always include: `docs/PRD.md`, `CLAUDE.md`, `README.md`, `.agents/memory/index.md`, `.agents/memory/architecture.md`, `.agents/plans/active/`. Add 2-4 project-critical files if they exist.

**Overwrite policy:** the file is regenerated wholesale — preserve no prior content. Brief is derived state from PRD.

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
populated_by: /refresh-brief
description: Operational facts about pricing, plans, billing — what the code needs to know about the business model
---
```

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

**Next:** `/prime` will now load brief instead of full PRD.
```

## Notes

- Brief is **append-overwrite**, not append-only — opposite of `errors.md` / `decisions.md`. It mirrors PRD state at the moment of refresh.
- Do not invent content. If a section has no source in PRD, omit the section rather than fill it with placeholders.
- Keep brief in the same language as PRD (typically English for technical content per repo conventions).
