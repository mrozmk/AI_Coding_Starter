# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this project.

> **Starter kit note:** seed file — run `/setup:create-CLAUDE_MD` after cloning. `{placeholder}` sections are yours to fill; the rest is the shared baseline.

---

## Project Overview

{One-paragraph description of what this project is and who it's for.}

---

## Language Rules

| Context | Language |
|---------|----------|
| Claude ↔ developer communication | **Polish** — always (set at bootstrap by `/setup:create-CLAUDE_MD`) |
| Code, comments, docstrings, commit messages, technical docs | **English** — always |
| App UI, user-facing messages, error messages | **As defined in PRD** (default: Polish) — check `docs/PRD.md` or ask if unclear |

---

## Commands

```bash
# Development
{dev-command}

# Build
{build-command}

# Test
{test-command}

# Lint / format
{lint-command}
```

---

## Validation

> **Source of truth for quality gates.** `/gates:verify-implementation` and `/orchestrate` read this section and run these commands in sequence (fail fast). Filled per-project by `/setup:create-CLAUDE_MD`. Until filled, gates fall back to stack-detected defaults.

```bash
# Run in order, stop on first failure
{typecheck-command} && {lint-command} && {test-command}
```

**Test policy — which layers MUST have tests:**

- Sensitive paths — payment, auth, webhook, license, locale/redirect routing — **MUST** have unit tests (mock external SDKs / DB). A change to these paths without a test is a gate failure, not a 🟡 nice-to-have.
- Core business logic in `{lib-dir}` — unit tests with edge cases.
- Thin HTTP adapters / boilerplate / trivial getters — tests optional.

> This section is the maturity signal `/plan-feature` reads to size its TESTING STRATEGY — keep it honest. Absence of CI does **not** mean "small project, tests optional".

---

## Tech Stack

| Technology | Purpose |
|------------|---------|
| {tech} | {why it's used} |

---

## Architecture

{One paragraph: high-level architectural pattern + data flow.} Source layout, module roles and naming rules live in [.agents/memory/architecture.md](.agents/memory/architecture.md).

---

## Code Structure & Modularity

Generic defaults — tune per project: files max **500 lines** · functions max **50 lines**, single responsibility · classes max **100 lines**, single concept · lines max **100 characters**. Core principles: **KISS**, **YAGNI**, **SOLID** (SRP, OCP, DIP), **Fail Fast**.

---

## Style & Conventions

{Describe naming conventions, formatting rules, docstring style, type-hint policy. Link to linter/formatter config.}

---

## Error Handling

Specific exceptions only — no bare `except` / generic catch · per-module logger, not `print` · fail fast on programmer errors, degrade gracefully on user/env errors · messages must **not leak** secrets, tokens, or internal paths.

---

## Security

**Never commit secrets** — credentials live in gitignored `.env` / config. Validate all user input at system boundaries · HTTPS-only for external APIs · error messages must not leak sensitive info.

---

## Git Workflow

- **Commits · sync · releases:** [/commit](.claude/commands/commit.md) (conventional commits), [/push](.claude/commands/push.md) / [/pull](.claude/commands/pull.md) (they resolve the current branch), [/release](.claude/commands/release.md) (bumps the detected manifest, CHANGELOG, tag).
- **AI git policy — three permission tiers** in [.claude/settings.json](.claude/settings.json), the source of truth for which command sits where. Precedence `deny` > `ask` > `allow`: `deny` is absolute — no prompt or classifier overrides it; `ask` always prompts, even in auto mode; anything in no list (bare `git merge`, soft/mixed `git reset`) prompts interactively.
- **`git worktree remove --force` can discard uncommitted work.** Its only guard is [/orchestrate](.claude/commands/orchestrate.md)'s `status --porcelain` check, which force-removes a worktree only when it is clean and fully merged.
- **[/orchestrate](.claude/commands/orchestrate.md) pushes the current branch**, not a hardcoded `main`; parallel runs and the supervised `--integrate` merge queue: [.agents/reference/parallel-orchestration.md](.agents/reference/parallel-orchestration.md).
- **Never include AI attribution** in commit messages unless explicitly requested.

**Orchestrate publish:** push

> The publish mode `/orchestrate` uses when no `--publish` flag is given (Phase 4, resolution step 2). `push` — the pipeline pushes each step commit to the run branch. `branch-local` — it commits but **never** pushes; publishing is a separate human act (open a PR, review, merge). Set this to `branch-local` in any PR-gated project (GitFlow, protected `main`/`develop`, mandatory review), where a pipeline push is rejected server-side rather than merely unwelcome. Omitting the line means `push`.

### Default branch

> _Filled in by `/setup:create-CLAUDE_MD` at project bootstrap based on the detected git workflow. Example: `` `main` (trunk-based) ``._

---

## Project Knowledge Layers

Knowledge layers under `.agents/`. **Before any task read [.agents/memory/index.md](.agents/memory/index.md)** — `When to Read` (what to load), `Quick Reference` (where to write a discovery), `Memory scope` (why memory stays in the repo).

| Layer | Contains | Lifecycle | Written by |
|-------|----------|-----------|------------|
| [sources/](.agents/sources/) | Raw input — briefs, transcripts, sketches, PDFs | Immutable, pruned manually | Human only |
| [memory/](.agents/memory/) | Lessons, decisions, quirks, patterns, architecture map, brief | Append-only (newest at top) · some regenerated | reflection pass, `/maintain:refresh-brief`, `/setup:create-CLAUDE_MD` |
| [reference/](.agents/reference/) | Stable reference docs — APIs, cheatsheets, domain facts | Long-lived | Human + AI |
| `backlog.md` *(optional)* | Delivery map — epics, task DAG, work packages | `Status`/`Ref` written back by the pipeline | `/setup:create-backlog` · `/plan-feature` · `/orchestrate` |
| [specs/](.agents/specs/) | Design docs — what to build and why | Lives with the feature | `/brainstorm` |
| [plans/](.agents/plans/) | Implementation plans — how to build | Short-lived: `active/` → `done/` | `/plan-feature` |

**Flow:** `sources/` → `/setup:create-PRD` → `/maintain:refresh-brief` → `[/setup:create-backlog]` → `/brainstorm` → `specs/` → `/plan-feature` → `plans/active/` → `/execute` → `plans/done/`

---

## Automatic Behaviors

Generic triggers, always on. **Project-specific routing** lives in [.agents/memory/index.md → When to Read](.agents/memory/index.md), not here.

- **Before any task:** read [.agents/memory/index.md](.agents/memory/index.md) — its `When to Read` table decides what else to load
- **Before any non-trivial response:** read [.agents/memory/user-profile.md](.agents/memory/user-profile.md) — style, expectations, what to avoid. Skip if `status: empty` or absent (gitignored, per-developer — copy `user-profile.md.example`).
- **Before implementing something new:** check `.agents/plans/active/` for existing plans
- **Before editing code (enforced by `guard-memory.sh`):** the first code edit per memory domain is blocked once a session — delegate a `general-purpose` subagent to distill the relevant `errors.md` / `patterns.md` / `decisions.md` entries, then `touch` the marker the hook prints. Dormant until [.claude/memory-domains.json](.claude/memory-domains.json) has path→domain rules.
- **When uncertain about approach:** make routine judgment calls yourself; stop and ask when different readings of the request would lead to materially different work
- **After fixing a bug:** consider an entry in [.agents/memory/errors.md](.agents/memory/errors.md) — *"Would a fresh Claude make this mistake again without it?"*
- **When a `domain/` memory file doesn't exist but is needed:** create it from the template in [.agents/memory/reflection-protocol.md](.agents/memory/reflection-protocol.md)
- **When writing to memory at the end of a run:** read [.agents/memory/reflection-protocol.md](.agents/memory/reflection-protocol.md) first — the save-or-not bar and entry formats live there, outside the `/prime` payload
- **Skip rule:** any memory file with frontmatter `status: empty` is a placeholder — do not load it
- **Loader Convention (when authoring slash commands):** never re-load context `/prime` already handles (CLAUDE.md, project-brief.md, architecture.md, full PRD) — read only files unique to that command's job. See [.agents/memory/index.md → Loader Convention](.agents/memory/index.md)
- **Output-Discipline Convention (when authoring slash commands):** every rule that shapes output — a length cap, an item limit, a mandatory section — states the condition under which it **yields**. Guardrails (correctness, safety, the command's identity) stay absolute and get no escape hatch. Artifacts and terminal reports are different surfaces with different rules. See [.agents/memory/index.md → Output-Discipline Convention](.agents/memory/index.md)

---

## Search Commands

**CRITICAL:** use `rg` (ripgrep), never `grep` or `find` — e.g. `rg "pattern"`, `rg --files -g "*.{ext}"`.

---

*Update this file when conventions change. Tool- or incident-specific knowledge goes to `.agents/memory/`.*
