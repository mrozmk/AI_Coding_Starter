#!/bin/bash
# PostToolUse(Read) — records memory-file read usage into a gitignored sidecar.
#
# When a .agents/memory/*.md file is Read, bump its entry in
# $CLAUDE_PROJECT_DIR/.claude/memory-usage.json:
#   { "<relpath>": { "last_referenced": "YYYY-MM-DD", "ref_count": N } }
#
# Design note: usage is LOCAL telemetry — your read patterns differ from a teammate's,
# so it is gitignored and never committed (unlike the original which mutated each memory
# file's frontmatter, churning git on every read). It feeds /maintain:cleanup-workflow's
# dead-memory pruning (Phase 2) and auto-load freshness (Phase 4.1).
#
# Silent on non-memory paths and the archive. Must always exit 0 — runs async; a read
# must never be blocked or fail because of telemetry.

[ -z "$CLAUDE_PROJECT_DIR" ] && exit 0
[ -d "$CLAUDE_PROJECT_DIR/.claude" ] || exit 0

PAYLOAD=$(cat)
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$FILE" ] && exit 0

# Track only files under .agents/memory/, excluding the historical archive.
case "$FILE" in
  *.agents/memory/archive/*) exit 0 ;;
  *.agents/memory/*.md) ;;
  *) exit 0 ;;
esac

# Key = path relative to .agents/memory/ (e.g. "errors.md", "domain/foo.md").
KEY="${FILE##*.agents/memory/}"
TODAY=$(date +%Y-%m-%d)
DB="$CLAUDE_PROJECT_DIR/.claude/memory-usage.json"

[ -f "$DB" ] || echo '{}' > "$DB" 2>/dev/null

# Read-modify-write via temp + atomic mv. A rare lost increment under concurrent async
# fires is acceptable — this is a best-effort metric, same idempotency stance as the audit log.
jq --arg k "$KEY" --arg d "$TODAY" \
  '.[$k] = {"last_referenced": $d, "ref_count": ((.[$k].ref_count // 0) + 1)}' \
  "$DB" > "$DB.tmp" 2>/dev/null && mv "$DB.tmp" "$DB" 2>/dev/null

exit 0
