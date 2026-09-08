# Project rules
<!-- harness:generated-rules -->

> Shared rules for every AI host working in this repository. `CLAUDE.md` and `AGENTS.md` are thin entry points that require reading this file; nothing loads it automatically, and `prime` reports whether it was actually read. Rendered by `scripts/rules.mjs` from the project profile and confirmed project facts; sections with a `{placeholder}` are unresolved and keep the project **incomplete**, never ready.

## Project

{project-description}

## Language Rules

| Context | Language |
|---|---|
| Assistant ↔ developer communication | **{language}** — always |
| Code, comments, docstrings, commit messages, technical docs | **English** — always |
| App UI, user-facing messages, error messages | {ui-language} |

## Commands

```bash
{commands}
```

## Validation

> Source of truth for quality gates. Run in order, stop on first failure. Legacy gates (`/harness:gates-verify-implementation`, `/orchestrate`) read this section by name.

```bash
{validation-command}
```

**Test policy — which layers MUST have tests:**

- Sensitive paths — {sensitive-paths} — **MUST** have unit tests (mock external SDKs / DB). A change to these paths without a test is a gate failure, not a nice-to-have.
- Core business logic in `{lib-dir}` — unit tests with edge cases.
- Thin adapters / boilerplate / trivial getters — tests optional.

> This section is the maturity signal `plan-feature` reads to size its TESTING STRATEGY — keep it honest. Absence of CI does **not** mean "small project, tests optional".
<!-- if:ui -->

**Runtime smoke — optional conditional step.** The commands above never render a frame. When a change touches `{ui-paths}` **and** an app is running, the gate also performs a baseline → reload → diff check (`.agents/reference/runtime-smoke.md` when present). No running app or device → `SKIPPED` with the reason (never `FAIL`, never a silent pass).
<!-- endif:ui -->

## Tech Stack

| Technology | Purpose |
|---|---|
{tech-stack-rows}

## Architecture

{architecture} Source layout, module roles and naming rules live in `.agents/memory/architecture.md`.

## Code Structure & Modularity

Generic defaults — tune per project: files max **500 lines** · functions max **50 lines**, single responsibility · classes soft **150** / hard **250 lines**, single concept — cohesion first: extract pure functions, never split a cohesive class to hit a number · lines max **100 characters**. Core principles: **KISS**, **YAGNI**, **SOLID** (SRP, OCP, DIP), **Fail Fast**.

## Style & Conventions

{style-conventions}

**Comments: why, not what — cap 1-2 lines.** A comment that restates the adjacent statement, echoes a variable / constant / function name, or repeats what the signature already says is **noise, and gets deleted**. Keep only a *why* the code cannot express: a vendor quirk, a rejected alternative, a non-obvious invariant, or a workaround with a ticket reference. Longer reasoning belongs in `.agents/memory/` or the spec, with a one-line pointer from the code. The `comments` hook nudges at write time where configured.

## Error Handling

Specific exceptions only — no bare `except` / generic catch · per-module logger, not `print` · fail fast on programmer errors, degrade gracefully on user/env errors · messages must **not leak** secrets, tokens, or internal paths.

## Security

**Never commit secrets** — credentials live in gitignored `.env` / config. Validate all user input at system boundaries · HTTPS-only for external APIs · error messages must not leak sensitive info.

**Egress policy — the AI can read a secret, so the guard is on sending it.** Reviewers run closed-context and read-only: anything they need is supplied in an exact-byte context pack that never contains `.env*`, keys, credentials, `user-profile.md`, raw inputs or handoffs. Host controls differ and are recorded per host, never assumed equal:

- **Claude Code:** `WebFetch` is an allowlist in `.claude/settings.json` (never widen to `domain:*`); `curl`/`wget` request bodies and non-GET methods are denied; `.env` edits are denied. These are string globs — defense-in-depth, not a boundary.
- **Codex CLI:** the sandbox and `approval_policy` are the controls; there is no string-glob permission tier. The `push` guard still blocks a committed credential before publication.

**Project docs hosts allowed for fetching:** {docs-hosts}

## Git Workflow

