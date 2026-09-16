# CLAUDE.md Template

A flexible template for creating global rules. Adapt the **project-specific sections** (Project Overview, Commands, Architecture, Validation, Notes) based on your project type.

> **Hard cap: ≤165 lines and ≤9 500 characters**, measured on the generated body (from `# CLAUDE.md` below), not on this preamble. The baseline body is ~115 lines / ~7 000 characters with its placeholders (about a third of the lines are blank), less once they are filled, so a project has real room for its own content. Push detail into memory files instead of bloating `CLAUDE.md`:
> - Directory tree, file map, naming rules, tech stack → `.agents/memory/architecture.md`
> - Patterns and conventions → `.agents/memory/patterns.md`
> - Architectural decisions, anything carrying a date or a "user decision" → `.agents/memory/decisions.md`
> - Incident history, false positives, "this tripped N times" → `.agents/memory/errors.md` or `.agents/reference/`
> - Module-specific knowledge → `.agents/memory/domain/{module}.md`
>
> `CLAUDE.md` is injected into every session and every subagent; memory is loaded on demand. So it keeps only what must hold **without** the agent reading anything else: **guardrails a pointer cannot replace, the data blocks commands parse by name, and pointers**. One line per rule; an explanation is at most one `>` blockquote line; history is never here. `/maintain:cleanup-workflow` Phase 3.6 measures the cap and Phase 5 offers the diet.

> **DO NOT remove or soften** the baseline sections — they are the shared contract for every project generated from this starter kit. The mandatory items — headings, `Git Workflow` content lines, and the LSP-conditional section — are listed in the contract block below; `/maintain:cleanup-workflow` 1.6 reads it. Their exact heading text is an API — slash commands and hooks address them by name, so a rename or a deletion breaks a consumer silently.
>
> Placeholder-style sections (marked with `{placeholder}` or `<!-- comment -->`) are the ones you fill in per project.

<!-- CLAUDE-CONTRACT:BEGIN — machine-readable; parsed by /maintain:cleanup-workflow 1.6.
     PREAMBLE ONLY: never copy this block into a generated CLAUDE.md. -->

| Item | Kind | Tier |
|------|------|------|
| Language Rules | heading | 1 |
| Validation | heading | 1 |
| Git Workflow | heading | 1 |
| **Orchestrate publish:** | content:Git Workflow | 1 |
| git worktree remove --force | content:Git Workflow | 1 |
| ### Branch model | content:Git Workflow | 1 |
| Commands | heading | 2 |
| Code Structure & Modularity | heading | 2 |
| Style & Conventions | heading | 2 |
| Automatic Behaviors | heading | 2 |
| Search Commands | heading | 2 |
| Security | heading | 2 |
| Project Knowledge Layers | heading | 2 |
| Code Navigation | conditional:lsp | — |

<!-- CLAUDE-CONTRACT:END -->

---

# CLAUDE.md

Rules and pointers for Claude Code in this repository — loaded into every session, so nothing here is knowledge. Knowledge lives under `.agents/`, starting at [.agents/memory/index.md](.agents/memory/index.md).

## Project Overview

{Two or three sentences: what this project is, who it is for, the stack in one breath. Full context: `docs/PRD.md`; distilled: `.agents/memory/project-brief.md`.}

## Language Rules

| Context | Language |
|---------|----------|
| Claude ↔ developer communication | **{communication-language}** — always |
| Code, comments, docstrings, commit messages, technical docs | **English** — always |
| App UI, user-facing messages, error messages | **As defined in PRD** (default: {communication-language}) |

## Commands

```bash
{dev-command}      # development
{build-command}    # build
{test-command}     # test
{lint-command}     # lint / format
```

## Architecture

{One paragraph: high-level pattern + data flow.} Layout, module roles, stack, naming: [.agents/memory/architecture.md](.agents/memory/architecture.md).

## Validation

> **Source of truth for quality gates** — `/gates:verify-implementation` and `/orchestrate` run these in order, stopping on the first failure.

```bash
{validation-commands}
```

**Runtime smoke — conditional.** A change under `{ui-paths}` with an app running → the check in [.agents/reference/runtime-smoke.md](.agents/reference/runtime-smoke.md); no running app → `SKIPPED` with a reason, never `FAIL`, never a silent pass. {Delete in a project with no rendered UI.}

**Test policy — which layers MUST have tests:**

- Sensitive paths — {sensitive-paths, e.g. payment, auth, webhook, redirect routing} — **MUST** have unit tests; a change there without a test is a gate failure.
- Core business logic in `{lib-dir}` — unit tests with edge cases.
- Thin adapters / boilerplate — tests optional.

> The maturity signal `/plan-feature` reads for its TESTING STRATEGY — keep it honest; no CI does not mean tests are optional.

## Code Structure & Modularity

