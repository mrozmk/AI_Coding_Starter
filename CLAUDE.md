# CLAUDE.md

Rules and pointers for Claude Code in this repository — loaded into every session, so nothing here is knowledge. Knowledge lives under `.agents/`, starting at [.agents/memory/index.md](.agents/memory/index.md).

> **Starter kit note:** seed file — run `/setup:create-CLAUDE_MD` after cloning. `{placeholder}` sections are yours to fill; the rest is the shared baseline.

## Project Overview

{Two or three sentences: what this project is, who it is for, the stack in one breath. Full context: `docs/PRD.md`; distilled: `.agents/memory/project-brief.md`.}

## Language Rules

| Context | Language |
|---------|----------|
| Claude ↔ developer communication | **Polish** — always (set at bootstrap by `/setup:create-CLAUDE_MD`) |
| Code, comments, docstrings, commit messages, technical docs | **English** — always |
| App UI, user-facing messages, error messages | **As defined in PRD** (default: Polish) |

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

> **Source of truth for quality gates** — `/gates:verify-implementation` and `/orchestrate` run these in order, stopping on the first failure. Filled by `/setup:create-CLAUDE_MD`; until then the gates use stack-detected defaults.

```bash
{typecheck-command} && {lint-command} && {test-command}
```

**Runtime smoke — conditional.** A change under `{ui-paths}` with an app running → the check in [.agents/reference/runtime-smoke.md](.agents/reference/runtime-smoke.md); no running app → `SKIPPED` with a reason, never `FAIL`, never a silent pass. {Delete in a project with no rendered UI.}

**Test policy — which layers MUST have tests:**

- Sensitive paths — payment, auth, webhook, license, locale/redirect routing — **MUST** have unit tests; a change there without a test is a gate failure.
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
- **Egress is guarded, not open.** `WebFetch` is an allowlist and `curl`/`wget` bodies are denied in [.claude/settings.json](.claude/settings.json); never widen either to silence a prompt. Why, the honest limits, the recorded exceptions (`pr-api.sh`, `git-baseline.sh`): [.agents/reference/security-egress.md](.agents/reference/security-egress.md).

**Project docs hosts allowed for `WebFetch`:** none beyond the defaults

## Git Workflow

- **Commands:** [/commit](.claude/commands/commit.md) · [/push](.claude/commands/push.md) / [/pull](.claude/commands/pull.md) · [/release](.claude/commands/release.md). Permission tiers (`deny` > `ask` > `allow`) live in [.claude/settings.json](.claude/settings.json); tiers, protected branches, `--no-track`, the pipeline's git: [.agents/reference/git-policy.md](.agents/reference/git-policy.md).
- **`git worktree remove --force` can discard uncommitted work.** Its only guard is [/orchestrate](.claude/commands/orchestrate.md)'s `status --porcelain` check, which force-removes a worktree only when it is clean and fully merged. `git worktree` and `git merge --ff-only` are reserved for the pipeline.
- **Never include AI attribution** in commits or PRs. Switched off by the `attribution` key in `settings.json` — keep the key; a rule file alone cannot outrank the host's session instruction.
- **Architecture cadence:** run [/architecture-review](.claude/commands/architecture-review.md) `--codex` (two independent sweeps, one report) on a cadence you choose — before a minor/major release, or after every few merged features — never on every patch: it is a whole-codebase sweep, slow and analyze-only. Candidates from its report go to `/brainstorm` as their own tasks; nothing is fixed inline during a release.

**Orchestrate publish:** push

> The mode `/orchestrate` uses with no `--publish` flag: `push` pushes each step commit; `branch-local` commits but **never** pushes (PR-gated projects). Omitted → `push`.

### Branch model

> _Filled in by `/setup:create-CLAUDE_MD` at project bootstrap._ The single source of branch facts — commands read them here, never guess. Fields: **Preset** · **Trunk** · **Integration** · **Branch names** · **Base → PR dest** · **Protected**, plus **Merge** only when the project deviates from its preset. Block absent → `origin/HEAD`, then `main`, then `master`; **never assume `develop`**. `**Merge:**` absent → squash for working types, merge commit for `release`/`hotfix`.

## Project Knowledge Layers

**Before any task read [.agents/memory/index.md](.agents/memory/index.md)** — `When to Read` (what to load), `Quick Reference` (where to write a discovery). Layers under `.agents/`: `sources/` (raw input, human-only) · `memory/` (lessons, decisions, patterns, map, brief) · `reference/` (stable docs, policies) · `specs/` · `plans/{active,done}/` · optional `backlog.md`.

**Flow:** `sources/` → `/setup:create-PRD` → `/maintain:refresh-brief` → `[/setup:create-backlog]` → `/brainstorm` → `specs/` → `/plan-feature` → `plans/active/` → `/execute` → `plans/done/`

## Automatic Behaviors

Generic triggers, always on. **Project-specific routing** lives in [.agents/memory/index.md → When to Read](.agents/memory/index.md), not here.

- **Before any task:** read `.agents/memory/index.md`. **Before any non-trivial response:** `.agents/memory/user-profile.md` (skip if absent or `status: empty`).
- **Before implementing something new:** check `.agents/plans/active/`.
- **When uncertain:** make routine judgment calls yourself; ask when different readings would lead to materially different work.
- **After a `/qa-verify` run with interaction rows:** offer to promote the recorded sequence into a regression test per [.agents/reference/qa-to-regression-test.md](.agents/reference/qa-to-regression-test.md) — QA never writes tests itself.
- **After fixing a bug, and when writing memory at run end:** follow [.agents/memory/reflection-protocol.md](.agents/memory/reflection-protocol.md); the default is to write nothing.
- **Skip rule:** a memory file with `status: empty` is a placeholder — do not load it.
- **Authoring slash commands:** Loader and Output-Discipline Conventions in `.agents/memory/index.md`.

## Search Commands

**CRITICAL:** use `rg`, never `grep` or `find`. `rg` skips hidden dirs — a sweep over `.claude/` or `.agents/` needs `rg --hidden -g '!.git'`.

---

*Update this file when conventions change. Tool- or incident-specific knowledge goes to `.agents/memory/`; policy rationale to `.agents/reference/`.*
