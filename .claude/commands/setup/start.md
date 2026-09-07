---
description: Guided bootstrap — interview, configure day-one files, prune unused command groups (wrapper for the harness plugin skill)
argument-hint: "[--rerun]"
---

# /setup:start → harness:setup-start

Invoke the Skill tool with skill `harness:setup-start` and args `$ARGUMENTS` verbatim, then follow that skill. Do nothing else first — no context loading, no work of your own.

If the Skill tool reports the skill unknown, the `harness` plugin is not enabled in this project. Say so and stop; do not fall back to an improvised version. To enable it here: `claude plugin install harness@ai-coding-starter --scope project` (after `claude plugin marketplace add mrozmk/AI_Coding_Starter`), or start the session with `claude --plugin-dir packages/claude` for development.
