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
| `commands/` | Slash commands — `/brainstorm`, `/plan-feature`, `/execute`, `/gates:verify-implementation`, `/check-implementation`, `/orchestrate`, `/commit`, `/push`, `/pull`, `/release`, `/analysis`, `/prime`, `/prime-ba`, `/setup:create-PRD`, `/maintain:refresh-brief`, `/setup:stack-research`, `/setup:create-CLAUDE_MD`, `/test-e2e`, `/maintain:cleanup-workflow`, `/gates:check-quality`, `/setup:createwikillm` |
| `agents/` | Sub-agents — `documentation-manager` |
| `skills/` | Skills — `/jira` (Jira Cloud via `mcp-atlassian` — create / edit / search / transition / comment / link Epics, Tasks, Bugs) |
| `templates/` | Starting templates — `CLAUDE-template.md` (project rules), `README-template.md` (project README, used by `/setup:create-CLAUDE_MD` on bootstrap) |
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

```
New chat → /prime → /brainstorm <feature | CS-1> → /plan-feature → /execute → /gates:verify-implementation → /commit
```

| Step | What it means |
|------|---------------|
| **New chat** | Open a fresh Claude Code session — no history, no leftover context from previous tasks. |
| **`/prime`** | Quick mode by default — loads `CLAUDE.md`, `.agents/memory/index.md`, `project-brief.md`, `architecture.md`, plus listings of plans/specs/reference and git state. Use `/prime full` after a long break or for deep multi-area work (also pulls `patterns.md`, `decisions.md`, `api.md`, `errors.md`, populated `domain/*`). |
| **`/brainstorm <feature>` or `/brainstorm CS-1`** | Free-text feature **or** a Jira key — Jira mode pulls the issue's description and acceptance criteria as input. Output: a design spec in `.agents/specs/`. |
| **`/plan-feature`** | Reads the approved spec, analyzes the codebase, optionally runs web research for declared external dependencies, writes a step-by-step plan to `.agents/plans/active/`. |
| **`/execute`** | Runs the active plan top to bottom. Moves it to `.agents/plans/done/` when complete. |
| **`/gates:verify-implementation`** | Validates checklist coverage, runs quality gates from `CLAUDE.md → Validation` (or stack-detected fallback), performs semantic code review, checks UI design compliance. Reports only — no code changes. |
| **`/commit`** | Conventional-commit message, plus a memory checkpoint — captures lessons / decisions / patterns into `.agents/memory/`. |

---

## Requirements

