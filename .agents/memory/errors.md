---
created: 2026-08-31
pinned: false
---

# Memory: Errors & Lessons

Non-obvious defects in **the application itself** — runtime, template or production-build behaviour of shipped code — with root cause and the rule that prevents a repeat.

Add newest entries at the **END** of the file.

---

## Scope — what belongs here, and what does not

This file is **application code only**. It is loaded whole when debugging, so every entry that is not about the shipped application costs context on every future investigation.

**Write here only if all three hold:**

1. The defect was in application source code that ships to users, or in the production build of it — and the entry **names that file or symbol**.
2. A fresh Claude reading the code would get it **wrong** without the note. Root cause is non-obvious: a framework contract, an ordering rule, an encoding trap, a silent fallback.
3. It is not already recorded here or in the matching `domain/*.md`.

**Route elsewhere — these are NOT errors.md material:**

| What broke | Goes to |
| --- | --- |
| A slash command, hook, subagent, MCP server, `.claude/` or `.agents/` file | [domain/harness.md](domain/harness.md) |
| Shell / git / `rg` / a CLI invocation; a debugging tool that lied | [domain/harness.md](domain/harness.md) |
| Misreading a design file, a ticket, or a review comment | [domain/harness.md](domain/harness.md) |
| A spec, test-runner, Storybook, Playwright or jsdom trap | [domain/testing.md](domain/testing.md) (create on first need) |
| Anything scoped to one module | that module's `domain/*.md` |

**Never write:** a routine fix, a typo, something visible by reading the code or `git log`, "the feature works now", or a lesson with no actionable rule. **The default outcome of a reflection pass is to write nothing.**

---

## Format

```
## YYYY-MM-DD — Short title

**What failed:** {symptom observed}
**Root cause:** {why it happened}
**Fix:** {what was changed — cite the source path}
**Rule:** {generalized lesson — how to avoid this next time}
```

---

<!-- No entries yet. First application-code lesson goes here (newest at the END). -->
