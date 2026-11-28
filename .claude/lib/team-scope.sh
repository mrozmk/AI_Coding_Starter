#!/usr/bin/env bash
# Start preflight of /start-team step 3a: refuse a ticket no team stage can deliver — every file
# its wanted change writes lies under .agents/memory/, which guard-team-memory.sh blocks for every
# team stage (the wrapup writes memory in its own clone only). The Supervisor lists the files; this
# script decides, with the guard's own path rule (guard-team-memory.sh, `case "$FILE"`).
#
# Usage: bash .claude/lib/team-scope.sh memory-only <KEY> <path>…
# Exit: 0 a path lies outside .agents/memory/ · 2 usage · 3 refused (one `refused:` line)
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail
usage() { sed -n '7,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ "${1:-}" = memory-only ] && [ -n "${2:-}" ] && [ $# -ge 3 ] || usage
KEY="${2#\#}"; shift 2
for p in "$@"; do
  case "$p" in
    .agents/memory|.agents/memory/*|*/.agents/memory|*/.agents/memory/*) ;;
    *) exit 0 ;;
  esac
done
echo "refused: #$KEY — memory-only change ($*): no team stage may write .agents/memory/ (guard-team-memory.sh) — do it in a solo session or ask the Supervisor"
exit 3
