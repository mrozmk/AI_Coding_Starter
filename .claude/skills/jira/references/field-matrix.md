# Field Matrix: Epic / Task / Bug

Per-issue-type field table, mapped to `mcp-atlassian` tool parameters. Load this file when the primary skill needs to know *what* to ask for and *how* to pass it.

**Conventions throughout:**
- `additional_fields` is a **JSON string** (stringified JSON), not a dict literal. Always wrap in quotes when passing as a tool argument.
- `components` is a **comma-separated string**, not an array. No spaces after commas.
- `description` is **markdown**. `mcp-atlassian` converts to ADF for Jira Cloud.
- All issue-type names are **case-sensitive** in Jira Cloud (`Epic`, `Task`, `Bug` — not `epic`).

---

## Epic

| Field | Required? | MCP parameter | Notes |
|---|---|---|---|
| Project | required | `project_key` | e.g. `"PROJ"`. Fall back to `$JIRA_DEFAULT_PROJECT` if user omitted. |
| Summary | required | `summary` | Short title; no trailing period. |
| Issue type | required | `issue_type` | Literal `"Epic"`. |
| Description | optional | `description` | Markdown. Use Epic template from `description-templates.md`. |
| Labels | optional | `additional_fields='{"labels": ["l1","l2"]}'` | Array of strings inside JSON string. Or use `$JIRA_DEFAULT_LABELS` split on comma. |
| Components | optional | `components` | Comma-separated string. |
| Assignee | optional | `assignee` | Atlassian account email (Cloud). |
| Priority | optional | `additional_fields='{"priority": {"name": "High"}}'` | Name must match an existing priority in the project. |
| Due date | optional | `additional_fields='{"duedate": "2026-05-30"}'` | ISO `YYYY-MM-DD`. |
| Epic Name | **sometimes required** | `additional_fields='{"customfield_10011": "..."}'` | Older Cloud instances require this as a separate field. On first create 400 about "customfield_10011 is required", capture the id to `.agents/memory/domain/jira.md`. |

---

## Task

| Field | Required? | MCP parameter | Notes |
|---|---|---|---|
| Project | required | `project_key` | Same as Epic. |
| Summary | required | `summary` | Same as Epic. |
| Issue type | required | `issue_type` | Literal `"Task"`. |
| **Parent Epic** | **required by skill invariant** | `additional_fields='{"parent": "EPIC-KEY"}'` | Flat string first; fall back to `{"parent": {"key": "..."}}` nested on shape error; ultimate fallback `{"epic_link": "EPIC-KEY"}` for legacy Cloud. Record working variant to memory. |
| Description | optional | `description` | Markdown. Use Task template. |
| Labels | optional | `additional_fields='{"labels": ["l1","l2"]}'` | As Epic. |
| Components | optional | `components` | Comma-separated string. Validate against project components before submit; drop unknowns with a note. |
| Assignee | optional | `assignee` | As Epic. |
| Priority | optional | `additional_fields='{"priority": {"name": "High"}}'` | As Epic. |
| Due date | optional | `additional_fields='{"duedate": "2026-05-30"}'` | As Epic. |

---

## Bug

Identical to Task except `issue_type="Bug"`. Reproduces here for clarity of the dry-run flow:

| Field | Required? | MCP parameter | Notes |
|---|---|---|---|
| Project | required | `project_key` | Same as Task. |
| Summary | required | `summary` | Same as Task. |
| Issue type | required | `issue_type` | Literal `"Bug"`. |
| **Parent Epic** | **required by skill invariant** | `additional_fields='{"parent": "EPIC-KEY"}'` | Same as Task. |
| Description | optional | `description` | Markdown. Use Bug template (steps to reproduce / expected / actual / environment). |
| Labels | optional | `additional_fields='{"labels": ["l1","l2"]}'` | As Task. |
| Components | optional | `components` | As Task. |
| Assignee | optional | `assignee` | As Task. |
| Priority | optional | `additional_fields='{"priority": {"name": "High"}}'` | For bugs, default to asking the user — severity matters. |
| Due date | optional | `additional_fields='{"duedate": "2026-05-30"}'` | As Task. |

---

## Update (`jira_update_issue`)

Updating uses a different shape — `fields` is a **JSON string** of the full fields dict to change (not merging with `additional_fields`):

```
jira_update_issue(
    issue_key="PROJ-123",
    fields='{"summary": "New title", "priority": {"name": "High"}}',
    additional_fields='{"labels": ["urgent"]}',
    components="backend,api"
)
```

**Update conventions:**
- Only put fields you are changing. Don't re-send unchanged fields.
- Labels are typically **replaced wholesale**, not merged. If you want to add a label while keeping existing ones, first `jira_get_issue(fields="labels")`, merge, then update.
- Components work the same way — comma-separated, replaces existing.
- Status cannot be changed via `jira_update_issue` — use `jira_transition_issue` (see `transition-pattern.md`).
