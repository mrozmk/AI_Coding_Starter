# CLAUDE.md Template

A flexible template for creating global rules. Adapt the **project-specific sections** (Project Overview, Tech Stack, Commands, Architecture, Testing, Validation, Notes) based on your project type.

> **Hard cap: ≤200 lines.** Push detail into memory files instead of bloating `CLAUDE.md`:
> - Directory tree, file map, naming rules → `.agents/memory/architecture.md`
> - Patterns and conventions → `.agents/memory/patterns.md`
> - Architectural decisions → `.agents/memory/decisions.md`
> - Module-specific knowledge → `.agents/memory/domain/{module}.md`
>
> `CLAUDE.md` keeps **rules, conventions, policies, and pointers** — not maps.

> **DO NOT remove or soften** the following sections — they are the shared baseline for every project generated from this starter kit:
> `Language Rules`, `Project Knowledge Layers`, `Automatic Behaviors`, `Proactive Agent Usage`, `Plan Mode`, `Search Commands`, `Error Handling`, `Security`, `Git Workflow`, `Code Structure & Modularity`.
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

<!-- One paragraph: high-level pattern + data flow.
     Full directory map and naming rules live in `.agents/memory/architecture.md`. -->

{High-level pattern and data flow. Examples: layered (routes → services → data), component-based, MVC, event-driven.}

> Detailed source layout, module roles, and naming rules: see [.agents/memory/architecture.md](.agents/memory/architecture.md)

---

## Testing

<!-- How to test and what patterns to follow -->

- **Run tests**: `{test-command}`
- **Test location**: `{test-directory}`
- **Pattern**: {describe test approach}

---

## Validation

<!-- Commands to run before committing -->

```bash
{validation-commands}
```

---

## Code Structure & Modularity

Generic defaults — tune per project:

- Files: max **500 lines**
- Functions: max **50 lines**, single responsibility
- Classes: max **100 lines**, single concept
- Line length: max **100 characters**

Core principles: **KISS**, **YAGNI**, **SOLID** (SRP, OCP, DIP), **Fail Fast**.

---

## Style & Conventions

{Describe naming conventions, formatting rules, docstring style, type-hint policy. Link to linter/formatter config.}

---

## Error Handling

- Specific exceptions only — no bare `except` / generic catch
- Per-module logger, not `print`
- Fail fast on programmer errors; graceful degradation on user/env errors
- Error messages must **not leak** secrets, tokens, or internal paths

---

## Security

- **Never commit secrets** — keep credentials in `.env` / config files ignored by git
- Validate all user input at system boundaries
- HTTPS-only for external APIs
- Error messages must not leak sensitive info

---

## Git Workflow

- **Commits:** use `/commit` skill — conventional commits (`feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`).
- **Remote sync:** use `/push` and `/pull` skills — both detect the current branch dynamically via `git rev-parse --abbrev-ref HEAD`. No need to specify a branch.
- **Releases:** use `/release` skill — detects project stack (`package.json` / `pyproject.toml` / `Cargo.toml` / `go.mod` / `composer.json` / `VERSION`), bumps the right manifest, updates CHANGELOG, creates an annotated tag.
- **AI git policy:** AI may run **non-destructive** git operations — `status`, `diff`, `log`, `add`, `commit`, `push`, `pull`, `fetch`, `stash`, `tag`, `describe`, `rev-parse`, `ls-remote`, `remote get-url`. **Destructive operations are denied** in `.claude/settings.json`: `push --force`, `push --force-with-lease`, `push -f`, `reset --hard`, `clean -f*`, `checkout -- *`, `restore .`, `branch -D`/`-d`, `rebase`, `merge`, `revert`, `cherry-pick`, `config`, `remote add/remove/set-url`, `reflog expire`, `gc --prune=now`. When an AI agent needs any of these, it must stop and ask the human.
- **Never include AI attribution** in commit messages unless explicitly requested.

### Default branch

> _Filled in by `/create-CLAUDE_MD` at project bootstrap based on the detected git workflow. Example: `` `main` (trunk-based) ``._

---

