# Project Memory — Index

**Read this file before starting any task.** For deep dives, read the relevant file below.

---

## Quick Reference

| Topic | File |
|-------|------|
| Bugs, failed approaches, lessons learned | [errors.md](errors.md) |
| Architectural & technical decisions | [decisions.md](decisions.md) |
| API behavior, protocol quirks, auth | [api.md](api.md) |
| Project-specific implementation patterns | [patterns.md](patterns.md) |
| Module-specific knowledge | `domain/{module}.md` (created ad-hoc) |

---

## When to Write

Add to memory when you discover something that:
- Wasn't obvious from reading the code
- A fresh Claude would likely get wrong without this note
- Cost you time to figure out (root cause, undocumented quirk, non-trivial decision)

Add newest entries at the **TOP** of each file.

Do NOT duplicate what's already in [CLAUDE.md](../../CLAUDE.md).

---

## Domain File Template

When creating a file in `domain/` for a specific module or subsystem:

```markdown
# Memory: {module_name}

{One-line summary of what this module does}

**Source:** `{path/to/module}`

---

## Key Logic
- {non-obvious rule 1}
- {non-obvious rule 2}

## External Contracts
- {field / endpoint / config key} — {what it represents here}

## Known Edge Cases
- {scenario} → {behavior}

## Related Decisions
- See [../decisions.md](../decisions.md) entry: {date} — {title}
```
