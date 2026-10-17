#!/usr/bin/env bash
# Keep team questions compatible with the supervisor's single-question answer tools.
set -euo pipefail
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ROOT/.agents/team/session.json" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
PAYLOAD=$(cat)
if jq -e '.tool_input.questions | arrays | length > 1' <<< "$PAYLOAD" >/dev/null 2>&1; then
  printf '%s\n' 'Team mode: ask one question per AskUserQuestion call.' \
    'Ask the next question only after receiving the answer; retry with one question.' >&2
  exit 2
fi
exit 0
