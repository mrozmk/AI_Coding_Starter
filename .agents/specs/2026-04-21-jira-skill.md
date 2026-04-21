# Design: Jira Skill + `/jira:*` Commands

**Date:** 2026-04-21
**Status:** Approved
**External docs required:** yes

## Summary

Project-level Claude Code skill (`jira`) that enables creating and editing Epics, Tasks, and Bugs in Jira through natural language ("create 5 tasks under Epic PROJ-100") and three explicit slash commands for bulk/search/transition operations. All Jira I/O goes through the `mcp-atlassian` MCP server — no custom HTTP code. Invariants: dry-run before every mutating operation, never create without explicit parameters.

## Problem

The user operates across multiple projects that use Jira (Cloud or Data Center depending on client). Repetitive Jira work — bulk-creating tasks under an Epic, editing fields, searching open bugs, transitioning statuses — is done by hand through the Jira UI. The Divante marketplace repo already contains proven configuration for MCP-based Jira integration (`plugins/docflow`), but it targets Jira Data Center, narrows scope to sub-task breakdown, and lives inside a plugin marketplace that is not this project's distribution channel.

Goal: extract what is reusable (the MCP config pattern and command/skill split), and produce a lightweight project-level skill fitted to this starter kit's conventions and to Jira Cloud for initial testing.

## Solution

Three-layer deliverable, no executable code:

1. **Transport** — `.mcp.json` in repo root declaring the `atlassian` MCP server (`uvx mcp-atlassian`), with Jira credentials inline. File is gitignored; a committed `.mcp.json.example` serves as the template for new clones.
2. **Skill knowledge** — `.claude/skills/jira/SKILL.md` + three `references/` files (field matrix per issue type, description templates, JQL cookbook). Lean SKILL.md (~1500 words) holds invariants and tool-routing; details are pulled on-demand from references.
3. **Explicit entry points** — three slash commands in `.claude/commands/jira/` (`bulk.md`, `search.md`, `transition.md`) that delegate to the skill. Other operations (single create, edit, comment, link) go through natural language recognition by SKILL.md.

**Hard invariants** encoded in SKILL.md:

- **Dry-run first**: every mutating operation (create, update, transition, comment, link) presents a table of planned changes and waits for explicit `y` confirmation before any MCP call is made.
- **No default creation**: if any of `project_key`, `parent_epic_key`, `summary`, `issue_type`, or `components` (when `JIRA_DEFAULT_COMPONENTS` is empty) is missing, the skill stops and asks. Task and Bug always require a parent Epic — no exceptions.
- **No sub-tasks**: Sub-task hierarchy is out of scope; the skill does not emit `issue_type: "Sub-task"`.

## Architecture

```
User input (natural language or /jira:*)
        │
        ▼
.claude/skills/jira/SKILL.md
        │  triggers on: "jira", "task", "bug", "epic", PROJ-123 regex
        │
        ├─ reads env (JIRA_URL, JIRA_API_TOKEN, JIRA_DEFAULT_*)
        ├─ gathers missing parameters from user (no guessing)
        ├─ builds operation plan
        ├─ DRY-RUN: presents table → waits for "y"
        │
        ▼
MCP server "atlassian" (uvx mcp-atlassian, declared in .mcp.json)
        │  tools: jira_create_issue, jira_update_issue, jira_get_issue,
        │         jira_search, jira_add_comment, jira_transition_issue,
        │         jira_get_transitions, jira_create_issue_link,
        │         jira_get_link_types
        ▼
Jira Cloud REST API (v3, ADF for description/comment)
```

**Split of concerns between config files:**

| What | Seen by | Where |
|---|---|---|
| `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN` | MCP server process (makes the HTTP calls) | `.mcp.json` → `env` (inline, gitignored) |
| `JIRA_DEFAULT_PROJECT`, `JIRA_DEFAULT_COMPONENTS`, `JIRA_DEFAULT_LABELS` | Claude Code process / skill (decides request shape) | `.claude/settings.local.json` → `env` |

Rationale: `env` declared in `.mcp.json` is passed only to the spawned MCP server, not visible to the model/skill. Skill defaults must live in `settings.local.json` so the model can read them at planning time.

**Scope (A+B+C+D+E+G from brainstorm):**

| Op | Support |
|---|---|
| Create Epic / Task / Bug | yes, single + bulk |
| Edit Epic / Task / Bug | yes, single + bulk (via JQL search then loop) |
| Search (JQL) | yes, with cookbook of common queries |
| Comments | yes, via `jira_add_comment` |
| Transitions | yes, via `/jira:transition` (explicit command — destructive) |
| Issue links (blocks, relates, etc.) | yes |
| Fields: assignee, labels, components, priority, due date, parent | yes |
| Sub-tasks | **no** — explicitly out of scope |

## Files

**New (gitignored):**

