#!/usr/bin/env bash
# Opt-in producer of rate-limits.json for the Herdr kit's limits panel.
# Usage, as (or from) a Claude Code status line command — the status line JSON comes on stdin:
#   rate-limits.sh                    write the file, print nothing
#   rate-limits.sh <cmd> [args...]    write the file, then pass the same stdin to <cmd> and exit with its status
# Writes {at: <now>} + .rate_limits (five_hour / seven_day) to
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/rate-limits.json, atomically. The kit installer does not copy
# this script and nothing wires it in: hook it up yourself (README.md → Limits).
# Never breaks a status line: no rate_limits, bad JSON, no jq or no config folder → nothing written,
# and the script itself never prints (stdout is the status line).
set -u

input="$(cat)"
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

if command -v jq >/dev/null 2>&1 && [ -d "$dir" ]; then
  out="$(printf '%s' "$input" | jq -c '(.rate_limits | select(type == "object" and (has("five_hour") or has("seven_day")))) as $r | {at: (now | floor)} + $r' 2>/dev/null)"
  if [ -n "$out" ]; then
    tmp="$(mktemp "$dir/.rate-limits.XXXXXX" 2>/dev/null)" || tmp=""
    if [ -n "$tmp" ]; then
      { printf '%s\n' "$out" > "$tmp" && mv -f "$tmp" "$dir/rate-limits.json"; } 2>/dev/null || rm -f "$tmp"
    fi
  fi
fi

if [ $# -gt 0 ]; then
  printf '%s' "$input" | "$@"
  exit $?
fi
exit 0
