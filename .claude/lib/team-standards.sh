#!/usr/bin/env bash
# The wrapup's writer for one accepted docs/coding-standards.md item (called by the wrapup only).
#
# Usage: bash .claude/lib/team-standards.sh entry-sha "<heading line>" [--rev <rev>]
#        bash .claude/lib/team-standards.sh add --verdict <teamlead-wrapup-<n>.json> --item memory-<n> --target-rev <sha>
#   entry-sha: the sha256 of a .agents/memory/patterns.md entry, for a rule's promotes_sha256 —
#   the clone's file, or with --rev that revision's blob (read into a temp file; the worktree is
#   never touched before the TeamLead decides).
#   add: writes the accepted item — the next free CS-<n>, a table row or an Open line, and for a
#   promotion the patterns.md pointer — idempotently; --target-rev is the wrapup's fixed target sha.
#   e.g. bash .claude/lib/team-standards.sh add --verdict .agents/team/runs/<run>/teamlead-wrapup-1.json --item memory-2 --target-rev <sha>
#
# Identity comes from .agents/team/session.json, checked here and again by team_wrapup.py.
# Exit: 0 ok · 2 usage or not the wrapup · 4 refused (team_wrapup.py names why).
# Contract: .agents/reference/team-lead.md §10 (Wrapup).
set -euo pipefail

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-lib.sh"

[ "${TEAM_SESSION_ROLE:-}" != TeamLead ] \
  || { echo "error: TeamLead decides standards items; the wrapup writes them" >&2; exit 2; }
[ -f "$(team_dir)/session.json" ] && [ "$(session_json role)" = wrapup ] \
  || { echo "error: team-standards.sh is the wrapup's" >&2; exit 2; }

OP="$1"; shift
case "$OP" in
  entry-sha)
    [ $# -eq 1 ] || [ $# -eq 3 ] || usage
    HEADING="$1"; shift
    if [ $# -eq 0 ]; then
      exec python3 -I "$LIB/team_wrapup.py" entry-sha "$(team_root)/.agents/memory/patterns.md" "$HEADING"
    fi
    [ "$1" = --rev ] || usage
    tmp="$(mktemp)"
    rc=0
    git -C "$(team_root)" show "$2:.agents/memory/patterns.md" > "$tmp" 2>/dev/null \
      || { rm -f "$tmp"; echo "error: no .agents/memory/patterns.md at $2" >&2; exit 4; }
    python3 -I "$LIB/team_wrapup.py" entry-sha "$tmp" "$HEADING" || rc=$?
    rm -f "$tmp"
    exit "$rc" ;;
  add)
    VERDICT=""; ITEM=""; TREV=""
    while [ $# -gt 0 ]; do
      [ $# -ge 2 ] || usage
      case "$1" in
        --verdict) VERDICT="$2" ;; --item) ITEM="$2" ;; --target-rev) TREV="$2" ;;
        *) usage ;;
      esac
      shift 2
    done
    [ -n "$VERDICT" ] || usage
    [[ "$ITEM" =~ ^memory-[1-9][0-9]*$ ]] || { echo "error: --item must be memory-<n>" >&2; exit 2; }
    [[ "$TREV" =~ ^[0-9a-f]{40}$ ]] || { echo "error: --target-rev must be a 40-hex sha (the wrapup's target_rev)" >&2; exit 2; }
    exec python3 -I "$LIB/team_wrapup.py" standards-add "$(team_root)" "$ITEM" "$VERDICT" "$TREV" ;;
  *) usage ;;
esac
