# CLAUDE.md Template

A flexible template for creating global rules. Adapt the **project-specific sections** (Project Overview, Tech Stack, Commands, Architecture, Testing, Validation, Notes) based on your project type.

> **Hard cap: ≤165 lines and ≤9 500 characters**, measured on the generated body (from `# CLAUDE.md` below), not on this preamble. Push detail into memory files instead of bloating `CLAUDE.md`:
> - Directory tree, file map, naming rules → `.agents/memory/architecture.md`
> - Patterns and conventions → `.agents/memory/patterns.md`
> - Architectural decisions → `.agents/memory/decisions.md`
> - Module-specific knowledge → `.agents/memory/domain/{module}.md`
>
> `CLAUDE.md` keeps **rules, conventions, policies, and pointers** — not maps.

> **DO NOT remove or soften** the following sections — they are the shared baseline for every project generated from this starter kit:
> `Language Rules`, `Validation`, `Commands`, `Code Structure & Modularity`, `Style & Conventions`, `Tech Stack`, `Automatic Behaviors`, `Search Commands`, `Security`, `Git Workflow`, `Project Knowledge Layers`, `Error Handling`. Their exact heading text is an API — slash commands and hooks address them by name, so a rename or a deletion breaks a consumer silently. Two lines inside `Git Workflow` are mandatory content too: the `**Orchestrate publish:**` line with its blockquote, and the `git worktree remove --force` guard sentence.
>
> Placeholder-style sections (marked with `{placeholder}` or `<!-- comment -->`) are the ones you fill in per project.

---

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

<!-- What is this project? One paragraph description -->

{Project description and purpose}

---

## Tech Stack

<!-- List technologies used. Add/remove rows as needed -->

| Technology | Purpose |
|------------|---------|
| {tech} | {why it's used} |

---

## Commands

<!-- Common commands for this project. Adjust based on your package manager and setup -->

```bash
# Development
{dev-command}

# Build
{build-command}

# Test
{test-command}

# Lint
{lint-command}
```

---

## Architecture

{One paragraph: high-level pattern + data flow. Examples: layered (routes → services → data), component-based, MVC, event-driven.} Source layout, module roles and naming rules live in [.agents/memory/architecture.md](.agents/memory/architecture.md).

---

## Testing

<!-- How to test and what patterns to follow -->

- **Run tests**: `{test-command}`
- **Test location**: `{test-directory}`
- **Pattern**: {describe test approach}

---

## Validation

> **Source of truth for quality gates.** `/gates:verify-implementation` and `/orchestrate` read this section and run these commands in sequence (fail fast).

```bash
# Run in order, stop on first failure
{validation-commands}
```

**Test policy — which layers MUST have tests:**

- Sensitive paths — {sensitive-paths, e.g. payment, auth, webhook, license, locale/redirect routing} — **MUST** have unit tests (mock external SDKs / DB). A change to these paths without a test is a gate failure, not a 🟡 nice-to-have.
- Core business logic in `{lib-dir}` — unit tests with edge cases.
- Thin HTTP adapters / boilerplate / trivial getters — tests optional.

> This section is the maturity signal `/plan-feature` reads to size its TESTING STRATEGY — keep it honest. Absence of CI does **not** mean "small project, tests optional".

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

- **Commits · sync · releases:** `/commit` (conventional commits), `/push` / `/pull` (they resolve the current branch), `/release` (bumps the detected manifest, CHANGELOG, tag).
- **AI git policy — three permission tiers** in `.claude/settings.json`, the source of truth for which command sits where. Precedence `deny` > `ask` > `allow`: `deny` is absolute — no prompt or classifier overrides it; `ask` always prompts, even in auto mode; anything in no list (bare `git merge`, soft/mixed `git reset`) prompts interactively.
- **`git worktree remove --force` can discard uncommitted work.** Its only guard is `/orchestrate`'s `status --porcelain` check, which force-removes a worktree only when it is clean and fully merged. `/orchestrate` pushes the current branch, not a hardcoded `main`.
- **Never include AI attribution** in commit messages unless explicitly requested.

**Orchestrate publish:** {push | branch-local}

> _Filled in by `/setup:create-CLAUDE_MD`._ The publish mode `/orchestrate` uses with no `--publish` flag. `push` — the pipeline pushes each step commit to the run branch. `branch-local` — it commits but **never** pushes; publishing is a separate human act (open a PR, review, merge). Choose `branch-local` for a PR-gated project (GitFlow, protected `main`/`develop`, mandatory review), where a pipeline push is rejected server-side, not merely unwelcome. Omitting the line means `push`.

### Default branch

> _Filled in by `/setup:create-CLAUDE_MD` at project bootstrap based on the detected git workflow. Example: `` `main` (trunk-based) ``._

---

## Language Rules

| Context | Language |
|---------|----------|
| Claude ↔ developer communication | **{communication-language}** — always (set at bootstrap by `/setup:create-CLAUDE_MD`; default Polish) |
| Code, comments, docstrings, commit messages, technical docs | **English** — always |
| App UI, user-facing messages, error messages in the app | **As defined in PRD** (default: {communication-language}) — check `docs/PRD.md` or ask if unclear |

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

Generic triggers, always on. **Project-specific routing** lives in `.agents/memory/index.md → When to Read`, not here.

- **Before any task:** read [.agents/memory/index.md](.agents/memory/index.md) — its `When to Read` table decides what else to load
- **Before any non-trivial response:** read `.agents/memory/user-profile.md` — style, expectations, what to avoid. Skip if `status: empty` or absent (gitignored, per-developer — copy `user-profile.md.example`).
- **Before implementing something new:** check `.agents/plans/active/` for existing plans
- **Before editing code (enforced by `guard-memory.sh`):** the first code edit per memory domain is blocked once a session — delegate a `general-purpose` subagent to distill the relevant `errors.md` / `patterns.md` / `decisions.md` entries, then `touch` the marker the hook prints. Dormant until `.claude/memory-domains.json` has path→domain rules **and** memory outgrows its size threshold (both required).
- **When uncertain about approach:** make routine judgment calls yourself; stop and ask when different readings of the request would lead to materially different work
- **After fixing a bug:** consider an entry in `.agents/memory/errors.md` — *"Would a fresh Claude make this mistake again without it?"*
- **When a `domain/` memory file doesn't exist but is needed:** create it from the template in `.agents/memory/reflection-protocol.md`
- **When writing to memory at the end of a run:** read `.agents/memory/reflection-protocol.md` first — the save-or-not bar and entry formats live there, outside the `/prime` payload
- **Skip rule:** any memory file with frontmatter `status: empty` is a placeholder — do not load it
- **Loader Convention (when authoring slash commands):** never re-load context `/prime` already handles (CLAUDE.md, project-brief.md, architecture.md, full PRD) — read only files unique to that command's job. See `.agents/memory/index.md → Loader Convention`
- **Output-Discipline Convention (when authoring slash commands):** every rule that shapes output — a length cap, an item limit, a mandatory section — states the condition under which it **yields**. Guardrails (correctness, safety, the command's identity) stay absolute. See `.agents/memory/index.md → Output-Discipline Convention`

---

## Search Commands

**CRITICAL:** use `rg` (ripgrep), never `grep` or `find` — e.g. `rg "pattern"`, `rg --files -g "*.{ext}"`.

---

## Notes

<!-- Any special instructions, constraints, or gotchas -->

- {note}
