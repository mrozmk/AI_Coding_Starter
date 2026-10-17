---
description: Open the live harness dashboard (teams, this session's sub-agents, Codex runs) in the default browser — starts it in tmux when needed
argument-hint: "[stop]"
allowed-tools: Bash(bash .claude/dashboard/dashboard.sh:*)
---

# /dashboard — live harness view in the browser

Arguments: **$ARGUMENTS** — empty (open) or `stop`. Run it in the **main checkout**, from the
Claude window whose session the page should show. What the page reads and its states:
`.agents/reference/team-pipeline.md` §10.

## Steps

1. Run exactly one call: `bash .claude/dashboard/dashboard.sh` (empty argument) or
   `bash .claude/dashboard/dashboard.sh stop`. Any other argument → say the command takes only
   `stop` and run nothing.
2. Report its output in Polish, in one or two lines: the URL, the pinned session, whether it was
   started, reused or restarted, and `/dashboard stop` to end it. A non-zero exit → print its error
   lines verbatim and stop.

## Guardrails

- The script is the whole command: it starts `serve.sh` in the detached tmux session `dashboard`
  (it survives this Claude session), waits until the page answers and opens it with `open`. Never
  run `serve.sh` or `server.py` directly, and never probe the page with `curl` — egress is guarded.
- Read-only: the page shows commands to answer a team, it never acts. Do not answer anything a
  team shows on the page unless the user asks in this conversation.
