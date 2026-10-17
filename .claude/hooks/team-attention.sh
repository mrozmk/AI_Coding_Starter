#!/bin/bash
# Notification hook — flags a team role session that needs a human.
#
# Problem it solves: an unattended coder/qa session can stop on a permission prompt or
# sit idle; the runner only sees records. This hook appends one line per notification to
# .agents/team/runs/<run>/attention, which team-run.sh turns into "needs attention: attach".
#
# No-op outside team mode (no .agents/team/session.json). Must exit 0 always.

command -v jq >/dev/null 2>&1 || exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
SESSION="$ROOT/.agents/team/session.json"
[ -f "$SESSION" ] || exit 0

RUN=$(jq -r '.run // ""' "$SESSION" 2>/dev/null)
[ -z "$RUN" ] && exit 0

PAYLOAD=$(cat)
KIND=$(printf '%s' "$PAYLOAD" | jq -r '.notification_type // .hook_event_name // ""' 2>/dev/null)
MSG=$(printf '%s' "$PAYLOAD" | jq -r '.message // ""' 2>/dev/null | tr '\n' ' ')

mkdir -p "$ROOT/.agents/team/runs/$RUN" 2>/dev/null || exit 0
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $KIND $MSG" >> "$ROOT/.agents/team/runs/$RUN/attention" 2>/dev/null
exit 0
