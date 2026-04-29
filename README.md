# AI-Assisted Development Starter Kit

A minimal, opinionated starter for projects built with [Claude Code](https://claude.com/claude-code) as a first-class development partner.

This repo ships **no application code** — only the scaffolding that makes Claude a reliable collaborator:

- `.claude/` — commands, agents, and permission settings
- `.agents/` — five persistent knowledge layers (sources, memory, reference, specs, plans)
- `CLAUDE.md` — project rules seed, ready to be filled in per project
- `.gitignore`, sensible defaults

---

## What's in the box

### `.claude/`

| Path | Purpose |
|------|---------|
| `commands/` | Slash commands — `/brainstorm`, `/plan-feature`, `/execute`, `/commit`, `/push`, `/pull`, `/release`, `/analysis`, `/prime`, `/prime-ba`, `/create-PRD`, `/refresh-brief`, `/create-CLAUDE_MD`, `/check-quality`, `/createwikillm`, `/remember`, `/explain` |
| `agents/` | Sub-agents — `documentation-manager` |
| `skills/` | Skills — `/jira` (Jira Cloud via `mcp-atlassian` — create / edit / search / transition / comment / link Epics, Tasks, Bugs) |
| `templates/` | Starting templates — `CLAUDE-template.md` |
| `settings.json` | Security-first permissions (non-destructive git allowed, destructive ops denied, deny on secrets, audit-log hooks) |

### `.agents/`

Five layers of persistent project knowledge:

| Layer | Contents | Lifecycle |
|-------|----------|-----------|
| `sources/` | **Raw input materials** — briefs, transcripts, sketches, PDFs supplied by the user. Feeds `/create-PRD` and `/createwikillm`. Never modified by Claude. | Immutable input, pruned manually |
| `memory/` | Lessons, decisions, quirks, patterns, plus three regenerated files: `architecture.md` (directory map), `project-brief.md` (TL;DR of PRD), `domain/business-model.md` (pricing/billing facts) | Mixed — most files append-only, three are regenerated wholesale by their owning command |
| `reference/` | Stable domain/API references | Long-lived, updated as domain evolves |
| `specs/` | Design docs from `/brainstorm` | Lives with the feature |
| `plans/` | Implementation plans — `active/` → `done/` | Short-lived |

Full routing of "what to read when" lives in [.agents/memory/index.md](.agents/memory/index.md) — its `When to Read` table tells Claude which memory files to load for the current task. `CLAUDE.md` stays slim (≤200 lines) and points to memory files instead of duplicating their content.

**Status frontmatter convention.** Regenerated files (`architecture.md`, `project-brief.md`, `domain/business-model.md`) carry a `status: empty | seeded | populated` flag. Files with `status: empty` are unfilled placeholders — `/prime` and other commands skip them, falling back to the source (e.g. PRD instead of empty brief). Run the owning command (`/create-CLAUDE_MD` or `/refresh-brief`) to populate them.

---

## Requirements

**Required:**
- [Claude Code](https://claude.com/claude-code) — the CLI tool that drives all slash commands and skills shipped here.
- Git — for the `/commit`, `/push`, `/pull`, `/release` workflow.

**Optional (per integration):**
- **Jira Cloud + `mcp-atlassian`** — only needed if you plan to use the `/jira` skill, or to feed Jira issues into `/test-e2e CS-1`. The starter ships the skill itself but does not require Jira to function. See [Jira integration setup](#jira-integration-optional) below.
- **`uvx`** (from [uv](https://github.com/astral-sh/uv)) — runtime for the `mcp-atlassian` MCP server, only if you wire up Jira.
- **MCP Playwright** — only needed if you plan to use `/test-e2e` for browser-driven E2E test generation. See [MCP Playwright setup](#mcp-playwright-optional) below.

That's it. No language runtime is required by the starter itself — pick your stack when scaffolding the actual project (the seed `CLAUDE.md` is stack-agnostic; `/create-CLAUDE_MD` adapts to whatever you initialize).

### Jira integration (optional)

The repo ships a `.mcp.json.example` template. To activate Jira:

1. Copy the template: `cp .mcp.json.example .mcp.json`
2. Fill in your Atlassian credentials in `.mcp.json` — `JIRA_URL`, `JIRA_USERNAME` (your Atlassian email), `JIRA_API_TOKEN` (generate at <https://id.atlassian.com/manage-profile/security/api-tokens>).
3. Optionally export `JIRA_DEFAULT_PROJECT=<KEY>` in your shell so commands like `/jira create` and `/prime-ba` skip the project prompt.

`.mcp.json` is gitignored — credentials never leave your machine. If you skip this, the `/jira` skill simply hard-stops with a clear error message; nothing else breaks.

### MCP Playwright (optional)

Required only if you use the `/test-e2e` command. Install via your MCP setup, e.g.:

```bash
claude mcp add playwright npx -- @anthropic-ai/mcp-playwright
```

Once installed, `/test-e2e` can drive a real browser to explore your UI and generate Playwright test files. If you skip this, `/test-e2e` falls back to a degraded mode (plan derived from code/spec inspection) instead of failing.

---

## Quick start

> **Bootstrap chain (steps 3–7):**
> `/create-PRD` → `/stack-research` → `/refresh-brief` → `/create-CLAUDE_MD` (after first scaffolding) → `/brainstorm <first feature>`.
>
> Each command produces a concrete artifact and feeds the next one. Running them in order keeps `docs/PRD.md`, `.agents/memory/project-brief.md`, `.agents/memory/architecture.md`, `.agents/memory/decisions.md`, and `.agents/specs/` mutually consistent.

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

If you already have briefs, transcripts, sketches, PDFs, or any written materials describing the product — drop them into [.agents/sources/](.agents/sources/). Both `/create-PRD` and `/createwikillm` will pick them up automatically as input context.

> **Next step:** once the materials are in place, run `/create-PRD` (step 3 below) — it reads `.agents/sources/` automatically and uses its contents alongside the conversation to draft the PRD.

### 3. Define the product

```
/create-PRD
```

Generates `docs/PRD.md` from your conversation **plus** any files in `.agents/sources/`. The PRD defines **what** you're building and **why** — target users, MVP scope, success criteria. Tech stack is left as a placeholder; you'll fill it in step 4.

### 4. Research the technology stack

```
/stack-research              # project-level — full stack from PRD (recommended after /create-PRD)
/stack-research realtime     # feature-level — focused research on a specific area
```

> Run this **after** `/create-PRD`. Performs structured web research, proposes 2–3 candidate stacks with concrete pros/cons, asks you to approve the recommendation, then **updates the PRD's `Technology Stack` (and `Core Architecture & Patterns` where relevant) sections** — with diff preview and per-section approval before any edit.
>
> Also auto-appends a one-line entry to `.agents/memory/decisions.md` (newest at top), so future Claude sessions discover the architectural choice without rereading the full brief.

The full brief is saved to `.agents/specs/YYYY-MM-DD-stack-research-<topic>.md` for long-term reference.

### 5. Distill the PRD into a fast-load brief

```
/refresh-brief
```

> Run this **after** `/stack-research` so the brief reflects the now-complete `Technology Stack` section. Generates `.agents/memory/project-brief.md` — a 50-line TL;DR that `/prime` loads instead of the full PRD on every session start. Re-run whenever PRD changes substantially.
>
> If the PRD contains pricing/billing/monetization sections, this also seeds `.agents/memory/domain/business-model.md` with code-relevant operational facts (plan IDs, feature gates, Stripe events).

### 6. Initialize project rules (after first scaffolding)

```
/create-CLAUDE_MD
```

> Run this **after** you have at least some scaffolding (e.g. `npm init`, `uv init`, initial config files). It analyzes the codebase to extract real patterns — on a truly empty repo it has nothing to read. The seed `CLAUDE.md` already ships with language rules, knowledge-layer routing, and security defaults, so you are not blocked without this step.

It generates **two files** in tandem:
- `CLAUDE.md` — slim rules file (≤200 lines), filled with project overview, tech stack, commands, conventions
- `.agents/memory/architecture.md` — full directory map, module roles, naming rules (loaded on demand, not in every conversation)

This split keeps `CLAUDE.md` cheap to load every session while preserving the detailed map.

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
| `/refresh-brief` | After substantial PRD changes — regenerates `project-brief.md` (and `domain/business-model.md` if PRD has pricing content) so future `/prime` calls stay fast and current. |
| `/stack-research` | Once after `/create-PRD` for project-wide stack selection; ad-hoc later for focused research on a specific area (`/stack-research realtime`, `/stack-research auth`). Updates PRD `Technology Stack` section + logs decision. |
| `/test-e2e <flow\|jira-key>` | After implementing a UI feature — explores the UI with MCP Playwright, produces a test plan for approval, generates Playwright tests under the project's test directory. Three input modes: empty (reads latest plan in `.agents/plans/active/`), Jira key like `CS-1` (pulls acceptance criteria via mcp-atlassian), or a flow name. Requires MCP Playwright; falls back to degraded mode otherwise. |
| `/cleanup-workflow` | Periodic AI-workflow housekeeping. Three sequential phases: (1) reference integrity check across 5 categories — markdown links, path refs, section anchors, slash commands, MCP tool refs; (2) memory pruning — surfaces stale entries in `errors.md` / `decisions.md` / `patterns.md` / `api.md` / `domain/*` and archives them (per-entry user decision) to `.agents/memory/archive/`; (3) workflow health warnings — empty status stuck >30 days, orphan specs, stale active plans, audit log size, large memory files. No auto-fix in Phase 1, archive-not-delete in Phase 2, signal-only in Phase 3. |
| `/analysis` | Deep analytical pass before a decision — no code, no files, 99% certainty rule, uses `AskUserQuestion` when possible. |
| `/remember <topic>` | After a discovery — routes the entry into the right memory file. |
| `/check-quality` | Before committing — format, lint, type-check, file-size gates. |
| `/explain <code>` | When Claude is exploring unfamiliar code. |

---

## When to run `/createwikillm`

`/createwikillm` bootstraps a persistent, synthesized knowledge base (Karpathy's LLM Wiki pattern). It is **not** part of the minimal flow — run it only when the signals below match your project.

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

If in doubt: do **not** run it. You can always add `/createwikillm` later; removing an unused wiki after the fact is more work than adding one when you actually need it.

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
- **Dangerous shell:** `rm -rf`, `sudo` — denied.
- **Hooks:** PreToolUse hooks append a timestamped audit trail to `.claude/audit.log` (gitignored).

User-local overrides live in `.claude/settings.local.json` (gitignored).

---

## Customizing the starter

- Edit `CLAUDE.md` placeholders after `/create-CLAUDE_MD` runs — add project-specific rules, naming conventions, key files.
- Add reference docs to `.agents/reference/` as you integrate new APIs/libraries.
- Drop in new slash commands under `.claude/commands/` — they appear automatically.
- Tighten or loosen `.claude/settings.json` permissions to match your risk profile.

---

## Language convention (default)

The starter assumes:
- Claude ↔ developer: **Polish**
- Code, comments, commits, technical docs: **English**
- User-facing UI: **per PRD**

Change this in `CLAUDE.md` → `Language Rules` if your team prefers a different split.
