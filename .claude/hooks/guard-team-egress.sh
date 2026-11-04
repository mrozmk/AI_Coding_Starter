#!/bin/bash
# PreToolUse(WebFetch, Bash) guard, team mode only: auto mode would let the classifier approve
# egress, so an unlisted WebFetch host or an egress tool in command position asks
# (lib/guard_team_egress.py). Never allows. Fail-closed: no python3 / a crash asks.
# Contract: .agents/reference/security-egress.md, .agents/reference/team-mode.md

[ -f "${CLAUDE_PROJECT_DIR:-.}/.agents/team/session.json" ] || [ -n "${TT_TEAM:-}" ] || exit 0
payload="$(cat)"
out="$(printf '%s' "$payload" | python3 -I "$(dirname "$0")/lib/guard_team_egress.py" 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"team egress: guard failed to run (rc '"$rc"') — Operator must approve (fail-closed)."}}'
  exit 0
fi
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
