---
description: Create an implementation plan from an approved spec, then grill it (wrapper for the harness plugin skill)
argument-hint: "[path-to-spec | optional — defaults to newest file in .agents/specs/]"
---

# /plan-feature → harness:plan-feature

Invoke the Skill tool with skill `harness:plan-feature` and args `$ARGUMENTS` verbatim, then follow that skill. Do nothing else first — no context loading, no work of your own.

If the Skill tool reports the skill unknown, the `harness` plugin is not enabled in this project. Say so and stop; do not fall back to an improvised version. To enable it here: `claude plugin install harness@ai-coding-starter --scope project` (after `claude plugin marketplace add mrozmk/AI_Coding_Starter`), or start the session with `claude --plugin-dir packages/claude` for development.