## Language Rules

| Context | Language |
|---------|----------|
| Claude ↔ developer communication | **Polish** — always |
| Code, comments, docstrings, commit messages, technical docs | **English** — always |
| App UI, user-facing messages, error messages in the app | **As defined in PRD** (default: Polish unless specified otherwise) |

> Claude always responds in Polish. Developer writes in Polish. Code stays in English.
> App language follows the product requirement — check PRD in `docs/PRD.md` or ask if unclear.

---

## Project Knowledge Layers

Five persistent knowledge stores under `.agents/`. **Before starting any task, read [.agents/memory/index.md](.agents/memory/index.md)** — its `When to Read` table tells you what else to load for the current task.

| Layer | Contains | Lifecycle | Written by |
|-------|----------|-----------|------------|
| [sources/](.agents/sources/) | Raw input materials | Immutable input | Human only |
| [memory/](.agents/memory/) | Lessons, decisions, quirks, patterns, architecture map | Append-only (most files) · regenerated (`architecture.md`, `project-brief.md`, `domain/business-model.md`) | `/remember`, `/refresh-brief`, `/create-CLAUDE_MD` |
| [reference/](.agents/reference/) | Stable reference docs | Long-lived | Human + AI (manually) |
| [specs/](.agents/specs/) | Design docs from `/brainstorm` | Lives with feature | `/brainstorm` |
| [plans/](.agents/plans/) | Implementation plans | Short-lived: `active/` → `done/` | `/plan-feature` |

**Flow:** `sources/` → `/create-PRD` → `/brainstorm` → `specs/` → `/plan-feature` → `plans/active/` → `/execute` → `plans/done/`

> Memory files behave in two modes: **append-style** (`errors.md`, `decisions.md`, `api.md`, `patterns.md`, `domain/{module}.md`) — newest entries at the TOP. **Regenerated** (`architecture.md`, `project-brief.md`, `domain/business-model.md`) — overwritten wholesale by their owning command.

---

## Automatic Behaviors

Generic triggers that apply always — no command needed. **Project-specific routing rules** live in `.agents/memory/index.md → When to Read` table, not here.

- **Before any task**: read [.agents/memory/index.md](.agents/memory/index.md) — use its `When to Read` table to decide what else to load
- **Before implementing something new**: check `.agents/plans/active/` for existing plans
- **When uncertain about approach**: stop and ask — **NEVER ASSUME OR GUESS**
- **After fixing a bug**: evaluate adding to `.agents/memory/errors.md` — *"Would a fresh AI make this mistake again without this entry?"*
- **When a `domain/` memory file doesn't exist but is needed**: create it using the template in `.agents/memory/index.md`
- **Skip rule**: any memory file with frontmatter `status: empty` is a placeholder — do not load it
- **Loader Convention (when authoring slash commands)**: do NOT re-load project context already handled by `/prime` (CLAUDE.md, project-brief.md, architecture.md, full PRD). Read only files unique to that command's job. See `.agents/memory/index.md → Loader Convention`

---

## Proactive Agent Usage

Available sub-agents (see `.claude/agents/`):

- `documentation-manager` — keeps README, docs, and inline comments in sync after source changes. Invoke when code changes touch public API, architecture, or user-facing behavior. **Do NOT invoke after every commit** — only when documentation would actually drift.
- `general-purpose` — complex multi-step research spanning the whole codebase

---

## Plan Mode

In plan mode, apply the 99% certainty protocol before every action. For deep analytical passes (architectural trade-offs, root-cause investigations, "should we do X or Y"), use `/analysis` — it enforces the 99% rule, prefers the `AskUserQuestion` tool for clarifications, and never writes code or files.

---

## Search Commands

**CRITICAL:** use `rg` (ripgrep), never `grep` or `find`:

```bash
rg "pattern"
rg --files -g "*.{ext}"
```

---

## On-Demand Context

<!-- Optional: Reference docs for deeper context -->

| Topic | File |
|-------|------|
| {topic} | `{path}` |

---

## Notes

<!-- Any special instructions, constraints, or gotchas -->

- {note}
