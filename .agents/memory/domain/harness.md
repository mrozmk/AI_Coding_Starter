---
status: empty
description: Harness & workflow lessons — the AI toolchain itself (.claude/ commands, hooks, subagents, MCP), shell/git/CLI traps, and requirement-reading failures (design file, ticket, review comment). NOT application code — that stays in errors.md.
created: 2026-08-31
pinned: false
---

# Memory: Harness & Workflow

Domain file — load per [index.md](../index.md) `When to Read`. Add newest entries at the **END**; format `## YYYY-MM-DD — <title>` ending in a **Rule:** line.

**Scope.** A lesson belongs here when the thing that broke was *not the product*: a slash command, a hook, a subagent contract, an MCP server, a shell/git/CLI invocation, a debugging tool that lied, or the way a requirement (design file, ticket, review comment) was read. Application runtime and build defects belong in [errors.md](../errors.md); test-harness traps belong in [testing.md](testing.md) (create on first need).

**Prefer a fix over an entry.** If the defect is in `.claude/` and you can repair it, repair it — an entry is for what cannot be fixed (shell semantics, vendor tool behaviour) or for a trap that will recur despite the fix.

---

<!-- No entries yet. Flip `status: empty` to `status: populated` with the first one. -->
