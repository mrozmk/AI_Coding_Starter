# CLAUDE.md Template

A flexible template for creating global rules. Adapt the **project-specific sections** (Project Overview, Tech Stack, Commands, Project Structure, Architecture, Code Patterns, Testing, Validation, Key Files, Notes) based on your project type.

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

## Project Structure

<!-- Describe your folder organization. This varies greatly by project type -->

```
{root}/
├── {dir}/     # {description}
├── {dir}/     # {description}
└── {dir}/     # {description}
```

---

## Architecture

<!-- Describe how the code is organized. Examples:
- Layered (routes → services → data)
- Component-based (features as self-contained modules)
- MVC pattern
- Event-driven
- etc.
-->

{Describe the architectural approach and data flow}

---

## Code Patterns

<!-- Key patterns and conventions used in this codebase -->

### Naming Conventions
- {convention}

### File Organization
- {pattern}

### Error Handling
- {approach}

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

## Key Files

<!-- Important files to know about -->

| File | Purpose |
|------|---------|
| `{path}` | {description} |

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

Five persistent knowledge stores under `.agents/` — each with a distinct purpose and lifecycle. **Before starting any task, read [.agents/memory/index.md](.agents/memory/index.md)** and any relevant file from other layers.

| Layer | Contains | Lifecycle | Written by | Read when |
|-------|----------|-----------|------------|-----------|
| [sources/](.agents/sources/) | Raw input materials — briefs, transcripts, sketches, PDFs | Immutable input, pruned manually | Human only | Feeds `/create-PRD` and `/createwikillm` |
| [memory/](.agents/memory/) | Lessons, decisions, quirks, patterns | **Append-only, permanent** | `/commit` memory checkpoint, `/remember` | Before every task (via `/prime`) |
| [reference/](.agents/reference/) | Stable reference docs — APIs, cheatsheets, domain facts | Long-lived, updated as domain evolves | Human + AI (manually) | When feature touches that domain |
| [specs/](.agents/specs/) | Design docs from `/brainstorm` — what to build and why | Lives with the feature | `/brainstorm` | Before `/plan-feature` |
| [plans/](.agents/plans/) | Implementation plans — how to build | Short-lived: `active/` → `done/` | `/plan-feature` | During `/execute` |

**Flow:** `sources/` (optional raw input) → `/create-PRD` → `/brainstorm` → `specs/` → `/plan-feature` → `plans/active/` → `/execute` → `plans/done/`

### Memory — routing discoveries

When you discover something worth remembering, append it immediately to the appropriate file:

| Discovery | File |
|-----------|------|
| Bug / lesson learned | `.agents/memory/errors.md` |
| API behavior / protocol quirk | `.agents/memory/api.md` |
| Architectural decision | `.agents/memory/decisions.md` |
| Project-specific pattern | `.agents/memory/patterns.md` |
| Module-specific knowledge | `.agents/memory/domain/{module}.md` |

If a relevant `domain/` file doesn't exist yet — create it using the template in `index.md`.

> Memory files are **append-style, newest entries at the TOP**, grouped by category.

---

## Automatic Behaviors

These apply always — no command needed:

- **Before any task**: read `.agents/memory/index.md` and any relevant domain memory file
- **After fixing a bug**: evaluate whether to save to `.agents/memory/errors.md` — ask yourself: *"Would a fresh AI make this mistake again without this entry?"*
- **Before implementing something new**: check `.agents/plans/active/` for existing plans related to the task
- **When uncertain about approach**: stop and ask before writing code — **NEVER ASSUME OR GUESS**
- **When a `domain/` memory file doesn't exist but is needed**: create it using the template in `.agents/memory/index.md`

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
