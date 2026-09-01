#!/bin/bash
# PostToolUse(Read|Bash) — records memory-file read usage into a gitignored sidecar.
#
# When a .agents/memory/*.md file is consulted, bump its entry in
# $CLAUDE_PROJECT_DIR/.claude/memory-usage.json:
#   { "<relpath>": { "last_referenced": "YYYY-MM-DD", "ref_count": N } }
#
# Design note: usage is LOCAL telemetry — your read patterns differ from a teammate's,
# so it is gitignored and never committed (unlike the original which mutated each memory
# file's frontmatter, churning git on every read). It feeds /maintain:cleanup-workflow's
# dead-memory pruning (Phase 2) and auto-load freshness (Phase 4.1).
#
# TWO INPUT SHAPES: Read/Edit carry `.tool_input.file_path`; Bash reads (`cat`, `sed -n`, `rg`)
# carry `.tool_input.command` — matching only `Read` left the sidecar empty (Phase 2B never ran).
#
# Silent on non-memory paths and the archive. Must always exit 0 — runs async; a read
# must never be blocked or fail because of telemetry.

[ -z "$CLAUDE_PROJECT_DIR" ] && exit 0
[ -d "$CLAUDE_PROJECT_DIR/.claude" ] || exit 0

PAYLOAD=$(cat)

# Fork-free dismissal of the ~99% of tool calls that mention no memory path at all.
case "$PAYLOAD" in *'.agents/memory/'*) ;; *) exit 0 ;; esac

# --- Collect candidate paths ------------------------------------------------
# Read/Edit/Write shape: one explicit file_path. Bash shape: scrape the command.
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // ""' 2>/dev/null)

if [ -n "$FILE" ]; then
  CANDIDATES="$FILE"
else
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)
  [ -z "$CMD" ] && exit 0
  # Strip redirect / tee targets first: appending to a memory file is maintenance,
  # not consultation, and counting it would keep a never-read file looking alive.
  # `tee` drops its options and every operand up to the next pipe/separator.
  # (grep -oE extracts from a bounded string, not a file search — the bounded-field-probe
  # exemption cleanup-workflow.md Phase 4.2 grants; rg is also unavailable in hook scripts.)
  READS=$(printf '%s' "$CMD" | sed -E \
    's/>>?[[:space:]]*[^[:space:]]+//g; s/(^|[[:space:]]|\|)tee([[:space:]]+-[-a-zA-Z=]+)*([[:space:]]+[^[:space:]|;&]+)+//g')
  CANDIDATES=$(printf '%s' "$READS" \
    | grep -oE "[^[:space:]\"';|)&]*\.agents/memory/[^[:space:]\"';|)&]*\.md" 2>/dev/null \
    | sort -u)
fi

[ -z "$CANDIDATES" ] && exit 0

TODAY=$(date +%Y-%m-%d)
DB="$CLAUDE_PROJECT_DIR/.claude/memory-usage.json"

# Self-heal on missing OR unusable. Testing -f alone is not enough: a 0-byte or malformed
# sidecar (an interrupted write, a `touch`) makes every jq below fail, so the `&& mv` never
# fires and the file stays broken forever — telemetry dies silently while looking healthy,
# and /maintain:cleanup-workflow then prunes on age alone believing it has usage data.
{ [ -s "$DB" ] && jq -e . "$DB" >/dev/null 2>&1; } || echo '{}' > "$DB" 2>/dev/null

# --- Bump each distinct memory file ----------------------------------------
while IFS= read -r p; do
  [ -z "$p" ] && continue
  case "$p" in
    *.agents/memory/archive/*) continue ;;
    *.agents/memory/*.md) ;;
    *) continue ;;
  esac

  # Bash shape can carry an unexpanded glob (`wc -l .agents/memory/*.md`) — never a key.
  case "$p" in *'*'*|*'?'*|*'{'*) continue ;; esac
  ABS="$p"; [ "${ABS#/}" = "$ABS" ] && ABS="$CLAUDE_PROJECT_DIR/$p"
  [ -f "$ABS" ] || continue

  # Key = path relative to .agents/memory/ (e.g. "errors.md", "domain/foo.md").
  KEY="${p##*.agents/memory/}"

  # Read-modify-write via temp + atomic mv. A rare lost increment under concurrent async
  # fires is acceptable — best-effort metric, same idempotency stance as the audit log.
  jq --arg k "$KEY" --arg d "$TODAY" \
    '.[$k] = {"last_referenced": $d, "ref_count": ((.[$k].ref_count // 0) + 1)}' \
    "$DB" > "$DB.tmp" 2>/dev/null && mv "$DB.tmp" "$DB" 2>/dev/null || rm -f "$DB.tmp" 2>/dev/null
done <<EOF
$CANDIDATES
EOF

exit 0
