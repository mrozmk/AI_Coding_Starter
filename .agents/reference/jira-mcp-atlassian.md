# Reference: `mcp-atlassian` for Jira Cloud

Distilled reference used by the `jira` skill. Authoritative, project-local summary — consult this first; only fall back to upstream docs when something here is marked `TBD` or a behavior diverges at runtime.

---

## 1. Setup

### Prerequisites

- **`uv` / `uvx`** (Astral) — runtime for the MCP server.
  - macOS install: `curl -LsSf https://astral.sh/uv/install.sh | sh`
  - Binaries land at `~/.local/bin/uv` and `~/.local/bin/uvx`.
  - Verify: `uvx --version`
- **Atlassian API token** (Jira Cloud):
  - Obtain at `https://id.atlassian.com/manage-profile/security/api-tokens`.
  - Token begins with `ATATT3xFfGF...` (legacy) or `atatt_...` (newer).

### Configuration files

Two files, separate concerns:

| File | Gitignored? | Content | Read by |
|---|---|---|---|
| `.mcp.json` | yes | Inline MCP-server env: `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN` | MCP server process |
| `.claude/settings.local.json` | yes | Skill defaults env: `JIRA_DEFAULT_PROJECT`, `JIRA_DEFAULT_COMPONENTS`, `JIRA_DEFAULT_LABELS` | Claude Code / skill |

Template for new clones: `.mcp.json.example` (committed, same shape with placeholder values). Copy to `.mcp.json` and fill real values.

### First run

Claude Code must be **restarted** after creating `.mcp.json` for the first time (MCP config is loaded at startup, not watched). After restart, `/mcp` shows the `atlassian` server as connected.

---

## 2. Auth matrix

| Deployment | Env variables | Notes |
|---|---|---|
| **Jira Cloud** (this project) | `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN` | `USERNAME` = Atlassian account email. Basic auth. |
| Jira Data Center / Server | `JIRA_URL`, `JIRA_PERSONAL_TOKEN` | PAT auth. Do NOT set `JIRA_USERNAME` or `JIRA_API_TOKEN` — those force Cloud mode and will fail. |

Switching deployments = swap the env set; no code change.

---

## 3. Markdown-to-ADF conversion

Jira Cloud REST API v3 requires **ADF (Atlassian Document Format)** — a JSON structure — for `description` and `comment` fields.

**`mcp-atlassian` performs this conversion server-side.** Callers (us) pass plain markdown in `description` and `comment`, and the server converts to ADF before sending to Jira.

