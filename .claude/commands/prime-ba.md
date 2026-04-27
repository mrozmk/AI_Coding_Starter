---
description: Prime agent with product context for the Business Analyst role
---

# Prime BA: Load Product Context for Story Work

## Objective

Build a product-level understanding of the project so the agent can help a Business Analyst write user stories, break features into tasks, and manage the Jira backlog. This command loads **product** context (PRD, specs, decisions, live backlog), not implementation context. For implementation-level priming, use `/prime`.

## Process

### 1. Read Core Product Documentation

Read in this order — stop reading a category if the file doesn't exist:

- `CLAUDE.md` — project rules, language conventions, workflow
- `docs/PRD.md` — product requirements (primary source of truth for what the product is)
- `README.md` — project root readme (context on audience and state)

### 2. Ingest Raw Sources

List and read everything in `.agents/sources/` — briefs, transcripts, sketches, PDFs the user prepared. These are immutable inputs that feed product thinking.

!`ls -la .agents/sources/ 2>/dev/null || echo "no sources/ directory"`

If files are present, read each one. If empty, note "no raw sources".

### 3. Read Approved Specs

List `.agents/specs/` — every file is an approved design doc from `/brainstorm`. Each spec represents a designed-but-not-necessarily-implemented feature.

!`ls -la .agents/specs/ 2>/dev/null || echo "no specs/ directory"`

Read each spec file found. Note its `Status` and `External docs required` flags.

### 4. Load Project Memory

- Read `.agents/memory/index.md` — always
- Read `.agents/memory/decisions.md` — product/architectural decisions the BA must know
- List `.agents/memory/domain/` directory — note which domains have accumulated knowledge:

!`ls .agents/memory/domain/ 2>/dev/null || echo "no domain/ directory"`

Don't read every domain file — just note which exist. Read a specific one only if the BA's task touches that domain.

### 5. Check Plans Pipeline

List plans — what's being implemented and what's already done:

!`ls .agents/plans/active/ 2>/dev/null || echo "no active plans"`
!`ls .agents/plans/done/ 2>/dev/null || echo "no completed plans"`

Filenames only — don't read the plans themselves unless the BA asks.

### 6. Jira Environment + Live Backlog

**Step 6a — Check environment:**

!`echo "JIRA_URL: $([ -n "$JIRA_URL" ] && echo set || echo MISSING)"; echo "JIRA_USERNAME: $([ -n "$JIRA_USERNAME" ] && echo set || echo MISSING)"; echo "JIRA_API_TOKEN: $([ -n "$JIRA_API_TOKEN" ] && echo set || echo MISSING)"; echo "JIRA_DEFAULT_PROJECT: ${JIRA_DEFAULT_PROJECT:-UNSET}"`

**Step 6b — Fetch live backlog (read-only, no confirmation needed):**

If `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN` are all set AND `JIRA_DEFAULT_PROJECT` is set → call:

```
mcp__atlassian__jira_search(
    jql="project = $JIRA_DEFAULT_PROJECT AND type = Epic ORDER BY created DESC",
    fields="summary,status,assignee,priority",
    limit=10
)
```

If any credential env is MISSING → skip this step silently, note "Jira offline" in the report.
If `JIRA_DEFAULT_PROJECT` is UNSET → skip the fetch, note that `JIRA_DEFAULT_PROJECT` is not configured (the BA can still query manually via `/jira search`).

### 7. Understand Current Activity

!`git log -10 --oneline`
!`git status`

---

## Output Report

Present a product-focused summary in these sections. Use bullets and tight prose — the BA needs to scan this fast.

### Product Vision
From PRD:
- **Mission** — one-sentence product mission
- **Target users** — primary personas
- **MVP scope** — 3-5 bullets of what's in scope
- **Out of scope** — 2-3 bullets of what's explicitly deferred

If no PRD exists, say so and recommend running `/create-PRD` first.

### Backlog State

Three parallel views — the BA needs all three to understand what's happening:

**Designed (local specs):**
- List each file in `.agents/specs/` with its one-line summary and `External docs required` flag

**Planned (active implementation):**
- List each file in `.agents/plans/active/`

**Shipped (done):**
- List each file in `.agents/plans/done/`

**Live backlog (Jira, if available):**
- Table of 10 latest epics — `Key | Summary | Status | Priority | Assignee`
- Link each key to `$JIRA_URL/browse/<KEY>`

### Gaps (candidates for story work)

Cross-reference PRD features vs specs/epics. Identify:
- PRD features with **no spec** in `.agents/specs/` — candidates for `/brainstorm`
- Specs with **no matching Jira epic** — candidates for creating Epics in Jira
- Raw sources in `.agents/sources/` that have **no derived spec** — candidates for PRD refresh or `/brainstorm`

Be concrete — name the feature and what's missing. If nothing obvious is missing, say "brak oczywistych luk".

### Key Decisions

Top 3-5 entries from `.agents/memory/decisions.md`. One line each — decision + why.

If empty, note "memory/decisions.md puste — decyzje nie były jeszcze zapisywane".

### Recommended Next Steps

Given the gaps identified, recommend concrete next actions in priority order. Examples:
- `/brainstorm <feature X>` — spec gap identified in PRD
- `/jira create epic` — spec exists but no Jira epic
- `/create-PRD` — no PRD yet, product direction unclear
- Refresh PRD — raw sources present but PRD seems outdated

Limit to 3 recommendations max. If nothing obvious, say "backlog wygląda spójnie — jesteś gotów do pracy nad user stories".

---

## Role Framing for This Session

After the report, remind yourself (and the user) of the BA role posture:
- Focus on **what** and **why**, not **how** (leave implementation detail to `/plan-feature` and developers)
- Prefer user-story format: "As a [user], I want [action], so that [benefit]"
- When creating tasks in Jira, always under a parent Epic (no free-floating tasks — per `jira` skill hard-gate)
- When in doubt about scope or product intent, ask — do not guess
