# Memory: Decisions

Architectural and technical decisions with rationale.

Add newest entries at the **TOP**.

---

## Format

```
## YYYY-MM-DD — Title

**Decision:** what was decided
**Why:** reasoning
**Alternatives considered:** what was rejected and why
**Impact:** where this shows up in the code
```

---

## 2026-04-21 — Jira skill: one consolidated skill, not multiple entries

**Decision:** ship the Jira integration as a single `.claude/skills/jira/SKILL.md` that dispatches on subcommand (first `$ARGUMENTS` word) or natural-language intent — NOT as "one primary skill + several companion skills/commands".

**Why:** in Claude Code every skill and every custom command both register as top-level `/name` slash commands. Subdirectory namespacing like `/jira:bulk` does not work ([claude-code issue #2422](https://github.com/anthropics/claude-code/issues/2422), closed as not planned). Flat fallback (`/jira-bulk`, `/jira-search`, `/jira-transition`) would add three entries alongside existing flat commands (`/commit`, `/push`, `/brainstorm`) and clutter the `/` autocomplete. User explicitly rejected the clutter.

**Alternatives considered:**
- Four skills with flat names `/jira`, `/jira-bulk`, `/jira-search`, `/jira-transition` — rejected: clutter.
- Primary skill + secondary skills with `user-invocable: false` — rejected: loses the "explicit destructive entry" benefit.
- Subdirectory namespacing `/jira:bulk` — technically impossible per the linked issue.

**Impact:**
- `.claude/skills/jira/SKILL.md` holds the single entry point; its body routes to flows via subcommand dispatch.
- Detailed flow logic lives in `.claude/skills/jira/references/` (bulk-pattern, transition-pattern, field-matrix, description-templates, jql-cookbook), loaded on-demand.
- Any future Claude-side feature that tempts "split into companion skills" should first evaluate subcommand routing.
