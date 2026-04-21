# Commit Message Validation

Validate the commit message in the command.

## Project Config

Check `${CLAUDE_PROJECT_ROOT}/.claude/git-conventions.local.md` for overrides:
- `commit_types` - custom type list
- `jira_projects` - Jira project keys for ticket references
- `ticket_required` - whether ticket reference is mandatory

## Default Rules

- **Format:** `type(scope): description` (scope optional)
- **Types:** `feat`, `fix`, `docs`, `test`, `chore`, `refactor`, `style`, `perf`, `ci`, `build`, `revert`
- **Description:** lowercase start, no period, imperative mood, under 72 chars
- **Ticket:** optional footer trailer only — `Refs: PROJ-123`

## Response

Return JSON only, no other text:

Valid:
```json
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}
```

Invalid:
```json
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "[reason]. Try: [corrected-message]"}}
```

## Special Cases

- `--amend` without new message: `ALLOW`
- Interactive mode (no `-m`): `ALLOW`
- Co-authored-by footers: valid, preserve them
