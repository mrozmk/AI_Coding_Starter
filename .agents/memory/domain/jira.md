---
status: seeded
description: Jira Cloud integration quirks discovered at runtime — placeholder until first real use
created: 2026-08-31
pinned: false
---

# Memory: jira

Jira Cloud integration via mcp-atlassian MCP server.

**Source:** `.claude/skills/jira/`

---

## Key Logic
- {to be filled on first real use — e.g. which `additional_fields` parent shape works in this instance}
- Sequential single `jira_create_issue` is the reliable creation path: batch create has failed with an empty transport error ("Command failed with no output") even at 4 issues, creating nothing — never retry the batch; create one by one (seeded from a previous engagement).

## External Contracts
- {field / endpoint / config key} — {what it represents here}
- Link kwargs: `jira_create_issue_link(link_type, inward_issue_key, outward_issue_key)` — for Blocks, inward = the blocker, outward = the blocked issue (verify after the first link).
- Component names are case-sensitive; a mismatch is a 4xx — read the project's components first.
- Transition ids are workflow-scoped: resolve them with `jira_get_transitions` per issue type, once per session.

## Known Edge Cases
- {scenario} → {behavior}
- `jira_update_issue` with only `fields` silently resets `components` (labels likely too) → re-assert the issue's current components on every update call.

## Related Decisions
- See [../decisions.md](../decisions.md) entry: {date} — {title}