- `.mcp.json` — MCP server declaration with inline Jira credentials. Never committed.
- `.claude/settings.local.json` — sets `env` for skill defaults (`JIRA_DEFAULT_PROJECT`, `JIRA_DEFAULT_COMPONENTS`, `JIRA_DEFAULT_LABELS`). May also be used for project-level permissions later.

**New (committed):**

- `.mcp.json.example` — template for new clones. Same shape as `.mcp.json` but with placeholder values (`https://YOUR-DOMAIN.atlassian.net`, `REPLACE_WITH_ATLASSIAN_API_TOKEN`).
- `.claude/skills/jira/SKILL.md` — skill entry point. Frontmatter (name, description with trigger phrases). Sections: (a) invariants (dry-run first, no default creation, no sub-tasks), (b) intent-to-tool mapping table, (c) minimal required fields per issue type, (d) bulk pattern (table confirm → sequential loop, stop on first error), (e) missing-env handling (hard stop with actionable message). Target: ≤1500 words.
- `.claude/skills/jira/references/field-matrix.md` — per-type field matrix (Epic / Task / Bug). Required vs optional, mapping to `jira_create_issue` / `jira_update_issue` parameter names. Loaded on demand by SKILL.md.
- `.claude/skills/jira/references/description-templates.md` — three markdown templates: Epic (vision + success criteria), Task (objective + acceptance criteria + technical notes), Bug (steps to reproduce + expected/actual + environment). No sub-task template.
- `.claude/skills/jira/references/jql-cookbook.md` — 10–15 pre-written JQL queries with one-line comments (open bugs assigned to me, tasks under epic X, recently created in sprint, etc.).
- `.claude/commands/jira/bulk.md` — `/jira:bulk` command. Explicit entry for creating N issues under a parent. Thin wrapper — delegates to SKILL.md, does not duplicate logic.
- `.claude/commands/jira/search.md` — `/jira:search` command. JQL input with completion hints from the cookbook. Returns a table.
- `.claude/commands/jira/transition.md` — `/jira:transition` command. Dedicated because status changes are destructive. Arguments: `[issue-key] [target-status?]`.
- `.agents/reference/jira-mcp-atlassian.md` — distilled reference for `mcp-atlassian` tool names, parameter shapes, and Jira Cloud specifics (ADF conversion, `parent` field for Epic link post-2023, basic auth with email+token). Written during planning phase from fresh web docs. SKILL.md links here instead of duplicating.
- `.agents/memory/domain/jira.md` — initially empty stub created from the template in `.agents/memory/index.md`. Populated over time with instance-specific quirks (required custom fields, non-standard statuses, workflow idiosyncrasies).

**Modified:**

- `.gitignore` — add `.mcp.json` and (if not already ignored) `.claude/settings.local.json`.
- `.claude/settings.json` — add `"mcp__atlassian__*"` to `permissions.allow` so the user is not prompted on every MCP tool call.
- `CLAUDE.md` — add one-line pointer under **Proactive Agent Usage** or **On-Demand Context** linking to the skill. No domain instructions duplicated.

## External dependencies

- **`mcp-atlassian` (community package on PyPI)** — verify canonical invocation (`uvx mcp-atlassian` vs alternative), current list of exposed MCP tool names and their exact input schemas (especially whether `jira_create_issue` accepts `parent_key` as a flat argument or nested `parent: {key: ...}`, and whether `labels` / `components` are arrays or comma-separated strings). Names in the Divante repo's `docflow` plugin may be outdated.
- **Jira Cloud REST API v3 + ADF** — confirm that `mcp-atlassian` performs markdown-to-ADF conversion server-side for `description` and `comment` fields. Confirm the canonical way to set the parent Epic on a Task/Bug in post-2023 Jira Cloud (the `parent` field, not the legacy `customfield_10014`). Confirm basic auth format: `JIRA_USERNAME` = Atlassian account email, `JIRA_API_TOKEN` issued from id.atlassian.com.
- **`uv` / `uvx`** — installation path on macOS (Astral installer), cache location, and behavior on first `uvx mcp-atlassian` invocation (download → run).
- **Claude Code — MCP and skills loading** — verify that `.claude/settings.local.json` → `env` is injected before MCP servers spawn (so interpolation works if we ever switch to `${VAR}` style). Verify that `.claude/skills/jira/SKILL.md` is auto-loaded with trigger phrases (no manual registration), and that `.claude/commands/jira/*.md` produces `/jira:*` namespaced slash commands. Verify Claude Code's behavior on gitignored `.mcp.json` (whether there is a trust prompt on first start, and whether that requires listing the server in `enabledMcpjsonServers`).

## Edge Cases