- Conventional commits: `type(scope): subject`, imperative, lowercase, ≤72 chars; body explains *why*. AI attribution in commits is switched off by `"attribution": { "commit": "", "pr": "", "sessionUrl": false }` in `.claude/settings.json` (a setting, not a prose rule — keep the key).
- Never force-push; destructive git operations require an explicit human decision. History rewrite is a human act.
- **`git worktree remove --force` can discard uncommitted work.** Its only guard is the orchestrate pipeline's `status --porcelain` check, which force-removes a worktree only when it is clean and fully merged. Never use it ad hoc.
- A new branch must not track a protected branch (`--no-track`); the push command sets the upstream on first push.

**Orchestrate publish:** {publish}

> Derived from the profile by `scripts/rules.mjs` — `push` only for a direct-to-trunk workflow; every PR-gated preset (feature-branch, gitflow, protected trunk) is `branch-local`: the pipeline commits but never pushes, publishing is a separate human act. Omitting the line means `push`, so the line is always rendered.

### Branch model

**Preset:** {preset} · **Trunk:** `{trunk}` · **Integration:** `{integration}`
**Branch names:** `{branch-pattern}` — types: {branch-types}
**Base → PR dest:** {pr-dest}
**Protected:** {protected}
**Merge:** {merge}

## Project Knowledge Layers

Knowledge layers under `.agents/`. **Before any task read `.agents/memory/index.md`** — `When to Read` (what to load), `Quick Reference` (where to write a discovery), `Memory scope` (why memory stays in the repo).

| Layer | Contains | Lifecycle | Written by |
|---|---|---|---|
| `sources/` | Raw input — briefs, transcripts, sketches | Immutable, pruned manually | Human only |
| `memory/` | Lessons, decisions, quirks, patterns, architecture map, brief | Append-only (newest at end) · some regenerated | reflection pass, bootstrap commands |
| `reference/` | Stable reference docs — APIs, cheatsheets, domain facts | Long-lived | Human + AI |
| `backlog.md` *(optional)* | Delivery map — epics, task DAG, work packages | `Status`/`Ref` written back by planning | backlog bootstrap · `plan-feature` |
| `specs/` | Design docs, each carrying its own approval stamp | Lives with the feature | `brainstorm` + `approval.mjs` |
| `plans/` | Implementation plans | Short-lived: `active/` → `done/` | `plan-feature` |
| `handoffs/` | Session handoffs (local scratchpad) | Per clone | `handoff` |

## Automatic Behaviors

- **Before any task:** read `.agents/memory/index.md` — its `When to Read` table decides what else to load.
- **Before any non-trivial response:** read `.agents/memory/user-profile.md` if present and not `status: empty` — it is the author's local, opted-in profile; it never enters a reviewer pack.
- **Before implementing something new:** check `.agents/plans/active/` for existing plans.
- **Before editing code:** the `memory-guard` hook (where active) blocks the first edit per memory domain per author context until memory was distilled; dormant until domain rules and the size threshold are configured.
- **After fixing a bug:** route the lesson per `.agents/memory/reflection-protocol.md` — application defect → `errors.md` (naming the source file); toolchain friction → `domain/harness.md`. The default is to write nothing.
- **Skip rule:** any memory file with frontmatter `status: empty` is a placeholder — do not load it. `.agents/memory/archive/` is never auto-loaded.
- **Loader Convention / Output-Discipline Convention** for anyone authoring procedures: see `.agents/memory/index.md`.

## Search Commands

Use `rg` (ripgrep), never `grep` or `find` — e.g. `rg "pattern"`, `rg --files -g "*.{ext}"`. `rg` skips hidden dirs — a sweep over `.claude/` or `.agents/` needs `rg --hidden -g '!.git'`.
<!-- if:lsp -->

## Code Navigation (LSP)

This project declares `{lsp-tool}`. Navigate by symbol where the host exposes it: `goToDefinition` / `findReferences` / `incomingCalls` / `hover` return real symbol references, not text matches. `rg` stays correct for free-text and non-code files. Codex CLI exposes no symbol-navigation tool; the section is informational there.
<!-- endif:lsp -->

## Working with the harness plugin

Start every session with `prime`. Planning: `brainstorm` → spec (Draft) → independent closed-context review → the user's single approval (`approval.mjs` stamp) → optionally `plan-feature` (profile `planning.after_brainstorm`). No planning skill writes application code, commits, pushes or deploys. Profile: `.agents/project-profile.json` (legacy `.claude/project-profile.json` still read in place). Installed version: `.agents/harness-version.json` (portable) + `.agents/harness-state/` (machine-local, gitignored).
