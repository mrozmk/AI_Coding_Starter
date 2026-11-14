#!/usr/bin/env bash
# Keep team questions compatible with the supervisor's single-question answer tools.
set -euo pipefail
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ROOT/.agents/team/session.json" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
PAYLOAD=$(cat)
# The per-run TeamLead has AskUserQuestion disallowed; the single-question rule is for stages.
SID=$(jq -r '.session_id // ""' <<< "$PAYLOAD" 2>/dev/null || true)
LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd || true)"
(cd "$ROOT" && . "$LIB/team-lib.sh" && team_lead_caller "$SID") 2>/dev/null && exit 0
if jq -e '.tool_input.questions | arrays | length > 1' <<< "$PAYLOAD" >/dev/null 2>&1; then
  printf '%s\n' 'Team mode: ask one question per AskUserQuestion call.' \
    'Ask the next question only after receiving the answer; retry with one question.' >&2
  exit 2
fi
exit 0