**Safe markdown subset** (verified reliably converts):
- Headings `#`, `##`, `###`
- Bold `**text**`, italic `*text*`
- Fenced code blocks with language tag
- Inline code \`code\`
- Bullet lists (one level deep)
- Numbered lists (one level deep)
- Links `[text](url)`

**Risky** — may fail ADF conversion, test case-by-case:
- Nested tables
- Deeply nested lists (3+ levels)
- HTML-in-markdown (`<details>`, `<br>`, etc.)
- Task lists `- [ ]` / `- [x]`

**Do NOT use** Jira wiki markup (`h3.`, `{{code}}`, `*bold*` with Jira semantics). That's Server/DC syntax and will be treated as literal markdown in Cloud, rendering wrong.

---

## 4. Tool catalog

Focus on tools the `jira` skill uses. Parameter notation: `name: type [required|optional]`.

### Create / modify

**`jira_create_issue`**(`project_key: string [required]`, `summary: string [required]`, `issue_type: string [required]`, `assignee: string [optional]`, `description: string [optional — markdown]`, `components: string [optional — comma-separated]`, `additional_fields: string [optional — JSON string]`)

**`jira_update_issue`**(`issue_key: string [required]`, `fields: string [required — JSON string]`, `additional_fields: string [optional — JSON string]`, `components: string [optional]`, `attachments: string [optional]`)

**`jira_batch_create_issues`**(`issues: string [required — JSON string, array of create payloads]`, `validate_only: boolean [optional — default false]`)
- `validate_only: true` → server-side validation only, returns per-issue errors, NO issues created. This is our dry-run validator.
- `validate_only: false` → executes. Per-issue atomicity (partial success possible).

**`jira_delete_issue`**(`issue_key: string [required]`) — not used by the skill (out of scope).

### Read

**`jira_get_issue`**(`issue_key: string [required]`, `fields: string [optional — comma-separated]`, `expand: string [optional]`, `comment_limit: integer [optional]`, `properties: string [optional]`, `update_history: boolean [optional]`)

**`jira_search`**(`jql: string [required]`, `fields: string [optional — comma-separated]`, `limit: integer [optional — max 50 per page]`, `start_at: integer [optional — pagination]`)

**`jira_get_all_projects`**(`include_archived: boolean [optional]`)

**`jira_get_project_issues`**(`project_key: string [required]`, `limit: integer [optional]`, `start_at: integer [optional]`)

### Comments

**`jira_add_comment`**(`issue_key: string [required]`, `comment: string [required — markdown]`)

### Transitions (two-call pattern)

**`jira_get_transitions`**(`issue_key: string [required]`) — returns array of `{id, name, to: {name, id}, ...}`. The `id` is what `jira_transition_issue` needs.

**`jira_transition_issue`**(`issue_key: string [required]`, `transition_id: string [required]`, `fields: string [optional — JSON string for transition-required fields like resolution]`, `comment: string [optional]`)

### Links (two-call pattern)

**`jira_get_link_types`**() — returns array of link types, e.g. `{id, name: "Blocks", inward: "is blocked by", outward: "blocks"}`. Names vary per instance — cache in-session.

**`jira_create_issue_link`**(TBD — verify input schema at first use; expected something like `link_type: string`, `inward_issue: string`, `outward_issue: string`).

---

## 5. Parent / Epic link convention

**This is an mcp-atlassian wrapper concept, not a Jira REST concept.** Don't look for `additional_fields` in Atlassian docs — it's how `mcp-atlassian` lets you pass arbitrary issue fields that aren't first-class tool parameters.

Route the parent Epic through `additional_fields` as a **JSON string** (not a dict literal — literally a stringified JSON):

```
additional_fields = '{"parent": "PROJ-100"}'
```

**Fallback for legacy Cloud** (pre-2023 instances that still use the Epic-Link custom field):

```
additional_fields = '{"epic_link": "PROJ-100"}'
```

**Recommended sequence** on first create in a new instance:
1. Try `{"parent": "EPIC-KEY"}` first.
2. On 400 with message about `parent` field not available → retry with `{"epic_link": "EPIC-KEY"}`.
3. Record the working variant to `.agents/memory/domain/jira.md` so subsequent calls skip the probe.

**Shape ambiguity** — upstream docs show both `{"parent": "EPIC-KEY"}` (flat string) and `{"parent": {"key": "EPIC-KEY"}}` (nested object) in different places. Try flat first; fall back to nested on shape error. Record which worked.

---

## 6. Components convention

`components` is a **comma-separated string**, NOT an array:

- ✓ `components: "backend,api"`
- ✗ `components: ["backend", "api"]`
- ✗ `components: "backend, api"` (space after comma — some instances are strict)

Same convention applies to:
- `fields` parameter in `jira_search` and `jira_get_issue` — comma-separated field names.
- `JIRA_DEFAULT_COMPONENTS` and `JIRA_DEFAULT_LABELS` env values — comma-separated strings.

---

## 7. Transitions (detail)

Status names are NOT directly usable — every `jira_transition_issue` call needs a `transition_id`.

```
1. jira_get_transitions(issue_key="PROJ-123")
   → [{"id":"11","name":"Start Progress","to":{"name":"In Progress"}},
      {"id":"21","name":"Done","to":{"name":"Done"}}, ...]

2. Match the user's desired status to a transition's `name` or `to.name` (case-insensitive).

3. jira_transition_issue(issue_key="PROJ-123", transition_id="11")
```

Some transitions require fields (e.g. Close → `resolution`). The response from step 1 often flags them; if not, the transition call fails with a message naming the required field. Ask the user, retry with `fields='{"resolution": {"name": "Done"}}'`.

---

## 8. Known limitations

- **No transaction / rollback.** A failed create-during-batch leaves previously-created issues in Jira. Plan for partial success explicitly.
- **Rate limiting.** Jira Cloud throttles at ~100 requests/second per user. Not a concern for normal use; can bite during large bulk ops. `mcp-atlassian` surfaces 429 as an error — retry is the caller's responsibility (we do not retry automatically).
- **Custom fields not in `additional_fields`-form.** If a project has a mandatory custom field that isn't discoverable from tool schemas, the first create returns 400 with the field id (e.g. `customfield_10011`). Capture it to `.agents/memory/domain/jira.md` with the project key + field meaning.
- **Description/comment ADF conversion edge cases.** See section 3 — stick to the safe subset unless you've verified something works in this instance.

---

## 9. Authoritative sources

- [sooperset/mcp-atlassian — GitHub](https://github.com/sooperset/mcp-atlassian) — source of truth for tool names, env variables, install.
- [mcp-atlassian — Jira Issues tools reference](https://mcp-atlassian.soomiles.com/docs/tools/jira-issues) — parameter schemas (source for this file's tool catalog).
- [mcp-atlassian — tools reference index](https://mcp-atlassian.soomiles.com/docs/tools-reference) — full 72-tool catalog.
- [Jira Cloud REST API v3](https://developer.atlassian.com/cloud/jira/platform/rest/v3/intro/) — the REST API `mcp-atlassian` calls under the hood.
- [Jira Cloud REST v3 — Issues group](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/) — ADF requirement for description/comment.
- [Atlassian Community — Epic parent via REST API](https://community.atlassian.com/forums/Jira-questions/Create-an-Issue-with-Epic-as-parent-using-REST-API/qaq-p/1409874) — context on legacy Epic-Link vs modern `parent`.

---

*Update this file when first-use probes reveal the working variants of `additional_fields` shape, Epic-Link vs `parent`, or when a new Jira instance surfaces a mandatory custom field.*
