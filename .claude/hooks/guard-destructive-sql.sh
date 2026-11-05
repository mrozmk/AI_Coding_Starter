#!/bin/bash
# PreToolUse(Bash) guard: SQL a command would run is classified by lib/guard_destructive_sql.py —
# DROP/TRUNCATE of a table/database/schema is denied, any other write asks.
# Covered: sqlcmd -Q/-i/--input-file/< file/cat file |/here-doc, scripts run by bash/sh/zsh/source/
# ./x.sh, and the same forms nested in bash -c / tmux. Not covered: SQL built at run time, eval.
# Fail-closed: if python3 is missing or the classifier crashes on a command that mentions sqlcmd or
# a .sql file, the run asks instead of slipping through.

payload="$(cat)"
out="$(printf '%s' "$payload" | python3 -I "$(dirname "$0")/lib/guard_destructive_sql.py" 2>/dev/null)"
rc=$?
if [ "$rc" -eq 2 ]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Destructive-SQL guard could not read the hook payload — Operator must approve (fail-closed)."}}'
  exit 0
fi
if [ "$rc" -ne 0 ] && printf '%s' "$payload" | grep -qiE 'sqlcmd|\.sql\b'; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Destructive-SQL guard failed to run (rc '"$rc"') on a command that mentions sqlcmd/.sql — Operator must approve (fail-closed)."}}'
  exit 0
fi
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
