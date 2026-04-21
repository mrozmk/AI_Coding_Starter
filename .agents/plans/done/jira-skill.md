# Feature: jira-skill

The following plan should be complete, but it's important that you validate codebase patterns and task sanity before you start implementing. Pay special attention to naming of existing utils, types, and models. Import from the right files.

**Source spec:** `.agents/specs/2026-04-21-jira-skill.md`
**External docs required:** yes

---

## Feature Description

A single project-level Claude Code **skill** at `.claude/skills/jira/` that handles Jira Epics, Tasks, and Bugs end-to-end through:
- **Natural language** (auto-trigger on "jira", "PROJ-XXX", "task", "bug", "epic"): `"stwórz 5 tasków pod Epickiem PROJ-100"`, `"zaktualizuj PROJ-42 priorytet na High"`, `"pokaż moje otwarte bugi"`, `"zmień PROJ-123 na In Progress"`.
- **Explicit invocation** `/jira` with optional subcommand as first argument: `/jira bulk PROJ-100 5 refaktor-auth`, `/jira search open-bugs`, `/jira transition PROJ-123 "In Progress"`, `/jira comment PROJ-123 "zaczynam pracę"`, `/jira link PROJ-124 blocks PROJ-125`.
- **Read-free mode** without arguments: `/jira` alone opens an interactive assistant that asks what the user wants to do.

All Jira I/O goes through the `mcp-atlassian` MCP server (no custom HTTP code). Hard invariants encoded in the skill body:
1. **Dry-run before every mutating operation** — table/diff preview, wait for explicit `y` confirmation.
2. **No default creation** — every required parameter (project, parent Epic, summary, issue type, components) must come from user input or explicit `JIRA_DEFAULT_*` env. Never fabricate.
3. **No sub-tasks** — skill does not emit `issue_type: "Sub-task"`.

### Relation to spec

The spec's *intent* is preserved in full — scope A+B+C+D+E+G from the brainstorm, no sub-tasks, dry-run first, env-only config, project-level placement. **Three implementation-level revisions** versus the spec, detailed in the NOTES section:

