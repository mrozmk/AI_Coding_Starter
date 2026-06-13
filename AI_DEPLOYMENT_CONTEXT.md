<!--
  AI_DEPLOYMENT_CONTEXT.md — gitignored, local-only.
  Purpose: starter context file for a FRESH AI session that needs to understand
  HOW to deploy/adopt this template into a target project. Not project rules
  (that's CLAUDE.md) — this is the "which deployment mode am I in, and what do I
  do" map. Read this, pick a scenario, follow its plan.
-->

# AI Deployment Context — adopting this template into a project

> **You are reading this because a fresh AI window needs to know how to roll this
> workflow template into a target codebase.** This file is *not* the project rules
> ([CLAUDE.md](CLAUDE.md) is). It answers a different question: **"which of the three
> adoption scenarios am I in, and what is the step-by-step plan?"**
>
> This file is **gitignored** — it's local scaffolding context, not shipped project content.

---

## 0. What this repo actually is

A **workflow template** for AI-assisted development with Claude Code. It ships **no
application code** — only the scaffolding that makes Claude a reliable collaborator:
slash commands, sub-agents, skills, permission settings, and five persistent
knowledge layers under `.agents/`.

Authoritative framework guide: **[README.md](README.md)** (the starter's root README — in a
bootstrapped project this guide moves to `.claude/README.md`). Project rules: **[CLAUDE.md](CLAUDE.md)**.

---

## 1. The three layers — what is portable vs. what is sacred

Every adoption decision hinges on this A/B/C split:

| Layer | Paths | Nature | Rule |
|---|---|---|---|
| **A — Skeleton** (portable) | `.claude/commands/`, `.claude/agents/`, `.claude/skills/`, `.claude/templates/`, `.claude/hooks/`, `.claude/README.md` | project-agnostic workflow definitions | **overwrite wholesale** from starter |
| **B — Config** (merge) | `.claude/settings.json`, `.claude/memory-domains.json`, `.agents/memory/index.md`, `.gitignore`, `.mcp.json.example` | shared structure + project additions | **merge / union** — never delete a project entry |
| **C — Knowledge** (sacred) | `CLAUDE.md`, `.agents/memory/*` (errors, decisions, patterns, api, architecture, project-brief, domain/*), `.agents/specs/`, `.agents/plans/`, `.agents/sources/`, `.agents/reference/`, root `README.md`, all source code | project-specific, project-owned | **NEVER overwrite** |

If you remember nothing else: **A overwrite, B merge, C never touch.**

---

## 2. Repo map — what is where, what it does

```
.claude/
  commands/        slash commands (the workflow itself) — see table below
    setup/         create-PRD, stack-research, create-CLAUDE_MD, createwikillm
    maintain/      refresh-brief, cleanup-workflow, sync-from-starter
    gates/         check-quality, verify-implementation, design-quality-check
  agents/          sub-agents (documentation-manager, orchestrator-* pipeline agents)
  skills/jira/     Jira Cloud skill (mcp-atlassian) — create/edit/search/transition/link
  templates/       CLAUDE-template.md, README-template.md (used at bootstrap)
  hooks/           audit-append, check-deps, guard-commit, guard-memory, track-memory-read (need `jq`)
  settings.json    security-first permissions (git non-destructive allowed, destructive denied, secret deny-prefixes)
  memory-domains.json   path→domain rules for guard-memory hook (starts dormant until filled)
  starter-sync-playbook.md  Scenario-2 sync playbook — framework-owned (NOT docs/, project-owned), self-updating

.agents/           FIVE knowledge layers (read .agents/memory/index.md FIRST in any task)
  sources/         raw human input (briefs, transcripts, PDFs) — Claude never writes here
  memory/          lessons/decisions/patterns/api + regenerated architecture.md, project-brief.md, domain/business-model.md
    index.md       "When to Read" routing table — the entry point for every task
  reference/       stable API/domain reference docs
  specs/           design docs from /brainstorm
  plans/           implementation plans: active/ → done/

CLAUDE.md          project rules (slim, ≤200 lines, points into .agents/memory/)
README.md          framework guide (starter) / project README (after bootstrap)
docs/              PROJECT-owned docs (PRD.md lands here via /setup:create-PRD) — never synced
.mcp.json.example  Jira MCP template (copy to .mcp.json, gitignored)
```

### Command quick-reference (the daily workflow)

| Command | Job |
|---|---|
| `/prime` (`/prime full`) | Load project context at session start |
| `/prime-ba` | Load Business-Analyst context (PRD, specs, Jira backlog) |
| `/setup:create-PRD` | Generate `docs/PRD.md` from conversation + `sources/` |
| `/setup:stack-research` | Research + choose tech stack, update PRD, log decision |
| `/maintain:refresh-brief` | Distill PRD → `project-brief.md` (fast-load TL;DR) |
| `/setup:create-CLAUDE_MD` | Generate `CLAUDE.md` + `architecture.md` + project `README.md` from real code |
| `/brainstorm <feature\|JIRA-KEY>` | Explore requirement → design spec in `specs/` |
| `/plan-feature` | Spec → step-by-step plan in `plans/active/` |
| `/execute` | Run the active plan → move to `plans/done/` |
| `/check-implementation` | Full quality loop: code-review --fix → simplify → verify, looping |
| `/gates:verify-implementation` | Read-only verification gate |
| `/orchestrate` | End-to-end pipeline: execute → refine → verify → commit → push |
| `/commit` `/push` `/pull` `/release` | Git workflow (conventional commits, no AI attribution) |
| `/maintain:cleanup-workflow` | Housekeeping: broken-ref check, memory pruning, health warnings |
| `/setup:createwikillm` | Build synthesized LLM wiki (only when ≥3-5 matured specs/plans) |

---

## 3. The three adoption scenarios

Identify which one you're in **before doing anything**:

- Target dir is **empty / brand-new idea** → **Scenario 1 (bootstrap)**
- Target **already used this template, older version**, has its own knowledge + code → **Scenario 2 (sync)**
- Target is a **large existing codebase that never had AI** → **Scenario 3 (brownfield retrofit)**

Decision cue: does `.claude/` exist in the target? **No + empty repo → S1. No + lots of code → S3. Yes (older) → S2.**

---

### Scenario 1 — Empty directory, fresh idea (BOOTSTRAP)

**Have:** full skeleton (A) + config (B) + empty knowledge placeholders (C, `status: empty`).
**Missing:** code, PRD, brief, architecture, decisions. `CLAUDE.md` is seed with `{placeholders}`.
**Risk:** none — this is the happy path.

**Plan (forward order — idea first, then code):**
```
1. Create repo from template (GitHub "Use this template" / gh / clone + rm -rf .git)
2. (optional) drop raw materials into .agents/sources/
3. /setup:create-PRD            → docs/PRD.md
4. /setup:stack-research        → choose stack, update PRD + decisions.md
5. — scaffold the stack —       (npm/uv/cargo/go init, first config files)
6. /maintain:refresh-brief      → project-brief.md
7. /setup:create-CLAUDE_MD      → CLAUDE.md + architecture.md + project README
                                  (first run also moves framework guide to .claude/README.md)
8. (optional) cp .mcp.json.example .mcp.json   → wire Jira / Playwright
→ feature loop: /brainstorm → /plan-feature → /execute → /check-implementation → /commit
```
**Don't:** run `/setup:createwikillm` (nothing to synthesize yet); run `/setup:create-CLAUDE_MD`
on a truly empty repo before any scaffolding (nothing to read).

---

### Scenario 2 — Project on an older template version (SYNC)

**Have:** old skeleton (A) + old config (B) + **live project knowledge** (C — filled
errors/decisions/patterns, custom CLAUDE.md, specs, plans, code). Some commands may be
locally modified.
**Missing:** newest commands/skills/hooks, new settings entries (e.g. new deny-prefixes),
new `index.md` rows.
**Risk (high):** overwriting C, losing local command edits, dropping project permissions.

**Plan — run the command, do not hand-roll:**
```
/maintain:sync-from-starter            # full run: dry-run → approval → apply
/maintain:sync-from-starter --check    # report only, writes nothing
/maintain:sync-from-starter v2.1.0     # pin to a starter ref
```
It clones the starter to `/tmp` → classifies every file A/B/C (authoritative list in
`.claude/starter-sync-playbook.md`) → **A** overwrite (incl. `hooks/`), **B** merge with diff
(settings = UNION of allow/deny, never removes project entries; `index.md` = starter
structure + preserved project `When to Read` rows; `.gitignore`/`.editorconfig`/`memory-domains.json` merge),
**C** untouched → **dry-run report, waits for approval** → applies + sanity-checks → proposes
`chore(workflow): sync … @<hash>` commit. Provenance lives in committed `.claude/.starter-sync.json`
→ repeated syncs become true **3-way merges** (local edit vs staleness, upstream deletions).
On real `settings.json`/hook conflicts it **recommends but asks** (`AskUserQuestion`) — never silently overwrites.

**Manual guards before/after:**
- `git diff .claude/commands/` first — know which command edits the overwrite will erase.
- Custom project commands (not in starter) → playbook flags "check if needed", never deletes — you decide.
- If C-file *format* changed (e.g. new `architecture.md` layout) → regenerate via
  `/setup:create-CLAUDE_MD` / `/maintain:refresh-brief`, never hand-edit.
- After sync: `/prime` to validate context; optionally `/maintain:cleanup-workflow`.

---

### Scenario 3 — Large existing codebase, never had AI (BROWNFIELD RETROFIT)

**Have:** lots of code, probably own README, git history, maybe CI/lint/test — but **zero AI layer**.
**Missing:** entire skeleton + all codified knowledge. Architecture lives only in code + heads.
**Risk:** context flooding (`create-CLAUDE_MD`/architecture trying to read a huge repo),
config collisions (starter `.gitignore`/`.editorconfig` vs project's), hooks premature.

Cannot use "Use this template" (would destroy the repo) and cannot use the sync playbook
(no `.claude/` to start from). This is a **manual skeleton inject, then reverse bootstrap**.

**Phase 0 — inject skeleton (copy A+B only, never C):**
```
1. Clone starter to /tmp.
2. Copy ONLY skeleton into the project:
   .claude/{commands,agents,skills,templates,hooks,README.md}
   .claude/{settings.json,memory-domains.json}
   .agents/  (full structure with status: empty placeholders)
   .mcp.json.example
3. .gitignore → MERGE (append missing lines: .claude/audit.log, .mcp.json,
   .agents/memory/archive/, .claude/settings.local.json) — do NOT overwrite project's.
4. Do NOT copy starter root README (project has its own). Do NOT force a seed CLAUDE.md.
5. chmod +x .claude/hooks/*.sh ; ensure `jq` installed (else hooks fail-open silently).
6. git commit: chore: add AI-assisted dev workflow scaffolding
```
**Phase 1 — reverse bootstrap via `/setup:map-codebase` (one command, scale-safe):**
```
7. /setup:map-codebase   → fan-out comprehension (distilled summaries, NO context flooding):
                           scan & filter → 🛑 Checkpoint 1 (confirm scope) →
                           parallel module-analyzers → architecture.md + docs/PRD.md →
                           🛑 Checkpoint 2 (validate reconstructed PRD) →
                           cascade: /maintain:refresh-brief → /setup:create-CLAUDE_MD
```
> **Why not run the producers by hand:** `/setup:create-CLAUDE_MD` analyzes inline (floods on a
> large repo), `/setup:create-PRD` is conversation-driven (wrong for an existing product). `/setup:map-codebase`
> solves the scale problem structurally — it scales the *number of agents*, not the aggregator's
> context — and chains the whole Phase-1 layer (architecture.md → PRD.md → project-brief.md →
> CLAUDE.md + README) with two human checkpoints. See [.claude/commands/setup/map-codebase.md](.claude/commands/setup/map-codebase.md).

**Phase 2 — enable mechanisms only when they earn their place:**
```
10. memory-domains.json → fill path→domain rules (from _examples) so guard-memory protects context.
11. settings.json → ADD permissions/deny for the real stack + CI; keep security-first.
12. Let errors/decisions/patterns grow NATURALLY from work — do not pre-fill.
13. /setup:createwikillm — only once ≥3-5 specs/done-plans accumulate and knowledge repeats.
```
**Phase 3 — pilot on a narrow slice:**
Pick one small feature, run the full loop `/brainstorm → /plan-feature → /execute →
/check-implementation → /commit` to confirm gates/quality match the stack on live code,
then roll out to the team.

---

## 4. One-glance comparison

| | Have | Missing | Mechanism | Main risk |
|---|---|---|---|---|
| **S1 Empty** | skeleton + config + empty C | code, PRD, knowledge | bootstrap chain (README steps) | none |
| **S2 Old template** | skeleton + config + live C | starter updates | `/maintain:sync-from-starter` (A/B/C, 3-way, dry-run) | overwriting C / local command edits |
| **S3 Brownfield** | only code | entire skeleton + knowledge | manual A+B inject → reverse bootstrap | context flooding at scale, config collisions |

---

## 5. Cross-cutting reminders for any scenario

- **First action in any task:** read [.agents/memory/index.md](.agents/memory/index.md) → its `When to Read` table tells you what else to load.
- **Language:** Claude ↔ developer in **Polish**; code/comments/commits in **English**; app UI per PRD. (See [CLAUDE.md](CLAUDE.md) → Language Rules.)
- **Git safety:** AI runs only non-destructive git ops; destructive ops are denied in `settings.json` — stop and ask the human.
- **Secrets:** never commit; never "Always allow" a Bash command with a literal token — use `$ENV_VARS`.
- **Hooks need `jq`** — without it they fail open silently (no audit log, no memory guard).
- **Don't duplicate `/prime` loads** when authoring commands (Loader Convention in `index.md`).
