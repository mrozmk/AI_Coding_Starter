#!/bin/bash
# Shared audit-log appender with self-rotation.
#
# Registered as an async PostToolUse / PreToolUse hook for Bash / WebFetch / Write / Edit
# (see .claude/settings.json). One entry per tool call, timestamped, into
# $CLAUDE_PROJECT_DIR/.claude/audit.log. Self-rotates at 5000 lines (keeps last 2500) so the
# log can never grow unbounded — the race between concurrent async hooks is harmless because
# tail+mv is idempotent (worst case it runs twice with the same result).
#
# Arg $1 = label: BASH | FETCH | WRITE | EDIT  (decides which tool_input field to log).
# Reads the tool JSON on stdin. Always exits 0 — logging must never block a tool.

LABEL="$1"
[ -z "$CLAUDE_PROJECT_DIR" ] && exit 0
[ -d "$CLAUDE_PROJECT_DIR/.claude" ] || exit 0

PAYLOAD=$(cat)
L="$CLAUDE_PROJECT_DIR/.claude/audit.log"

case "$LABEL" in
  BASH)  V=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""'   2>/dev/null) ;;
  FETCH) V=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.url // ""'       2>/dev/null) ;;
  *)     V=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // ""' 2>/dev/null) ;;
esac

TS=$(date '+%Y-%m-%d %H:%M:%S')
printf '[%s] %-6s %s\n' "$TS" "$LABEL" "$V" >> "$L" 2>/dev/null

# Self-rotation: cap at 5000 lines, keep the most recent 2500.
[ -f "$L" ] && [ "$(wc -l < "$L" 2>/dev/null)" -gt 5000 ] \
  && tail -n 2500 "$L" > "$L.tmp" 2>/dev/null && mv "$L.tmp" "$L" 2>/dev/null

exit 0
