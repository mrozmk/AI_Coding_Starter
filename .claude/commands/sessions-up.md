---
description: After a machine restart — start every missing role session (Supervisor, TeamLead, Advisor) fresh, the team-watch loops, the Reviewer check, monitoring start all; report incl. interrupted team runs
allowed-tools: Bash(bash .claude/lib/supervisor-sessions.sh:*), Bash(bash .claude/lib/costs/runtime-mark.sh:*)
---

# /sessions-up — bring the role sessions back

Runs from any session in the main checkout (also a plain one). Every role starts as a separate,
fresh tmux session launched with the prompt `/session-role <role>`, so it bootstraps itself;
this session types nothing into them. Runbook:
`.agents/reference/supervisor-sessions.md#morning--after-a-restart`.

## Steps

1. `bash .claude/lib/supervisor-sessions.sh up` (a normal run takes under a minute; use
   `run_in_background: true` only if it exceeds 2 minutes).
2. Relay its report in the developer's language: each role (`started` / `restarted (dead pane)` /
   `already running` / `running (here)`), the team-watch line, the `Reviewer:` line, interrupted
   team runs with their `/start-team <team>`, the `monitoring` readiness lines and the
   `tmux attach -t …` lines.
3. Last line: "Close this bootstrap session — the roles run in their own windows."

## Guardrails

- Never resume a team run — interrupted runs are only listed; `/start-team <team>` is the
  Operator's.
- Never `claude --resume` a role and never give this session a role.
- A `refused:` / `error:` line is relayed verbatim, never worked around.

## Stage end marker (token usage)

When this command finishes — after its final report, and on any path that ends it early — run
exactly this once, as its own Bash call from the repo root, with nothing chained before or after it:

`bash .claude/lib/costs/runtime-mark.sh stage end sessions-up`
