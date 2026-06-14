<!-- STARTER-KIT-README: this is the framework guide. On bootstrap, /setup:create-CLAUDE_MD moves
     this file to .claude/README.md and generates a project README in its place. See the
     "About this README" callout below. -->

# AI-Assisted Development Starter Kit

A minimal, opinionated starter for projects built with [Claude Code](https://claude.com/claude-code) as a first-class development partner.

This repo ships **no application code** — only the scaffolding that makes Claude a reliable collaborator:

- `.claude/` — commands, agents, skills, and permission settings
- `.agents/` — five persistent knowledge layers (sources, memory, reference, specs, plans)
- `CLAUDE.md` — project rules seed, ready to be filled in per project
- `.gitignore`, sensible defaults

> **About this README.** While you read it in the *starter repo*, it documents the **framework**.
> The first time you run `/setup:create-CLAUDE_MD` in a real project, this guide is moved to
> `.claude/README.md` and a fresh, project-specific `README.md` is generated in its place (from
> `.claude/templates/README-template.md`). That keeps the root README describing *your* project
> while the framework guide stays available at `.claude/README.md`. See
> [The root README is yours — the framework guide moves aside](#the-root-readme-is-yours--the-framework-guide-moves-aside).

---

## What's in the box

### `.claude/`

| Path | Purpose |
|------|---------|
| `commands/` | Slash commands — `/brainstorm`, `/plan-feature`, `/execute`, `/gates:verify-implementation`, `/gates:design-quality-check`, `/gates:check-quality`, `/check-implementation`, `/deep-review`, `/design`, `/architecture-review`, `/orchestrate`, `/commit`, `/push`, `/pull`, `/release`, `/analysis`, `/handoff`, `/prime`, `/prime-ba`, `/setup:create-PRD`, `/maintain:refresh-brief`, `/setup:stack-research`, `/setup:create-CLAUDE_MD`, `/setup:map-codebase`, `/maintain:sync-from-starter`, `/test-e2e`, `/maintain:cleanup-workflow`, `/memory-audit`, `/retro`, `/setup:createwikillm` |
| `agents/` | Sub-agents — `documentation-manager` + the `/orchestrate` pipeline agents (`orchestrator-executor`, `orchestrator-refiner`, `orchestrator-verifier`, `orchestrator-committer`, `orchestrator-designer`) |
| `skills/` | Skills — `/jira` (Jira Cloud via `mcp-atlassian` — create / edit / search / transition / comment / link Epics, Tasks, Bugs). Plus two command-bound resource bundles loaded by path (no `SKILL.md`): `design/` (UI-design knowledge for `/design`) and `architecture-review/` (depth/locality method for `/architecture-review`). |
| `templates/` | Starting templates — `CLAUDE-template.md` (project rules), `README-template.md` (project README, used by `/setup:create-CLAUDE_MD` on bootstrap) |
| `hooks/` | Workflow hooks — `guard-commit` (empty-commit guard), `guard-push` (pre-publication secret scan), `guard-memory` (memory-distillation gate), `audit-append` (audit log), `track-memory-read` (read telemetry), `nudge-lsp` (nudges toward LSP when a Grep looks like a symbol search), `check-deps` (SessionStart dep preflight). Need `jq`. |
| `workflows/` | `Workflow` orchestration scripts — `map-codebase.js` (brownfield fan-out comprehension), driven by `/setup:map-codebase` |
| `settings.json` | Security-first permissions (non-destructive git allowed, destructive ops denied, deny on secrets, audit-log hooks) |

### `.agents/`

Five layers of persistent project knowledge:

| Layer | Contents | Lifecycle |
|-------|----------|-----------|
| `sources/` | **Raw input materials** — briefs, transcripts, sketches, PDFs supplied by the user. Feeds `/setup:create-PRD` and `/setup:createwikillm`. Never modified by Claude. | Immutable input, pruned manually |
| `memory/` | Lessons, decisions, quirks, patterns, plus three regenerated files: `architecture.md` (directory map), `project-brief.md` (TL;DR of PRD), `domain/business-model.md` (pricing/billing facts) | Mixed — most files append-only, three are regenerated wholesale by their owning command |
| `reference/` | Stable domain/API references | Long-lived, updated as domain evolves |
| `specs/` | Design docs from `/brainstorm` | Lives with the feature |
| `plans/` | Implementation plans — `active/` → `done/` | Short-lived |

Full routing of "what to read when" lives in [.agents/memory/index.md](.agents/memory/index.md) — its `When to Read` table tells Claude which memory files to load for the current task. `CLAUDE.md` stays slim (≤200 lines) and points to memory files instead of duplicating their content.

**Status frontmatter convention.** Regenerated files (`architecture.md`, `project-brief.md`, `domain/business-model.md`) carry a `status: empty | seeded | populated` flag. Files with `status: empty` are unfilled placeholders — `/prime` and other commands skip them, falling back to the source (e.g. PRD instead of empty brief). Run the owning command (`/setup:create-CLAUDE_MD` or `/maintain:refresh-brief`) to populate them.

---

## Two daily flows

This starter supports two distinct roles. Both share the same knowledge layers (`.agents/`, `CLAUDE.md`) — they differ only in the command chain.

> **Why every flow starts with a new chat + prime?** A fresh chat means no leftover context from a previous task that could bias Claude. Priming (`/prime` or `/prime-ba`) is the *first message* in that fresh chat — it loads the project's knowledge layers (PRD brief, architecture map, memory) so Claude reasons over the actual project state instead of guessing. Skipping either step is the most common cause of off-target answers.

### Business Analyst flow

```
New chat → /prime-ba → Source files → /brainstorm → Jira draft → Jira sent
```

| Step | What it means |
|------|---------------|
| **New chat** | Open a fresh Claude Code session — no history, no leftover context from previous tasks. |
| **`/prime-ba`** | Loads the BA-specific context: `docs/PRD.md`, `.agents/specs/`, and the Jira backlog (via `mcp-atlassian`). Implementation details (`patterns.md`, `errors.md`, code) are intentionally skipped — a BA reasons over product, not internals. |
| **Source files** | Drop briefs, transcripts, sketches, PDFs into [.agents/sources/](.agents/sources/). Raw input — never modified by Claude. The BA references these files manually when writing the `/brainstorm` prompt; they are not auto-loaded. |
| **`/brainstorm <feature>`** | Explores the requirement, proposes 2-3 approaches, writes a design spec to `.agents/specs/YYYY-MM-DD-<topic>.md`. No code, no Jira — design gate before anything ships. |
| **Jira draft** | `/jira create` (single issue) or `/jira bulk` (Epic + Tasks) drafts Epic/Task/Bug from the approved spec. Drafts stay local — nothing leaves your machine until you confirm. |
| **Jira sent** | Confirm the draft to send it to Jira Cloud via `mcp-atlassian`. Issues are now visible to the team and ready for the Developer flow. |

### Developer flow

The first half is always the same — **prime → brainstorm → plan-feature** turns an idea (or Jira issue) into an approved, codebase-aware plan. How you take that plan to *shipped* is your call — pick by how much you want to drive:

**A — Manual (more human-in-the-loop):**

```
New chat → /prime → /brainstorm <feature | CS-1> → /plan-feature → /execute → /check-implementation → /commit → /push
```

> You run and review each step. `/check-implementation` **applies** fixes (`code-review --fix` → `simplify`) and loops the read-only gate until it passes, then stops at a clean tree for **you** to `/commit` and `/push`. Best for high-stakes changes, or when you want eyes on every gate.

**B — Orchestrated (hands-off):**

```
New chat → /prime → /brainstorm <feature | CS-1> → /plan-feature → /orchestrate
```

> `/orchestrate` drives the whole back half end-to-end — execute → refine → verify → [design-check] → commit → push — looping fixes itself and escalating to you only on a real blocker. Best for well-scoped plans you trust the pipeline to ship.

| Step | What it means |
|------|---------------|
| **New chat** | Open a fresh Claude Code session — no history, no leftover context from previous tasks. |
| **`/prime`** | Quick mode by default — loads `CLAUDE.md`, `.agents/memory/index.md`, `project-brief.md`, `architecture.md`, plus listings of plans/specs/reference and git state. Use `/prime full` after a long break or for deep multi-area work (also pulls `patterns.md`, `decisions.md`, `api.md`, `errors.md`, populated `domain/*`). |
| **`/brainstorm <feature>` or `/brainstorm CS-1`** | Free-text feature **or** a Jira key — Jira mode pulls the issue's description and acceptance criteria as input. Output: a design spec in `.agents/specs/`. |
| **`/plan-feature`** | Reads the approved spec, analyzes the codebase, optionally runs web research for declared external dependencies, writes a step-by-step plan to `.agents/plans/active/`. |
| **`/execute`** *(flow A)* | Runs the active plan top to bottom. Moves it to `.agents/plans/done/` when complete. |
| **`/check-implementation`** *(flow A)* | Full quality loop: `code-review --fix` (correctness) → `simplify` (cleanliness) → `gates:verify-implementation` (read-only gate, incl. conditional design-parity), looping up to 3× until the gate approves. **Applies** fixes; leaves a commit-ready tree — does **not** commit. |
| **`/commit` → `/push`** *(flow A)* | Conventional-commit message + a memory-reflection checkpoint, then push to the current branch. |
| **`/orchestrate`** *(flow B)* | Runs the whole back half as one pipeline — execute → refine → verify → [design] → commit → push — via sub-agents, looping fixes and escalating only on blockers. Replaces the `/execute … /push` tail of flow A. |

> Both flows share the same gates and memory-reflection — `/orchestrate` just drives them for you instead of you running each command. The read-only, report-only `/gates:verify-implementation` is also available standalone when you only want the verdict without applying fixes.

---

## Requirements

**Required:**
- [Claude Code](https://claude.com/claude-code) — the CLI tool that drives all slash commands and skills shipped here.
- Git — for the `/commit`, `/push`, `/pull`, `/release` workflow.
- [`jq`](https://jqlang.github.io/jq/) — required by the workflow hooks (`guard-memory`, `track-memory-read`, `audit-append`, `guard-push`). Most **fail open silently** without it: the memory-distillation guard never fires, the audit log stays empty, and read telemetry is not recorded — with no error shown. `guard-push` fails open **loudly** (it prints a "secret scan SKIPPED" warning) so the security gap is visible. Install via `brew install jq` / `apt install jq` before relying on those safeguards.
- [`gitleaks`](https://github.com/gitleaks/gitleaks) *(optional)* — if on `PATH`, `guard-push` runs it as a broader entropy/ruleset pass on top of its built-in baseline scan. Without it the baseline (known-format tokens, private keys, credential files, hardcoded assignments) still applies.

**Optional (per integration):**
- **Jira Cloud + `mcp-atlassian`** — only needed if you plan to use the `/jira` skill, or to feed Jira issues into `/test-e2e CS-1`. The starter ships the skill itself but does not require Jira to function. See [Jira integration setup](#jira-integration-optional) below.
- **`uvx`** (from [uv](https://github.com/astral-sh/uv)) — runtime for the `mcp-atlassian` MCP server, only if you wire up Jira.
- **MCP Playwright** — only needed if you plan to use `/test-e2e` for browser-driven E2E test generation. See [MCP Playwright setup](#mcp-playwright-optional) below.

That's it. No language runtime is required by the starter itself — pick your stack when scaffolding the actual project (the seed `CLAUDE.md` is stack-agnostic; `/setup:create-CLAUDE_MD` adapts to whatever you initialize).

### Recommended MCP servers

These three MCP servers extend the shipped commands. Install only what you actually use.

| MCP | What it does | Repo | Used by |
|-----|--------------|------|---------|
| **context7** | Fetches up-to-date library / API docs on demand | [upstash/context7](https://github.com/upstash/context7) | Any command researching external libs (`/plan-feature` Phase 2, `/setup:stack-research`, `/brainstorm` for new deps) |
| **playwright-mcp** | Browser automation — drives a real browser for testing and UI verification | [microsoft/playwright-mcp](https://github.com/microsoft/playwright-mcp) | `/test-e2e`, UI checks in `/gates:verify-implementation` |
| **mcp-atlassian** | Jira Cloud — create / edit / search / transition Epics, Tasks, Bugs | [sooperset/mcp-atlassian](https://github.com/sooperset/mcp-atlassian) | `/jira` skill, `/prime-ba`, `/test-e2e CS-1` |

**Quick install (Claude Code CLI):**

```bash
# context7 — no credentials required
claude mcp add context7 -- npx -y @upstash/context7-mcp

# playwright — no credentials required
claude mcp add playwright -- npx -y @playwright/mcp@latest

# mcp-atlassian — needs Atlassian API token; uses the bundled .mcp.json.example
#   (see "Jira integration (optional)" below)
```

After installing, restart your Claude Code session so the new MCP tools register. Verify with `claude mcp list`.

For canonical install commands, env-var configuration, and version pinning, follow the linked repos.

### Jira integration (optional)

The repo ships a `.mcp.json.example` template. To activate Jira:

1. Copy the template: `cp .mcp.json.example .mcp.json`
2. Fill in your Atlassian credentials in `.mcp.json` — `JIRA_URL`, `JIRA_USERNAME` (your Atlassian email), `JIRA_API_TOKEN` (generate at <https://id.atlassian.com/manage-profile/security/api-tokens>).
3. Optionally export `JIRA_DEFAULT_PROJECT=<KEY>` in your shell so commands like `/jira create` and `/prime-ba` skip the project prompt.

`.mcp.json` is gitignored — credentials never leave your machine. If you skip this, the `/jira` skill simply hard-stops with a clear error message; nothing else breaks.

### MCP Playwright (optional)

Required only if you use the `/test-e2e` command. The starter uses Microsoft's [playwright-mcp](https://github.com/microsoft/playwright-mcp):

```bash
claude mcp add playwright -- npx -y @playwright/mcp@latest
```

Once installed, `/test-e2e` can drive a real browser to explore your UI and generate Playwright test files. If you skip this, `/test-e2e` falls back to a degraded mode (plan derived from code/spec inspection) instead of failing.

---

## Quick start

> **Bootstrap chain:**
> `/setup:create-PRD` → `/setup:stack-research` → `/setup:create-CLAUDE_MD` (after first scaffolding — it distills the brief for you) → `/brainstorm <first feature>`.
>
> Each command produces a concrete artifact and feeds the next one. At bootstrap, `/setup:create-CLAUDE_MD` runs the PRD→brief distillation itself, so you don't call `/maintain:refresh-brief` by hand here — that stays a `maintain/` command for later PRD changes. Running them in order keeps `docs/PRD.md`, `.agents/memory/project-brief.md`, `.agents/memory/architecture.md`, `.agents/memory/decisions.md`, and `.agents/specs/` mutually consistent.

### 1. Create a new project from this template

This repo is a **GitHub template** — pick whichever method you prefer:

**Option A — GitHub UI (recommended):**

1. Go to <https://github.com/mrozmk/AI_Coding_Starter>
2. Click **"Use this template"** → **"Create a new repository"**
3. Name it, choose visibility, create
4. Clone it locally: `git clone <url-of-new-repo> my-new-project && cd my-new-project`

**Option B — `gh` CLI (one-liner):**

```bash
gh repo create my-new-project --template mrozmk/AI_Coding_Starter --private --clone
cd my-new-project
```

Use `--public` instead of `--private` if you want a public repo.

**Option C — manual clone (no GitHub account needed):**

```bash
git clone https://github.com/mrozmk/AI_Coding_Starter my-new-project
cd my-new-project
rm -rf .git
git init
```

All three give you the same result: a fresh project with starter scaffolding and clean git history.

### 2. Drop raw materials (optional)

If you already have briefs, transcripts, sketches, PDFs, or any written materials describing the product — drop them into [.agents/sources/](.agents/sources/). Both `/setup:create-PRD` and `/setup:createwikillm` will pick them up automatically as input context.

> **Next step:** once the materials are in place, run `/setup:create-PRD` (step 3 below) — it reads `.agents/sources/` automatically and uses its contents alongside the conversation to draft the PRD.

### 3. Define the product

```
/setup:create-PRD
```

Generates `docs/PRD.md` from your conversation **plus** any files in `.agents/sources/`. The PRD defines **what** you're building and **why** — target users, MVP scope, success criteria. Tech stack is left as a placeholder; you'll fill it in step 4.

### 4. Research the technology stack

```
/setup:stack-research              # project-level — full stack from PRD (recommended after /setup:create-PRD)
/setup:stack-research realtime     # feature-level — focused research on a specific area
```

> Run this **after** `/setup:create-PRD`. Performs structured web research, proposes 2–3 candidate stacks with concrete pros/cons, asks you to approve the recommendation, then **updates the PRD's `Technology Stack` (and `Core Architecture & Patterns` where relevant) sections** — with diff preview and per-section approval before any edit.
>
> Also auto-appends a one-line entry to `.agents/memory/decisions.md` (newest at top), so future Claude sessions discover the architectural choice without rereading the full brief.

The full brief is saved to `.agents/specs/YYYY-MM-DD-stack-research-<topic>.md` for long-term reference.

### 5. Distill the PRD into a fast-load brief — automatic at bootstrap

```
/maintain:refresh-brief   # only standalone LATER, after substantial PRD changes
```

> **At bootstrap you don't run this** — step 6 (`/setup:create-CLAUDE_MD`) distills the brief for you while it's still empty. `/maintain:refresh-brief` is a **maintenance** command you run later, after the PRD changes substantially.
>
> Either way it generates `.agents/memory/project-brief.md` — a 50-line TL;DR that `/prime` loads instead of the full PRD on every session start — and, if the PRD has pricing/billing/monetization sections, also seeds `.agents/memory/domain/business-model.md` (plan IDs, feature gates, Stripe events).

### 6. Initialize project rules (after first scaffolding)

```
/setup:create-CLAUDE_MD
```

> Run this **after** you have at least some scaffolding (e.g. `npm init`, `uv init`, initial config files). It analyzes the codebase to extract real patterns — on a truly empty repo it has nothing to read. The seed `CLAUDE.md` already ships with language rules, knowledge-layer routing, and security defaults, so you are not blocked without this step.
>
> **It also distills the brief for you at bootstrap:** if `project-brief.md` is still empty and a `docs/PRD.md` exists, this command runs the PRD→brief step itself before generating the README/CLAUDE.md — so step 5 isn't a separate manual call. (It skips that if the brief is already current.)
>
> **Adopting into a large existing codebase (brownfield)?** Don't run this alone — run [`/setup:map-codebase`](.claude/commands/setup/map-codebase.md) instead. It fans out parallel analysis sub-agents (distilled summaries, no context flooding), produces `architecture.md` + a reconstructed `docs/PRD.md`, and cascades into `/maintain:refresh-brief` and `/setup:create-CLAUDE_MD` — the whole Phase-1 AI layer in one guided run with two review checkpoints.

It generates **three files** in tandem:
- `CLAUDE.md` — slim rules file (≤200 lines), filled with project overview, tech stack, commands, conventions
- `.agents/memory/architecture.md` — full directory map, module roles, naming rules (loaded on demand, not in every conversation)
- `README.md` — the project's human-facing README. On the **first run** this also moves the starter's framework guide to `.claude/README.md` (see [below](#the-root-readme-is-yours--the-framework-guide-moves-aside)).

The CLAUDE/architecture split keeps `CLAUDE.md` cheap to load every session while preserving the detailed map.

### 7. Design a feature

```
/brainstorm <feature idea>
```

Explores requirements, proposes 2-3 approaches, and writes a design doc to `.agents/specs/YYYY-MM-DD-<topic>.md`. No code is written until the design is approved.

### 8. Plan the implementation

```
/plan-feature          # picks up the newest spec from .agents/specs/
/plan-feature .agents/specs/2026-04-19-my-feature.md   # or point at a specific spec
```

Reads the approved spec, analyzes the codebase, and — **only if** the spec declares `External docs required: yes` — performs a web-research phase for the libs/APIs listed in the spec's `External dependencies`. Writes a step-by-step plan to `.agents/plans/active/`.

### 9. Execute

```
/execute
```

Runs the active plan. Moves it to `.agents/plans/done/` when complete.

> If the feature includes UI, run `/test-e2e <flow-name>` (or `/test-e2e CS-1` to pull acceptance criteria from a Jira issue) after implementation to generate Playwright E2E tests. Requires MCP Playwright (see Requirements above); falls back to degraded mode without it.
>
> Run `/gates:verify-implementation` after `/execute` to validate the plan was satisfied — checklist coverage, quality gates, semantic review, and (for UI) design compliance. Reports only; no code changes.

### 10. Commit

```
/commit
```

Conventional-commit message, plus a memory checkpoint — captures any lessons, decisions, or patterns worth keeping in `.agents/memory/`.

---

## Daily workflow

| Command | When to run |
|---------|-------------|
| `/prime` | Start of every session — quick mode: loads `CLAUDE.md` + `index.md` + `project-brief.md` + `architecture.md` + listings only. Cheap and sufficient for most sessions. |
| `/prime full` | When returning to a project after a long break or starting deep multi-area work — also loads `patterns.md`, `decisions.md`, `api.md`, `errors.md`, all `domain/*`, `reference/`, `specs/`. |
| `/prime-ba` | When working as a Business Analyst on stories/backlog — loads PRD, specs, Jira backlog (no implementation context). Independent from `/prime`. |
| `/maintain:refresh-brief` | After substantial PRD changes — regenerates `project-brief.md` (and `domain/business-model.md` if PRD has pricing content) so future `/prime` calls stay fast and current. |
| `/setup:stack-research` | Once after `/setup:create-PRD` for project-wide stack selection; ad-hoc later for focused research on a specific area (`/setup:stack-research realtime`, `/setup:stack-research auth`). Updates PRD `Technology Stack` section + logs decision. |
| `/setup:map-codebase` | **Brownfield bootstrap** — adopting the workflow into a large existing codebase that never had AI. One run: parallel fan-out comprehension (distilled summaries, no context flooding) → `architecture.md` + reconstructed `docs/PRD.md` → cascades into `/maintain:refresh-brief` + `/setup:create-CLAUDE_MD`. Two review checkpoints (scope; PRD validation). See [.claude/commands/setup/map-codebase.md](.claude/commands/setup/map-codebase.md). |
| `/test-e2e <flow\|jira-key>` | After implementing a UI feature — explores the UI with MCP Playwright, produces a test plan for approval, generates Playwright tests under the project's test directory. Three input modes: empty (reads latest plan in `.agents/plans/active/`), Jira key like `CS-1` (pulls acceptance criteria via mcp-atlassian), or a flow name. Requires MCP Playwright; falls back to degraded mode otherwise. |
| `/maintain:sync-from-starter [--check\|<ref>]` | Pull newer workflow definitions from the upstream starter (commands, agents, skills, hooks, config) without touching project knowledge. 3-way aware via a committed `.claude/.starter-sync.json` provenance manifest; recommends but asks on `settings.json`/hook conflicts. `--check` = dry-run only; `<ref>` = pin to a tag. See [.claude/starter-sync-playbook.md](.claude/starter-sync-playbook.md). |
| `/maintain:cleanup-workflow` | Periodic AI-workflow housekeeping. Three sequential phases: (1) reference integrity check across 5 categories — markdown links, path refs, section anchors, slash commands, MCP tool refs; (2) memory pruning — surfaces stale entries in `errors.md` / `decisions.md` / `patterns.md` / `api.md` / `domain/*` and archives them (per-entry user decision) to `.agents/memory/archive/`; (3) workflow health warnings — empty status stuck >30 days, orphan specs, stale active plans, audit log size, large memory files. No auto-fix in Phase 1, archive-not-delete in Phase 2, signal-only in Phase 3. |
| `/retro` | At the end of a long or frictional session, before `/clear` — generates an **evidence-based** session retrospective from the session's `.jsonl` transcript (paths, counts, tool-call refs, timestamps; no opinions or self-assessment). Refuses to write when the session was trivial or friction-free (`<15` tool calls, `<5` min, or zero friction signals) — `--force` overrides loudly. Saves one `.md` under `.agents/retros/` (or `.claude/retros/`); never touches code or repo state. Output feeds `/maintain:cleanup-workflow`. Flags: `--dry-run`, `--force`, `--transcript <path>`, `--slug <kebab>`. |
| `/analysis` | Deep analytical pass before a decision — no code, no files, 99% certainty rule, uses `AskUserQuestion` when possible. |
| `/gates:check-quality` | Before committing — format, lint, type-check, file-size gates. |
| `/gates:verify-implementation [plan-name]` | After `/execute` finishes a plan — validates checklist completion, runs quality gates from `CLAUDE.md → Validation` (or stack-detected fallback), performs language-aware semantic review (TypeScript-first; sections gated on detected stack), and verifies design compliance for UI plans. Reports only — does not modify code. |
| `/check-implementation [plan-name]` | The **full** quality loop after `/execute`: `code-review --fix` (correctness) → `simplify` (cleanliness) → `gates:verify-implementation` (read-only gate), looping up to 3× until the gate approves, then stopping for `/commit`. Unlike `/gates:verify-implementation` it **applies** fixes; unlike `/orchestrate` it does not commit/push. The same loop `/orchestrate` runs per-step (Step 5.1b). |

---

## Orchestration internals — how the agent-spawning commands work

Three commands do heavy multi-step work. They use **two different orchestration mechanisms** and spawn different agents on different models. This section spells out exactly what runs, when, why, and on which model.

### Model strategy (shared across the pipeline)

The principle is **right model for the job** — judgment work on the strongest model, mechanical work on the cheapest:

| Role | Agent | Model | Mutates? | Why |
|------|-------|-------|----------|-----|
| Orchestrator (your session) | — (the `/orchestrate` driver) | your interactive model (typically **Opus 4.8**) | no (decides/routes) | needs the most judgment — it loops, gates, escalates |
| Execute a plan | `orchestrator-executor` | **Sonnet 4.6** (`acceptEdits`) | ✅ code | implementation: fast + capable; per-step overridable to `opus`/`haiku` |
| Refine (bugs + cleanup) | `orchestrator-refiner` | **Sonnet 4.6** (`acceptEdits`) | ✅ code | runs `code-review --fix` + `simplify` |
| Verify (code gate) | `orchestrator-verifier` | **Opus 4.8**, `effort: high` | ❌ read-only | the gate must be sharp; independence from the fixer |
| Design parity | `orchestrator-designer` | **Opus 4.8**, `effort: high` | ❌ read-only | pixel/structural audit vs reference design |
| Commit | `orchestrator-committer` | **Haiku 4.5** (`acceptEdits`) | ✅ git index | purely mechanical stage+commit — cheapest tier |
| Doc sync | `documentation-manager` | inherits | ✅ docs | only on `/orchestrate --sync-docs` when docs would drift |

> Keeping the **verifier/designer (judges) on a different, read-only setup from the executor/refiner (fixers)** is deliberate — no agent grades its own homework.

### `/check-implementation` — in-context quality loop (no fleet)

Drives freshly-written code to **commit-ready**, then stops. Runs **in your own session** (you see every step) — it does *not* spawn an executor fleet; the only thing it spawns is the design gate (to isolate visual-tool output). It **applies fixes** but never commits.

```
resolve scope (plan | diff-only)
  └─ loop, max 3×:
       1a /code-review --fix   (correctness — find & fix logic bugs)
       1b /deep-review         (cleanliness — structural / maintainability cleanup)
       1c /gates:verify-implementation   (read-only CODE gate: tests/lint/build + semantic review)
       1d @orchestrator-designer  ← spawned, Opus 4.8, ONLY if UI changed AND a reference design exists
       1e decide: approve → done · gaps → feed into next 1a · blocker / 3× → escalate to you
  └─ leaves a clean tree → you run /commit
```

**Why this order:** bugs first (don't polish code you're about to rewrite), cleanliness second, then the read-only gate (it can't invalidate itself), design last (slowest, UI-only). The design gate defaults to **skip** unless the change touches UI *and* a reference design exists.

### `/orchestrate` — full autonomous pipeline (spawns the fleet, commits, pushes)

The only command that takes a plan all the way to **pushed**. Your main session becomes the **orchestrator**: it decides / routes / loops / reports and performs the `git push` itself (push authorization lives in your session, not in sub-agents) — but it never implements, audits, or commits. Each of those is a sub-agent.

**Per step** (sequential; flat = one plan, umbrella = a DAG of steps each in its own git worktree on a named branch, fast-forward-merged to `main`):

```
5.1  Execute       → @orchestrator-executor   (Sonnet 4.6; per-step model override opus/haiku/sonnet via the plan's Model column)
5.1-recon          → orchestrator re-derives the facts itself (independent ground-truth, before trusting any report)
5.1b Refine        → @orchestrator-refiner     (Sonnet 4.6 — code-review --fix + simplify)
5.2  Verify   ≤3×  → @orchestrator-verifier    (Opus 4.8 high, read-only)        ┐ GAPS loop back
5.3  Design   ≤2×  → @orchestrator-designer    (Opus 4.8 high, read-only)        ┘ into the next Refine/Execute
       (5.3 runs ONLY if .agents/specs/design/Ready/ exists)
5.4  Commit        → @orchestrator-committer   (Haiku 4.5) → clean-build gate
5.4b Push          → orchestrator (your session) — git push, ff-merge the step branch to main
```

**Looping & escalation:** verifier/designer GAPS feed back into the next refine/execute pass; it loops fixes on its own and **escalates to you only on a real blocker** (Phase 6) — never asks "continue?" mid-loop. On completion (Phase 7) it moves the plan + a durable run-log to `plans/done/`; with `--sync-docs` it spawns `@documentation-manager` and commits a `docs:` follow-up.

> `/check-implementation` ≈ the 5.1b→5.2 slice of `/orchestrate`, run inline in your session without the commit/push. Use `/check-implementation` when you want to drive + review; `/orchestrate` when you trust the pipeline to ship.

### `/setup:map-codebase` — Workflow fan-out (a different primitive)

Brownfield comprehension uses the **`Workflow` engine**, not the Agent-tool fleet above — a deterministic script with a hard concurrency cap and token budget. Your session drives the **interaction + sequencing** (the two checkpoints, the cascade); the Workflow runs the **parallel compute**.

```
Phase 0  Scan & filter        (deterministic bash, NO LLM — git ls-files -z, categorize, import-graph in-degree)
   🛑 Checkpoint 1 — confirm scope (what's analyzed / skipped)
Phase 1  Fan-out (parallel, concurrency-capped at min(16, cores−2)):
            N × module-analyzer   (one per module — schema-validated summary, NEVER raw source)
            docs-analyzer         (README/docs/ADRs → decisions, patterns, the "why")
            infra-analyzer        (IaC/CI → hosting, deployables, external services)
Phase 2  Synthesis (from summaries only — never re-reads code):
            architecture-synthesizer  → architecture.md (+ topology + Mermaid map)
            reverse-prd-writer         → docs/PRD.md
            data-model-synthesizer     → domain/data-model.md (if persistence)
   write artifacts
   🛑 Checkpoint 2 — validate the reconstructed PRD
Phase 4  Cascade → /maintain:refresh-brief → /setup:create-CLAUDE_MD
```

**Anti-flooding contract:** analyzers return distilled summaries, never file contents — so codebase size scales the *number of agents*, not the aggregator's context. Workflow agents inherit your **session model**; the script never holds source code.

---

## When to run `/setup:createwikillm`

`/setup:createwikillm` bootstraps a persistent, synthesized knowledge base (Karpathy's LLM Wiki pattern). It is **not** part of the minimal flow — run it only when the signals below match your project.

**Run it when:**
- You have **≥ 3-5 matured specs in `.agents/specs/`** or completed plans in `.agents/plans/done/`, and the same knowledge keeps resurfacing across features.
- You are building a **product-facing LLM** (chatbot, runtime assistant, agent) that needs synthesized domain knowledge injected into its context at query time.
- **`.agents/sources/` is a large corpus** (many transcripts, patch-notes, documentation files) that will not fit into a single prompt and benefits from pre-synthesis.
- `.agents/memory/` entries are **drifting into long narratives** instead of short, actionable lessons — that is a signal you need a wiki layer.

**Skip it (and stay with `memory/` + `reference/`) when:**
- The repo is **fresh**, with no specs or completed plans yet.
- The project is **small / single-feature** — memory files are enough.
- There is **no product-LLM** consuming the wiki at runtime, and `.agents/sources/` is empty or ephemeral.
- You would be maintaining it "just in case" — an unused wiki rots faster than it helps.

If in doubt: do **not** run it. You can always add `/setup:createwikillm` later; removing an unused wiki after the fact is more work than adding one when you actually need it.

---

## Design principles

- **KISS, YAGNI, SOLID** — write the simplest thing that works
- **Fail fast** on programmer errors; degrade gracefully on user/env errors
- **Read memory before acting** — `.agents/memory/` is permanent project context
- **Design before building** — `/brainstorm` is a hard gate before implementation
- **Commits tell a story** — conventional commits via `/commit`, no AI attribution unless asked

Full rules live in [CLAUDE.md](CLAUDE.md).

---

## Permissions & safety

`.claude/settings.json` ships a security-first policy:

- **Git:** AI may run non-destructive operations — `status`, `diff`, `log`, `add`, `commit`, `push`, `pull`, `fetch`, `stash`, `tag`, `describe`, `rev-parse`, `ls-remote`, `remote get-url` — via the shipped [/push](.claude/commands/push.md) / [/pull](.claude/commands/pull.md) / [/release](.claude/commands/release.md) / [/commit](.claude/commands/commit.md) skills. Destructive operations are **denied by default**: `push --force`, `push --force-with-lease`, `reset --hard`, `clean -f*`, `checkout -- *`, `restore .`, `branch -D`/`-d`, `rebase`, `merge`, `revert`, `cherry-pick`, `config`, `remote add/remove/set-url`, `reflog expire`, `gc --prune=now`.
- **Secrets:** `.env*`, `*.pem`, `*.key`, `*secret*`, `*credentials*` — write/edit denied.
- **Inline tokens in shell:** `Bash` denies any command containing known secret prefixes (`ATATT`, `ghp_`, `github_pat_`, `gho_`, `ghs_`, `ghu_`, `xoxb-`, `xoxp-`, `xapp-`, `xoxa-`, `AKIA`, `ASIA`, `sk-ant-`) — defense-in-depth so a literal token never gets cached in `permissions.allow` after an "Always allow" click.
- **Secrets in pushed content:** the `guard-push` hook scans every `git push` for secrets in the commits about to be published — closing the gap the deny-prefixes leave open (a token in file *content*, not in a shell command). It blocks (exit 2) on known-format tokens, private keys, credentialed connection strings, hardcoded credential assignments, and credential files (`.env`, `*.pem`, `*.key`, `.npmrc`, `*.tfstate`, …); uses `gitleaks` for a broader pass if installed. Escape hatches: inline `# guard-push:allow`, `*.example` files, or `GUARD_PUSH_SKIP=1 git push` (logged to `audit.log`). See [/push](.claude/commands/push.md).
- **Dangerous shell:** `rm -rf`, `sudo` — denied.
- **Hooks:** PreToolUse hooks append a timestamped audit trail to `.claude/audit.log` (gitignored).

User-local overrides live in `.claude/settings.local.json` (gitignored) — Claude Code writes new "Always allow" approvals there by default, keeping per-session permissions out of the committed `settings.json`.

---

## Customizing the starter

- Edit `CLAUDE.md` placeholders after `/setup:create-CLAUDE_MD` runs — add project-specific rules, naming conventions, key files.
- Add reference docs to `.agents/reference/` as you integrate new APIs/libraries.
- Drop in new slash commands under `.claude/commands/` — they appear automatically.
- Tighten or loosen `.claude/settings.json` permissions to match your risk profile.
- **Sync workflow with upstream** — when this starter ships new commands or updated skills, refresh `.claude/` and the `.agents/` framework in a downstream project without touching your project's memory, specs, plans, or `CLAUDE.md`. Run the command:

  ```
  /maintain:sync-from-starter            # full run: dry-run → approval → apply
  /maintain:sync-from-starter --check    # report what would change, write nothing
  /maintain:sync-from-starter v2.1.0     # pin to a specific starter ref
  ```

  It clones the upstream starter to `/tmp`, classifies every file into three buckets — **A** overwrite (commands, agents, skills, templates, **hooks**, `.claude/README.md`), **B** merge with a diff (`settings.json` permissions, `index.md`, `.gitignore`, `memory-domains.json`, `.editorconfig`, `.mcp.json.example`), **C** never touch (your `CLAUDE.md`, `architecture.md`, append-only memory, specs, plans, root README, `LICENSE`, code) — then shows a **dry-run report and waits for your approval before writing anything**, and finally proposes a `chore(workflow): sync …` commit. It tracks provenance in a committed `.claude/.starter-sync.json` so repeated syncs become true **3-way merges** (telling intentional local edits from staleness, detecting upstream-deleted files), and on real `settings.json`/hook conflicts it **recommends but asks** rather than overwriting. Authoritative file classification and flow: [.claude/starter-sync-playbook.md](.claude/starter-sync-playbook.md); command: [.claude/commands/maintain/sync-from-starter.md](.claude/commands/maintain/sync-from-starter.md).

---

## The root README is yours — the framework guide moves aside

A single root `README.md` can't serve two audiences at once: visitors to the *starter repo* want
to read about the framework, but your *project* needs its root README to describe the application.
The starter resolves this with a one-time **swap on bootstrap**, not a delete:

1. **In the starter repo**, the root `README.md` is this framework guide (so the GitHub template
   page documents the workflow).
2. **On your first `/setup:create-CLAUDE_MD`**, the command:
   - moves this guide to `.claude/README.md` (preserved, framework-owned), and
   - generates a fresh project `README.md` at the root from `.claude/templates/README-template.md`,
     filled with your project name, description, tech stack, commands, and structure.
3. **On later `/setup:create-CLAUDE_MD` runs**, your project README is left alone — it only offers to
   fill leftover `{placeholder}` markers, never clobbering a customized README.

After bootstrap:

| File | Owner | Updated by |
|------|-------|------------|
| `README.md` (root) | **your project** | you / `/setup:create-CLAUDE_MD` placeholder fill |
| `.claude/README.md` | **the framework** | `.claude/starter-sync-playbook.md` (pulls the starter's newest guide) |
| `LICENSE` (root) | **your project** | `/setup:create-CLAUDE_MD` bootstrap — you pick the license type + copyright holder |
| `.claude/STARTER-LICENSE` | **the starter** (MIT attribution, preserved) | `.claude/starter-sync-playbook.md` |

> **`LICENSE` gets the same treatment as the README.** On first `/setup:create-CLAUDE_MD`, the starter's MIT license moves to `.claude/STARTER-LICENSE` (preserving the starter author's copyright notice — MIT requires it to survive in copies of the scaffolding) and a fresh root `LICENSE` is generated for *your* project from the type + copyright holder you choose. Later runs leave your `LICENSE` untouched.

When you sync workflow updates from upstream (see below), the framework guide is refreshed at
`.claude/README.md` — your project's root README is never touched.

---

## Language convention (default)

The starter assumes:
- Claude ↔ developer: **Polish**
- Code, comments, commits, technical docs: **English**
- User-facing UI: **per PRD**

Change this in `CLAUDE.md` → `Language Rules` if your team prefers a different split.
