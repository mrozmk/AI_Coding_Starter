# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this project.

> **Starter kit note:** This is a seed file. Run `/create-CLAUDE_MD` after cloning to fill in project-specific sections (overview, tech stack, commands, architecture). The sections below with `{placeholder}` markers are the ones to customize — everything else is generic best practice for AI-assisted development.

---

## Project Overview

{One-paragraph description of what this project is and who it's for.}

---

## Language Rules

| Context | Language |
|---------|----------|
| Claude ↔ developer communication | **Polish** — always |
| Code, comments, docstrings, commit messages, technical docs | **English** — always |
| App UI, user-facing messages, error messages | **As defined in PRD** (default: Polish unless specified otherwise) |

> Claude always responds in Polish. Developer writes in Polish. Code stays in English.
> App language follows the product requirement — check `docs/PRD.md` or ask if unclear.

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

## Tech Stack

| Technology | Purpose |
|------------|---------|
| {tech} | {why it's used} |

---

## Project Structure

```
{root}/
├── {dir}/      # {description}
├── .agents/    # AI knowledge layers (sources / memory / reference / specs / plans)
└── .claude/    # Claude Code commands, agents, settings
```

---

## Architecture

{Describe the architectural approach, key patterns, and data flow.}

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

- **Commits:** use [/commit](.claude/commands/commit.md) skill — conventional commits (`feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`).
- **Remote sync:** use [/push](.claude/commands/push.md) and [/pull](.claude/commands/pull.md) skills — both detect the current branch dynamically via `git rev-parse --abbrev-ref HEAD`. No need to specify a branch.
- **Releases:** use [/release](.claude/commands/release.md) skill — detects project stack (`package.json` / `pyproject.toml` / `Cargo.toml` / `go.mod` / `composer.json` / `VERSION`), bumps the right manifest, updates CHANGELOG, creates an annotated tag.
- **AI git policy:** AI may run **non-destructive** git operations — `status`, `diff`, `log`, `add`, `commit`, `push`, `pull`, `fetch`, `stash`, `tag`, `describe`, `rev-parse`, `ls-remote`, `remote get-url`. **Destructive operations are denied** in [.claude/settings.json](.claude/settings.json): `push --force`, `push --force-with-lease`, `push -f`, `reset --hard`, `clean -f*`, `checkout -- *`, `restore .`, `branch -D`/`-d`, `rebase`, `merge`, `revert`, `cherry-pick`, `config`, `remote add/remove/set-url`, `reflog expire`, `gc --prune=now`. When an AI agent needs any of these, it must stop and ask the human.
- **Never include AI attribution** in commit messages unless explicitly requested.

### Default branch

> _Filled in by `/create-CLAUDE_MD` at project bootstrap based on the detected git workflow. Example: `` `main` (trunk-based) ``._

---

## Project Knowledge Layers

Five persistent knowledge layers under `.agents/` — each with a distinct purpose and lifecycle. **Before starting any task, read [.agents/memory/index.md](.agents/memory/index.md)** and any relevant file from other layers.

| Layer | Contains | Lifecycle | Written by | Read when |
|-------|----------|-----------|------------|-----------|
| [sources/](.agents/sources/) | Raw input materials — briefs, transcripts, sketches, PDFs supplied by the user | Immutable input, pruned manually | Human only (never Claude) | Feeds `/create-PRD` and `/createwikillm` |
| [memory/](.agents/memory/) | Lessons, decisions, quirks, patterns | **Append-only, permanent** | `/commit` memory checkpoint, `/remember` | Before every task (via `/prime`) |
| [reference/](.agents/reference/) | Stable reference docs — APIs, cheatsheets, domain facts | Long-lived, updated as domain evolves | Human + AI (manually) | When feature touches that domain |
| [specs/](.agents/specs/) | Design docs from `/brainstorm` — what to build and why | Lives with the feature | `/brainstorm` | Before `/plan-feature` |
| [plans/](.agents/plans/) | Implementation plans — how to build | Short-lived: `active/` → `done/` | `/plan-feature` | During `/execute` |

**Flow:** `sources/` (optional raw input) → `/create-PRD` → `/brainstorm` → `specs/` → `/plan-feature` → `plans/active/` → `/execute` → `plans/done/`

> For synthesized cross-reference knowledge, run `/createwikillm` to set up a project wiki. It adds a `wiki/` row to the table above.

### Memory — routing discoveries

| Discovery | Write to |
|-----------|----------|
| Bug / lesson learned | [.agents/memory/errors.md](.agents/memory/errors.md) |
| API behavior / protocol quirk | [.agents/memory/api.md](.agents/memory/api.md) |
| Architectural decision | [.agents/memory/decisions.md](.agents/memory/decisions.md) |
| Project-specific pattern | [.agents/memory/patterns.md](.agents/memory/patterns.md) |
| Module-specific knowledge | `.agents/memory/domain/{module}.md` (create as needed) |

> Memory files are **append-style, newest entries at the TOP**, grouped by category. This is distinct from Claude Code's auto-memory system (one file per entry) — `.agents/memory/` is the project's own layer.

> For longer-form synthesized knowledge (cross-referenced overviews), use the wiki — see `.agents/wiki/SCHEMA.md` (available after `/createwikillm`).

---

## Automatic Behaviors

These apply always — no command needed:

- **Before any task:** read [.agents/memory/index.md](.agents/memory/index.md) and any relevant domain memory file
- **After fixing a bug:** evaluate adding to [.agents/memory/errors.md](.agents/memory/errors.md) — *"Would a fresh Claude make this mistake again without the entry?"*
- **Before implementing something new:** check `.agents/plans/active/` for existing plans
- **When uncertain about approach:** stop and ask — **NEVER ASSUME OR GUESS**
- **When a `domain/` memory file doesn't exist but is needed:** create it using the template in [.agents/memory/index.md](.agents/memory/index.md)

---

## Proactive Agent Usage

Available sub-agents (see `.claude/agents/`):

- `documentation-manager` — keeps README, docs, and inline comments in sync after source changes. Invoke when code changes touch public API, architecture, or user-facing behavior. **Do NOT invoke after every commit** — only when documentation would actually drift.
- `general-purpose` — complex multi-step research spanning the whole codebase

---

## Plan Mode

In plan mode, apply the 99% certainty protocol before every action. For deep analytical passes (architectural trade-offs, root-cause investigations, "should we do X or Y"), use [/analysis](.claude/commands/analysis.md) — it enforces the 99% rule, prefers the `AskUserQuestion` tool for clarifications, and never writes code or files.

---

## Search Commands

**CRITICAL:** use `rg` (ripgrep), never `grep` or `find`:

```bash
rg "pattern"
rg --files -g "*.{ext}"
```

---

## Key Files

| File | Purpose |
|------|---------|
| {path} | {description} |

---

## On-Demand Context

| Topic | File |
|-------|------|
| Product requirements | `docs/PRD.md` |
| Architectural decisions | [.agents/memory/decisions.md](.agents/memory/decisions.md) |
| Lessons learned | [.agents/memory/errors.md](.agents/memory/errors.md) |

---

*Update this file when adding new architecture or conventions. For tool-specific or incident-specific knowledge, use `.agents/memory/` instead.*
