---
status: populated
description: Harness & workflow lessons — the AI toolchain itself (.claude/ commands, hooks, subagents, MCP), shell/git/CLI traps, and requirement-reading failures (design file, ticket, review comment). NOT application code — that stays in errors.md.
created: 2026-08-31
pinned: false
---

# Memory: Harness & Workflow

Domain file — load per [index.md](../index.md) `When to Read`. Add newest entries at the **END**; format `## YYYY-MM-DD — <title>` ending in a **Rule:** line.

**Scope.** A lesson belongs here when the thing that broke was *not the product*: a slash command, a hook, a subagent contract, an MCP server, a shell/git/CLI invocation, a debugging tool that lied, or the way a requirement (design file, ticket, review comment) was read. Application runtime and build defects belong in [errors.md](../errors.md); test-harness traps belong in [testing.md](testing.md) (create on first need).

**Prefer a fix over an entry.** If the defect is in `.claude/` and you can repair it, repair it — an entry is for what cannot be fixed (shell semantics, vendor tool behaviour) or for a trap that will recur despite the fix.

---

## 2026-09-06 — Live smoke evidence is bound to source bytes: batch fixes, then run once

**What failed:** eight ~60-minute installed-host runs in two days; every fix to a fixture, an assertion or a doc changed `source_digest` and invalidated the previous evidence, so each fix cost another full run. Run 7 additionally died after the hour on an archive-slot collision that a pre-run check would have caught in a second.
**Root cause:** running `smoke-harness.mjs --live` after every single correction instead of collecting corrections offline first; archiving evidence at the end of the run.
**Fix:** `scripts/lib/smoke-live.mjs` archives previous evidence *before* the first model call into the first free numbered slot; evidence from a failed run is still written.
**Rule:** after a red live run, read every receipt, fix everything offline, run the full offline gate, and only then spend one live run. Never launch a live run to check a single assertion.