Files max **500 lines** · functions max **50 lines** · classes soft **150** / hard **250** · lines max **100 chars** · **KISS**, **YAGNI**, **SOLID**, **Fail Fast**. Tune per project; never split a cohesive unit to hit a number.

## Style & Conventions

{Naming, formatting, docstring style, type-hint policy — link the linter/formatter config, do not enumerate its rules.}

**Comments: why, not what — cap 1-2 lines.** A comment that restates the code or echoes a name is noise and gets deleted; keep only a *why* the code cannot express. Longer reasoning → `.agents/memory/` with a one-line pointer.

> Enforced by `guard-comments.sh`, `/deep-review` standard 8 and `/gates:verify-implementation`, all by this heading's name — keep the heading and the rule together.

**Errors:** specific exceptions only, no bare catch · logger, not `print` · fail fast on programmer errors, degrade gracefully on user/env errors · messages never leak secrets or paths.

## Security

- **Never commit secrets** — credentials live in gitignored `.env` / config. Validate input at system boundaries.
- **Egress is guarded, not open.** `WebFetch` is an allowlist and `curl`/`wget` bodies are denied in [.claude/settings.json](.claude/settings.json); never widen either to silence a prompt. Why, the honest limits, the recorded exceptions: [.agents/reference/security-egress.md](.agents/reference/security-egress.md).

**Project docs hosts allowed for `WebFetch`:** {hosts, or "none beyond the defaults"}

## Git Workflow

- **Commands:** `/commit` · `/push` / `/pull` · `/release`. Permission tiers (`deny` > `ask` > `allow`) live in [.claude/settings.json](.claude/settings.json); tiers, protected branches, `--no-track`, the pipeline's git: [.agents/reference/git-policy.md](.agents/reference/git-policy.md).
- **`git worktree remove --force` can discard uncommitted work.** Its only guard is `/orchestrate`'s `status --porcelain` check, which force-removes a worktree only when it is clean and fully merged. `git worktree` and `git merge --ff-only` are reserved for the pipeline.
- **Never include AI attribution** in commits or PRs. Switched off by the `attribution` key in `settings.json` — keep the key; a rule file alone cannot outrank the host's session instruction.

**Orchestrate publish:** {push | branch-local}

> The mode `/orchestrate` uses with no `--publish` flag: `push` pushes each step commit; `branch-local` commits but **never** pushes (PR-gated projects). Omitted → `push`.

### Branch model

**Preset:** {trunk | feature-branch | gitflow | custom} · **Trunk:** `{branch}` · **Integration:** `{branch}`
**Branch names:** `{<type>/<KEY>-<slug> | <type>/<slug>}` — types: {closed list}
**Base → PR dest:** {base and PR-destination rule, per-type exceptions}
**Protected:** {never a PR source nor a pipeline push target, or `none`}
**Merge:** {emit ONLY when the project deviates from its preset; otherwise delete this line}

> The single source of branch facts — commands read them here, never guess. Block absent → `origin/HEAD`, then `main`, then `master`; **never assume `develop`**. `**Merge:**` absent → squash for working types, merge commit for `release`/`hotfix`.

## Project Knowledge Layers

**Before any task read [.agents/memory/index.md](.agents/memory/index.md)** — `When to Read` (what to load), `Quick Reference` (where to write a discovery). Layers under `.agents/`: `sources/` (raw input, human-only) · `memory/` (lessons, decisions, patterns, map, brief) · `reference/` (stable docs, policies) · `specs/` · `plans/{active,done}/` · optional `backlog.md`.

**Flow:** `sources/` → `/setup:create-PRD` → `/maintain:refresh-brief` → `[/setup:create-backlog]` → `/brainstorm` → `specs/` → `/plan-feature` → `plans/active/` → `/execute` → `plans/done/`

## Automatic Behaviors

Generic triggers, always on. **Project-specific routing** lives in `.agents/memory/index.md → When to Read`, not here.

- **Before any task:** read `.agents/memory/index.md`. **Before any non-trivial response:** `.agents/memory/user-profile.md` (skip if absent or `status: empty`).
- **Before implementing something new:** check `.agents/plans/active/`.
- **When uncertain:** make routine judgment calls yourself; ask when different readings would lead to materially different work.
- **After fixing a bug, and when writing memory at run end:** follow [.agents/memory/reflection-protocol.md](.agents/memory/reflection-protocol.md); the default is to write nothing.
- **Skip rule:** a memory file with `status: empty` is a placeholder — do not load it.
- **Authoring slash commands:** Loader and Output-Discipline Conventions in `.agents/memory/index.md`.

## Search Commands

**CRITICAL:** use `rg`, never `grep` or `find`. `rg` skips hidden dirs — a sweep over `.claude/` or `.agents/` needs `rg --hidden -g '!.git'`.

## Notes

<!-- Constraints and gotchas — one line each; a story goes to memory -->

- {note}
