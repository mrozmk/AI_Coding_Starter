# Branch Name Validation

Validate the branch name in the command.

## Project Config

Check `${CLAUDE_PROJECT_ROOT}/.claude/git-conventions.local.md` for overrides:
- `prefixes` - custom prefix list
- `jira_projects` - Jira project keys (e.g., PROJ, TEAM)
- `ticket_required` - whether ticket ID is mandatory

## Default Rules

- **Prefixes:** `feat/`, `fix/`, `hotfix/`, `docs/`, `test/`, `chore/`, `refactor/`
- **Format:** `{prefix}/{description}` or `{prefix}/{TICKET-ID}-{description}` or `{prefix}/{module}/{description}`
- **Case:** lowercase only, kebab-case (hyphens, no underscores)
- **Ticket:** optional unless `ticket_required: true`

## Response

Return JSON only, no other text:

Valid:
```json
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}
```

Invalid:
```json
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "[reason]. Try: [corrected-name]"}}
```