**Configuration:**
- Missing `JIRA_URL` / `JIRA_API_TOKEN` → skill hard-stops with the specific missing variable named and a pointer to `.claude/settings.local.json` / `.mcp.json`. No attempts with empty credentials.
- `uvx` not in PATH → MCP server fails to start. First tool call reports "MCP Atlassian not running; check `uvx --version` and restart Claude Code".
- Cloud URL with Data Center auth (or vice versa) → 401/404 from `mcp-atlassian` → message pointing at URL/auth mismatch.
- `JIRA_DEFAULT_COMPONENTS` contains components that do not exist in the target project → validated at dry-run time (via project components endpoint); invalid ones are dropped from the plan with a visible note.

**Parent and scope:**
- Parent key does not exist → 404 from `jira_get_issue`; stop.
- Parent exists but is not an Epic → ask user before proceeding; do not silently link.
- Task / Bug request without parent-Epic specified and `JIRA_DEFAULT_PROJECT` unset or Epic unknown → stop and ask (hard rule from invariants).
- User tries to create issue in a project they lack permission for → 403; message with project key and `JIRA_USERNAME`.

**Fields and validation:**
- Project schema requires custom field (e.g. Story Points, Epic Name) → first create returns 400; raw response is shown, user supplies values, and the pattern is proposed for capture into `.agents/memory/domain/jira.md` for future runs.
- Components list validated against the parent's project (separate endpoint call) before the plan is shown — drops unknown, keeps valid.

**Bulk operations:**
- Partial failure mid-loop (e.g. 3 of 5 created, 4th returns 400) → loop stops; report lists created keys and remaining unfinished items with the raw error; user chooses whether to fix and resume from the failing index. Never auto-revert — Jira has no transactions.
- Potential duplicate detection — dry-run table adds a `⚠ duplicate?` column when `jira_search` (`parent=X AND summary ~ "..."`) returns matches. User decides.
- Large plans (>10 issues) — same dry-run table, collapsible full-description view on `[r]`; progress reporting every 5 issues during the loop.

**JQL:**
- Syntax error → 400 → parsed error shown with a suggested fix.
- Zero results → normal path, not an error.
- Result size >50 → first 50 shown with total count; ask whether to narrow or paginate.
- Ambiguous natural-language query ("show my bugs") → show interpreted JQL before executing, wait for `y` or edit.

**Transitions:**
- Target status not available in workflow for this issue → list available transitions from `jira_get_transitions`; user picks one (or chains multi-step).
- Transition requires fields (e.g. resolution on Close) → ask for missing fields first.

**Links and comments:**
- Markdown in comment has elements ADF rejects (nested tables, certain list shapes) → `mcp-atlassian` returns an error; show raw error and ask user to simplify. Exact conversion limits verified in planning.
- Link type names vary per instance ("blocks" vs "Blocks") → `jira_get_link_types` on first use in a session, cached in-session only.

**Model / context loss:**
- Dry-run invariant holds across turns: the skill re-displays the plan table before any mutating call, even if the user has typed `y` in a previous turn. Confirm window is one turn.

## Out of Scope

- Sub-tasks (hierarchy `Epic → Task/Bug` only; no `issue_type: "Sub-task"`)
- Stories (would be a separate spec — different hierarchy)
- Confluence integration (`mcp-atlassian` supports it; not configured here)
- Attachments, sprint management, worklogs, time tracking
- Bulk custom-field support beyond the standard set (summary, description, labels, components, assignee, priority, due date, parent)
- CSV import / mass migration
- Rate limit retry, offline queueing, background jobs
- Undo / rollback (technically impossible — Jira has no transactions; dry-run is the only defense)
- Plugin marketplace packaging (stay project-level; re-promotion to a Divante plugin is a separate operation if ever needed)

## Decisions recorded

Resolved during brainstorm:

1. **Jira Cloud is the initial target** (per brainstorm P1). Data Center support is deferred but architecture does not preclude it — switching is a matter of swapping env variables and the MCP server's auth method.
2. **Project-level placement** (P3, option A). Files live under `.claude/` and project root. No user-level or plugin packaging.
3. **Dry-run first is an invariant, not a default** (P4, option A). Applies to every mutating operation including single updates and transitions.
4. **Env-only configuration** (P5, option C). No `jira.local.md` or config YAML. Two env buckets: `.mcp.json` for MCP credentials, `settings.local.json` for skill defaults.
5. **Mixed surface** (P6, option C). SKILL.md as primary natural-language entry; three slash commands (`/jira:bulk`, `/jira:search`, `/jira:transition`) as explicit entries for bulk and destructive operations.
6. **`.mcp.json` is gitignored; inline credentials**; committed `.mcp.json.example` as template.
7. **Namespaced slash commands** (`/jira:bulk`, not `/jira-bulk`) via `.claude/commands/jira/` subfolder. Deviates from the project's otherwise-flat convention (`/commit`, `/push`), justified by expected growth of Jira-related commands.
8. **No default creation without full context**. Task and Bug always require explicit parent Epic; missing parameters stop the flow with a question. No fallback to "create without parent".
