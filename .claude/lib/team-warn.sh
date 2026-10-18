#!/usr/bin/env bash
# Append a durable warning to a team clone's team.json — for a non-fatal failure the run walks past
# but a human must still be able to recover (today: `/start-team` 4b `set-status started`).
#
# Usage: bash .claude/lib/team-warn.sh <team> <text>
# Exit: 0 recorded · 1 no clone / cannot write · 2 usage
# `warnings` is an append-only array of `{at, text}`; `team-run.sh status` prints it when non-empty.
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

TEAM="${1:-}"; TEXT="${2:-}"
[ -n "$TEAM" ] && [ -n "$TEXT" ] || { echo "usage: team-warn.sh <team> <text>" >&2; exit 2; }

root="$(git rev-parse --show-toplevel)"
. "$root/.claude/lib/team-profile.sh"
team_profile_load "$root"
CLONE="$(team_clone_dir "$TEAM" "$root")"
F="$CLONE/.agents/team/team.json"
[ -f "$F" ] || { echo "error: no team clone at $CLONE" >&2; exit 1; }

# temp file + mv: a crash mid-write must not truncate the clone's identity file.
jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg t "$TEXT" \
  '.warnings = ((.warnings // []) + [{at: $at, text: $t}])' "$F" > "$F.new" \
  || { rm -f "$F.new"; echo "error: cannot rewrite $F" >&2; exit 1; }
mv "$F.new" "$F" || { echo "error: cannot replace $F" >&2; exit 1; }
echo "warning recorded in $F"
