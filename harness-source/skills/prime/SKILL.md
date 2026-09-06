---
name: prime
description: Load project context for an engineering session — shared rules, memory routing, brief, architecture, profile, plans, repo state — and report exactly what was read. Read-only. Run first in every fresh session; add `full` for a deep load.
argument-hint: "[full]"
---

# prime — load project context

**Input:** optional word `full`. Anything else is ignored. Quick mode is the default.

**Roots.** `project_root` = the repository root of the current working directory (`git rev-parse --show-toplevel`, else the cwd). `plugin_root` = the installed plugin directory this file lives in (two levels above this `SKILL.md`; on Claude Code it is also `${CLAUDE_PLUGIN_ROOT}`). Every path below is relative to one of these two roots — never to the current shell directory and never to a starter checkout.

**Guardrails (absolute):** read only. Never write, never run a validation command, never install or update anything, never read `.env*`, `.agents/sources/`, `.agents/handoffs/` or `.agents/memory/archive/` (raw inputs, scratch, history). `.agents/memory/user-profile.md` is the developer's **local, opted-in** profile: read it for the author's own session when it exists and is not `status: empty` (project rules → Automatic Behaviors); it never enters a reviewer pack — that is a separate export policy, not a reason to blind the author.

## Steps

### 0. Binding check

Run `node <plugin_root>/scripts/profile.mjs check-version --project-root <project_root> --host <this host: claude|codex> --plugin-root <plugin_root>`.

- `ok: true` → note `harness <version>` for the report; `migration_needed: true` → add a Warning pointing at `profile.mjs migrate-binding` (schema-1 receipt). `alternate_root` present → still bound: the host loaded the same release bytes from another directory (a local marketplace runs from its source path while the registry names the cache copy); mention the `note` once, no Warning.
- `ok: false` → note the error verbatim under Warnings. The project is not bound to this installation on this machine (fresh clone, moved cache, upgraded plugin — a committed `.agents/harness-version.json` without a local `.agents/harness-state/` binding is expected-not-bound). Prime still loads context, but every planning entrypoint (`brainstorm`, `plan-feature`) must refuse until `setup-start` (re-)binds. Never fall back to files from a starter checkout.

### 1. Rules — always

Run `node <plugin_root>/scripts/rules.mjs authority --project-root <project_root>` and follow its verdict:

- `brownfield` → `CLAUDE.md` is the authority. On Claude Code it is already injected — count it as loaded; on Codex read it in full (`AGENTS.md` points at it). Do **not** read a thin generated `.agents/project-rules.md` as if it were rules.
- `greenfield` → read `.agents/project-rules.md` in full (shared rules, not auto-loaded by any host); `CLAUDE.md` is its compatibility rendering.
- `conflict` → Warning with both files named; load neither as authority and say so — a human picks.
- `none` (a truly empty repository) → Warning: `no project rules — run setup-start`; continue with the repo-state steps only.

If the verdict carries `unresolved_required` (e.g. a placeholder validation command) → Warning `rules incomplete — unresolved: …`; the gates cannot run until it is fixed.

### 2. Memory routing — always

Read `.agents/memory/index.md` if it exists (absent → Warning `no memory layer — run setup-start` (`bootstrap.mjs seed`); continue). Probe the frontmatter `status:` of `.agents/memory/architecture.md`, `.agents/memory/project-brief.md`, `.agents/memory/domain/business-model.md` (first 10 lines each). `populated`/`seeded` → read in full. `empty`/absent → skip and warn (an empty brief or architecture is a warning about missing product knowledge, never a blocker):

- brief empty → `⚠️ project-brief.md is empty`; fallback: first 100 lines of `docs/PRD.md` if present, else note `no PRD yet`.
- architecture empty → `⚠️ architecture.md is empty`; fallback: a shallow file listing (`rg --files --max-depth 3`, directories only, ≤40 lines). No full tree dump.

### 3. Profile — always

Run `node <plugin_root>/scripts/profile.mjs read --project-root <project_root>`. Record: status (`ok` / `missing` / `conflict`), file used, effective `after_brainstorm`, reviewer roles, and the `groups` map. `conflict` → Warning with the differing keys; no planning entrypoint may write until a human resolves it. `missing` → Warning: `no profile — run setup-start (interview)`.

### 4. Pipeline and repo state — always

List (never read) `.agents/plans/active/`, the last 5 of `.agents/plans/done/`, top-level `*.md` in `.agents/specs/` and `.agents/reference/` (names and sizes only). Then `git log -10 --oneline`, `git status --short`, and ahead/behind of the upstream if one exists. Read-only git only.

### 5. Full mode only

Also read `.agents/memory/patterns.md`, `decisions.md`, `api.md`, `errors.md` (skip files under 5 non-empty lines) and every populated `.agents/memory/domain/*.md`. Then load `.agents/reference/*.md` ascending by size under a budget: per-file cap 40 KB, total 120 KB, at most 25 files; list what was skipped and why (`CAP` / `MAXLOAD` / `BUDGET`). `.agents/specs/` is never auto-read in either mode.

## Report

Facts only, no narration, no re-summary of the brief. Sections, in order:

- **Loaded (quick|full):** the exact files read this run, dot-separated. This line is the proof of what entered context.
- **Rules:** authority (`brownfield: CLAUDE.md` | `greenfield: .agents/project-rules.md` | `conflict` | `none`) and `ready` or `incomplete — unresolved: …`.
- **Harness:** `harness <version> bound at <root>` or the binding error (expected-not-bound on this machine is stated as such).
- **Profile:** status · file · `after_brainstorm` · reviewer roles · groups (enabled/disabled).
- **Memory:** one bullet per memory file with size and mtime.
- **Pipeline:** active plans · last done plans · spec count · reference count.
- **Repo:** branch · ahead/behind · last commit · dirty files.
- **Warnings:** only when there is one (empty brief/architecture, missing memory layer, missing or incomplete rules, unbound harness, schema-1 receipt, profile conflict/invalid/missing, skipped references per reason).

No closing summary. Stop after the report.