**Required:**
- [Claude Code](https://claude.com/claude-code) — the CLI tool that drives all slash commands and skills shipped here.
- Git — for the `/commit`, `/push`, `/pull`, `/release` workflow.
- [`jq`](https://jqlang.github.io/jq/) — required by the workflow hooks (`guard-memory`, `track-memory-read`, `audit-append`). They **fail open silently** without it: the memory-distillation guard never fires, the audit log stays empty, and read telemetry is not recorded — with no error shown. Install via `brew install jq` / `apt install jq` before relying on those safeguards.

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

> **Bootstrap chain (steps 3–7):**
> `/setup:create-PRD` → `/setup:stack-research` → `/maintain:refresh-brief` → `/setup:create-CLAUDE_MD` (after first scaffolding) → `/brainstorm <first feature>`.
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

### 5. Distill the PRD into a fast-load brief

```
/maintain:refresh-brief
```

> Run this **after** `/setup:stack-research` so the brief reflects the now-complete `Technology Stack` section. Generates `.agents/memory/project-brief.md` — a 50-line TL;DR that `/prime` loads instead of the full PRD on every session start. Re-run whenever PRD changes substantially.
>
> If the PRD contains pricing/billing/monetization sections, this also seeds `.agents/memory/domain/business-model.md` with code-relevant operational facts (plan IDs, feature gates, Stripe events).

### 6. Initialize project rules (after first scaffolding)

```
/setup:create-CLAUDE_MD
```

> Run this **after** you have at least some scaffolding (e.g. `npm init`, `uv init`, initial config files). It analyzes the codebase to extract real patterns — on a truly empty repo it has nothing to read. The seed `CLAUDE.md` already ships with language rules, knowledge-layer routing, and security defaults, so you are not blocked without this step.

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
| `/test-e2e <flow\|jira-key>` | After implementing a UI feature — explores the UI with MCP Playwright, produces a test plan for approval, generates Playwright tests under the project's test directory. Three input modes: empty (reads latest plan in `.agents/plans/active/`), Jira key like `CS-1` (pulls acceptance criteria via mcp-atlassian), or a flow name. Requires MCP Playwright; falls back to degraded mode otherwise. |
| `/maintain:sync-from-starter [--check\|<ref>]` | Pull newer workflow definitions from the upstream starter (commands, agents, skills, hooks, config) without touching project knowledge. 3-way aware via a committed `.claude/.starter-sync.json` provenance manifest; recommends but asks on `settings.json`/hook conflicts. `--check` = dry-run only; `<ref>` = pin to a tag. See [.claude/starter-sync-playbook.md](.claude/starter-sync-playbook.md). |
| `/maintain:cleanup-workflow` | Periodic AI-workflow housekeeping. Three sequential phases: (1) reference integrity check across 5 categories — markdown links, path refs, section anchors, slash commands, MCP tool refs; (2) memory pruning — surfaces stale entries in `errors.md` / `decisions.md` / `patterns.md` / `api.md` / `domain/*` and archives them (per-entry user decision) to `.agents/memory/archive/`; (3) workflow health warnings — empty status stuck >30 days, orphan specs, stale active plans, audit log size, large memory files. No auto-fix in Phase 1, archive-not-delete in Phase 2, signal-only in Phase 3. |
| `/analysis` | Deep analytical pass before a decision — no code, no files, 99% certainty rule, uses `AskUserQuestion` when possible. |
| `/gates:check-quality` | Before committing — format, lint, type-check, file-size gates. |
| `/gates:verify-implementation [plan-name]` | After `/execute` finishes a plan — validates checklist completion, runs quality gates from `CLAUDE.md → Validation` (or stack-detected fallback), performs language-aware semantic review (TypeScript-first; sections gated on detected stack), and verifies design compliance for UI plans. Reports only — does not modify code. |
| `/check-implementation [plan-name]` | The **full** quality loop after `/execute`: `code-review --fix` (correctness) → `simplify` (cleanliness) → `gates:verify-implementation` (read-only gate), looping up to 3× until the gate approves, then stopping for `/commit`. Unlike `/gates:verify-implementation` it **applies** fixes; unlike `/orchestrate` it does not commit/push. The same loop `/orchestrate` runs per-step (Step 5.1b). |

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
- **Dangerous shell:** `rm -rf`, `sudo` — denied.
- **Hooks:** PreToolUse hooks append a timestamped audit trail to `.claude/audit.log` (gitignored).

User-local overrides live in `.claude/settings.local.json` (gitignored) — Claude Code writes new "Always allow" approvals there by default, keeping per-session permissions out of the committed `settings.json`.

> ⚠️ **Never approve "Always allow this exact command"** for a Bash invocation that contains a literal secret (`-u "user:hardcodedToken"`, inline `Authorization: Bearer ...`, hardcoded DB URL with embedded password). Claude Code caches the **full literal command**, including the token. Always pass secrets via `$ENV_VARS` instead — `curl -u "$JIRA_USER:$JIRA_TOKEN" ...`. The deny-prefix list above is a safety net, not a substitute for this discipline.

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

When you sync workflow updates from upstream (see below), the framework guide is refreshed at
`.claude/README.md` — your project's root README is never touched.

---

## Language convention (default)

The starter assumes:
- Claude ↔ developer: **Polish**
- Code, comments, commits, technical docs: **English**
- User-facing UI: **per PRD**

Change this in `CLAUDE.md` → `Language Rules` if your team prefers a different split.
