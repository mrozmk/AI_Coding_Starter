#!/usr/bin/env bash
# Provision a team clone next to this checkout, on a fresh branch cut from a harness-carrying line.
#
# Usage: bash .claude/lib/team-new.sh <team> <TT-key> <new-branch> <base-ref> [mode]
#   mode: brainstorm (default) | quick | cli — fixed for the ticket
#   e.g. bash .claude/lib/team-new.sh alfa TT-790 feature/TT-790-slug origin/develop-netcore7
#
# Result: ../<repo>-<team>/ on <new-branch>, per-developer files copied, .agents/team/team.json.
# Next ticket in the same clone: team-next.sh. Runbook: .agents/reference/team-pipeline.md
set -euo pipefail

if [ $# -ne 4 ] && [ $# -ne 5 ]; then
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

team="$1"; key="$2"; branch="$3"; base="$4"; mode="${5:-brainstorm}"

. "$(dirname "$0")/team-lib.sh"
. "$(dirname "$0")/team-modes.sh"

root="$(git rev-parse --show-toplevel)"
dir="$(dirname "$root")/$(basename "$root")-${team}"
TEAM_PROBLEMS=()
team_check_name "$team" 2>/dev/null || TEAM_PROBLEMS+=("team name '$team' must match [a-z0-9-]+")
[ ! -e "$dir" ] || TEAM_PROBLEMS+=("$dir already exists — to start the next ticket there: team-next.sh")
team_ticket_checks "$root" "$key" "$branch" "$base"
team_mode_checks "$root" "$base" "$mode"

if [ ${#TEAM_PROBLEMS[@]} -gt 0 ]; then
  for p in "${TEAM_PROBLEMS[@]}"; do echo "error: $p" >&2; done
  exit 1
fi

# Real origin URL + --reference-if-able: a local-path clone would need `git remote set-url` (denied).
git clone --quiet --reference-if-able "$root" --dissociate "$(git -C "$root" remote get-url origin)" "$dir"
git -C "$dir" switch --quiet --no-track -c "$branch" "$base"
team_seed_files "$root" "$dir"
team_write_json "$dir" "$team" "$key" "$branch" "$base" "$mode"

echo "clone:    $dir"
echo "branch:   $branch (from $base)"
echo "base sha: $(git -C "$dir" rev-parse HEAD)"
echo "mode:     $mode"
echo "next:     bash .claude/lib/team-run.sh $team   (from this checkout)"