1. **Surface reduced to a single skill** (spec decision #5 and #7 revised). Spec proposed "one SKILL.md + three namespaced slash commands" `/jira:bulk`, `/jira:search`, `/jira:transition`. Web research confirmed that subdirectory-based namespacing does NOT work in Claude Code ([issue #2422](https://github.com/anthropics/claude-code/issues/2422) closed as not planned), AND that custom commands have been merged into skills (each skill already produces its own `/name`). Rather than flat names `/jira-bulk` etc. — which would clutter the user's `/` menu alongside existing flat commands `/commit`, `/push`, `/brainstorm` — this plan consolidates everything into **one skill `/jira`**. Subcommand dispatch happens inside the skill body (first word of `$ARGUMENTS` routes to the right flow). User-facing result: one new entry in autocomplete, same functional surface.
2. **Bulk mechanism** — `mcp-atlassian` exposes `jira_batch_create_issues(issues, validate_only)`. The plan uses this instead of a sequential loop: `validate_only: true` is the dry-run phase (server-side shape validation), then `validate_only: false` executes. Same user-facing invariants, cleaner implementation.
3. **Parent via `additional_fields`** — actual mcp-atlassian schema routes parent/epic-link through an `additional_fields` JSON string, not as a flat parameter. Plan uses `{"parent": "EPIC-KEY"}` first, with fallback to `{"epic_link": "EPIC-KEY"}` for legacy Cloud instances.

---

## User Story

As a developer using the `AI_Coding_Starter` project
I want a single `/jira` skill (auto-triggered by natural language or explicitly with subcommands) that creates and edits Epics, Tasks, Bugs, handles search, transitions, comments, and links
So that bulk operations ("5 tasks under Epic X") and routine edits take one prompt instead of N clicks in the Jira UI, without ever executing a Jira mutation before I see exactly what it will do, and without cluttering my `/` command menu with multiple Jira entries.

---

## Problem Statement

Repetitive Jira work — bulk-creating tasks under an Epic, editing fields, searching open bugs by JQL, transitioning statuses, commenting, linking issues — is currently done manually through the Jira web UI. The `divante-claude-marketplace-main/plugins/docflow` source repo has a working pattern for MCP-based Jira integration, but it targets Jira Data Center, narrows scope to sub-task breakdown, and ships as a marketplace plugin — not this starter kit's distribution channel.

## Solution Statement

Extract the reusable MCP pattern (community server `mcp-atlassian` launched via `uvx`, environment-variable credentials) and adapt it into a **single** project-level skill targeted at Jira Cloud. The skill dispatches on subcommand (first `$ARGUMENTS` word) or on natural-language intent (auto-trigger via description/when_to_use phrases). Large details (field matrix, description templates, JQL cookbook, bulk pattern, transition pattern) live in `.claude/skills/jira/references/` and are loaded on-demand by the skill. Credentials are inline in gitignored `.mcp.json` (MCP-server process env); skill defaults are in gitignored `.claude/settings.local.json` (Claude Code process env). A committed `.mcp.json.example` is the setup template for new clones.

## Feature Metadata

**Feature Type**: New Capability (one skill, no executable code)
**Estimated Complexity**: Medium (single author, one skill surface, but a dozen files and a non-trivial external integration)
**Primary Systems Affected**:
- `.claude/skills/jira/` (new directory — does not exist yet)
- `.mcp.json` + `.mcp.json.example` (new, project root)
- `.claude/settings.local.json` (new)
- `.claude/settings.json` (modified — permissions allowlist)
- `.agents/reference/` (new reference doc)
- `.agents/memory/domain/` (new stub)
- `.gitignore` (modified — `.mcp.json` added; `.claude/settings.local.json` already ignored)
- `CLAUDE.md` (modified — one-line pointer)

**Dependencies**:
- `uv` / `uvx` from Astral (runtime for MCP server) — installed on host machine
- `mcp-atlassian` (community PyPI package by sooperset) — auto-fetched by `uvx` on first run
- Jira Cloud instance + API token from `id.atlassian.com`

---

## CONTEXT REFERENCES

### Relevant Codebase Files — IMPORTANT: READ BEFORE IMPLEMENTING

- [CLAUDE.md](../../../CLAUDE.md) (lines 1-200) — Project rules. Polish ↔ developer, English in code/docs, `.agents/*` knowledge layers, git policy, automatic behaviors. User-facing skill output stays Polish-by-default (per "App UI"); skill internals (frontmatter, procedural body, references) are English so trigger-phrase matching works for both Polish and English inputs.
- [.agents/specs/2026-04-21-jira-skill.md](../../specs/2026-04-21-jira-skill.md) (entire file) — The approved spec. Single source of truth for **what** and **why**.
- [.agents/sources/divante-claude-marketplace-main/plugins/docflow/.mcp.json](../../sources/divante-claude-marketplace-main/plugins/docflow/.mcp.json) (lines 1-14) — Pattern for MCP server declaration via `uvx mcp-atlassian`. Uses `${VAR}` placeholders and Data-Center auth; we use inline values and Cloud auth.
- [.agents/sources/divante-claude-marketplace-main/plugins/docflow/skills/jira-workflow/SKILL.md](../../sources/divante-claude-marketplace-main/plugins/docflow/skills/jira-workflow/SKILL.md) (entire file, lines 1-238) — Reference for SKILL.md structure, issue markup patterns, and tool-name conventions. Note: uses Jira-Server wiki markup in templates; we use markdown (mcp-atlassian auto-converts to ADF for Cloud).
- [.agents/sources/divante-claude-marketplace-main/plugins/docflow/commands/jira-tasks.md](../../sources/divante-claude-marketplace-main/plugins/docflow/commands/jira-tasks.md) (lines 1-122) — Reference for frontmatter (`description`, `argument-hint`, `allowed-tools`) and `$ARGUMENTS` usage.
- [.claude/commands/commit.md](../../../.claude/commands/commit.md) (lines 1-51) — Project convention: simple YAML frontmatter, numbered steps, CRITICAL-rules callouts. Mirror the tone.
- [.claude/commands/brainstorm.md](../../../.claude/commands/brainstorm.md) (lines 1-162) — Example of a larger skill with phased process, tables, HARD-GATE invariant. Mirror invariant-callout style.
- [.claude/settings.json](../../../.claude/settings.json) (lines 1-103) — Current permissions structure. We add `"mcp__atlassian__*"` to `permissions.allow`.
- [.gitignore](../../../.gitignore) (lines 1-125) — Already ignores `.claude/settings.local.json` (line 25). We add `.mcp.json` in the "Secrets & local config" block.
- [.agents/memory/index.md](../../memory/index.md) (lines 32-56) — Template for new `domain/jira.md` stub.

### New Files to Create

Project root:
- `.mcp.json` — MCP server declaration with inline Cloud credentials. Gitignored.
- `.mcp.json.example` — Committed template for new clones with placeholder values.

Claude config — **one skill directory**:
- `.claude/settings.local.json` — Sets `env` for skill defaults. Gitignored.
- `.claude/skills/jira/SKILL.md` — The skill. Sole slash-command entry (`/jira`). Contains frontmatter, invariants, subcommand dispatch, intent-to-tool routing, env preflight, error handling. Links to references on-demand.
- `.claude/skills/jira/references/field-matrix.md` — Per-type required/optional fields, mapped to MCP tool parameters (incl. `additional_fields` JSON convention).
- `.claude/skills/jira/references/description-templates.md` — Markdown templates for Epic / Task / Bug descriptions.
- `.claude/skills/jira/references/jql-cookbook.md` — 10-15 pre-written JQL queries.
- `.claude/skills/jira/references/bulk-pattern.md` — Detailed flow for bulk creation using `jira_batch_create_issues` with `validate_only`.
- `.claude/skills/jira/references/transition-pattern.md` — Two-phase flow for status transitions (`jira_get_transitions` → `jira_transition_issue`).

Knowledge layers:
- `.agents/reference/jira-mcp-atlassian.md` — Tool reference for `mcp-atlassian`: canonical tool names, parameter shapes, Cloud-vs-Server auth, markdown-to-ADF conversion note.
- `.agents/memory/domain/jira.md` — Empty stub instantiated from the template.

Modifications:
- `.gitignore` — add `.mcp.json` entry.
- `.claude/settings.json` — add `"mcp__atlassian__*"` to `permissions.allow`.
- `CLAUDE.md` — one-line pointer in Proactive Agent Usage or On-Demand Context.

### Relevant Documentation

All links were consulted during planning. Execution should re-consult the tool-reference page only for ambiguities surfacing during implementation.

- [Claude Code — Extend Claude with skills](https://code.claude.com/docs/en/skills)
  - Sections used: Frontmatter reference, Where skills live, Add supporting files, Control who invokes a skill, Pass arguments to skills, Inject dynamic context.
  - Why: Frontmatter fields (`name`, `description`, `when_to_use`, `argument-hint`, `allowed-tools`), the 1,536-char description cap, `$ARGUMENTS` / `$0` substitutions, and the `!`cmd` ` shell-injection syntax for env preflight.
- [Claude Code — Slash commands](https://code.claude.com/docs/en/slash-commands)
  - Why: Confirms custom commands and skills share the same `/name` dispatch.
- [GitHub — anthropics/claude-code issue #2422](https://github.com/anthropics/claude-code/issues/2422)
  - Why: Subdirectory namespacing not supported — authoritative reason for consolidating to a single skill.
- [sooperset/mcp-atlassian (GitHub)](https://github.com/sooperset/mcp-atlassian)
  - Why: Confirms Cloud auth env (`JIRA_URL` + `JIRA_USERNAME` + `JIRA_API_TOKEN`), 72-tool scope, install methods (uvx/pip/docker).
- [mcp-atlassian — Jira Issues tools reference](https://mcp-atlassian.soomiles.com/docs/tools/jira-issues)
  - Why: Exact tool signatures. Key facts: `parent`/`epic_link` go through `additional_fields` as a JSON string; `components` is a comma-separated string; `description` is markdown (auto-converted); `jira_batch_create_issues(issues, validate_only?)` exists; `jira_transition_issue` needs `transition_id` (not a status name).
- [mcp-atlassian — tools reference index](https://mcp-atlassian.soomiles.com/docs/tools-reference)
  - Why: Tool-name confirmations for `jira_add_comment`, `jira_create_issue_link`, `jira_search`.
- [Atlassian Developer — Jira Cloud REST v3 (issues)](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/)
  - Why: ADF requirement for description/comment (handled by mcp-atlassian's markdown conversion).
- [Atlassian Community — "Create an Issue with Epic as parent using REST API"](https://community.atlassian.com/forums/Jira-questions/Create-an-Issue-with-Epic-as-parent-using-REST-API/qaq-p/1409874)
  - Why: Context on legacy Epic-Link custom field vs modern `parent` field.
- [Astral — uv installation](https://docs.astral.sh/uv/getting-started/installation/)
  - Why: Install command `curl -LsSf https://astral.sh/uv/install.sh | sh`; binaries at `~/.local/bin/uv` and `~/.local/bin/uvx`.
- [Astral — uv tools (uvx)](https://docs.astral.sh/uv/guides/tools/)
  - Why: `uvx <pkg>` auto-fetches from PyPI into a temporary isolated env; no global install.

### Patterns to Follow

**Naming conventions (from existing `.claude/commands/*.md`):**
- Slash-command names: lowercase, hyphenated. Our skill: `/jira`.
- Skill directory name matches slash name: `.claude/skills/jira/`.
- Reference file names: `kebab-case.md`.

**Frontmatter (from [commit.md:1-4](../../../.claude/commands/commit.md)):**
```yaml
---
description: <single line, terse, user-facing summary>
---
```
For this auto-triggering skill, also include `name: jira`, `when_to_use:` with explicit trigger phrases, `argument-hint:`, and `allowed-tools:`. Keep combined `description + when_to_use` under 1,536 chars.

**Numbered steps pattern (from commit.md, brainstorm.md):**
```markdown
## Steps to follow (execute all in order):

1. [action]
2. [action — including invariant callouts]
```

**Invariant callout (from brainstorm.md:10-12):**
```markdown
<HARD-GATE>
Do NOT {action} until {precondition}. {Why in one sentence.}
</HARD-GATE>
```
Use this for the dry-run, no-default-creation, and no-sub-tasks rules at the top of `jira/SKILL.md`.

**Inline tables (from commit.md, brainstorm.md):**
Plain markdown tables. Never ASCII art for dry-run previews.

**Language:**
- **Skill internals (frontmatter, procedural body, reference docs): English.** CLAUDE.md "Language Rules" → technical docs in English.
- **User-facing strings the skill prints: Polish.** CLAUDE.md "App UI". Example: dry-run prompt says `"Tworzę? [y/n/edit]"`, not `"Create? [y/n/edit]"`.

**Error handling:**
- Don't swallow MCP errors. On 4xx/5xx, show the raw error. Token never appears in prompts so raw errors are safe (CLAUDE.md "Error messages must not leak secrets" is satisfied at config layer).
- Missing env: hard stop before any MCP call, name the missing variable, point at the file to edit.

**Anti-patterns to avoid:**
- Do **not** fabricate parameters when the user didn't supply them and no `JIRA_DEFAULT_*` applies. Ask.
- Do **not** hard-code project keys, labels, or team conventions in the skill body. Everything project-specific comes from env or from user input at runtime.
- Do **not** use Jira Server wiki markup (`h3.`, `*bold*`, `{{code}}`) in description templates — Cloud expects ADF, mcp-atlassian converts standard markdown.
- Do **not** add fields beyond the spec's core set (summary, description, labels, components, assignee, priority, due date, parent). Anything else → user-provided `additional_fields` ad-hoc, captured to memory on first-use.
- Do **not** use `${VAR}` interpolation in `.mcp.json` — spec option C is inline values + `.mcp.json` gitignored.
- Do **not** commit `.mcp.json` or `.claude/settings.local.json` — both gitignored.

---

## IMPLEMENTATION PLAN

Two phases plus manual validation. Everything converges on one SKILL.md; references exist to keep that SKILL.md under 500 lines.

### Phase 1: Foundation — config, transport, knowledge layers

Everything the skill depends on. Does not touch skill files yet.

1.1. Update `.gitignore` to ignore `.mcp.json` (keep `.mcp.json.example` tracked).
1.2. Create `.mcp.json` (gitignored) with Cloud credential placeholders inline.
1.3. Create `.mcp.json.example` (tracked) — identical content, template.
1.4. Create `.claude/settings.local.json` (gitignored) with skill-side defaults in `env`.
1.5. Add `"mcp__atlassian__*"` to `permissions.allow` in `.claude/settings.json`.
1.6. Create `.agents/reference/jira-mcp-atlassian.md` — distilled tool reference.
1.7. Create `.agents/memory/domain/jira.md` — empty stub.

### Phase 2: The skill — one SKILL.md + five references

All inside `.claude/skills/jira/`.

2.1. Create `references/field-matrix.md` — Epic / Task / Bug field tables.
2.2. Create `references/description-templates.md` — markdown templates per type.
2.3. Create `references/jql-cookbook.md` — 10-15 JQL snippets.
2.4. Create `references/bulk-pattern.md` — detailed `jira_batch_create_issues` flow.
2.5. Create `references/transition-pattern.md` — two-phase transition flow.
2.6. Create `SKILL.md` — primary skill body. All three invariants, env preflight, subcommand dispatch, intent-to-tool table, error handling. Links to all references.

### Phase 3: Wire-up

3.1. Update `CLAUDE.md` — one-line pointer to the skill.

### Phase 4: Manual validation

Project is a starter kit — no test framework, no CI. Validation is manual smoke-testing against a real Jira Cloud project.

4.1. Runtime: `uvx --version` succeeds.
4.2. After Claude Code restart: `/jira` appears in autocomplete (only new `/` entry).
4.3. `/mcp` shows the `atlassian` server, status connected.
4.4. Natural-language Polish prompt auto-triggers the skill.
4.5. `/jira bulk PROJ-XXX 2 test-refaktor` produces a dry-run table; `n` aborts; `y` creates two issues.
4.6. `/jira transition PROJ-XXX "In Progress"` previews status change; `y` applies.
4.7. `/jira comment PROJ-XXX "test"` previews comment; `y` posts.

---

## STEP-BY-STEP TASKS

IMPORTANT: Execute every task in order, top to bottom. Each task is atomic and independently testable. Paths are relative to repo root `/Users/marekmroz/Desktop/AI_Coding_Starter/`.

### Task 1.1 — UPDATE `.gitignore`

- **IMPLEMENT**: Add line `.mcp.json` inside the existing `# Secrets & local config — NEVER commit` block (after `.env.*`, before `*.pem`). Do NOT add `.mcp.json.example`.
- **PATTERN**: Follow the block-comment style in [.gitignore:10-16](../../../.gitignore).
- **IMPORTS**: N/A
- **GOTCHA**: `.claude/settings.local.json` is already ignored ([.gitignore:25](../../../.gitignore)) — do not re-add.
- **VALIDATE**:
  ```bash
  grep -E '^\.mcp\.json$' .gitignore && git check-ignore .mcp.json
  # Expected: prints ".mcp.json" then ".mcp.json".
  ```

### Task 1.2 — CREATE `.mcp.json`

- **IMPLEMENT**: JSON with one `mcpServers` entry named `atlassian`, running `uvx mcp-atlassian`, with `env` containing inline `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN`. Placeholder strings — user edits real values.
- **PATTERN**: Shape mirrors [divante docflow .mcp.json](../../sources/divante-claude-marketplace-main/plugins/docflow/.mcp.json); without `${VAR}` interpolation and without Confluence entries.
- **IMPORTS**: N/A
- **GOTCHA**:
  - Valid JSON only — no trailing commas, no comments.
  - `JIRA_URL` for Cloud: `https://your-domain.atlassian.net` (no trailing slash).
  - `JIRA_USERNAME` is the Atlassian account **email**.
  - `JIRA_API_TOKEN` from `id.atlassian.com → Security → API tokens`.
  - Do NOT include `JIRA_PERSONAL_TOKEN` — that's Server/DC auth and conflicts with Cloud.
- **CONTENT** (write literally — user replaces values):
  ```json
  {
    "mcpServers": {
      "atlassian": {
        "command": "uvx",
        "args": ["mcp-atlassian"],
        "env": {
          "JIRA_URL": "https://REPLACE-WITH-YOUR-DOMAIN.atlassian.net",
          "JIRA_USERNAME": "REPLACE-WITH-YOUR-ATLASSIAN-EMAIL",
          "JIRA_API_TOKEN": "REPLACE-WITH-ATLASSIAN-API-TOKEN"
        }
      }
    }
  }
  ```
- **VALIDATE**:
  ```bash
  jq '.mcpServers.atlassian.command' .mcp.json
  # Expected: "uvx"
  jq '.mcpServers.atlassian.env | keys' .mcp.json
  # Expected: ["JIRA_API_TOKEN","JIRA_URL","JIRA_USERNAME"]
  ```

### Task 1.3 — CREATE `.mcp.json.example`

- **IMPLEMENT**: Identical content to `.mcp.json` (same placeholders). Point: existing in git so new clones have a template.
- **PATTERN**: Same as 1.2.
- **IMPORTS**: N/A
- **GOTCHA**: JSON has no comment syntax. Instructional text belongs in CLAUDE.md (Task 3.1) or reference doc (Task 1.6).
- **VALIDATE**:
  ```bash
  jq '.' .mcp.json.example > /dev/null && git check-ignore .mcp.json.example || echo "tracked (correct)"
  # Expected: no jq error, and the second command prints "tracked (correct)".
  ```

### Task 1.4 — CREATE `.claude/settings.local.json`

- **IMPLEMENT**: JSON with one `env` object — `JIRA_DEFAULT_PROJECT`, `JIRA_DEFAULT_COMPONENTS`, `JIRA_DEFAULT_LABELS`. Placeholder strings.
- **PATTERN**: Claude Code reads `env` from this file and exposes values to the model's process, so the skill can read them.
- **IMPORTS**: N/A
- **GOTCHA**:
  - Separate file from `.mcp.json` by design — `.mcp.json` env reaches only MCP server process; this file's env reaches the model process. Do NOT collapse.
  - `JIRA_DEFAULT_COMPONENTS` and `JIRA_DEFAULT_LABELS` are comma-separated strings (matching mcp-atlassian `components` input format). Empty string = no default.
- **CONTENT**:
  ```json
  {
    "env": {
      "JIRA_DEFAULT_PROJECT": "REPLACE-WITH-PROJECT-KEY",
      "JIRA_DEFAULT_COMPONENTS": "",
      "JIRA_DEFAULT_LABELS": "from-claude"
    }
  }
  ```
- **VALIDATE**:
  ```bash
  jq '.env | keys' .claude/settings.local.json
  # Expected: ["JIRA_DEFAULT_COMPONENTS","JIRA_DEFAULT_LABELS","JIRA_DEFAULT_PROJECT"]
  git check-ignore .claude/settings.local.json
  # Expected: prints the path (= ignored, correct).
  ```

### Task 1.5 — UPDATE `.claude/settings.json`

- **IMPLEMENT**: Add entry `"mcp__atlassian__*"` to `permissions.allow`. Place near the top of the array or grouped by prefix.
- **PATTERN**: Existing `Bash(...)` entries are the only visible pattern (MCP-tool entries don't exist yet in this file).
- **IMPORTS**: N/A
- **GOTCHA**:
  - Invalid JSON breaks the entire settings file. Use Edit with exact context.
  - Do NOT remove any existing deny rules.
- **VALIDATE**:
  ```bash
  jq '.permissions.allow | map(select(test("^mcp__atlassian")))' .claude/settings.json
  # Expected: ["mcp__atlassian__*"]
  jq '.' .claude/settings.json > /dev/null
  # Expected: no parse error.
  ```

### Task 1.6 — CREATE `.agents/reference/jira-mcp-atlassian.md`

- **IMPLEMENT**: Reference doc distilling mcp-atlassian for the skill. Structure:
  1. **Setup** — `uvx --version` check, how to get API token, how to fill `.mcp.json` and `.claude/settings.local.json`.
  2. **Auth matrix** — Cloud (we use this) vs Server/DC (one-line note).
  3. **Markdown-to-ADF conversion** — one paragraph: mcp-atlassian auto-converts markdown to ADF server-side; pass markdown everywhere in `description` / `comment`.
  4. **Tool catalog** — each tool as `tool_name(param1: type [required], param2: type [optional], ...)` with one-line description. At minimum: `jira_create_issue`, `jira_update_issue`, `jira_get_issue`, `jira_search`, `jira_add_comment`, `jira_transition_issue`, `jira_get_transitions`, `jira_create_issue_link`, `jira_get_link_types`, `jira_batch_create_issues`, `jira_get_all_projects`.
  5. **Parent / Epic link convention** — `additional_fields` is a **JSON string** (not object): `{"parent": "EPIC-KEY"}` (try first) or `{"epic_link": "EPIC-KEY"}` (fallback for older Cloud).
  6. **Components convention** — comma-separated string, NOT array.
  7. **Transitions** — two-call: `jira_get_transitions(issue_key)` → pick `id` by status name → `jira_transition_issue(issue_key, transition_id)`.
  8. **Known limitations** — no transaction/rollback; `jira_batch_create_issues` has per-issue atomicity (partial success possible).
  9. **Authoritative sources** — links from the Relevant Documentation section above.
- **PATTERN**: Plain markdown, h2 per section, tables for the tool catalog.
- **IMPORTS**: N/A
- **GOTCHA**:
  - Do NOT invent parameter names not seen in docs. If in doubt: `"TBD — verify at first use against mcp__atlassian__<tool> JSON schema"`.
  - State explicitly that `additional_fields` is an mcp-atlassian wrapper, not a Jira REST concept.
- **VALIDATE**:
  ```bash
  test -s .agents/reference/jira-mcp-atlassian.md && grep -cE '^## ' .agents/reference/jira-mcp-atlassian.md
  # Expected: non-empty file; count ≥8 (one per section).
  ```

### Task 1.7 — CREATE `.agents/memory/domain/jira.md`

- **IMPLEMENT**: Empty stub using template from [.agents/memory/index.md](../../memory/index.md) lines 32-56. Fill `{module_name}` = "jira", `{One-line summary}` = "Jira Cloud integration via mcp-atlassian MCP server.", `{path/to/module}` = `.claude/skills/jira/`. Leave bullet placeholders intact.
- **PATTERN**: The template is already defined in `memory/index.md`.
- **IMPORTS**: N/A
- **GOTCHA**: Do NOT pre-populate with speculative quirks. Real usage seeds this.
- **VALIDATE**:
  ```bash
  head -5 .agents/memory/domain/jira.md
  # Expected: starts with "# Memory: jira".
  ```

### Task 2.1 — CREATE `.claude/skills/jira/references/field-matrix.md`

- **IMPLEMENT**: Three markdown tables, one per issue type:
  - **Epic**: required = `project_key`, `summary`, `issue_type="Epic"`. Optional = `description` (markdown), `labels`, `components` (comma-separated string), `assignee`, `priority`, `duedate`. Custom: some older Jira projects require "Epic Name" → route via `additional_fields: '{"customfield_10011": "..."}' ` if first create returns 400.
  - **Task**: required = `project_key`, `summary`, `issue_type="Task"`, `additional_fields='{"parent": "EPIC-KEY"}'`. Optional same as Epic.
  - **Bug**: same as Task but `issue_type="Bug"`.
  Columns: Field | Required? | MCP parameter | Notes.
- **PATTERN**: Plain markdown tables, English headings.
- **IMPORTS**: N/A
- **GOTCHA**:
  - Every row mapping to `additional_fields` must flag "JSON **string**, not object".
  - `components` is comma-separated string, not array — flag in Notes.
- **VALIDATE**:
  ```bash
  grep -c '^| ' .claude/skills/jira/references/field-matrix.md
  # Expected: ≥15 (three tables, ≥5 rows each including header/separator).
  ```

### Task 2.2 — CREATE `.claude/skills/jira/references/description-templates.md`

- **IMPLEMENT**: Three markdown templates, each ≤20 lines:
  - **Epic**: `## Vision` / `## Success Criteria` / `## Out of Scope` / `## Links`.
  - **Task**: `## Objective` / `## Acceptance Criteria` (bullet checklist) / `## Technical Notes`.
  - **Bug**: `## Steps to Reproduce` (numbered) / `## Expected Behavior` / `## Actual Behavior` / `## Environment` / `## Evidence`.
- **PATTERN**: Follow [divante jira-workflow SKILL.md:90-132](../../sources/divante-claude-marketplace-main/plugins/docflow/skills/jira-workflow/SKILL.md) STRUCTURE, but:
  - Drop "Files to Modify" and "Dependencies (PROJ-XXX)" sections (not in scope).
  - Rewrite Jira wiki markup (`h3.`, `{{code}}`) into **markdown** (`##`, backtick-code). Deliberate.
  - Drop Story template entirely.
- **IMPORTS**: N/A
- **GOTCHA**:
  - Do NOT use Jira wiki markup. Cloud needs ADF; mcp-atlassian converts standard markdown.
  - Nested markdown tables and deep nested lists sometimes fail ADF conversion. Keep templates flat — simple lists, headings.
- **VALIDATE**:
  ```bash
  grep -E '^## (Vision|Objective|Steps to Reproduce)' .claude/skills/jira/references/description-templates.md | wc -l
  # Expected: 3.
  ```

### Task 2.3 — CREATE `.claude/skills/jira/references/jql-cookbook.md`

- **IMPLEMENT**: 10-15 labeled JQL snippets, one h3 per snippet:
  - Open bugs assigned to me in default project
  - Open tasks under a given Epic (parameterized by EPIC-KEY)
  - My issues created in last 7 days
  - Unresolved issues with no assignee
  - Issues changed in last 24h
  - Issues in active sprint
  - High-priority bugs
  - Issues blocked by another
  - Sub-tasks of a parent (for search only — we don't create sub-tasks)
  - Issues with a specific label
  - Issues without components
  - Issues with due date within 7 days
  - Closed issues resolved this week
  Each: one-line purpose + fenced JQL block. Use `$JIRA_DEFAULT_PROJECT` literal where project-dependent; skill substitutes at runtime.
- **PATTERN**: Markdown h3 per snippet, fenced code block for JQL.
- **IMPORTS**: N/A
- **GOTCHA**:
  - `currentUser()` = "me". Do NOT hardcode usernames.
  - `Sprint in openSprints()` requires project has Scrum sprints. Footnote-flag it.
- **VALIDATE**:
  ```bash
  grep -c '^### ' .claude/skills/jira/references/jql-cookbook.md
  # Expected: ≥10.
  ```

### Task 2.4 — CREATE `.claude/skills/jira/references/bulk-pattern.md`

- **IMPLEMENT**: Detailed bulk-create flow (~60-80 lines):
  1. **Parse** `$ARGUMENTS`: `$0` = parent-epic-key, `$1` = count (optional, default "ask"), rest = topic.
  2. **Validate** `$0`: `jira_get_issue($0, fields="summary,issuetype,project")`. If `issuetype != "Epic"`, stop and ask.
  3. **Generate plan** — N issues, auto-written summaries from topic, fill `components` and `labels` from env defaults.
  4. **Dry-run** — call `jira_batch_create_issues(issues=<JSON-string>, validate_only=true)`. Any validation error → show raw response, stop.
  5. **Render confirm table** — `| # | Type | Summary | Components | Labels |`, then `"Tworzę N zadań pod $0? [y/n/edit]"`.
  6. **Execute on y** — `jira_batch_create_issues(issues=<same-JSON-string>, validate_only=false)`. Report created keys.
  7. **Partial failure** — list created keys + failed issues with raw errors. No auto-rollback.
- **PATTERN**: Numbered steps, markdown tables.
- **IMPORTS**: N/A
- **GOTCHA**:
  - `issues` param for `jira_batch_create_issues` is a **JSON string** (same convention as `additional_fields`). Serialize, don't pass list literal.
  - `validate_only: true` catches shape errors but some schema errors (missing custom fields) only surface on real execute. Expect possible mid-batch partial success.
- **VALIDATE**:
  ```bash
  grep -E 'jira_batch_create_issues|validate_only' .claude/skills/jira/references/bulk-pattern.md | wc -l
  # Expected: ≥4 (tool name + validate_only mentioned multiple times).
  ```

### Task 2.5 — CREATE `.claude/skills/jira/references/transition-pattern.md`

- **IMPLEMENT**: Detailed transition flow (~40-60 lines):
  1. **Parse** `$0` = issue-key, `$1` = target-status-name (optional).
  2. **Discover** — `jira_get_transitions($0)` returns `[{id, name, ...}]`.
  3. **Select**:
     - If `$1` given and matches a transition name (case-insensitive) → pick that id.
     - If `$1` not given → show list, ask user to pick by name or number.
     - If `$1` given but no match → show available list, ask user to choose from them (don't guess).
  4. **Fetch current status** for the diff prompt: `jira_get_issue($0, fields="status")`.
  5. **Dry-run** — `"Zmieniam $0 z '$CURRENT_STATUS' na '$TARGET_STATUS'? [y/n]"`.
  6. **Execute on y** — `jira_transition_issue($0, transition_id=<id>)`. If response indicates the transition requires fields (Jira workflow with required resolution, comment, etc.), ask user for each, retry with `fields` populated.
  7. **Report** — `"$0 → $TARGET_STATUS ✓"`.
- **PATTERN**: Numbered steps.
- **IMPORTS**: N/A
- **GOTCHA**:
  - `transition_id` is a string id (often numeric) — do NOT pass the status name directly.
  - Close/Resolve transitions typically require a `resolution` field. Prompt interactively; don't default.
- **VALIDATE**:
  ```bash
  grep -E 'jira_get_transitions|jira_transition_issue' .claude/skills/jira/references/transition-pattern.md | wc -l
  # Expected: ≥2.
  ```

### Task 2.6 — CREATE `.claude/skills/jira/SKILL.md`

THIS IS THE CORE FILE. Target ≤500 lines (docs recommend).

- **IMPLEMENT**: Sections in this order:

  **1. Frontmatter:**
  ```yaml
  ---
  name: jira
  description: Create, edit, search, comment, link, and transition Jira Cloud Epics, Tasks, and Bugs via mcp-atlassian. Use when the user mentions Jira, a PROJ-XXX issue key, or asks to create/update/search/comment/transition tasks, epics, or bugs. Supports bulk creation under a parent Epic.
  when_to_use: |
    Triggered by phrases in Polish or English like "stwórz task", "create epic", "edytuj bug", "dodaj komentarz", "pokaż moje bugi", "zmień status", "transition", "zablokuj przez", "powiąż z", or any reference to a Jira issue key (regex [A-Z]+-\d+). Also via explicit /jira invocation with optional subcommand as first argument: /jira bulk, /jira search, /jira transition, /jira comment, /jira link, /jira create, /jira update. Handles Epic/Task/Bug only — no sub-tasks.
  argument-hint: "[subcommand] [args...]"
  allowed-tools: mcp__atlassian__jira_get_issue mcp__atlassian__jira_search mcp__atlassian__jira_create_issue mcp__atlassian__jira_update_issue mcp__atlassian__jira_add_comment mcp__atlassian__jira_transition_issue mcp__atlassian__jira_get_transitions mcp__atlassian__jira_create_issue_link mcp__atlassian__jira_get_link_types mcp__atlassian__jira_get_all_projects mcp__atlassian__jira_batch_create_issues
  ---
  ```
  (Check: combined `description + when_to_use` < 1,536 chars. Above draft ≈ 700 chars — ample headroom.)

  **2. HARD-GATE invariants** — the three spec invariants as a <HARD-GATE> block at the very top of the body. One block, three bullets:
  - Dry-run first (for every mutating op).
  - No default creation (all required params explicit or from `JIRA_DEFAULT_*`).
  - No sub-tasks (never emit `issue_type: "Sub-task"`).

  **3. Env preflight** — inline shell via `` !`command` ``:
  ```
  Environment check (must run before any MCP call):
  - JIRA_URL: !`test -n "$JIRA_URL" && echo set || echo MISSING`
  - JIRA_USERNAME: !`test -n "$JIRA_USERNAME" && echo set || echo MISSING`
  - JIRA_API_TOKEN: !`test -n "$JIRA_API_TOKEN" && echo set || echo MISSING`
  - JIRA_DEFAULT_PROJECT: !`echo "${JIRA_DEFAULT_PROJECT:-UNSET}"`
  - JIRA_DEFAULT_COMPONENTS: !`echo "${JIRA_DEFAULT_COMPONENTS:-UNSET}"`
  - JIRA_DEFAULT_LABELS: !`echo "${JIRA_DEFAULT_LABELS:-UNSET}"`
  ```
  If any MCP-side variable is MISSING → hard stop, instruct user to fill `.mcp.json` and restart Claude Code.

  **4. Subcommand dispatch** — inspect `$0` (first word of `$ARGUMENTS`):
  | `$0` | Action | Detailed pattern |
  |---|---|---|
  | *(empty)* | Interactive assistant — ask what to do | inline |
  | `create` | Single-issue create | inline + field-matrix.md |
  | `update` | Single-issue edit | inline + field-matrix.md |
  | `bulk` | Bulk create under parent | → `references/bulk-pattern.md` |
  | `search` | JQL search | inline + jql-cookbook.md |
  | `comment` | Add comment | inline |
  | `link` | Create issue link | inline |
  | `transition` | Status change | → `references/transition-pattern.md` |
  | *anything else* | Treat as natural language and infer intent | inline |
  Natural-language auto-trigger (no `/jira` prefix): reuses the same dispatch after inferring the verb from the prompt.

  **5. Field conventions** (one-paragraph primer) — components = comma-separated string; parent = via `additional_fields` JSON string `{"parent": "KEY"}`; description = markdown (auto-converted to ADF). Link to `references/field-matrix.md` for full matrix.

  **6. Description templates** — link to `references/description-templates.md`.

  **7. Common flows** (concise — ≤10 lines each):
  - **Create Epic/Task/Bug** — gather fields (ask if missing), dry-run table, confirm, `jira_create_issue`.
  - **Update** — `jira_get_issue` for current values, show diff (old → new) as table, confirm, `jira_update_issue`.
  - **Search** — if `$1` matches a cookbook snippet id, resolve. If ambiguous natural language, show interpreted JQL and ask. Then `jira_search(jql=..., fields="summary,status,assignee,priority,parent", limit=50)`. Render table. If `total > 50`, offer paginate/narrow.
  - **Comment** — dry-run (show comment text), confirm, `jira_add_comment`.
  - **Link** — `jira_get_link_types` first (cached in-session), confirm link type and direction, `jira_create_issue_link`.
  - **Bulk** — delegate to `references/bulk-pattern.md`.
  - **Transition** — delegate to `references/transition-pattern.md`.

  **8. Error handling** (short):
  - 4xx/5xx → show raw error, no auto-retry, no swallowing.
  - 400 about missing required custom field → show error, ask user for value, offer to capture pattern to `.agents/memory/domain/jira.md`.
  - Missing required user input → stop and ask (hard invariant #2).

- **PATTERN**: Follow [brainstorm.md](../../../.claude/commands/brainstorm.md) tone — numbered process steps, HARD-GATE callouts, "wait for user" checkpoints.
- **IMPORTS**: Frontmatter `allowed-tools` declares all MCP tools the skill may call.
- **GOTCHA**:
  - Inline `!` ``…`` ``  shell checks run every skill invocation — keep each as a single cheap `test`.
  - Trigger phrases in `description`/`when_to_use` must cover Polish and English — developer writes Polish per CLAUDE.md, but pasted content is English.
  - Skill body stays in conversation across the session (docs: "Skill content lifecycle"). Write invariants as standing rules, not one-time steps.
  - Keep description + when_to_use combined under 1,536 chars — longer text gets truncated in the skill listing and can strip trigger keywords.
- **VALIDATE**:
  ```bash
  head -20 .claude/skills/jira/SKILL.md | grep -E '^name: jira$' && wc -l .claude/skills/jira/SKILL.md
  # Expected: "name: jira" found in frontmatter; total lines ≤ 500.
  awk '/^---$/{c++;next} c==1' .claude/skills/jira/SKILL.md | head -40
  # Expected: frontmatter printed cleanly — name, description, when_to_use, argument-hint, allowed-tools visible.
  ```

### Task 3.1 — UPDATE `CLAUDE.md`

- **IMPLEMENT**: Add ONE row to the "On-Demand Context" table at the bottom of CLAUDE.md:
  ```markdown
  | Jira integration | [.claude/skills/jira/SKILL.md](.claude/skills/jira/SKILL.md) · [.agents/reference/jira-mcp-atlassian.md](.agents/reference/jira-mcp-atlassian.md) |
  ```
  Insert between existing rows alphabetically.
- **PATTERN**: Match existing row style in On-Demand Context table.
- **IMPORTS**: N/A
- **GOTCHA**:
  - Do NOT duplicate domain instructions in CLAUDE.md. Only the pointer.
  - Do NOT add Jira-specific language rules — inherited from Language Rules table.
- **VALIDATE**:
  ```bash
  grep -E 'Jira integration' CLAUDE.md
  # Expected: one match.
  ```

### Phase 4 tasks — manual validation only

Tracked in VALIDATION COMMANDS → Level 3.

---

## TESTING STRATEGY

Very small starter-kit: no test framework, no CI, no compiled artifacts. Automated tests **not warranted**.

**Manual validation** (see Level 3 below): minimum smoke-test = one JSON parse pass on all new JSON files, one real Task created end-to-end in a non-prod Jira Cloud project, one search, one transition. This verifies auth, MCP server, markdown-to-ADF conversion, the dry-run invariant, and the subcommand dispatch.

---

## VALIDATION COMMANDS

Execute all applicable. Any failure stops progression.

### Level 1: Syntax & Style

```bash
# JSON files — must all parse
jq '.' .mcp.json > /dev/null
jq '.' .mcp.json.example > /dev/null
jq '.' .claude/settings.local.json > /dev/null
jq '.' .claude/settings.json > /dev/null

# YAML frontmatter of SKILL.md — extract and inspect
awk '/^---$/{c++;next} c==1' .claude/skills/jira/SKILL.md | head -40
# Expected: name: jira, description:, when_to_use:, argument-hint:, allowed-tools: present.

# Gitignore correctness
git check-ignore .mcp.json .claude/settings.local.json
# Expected: both paths echoed.
git check-ignore .mcp.json.example || echo "tracked (correct)"
# Expected: "tracked (correct)".

# Reference files non-empty
for f in .agents/reference/jira-mcp-atlassian.md \
         .claude/skills/jira/references/field-matrix.md \
         .claude/skills/jira/references/description-templates.md \
         .claude/skills/jira/references/jql-cookbook.md \
         .claude/skills/jira/references/bulk-pattern.md \
         .claude/skills/jira/references/transition-pattern.md; do
  test -s "$f" && echo "OK: $f" || echo "EMPTY: $f"
done
# Expected: all OK.
```

### Level 2: Tests

N/A — no test framework.

### Level 3: Manual Validation

**Prerequisites** (user, one-time):
1. Install uv: `curl -LsSf https://astral.sh/uv/install.sh | sh`. Verify: `uvx --version`.
2. Create Atlassian API token: `https://id.atlassian.com/manage-profile/security/api-tokens`.
3. Fill real values in `.mcp.json` (JIRA_URL, JIRA_USERNAME, JIRA_API_TOKEN) and `.claude/settings.local.json` (JIRA_DEFAULT_PROJECT at minimum).
4. Restart Claude Code (required for `.mcp.json` to load and the new skill directory to be watched).

**Smoke test** (user, one run):
1. Type `/` — autocomplete shows `/jira` with its description. No other new entries.
2. Type `/mcp` — `atlassian` server appears, status "connected".
3. Type natural Polish: `"Pokaż moje otwarte bugi w domyślnym projekcie"`. Expected: skill auto-triggers, shows interpreted JQL, confirms, calls `jira_search`, renders result table.
4. Type `/jira bulk PROJ-XXX 2 test-refaktor` (real test Epic key). Expected: dry-run table with 2 issues appears; answer `n` — NO issues created in Jira. Repeat, answer `y` — issues created, keys reported.
5. Verify in Jira web UI that the two tasks exist under the Epic. Delete them.
6. Type `/jira transition PROJ-XXX "In Progress"` on a test issue. Expected: current status shown, confirm prompt, on `y` transitions; Jira UI reflects change.
7. Type natural Polish: `"Dodaj komentarz do PROJ-XXX: test z Claude"`. Expected: dry-run shows comment body, on `y` calls `jira_add_comment`. Verify in Jira UI.
8. Type `/jira` alone (no args). Expected: skill asks what you want to do (create / update / search / etc.).

---

## ACCEPTANCE CRITERIA

- [ ] All tasks 1.1–1.7, 2.1–2.6, 3.1 completed in order.
- [ ] All Level 1 validation commands pass with zero errors.
- [ ] `.mcp.json` gitignored; `.mcp.json.example` tracked.
- [ ] `.claude/settings.local.json` gitignored.
- [ ] Exactly one new slash-command entry appears in autocomplete: `/jira`. No other Jira-related entries.
- [ ] `description + when_to_use` combined under 1,536 chars (Claude Code description cap).
- [ ] MCP `atlassian` server connects after Claude Code restart.
- [ ] Natural-language Polish phrases auto-trigger the skill.
- [ ] `/jira bulk` produces a dry-run table before any create call (verified by answering `n`).
- [ ] One Task created end-to-end in real Jira Cloud, visible in web UI, markdown description correctly rendered (ADF conversion works).
- [ ] `CLAUDE.md` has the pointer; no domain instructions duplicated there.

---

## COMPLETION CHECKLIST

- [ ] All tasks completed in order
- [ ] Each task's VALIDATE block passed
- [ ] Level 1 validation passes
- [ ] Level 3 manual validation passes (smoke-test items 1–8)
- [ ] `.agents/memory/domain/jira.md` stub exists, empty of speculation
- [ ] Plan moved from `.agents/plans/active/` to `.agents/plans/done/` by `/execute` after completion (not done here)

---

## NOTES

### Deviations from the spec (intentional, surfaced for review)

**1. Single skill instead of "SKILL.md + three commands"** (spec decisions #5, #7 revised):

Spec proposed `/jira:bulk`, `/jira:search`, `/jira:transition` via `.claude/commands/jira/` subfolder namespacing. Web research confirmed:
- Subdirectory namespacing does NOT produce `/namespace:command` ([issue #2422](https://github.com/anthropics/claude-code/issues/2422) closed as not planned).
- Custom commands have been merged into skills; both live in the same `/<name>` namespace.

Flat fallback (`/jira-bulk` etc.) was initially considered but rejected by the user: it would clutter the `/` autocomplete menu alongside existing flat commands (`/commit`, `/push`, `/brainstorm`) with multiple Jira entries. Plan consolidates everything into **one skill `/jira`**. Subcommand dispatch happens inside the skill body via first `$ARGUMENTS` word (`bulk`, `search`, `transition`, `comment`, `link`, `create`, `update`). Natural-language auto-trigger (no slash prefix) covers the rest. Zero change to functional scope.

**2. Bulk via `jira_batch_create_issues`** (spec described a sequential loop):

Spec described a sequential loop over `jira_create_issue` with progress reporting every N issues. Research confirmed `mcp-atlassian` exposes `jira_batch_create_issues(issues, validate_only)`. Plan uses the batch tool: `validate_only: true` is the dry-run phase (server-side shape validation), then `validate_only: false` executes. Same user-facing invariants; more robust error surface. Caveat: `issues` is a **JSON string** — serialize, don't pass a list literal.

**3. Parent via `additional_fields`** (spec wrote `parent_key` as a flat parameter):

Actual mcp-atlassian schema routes parent/epic-link through `additional_fields` as a JSON **string**: `{"parent": "EPIC-KEY"}` (modern Cloud) or `{"epic_link": "EPIC-KEY"}` (legacy). Plan uses `parent` first, falls back to `epic_link` only on "parent field not available" error. Naming detail; no scope change.

### Open questions that should NOT block implementation

- **Exact shape of `additional_fields` for `parent`**: docs show both `{"parent": "EPIC-KEY"}` (flat string) and `{"parent": {"key": "EPIC-KEY"}}` (nested object) in different places. Executing agent tries flat first, falls back to nested on error, records the working variant to `.agents/memory/domain/jira.md` on first use.
- **Legacy "Epic Name" custom field requirement**: Unknown without a concrete test project. `field-matrix.md` flags this as a possible 400; on first hit, capture the customfield id to memory.

### Design decisions NOT relitigated

All spec decisions are preserved in intent (Cloud target, project-level placement, dry-run invariant, env-only config, `.mcp.json` gitignored, no sub-tasks, no default creation). This plan refines the *how* — never the *what*.

### Confidence score: **7.5/10** for one-pass implementation success

- High confidence: file layout, env split, gitignore logic, skill frontmatter, reference doc structure (~9/10).
- Medium confidence: exact `additional_fields` shape for parent (flat vs nested) (~6/10 — one error-and-retry round likely on first real create).
- Medium confidence: ADF conversion edge cases for complex description content (~7/10 — conservative markdown in templates mitigates).
- The Level 3 smoke test is the final arbiter. A 10-minute fix-and-retry cycle is expected on first real write.

Slight upgrade from the prior version (7/10 → 7.5/10): collapsing to one skill removes three whole SKILL.md files worth of consistency risk, and removes a subtle coordination failure mode where the secondary skills and the primary skill could drift on the dry-run rule. One file, one invariant definition.

Not within confidence scope: whether the user has a Jira Cloud test project and the patience to run the smoke. That is setup, not execution.
