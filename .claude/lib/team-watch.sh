#!/usr/bin/env bash
# Watch one or more teams and print one line per state change (the event stream for /monitor).
#
# Usage: bash .claude/lib/team-watch.sh [--once] <team> [team...]
#   e.g. bash .claude/lib/team-watch.sh alfa gamma
#
# Events: WATCH (initial state) · STAGE · RECORD · ATTENTION (+ the role's screen) · RUNNER stopped.
# Polls local files and tmux every TEAM_WATCH_SECS (default 15); never exits on its own unless --once.
set -euo pipefail

once=0
[ "${1:-}" != --once ] || { once=1; shift; }
if [ $# -lt 1 ]; then
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
. "$(dirname "$0")/team-lib.sh"

root="$(git rev-parse --show-toplevel)"
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
POLL="${TEAM_WATCH_SECS:-15}"

screen() {  # last non-empty lines of a role's pane, indented so they batch with their event
  team_pane "$1" "${2:-15}" | sed 's/^/  | /' || true
}

# One snapshot per team: "stage|newest record + verdict|attention lines|runner alive".
snapshot() {
  local team="$1" td="$2" run stage rec="none" att=0 runner=down r
  run="$(cat "$td/run" 2>/dev/null || true)"
  stage="idle"
  [ ! -f "$td/session.json" ] || stage="$(jq -r '"\(.role) attempt \(.attempt)"' "$td/session.json")"
  r="$(ls -1t "$td/runs/$run"/*-*-*.json 2>/dev/null | head -n 1)" || true
  [ -z "$r" ] || rec="$(basename "$r") $(jq -r .verdict "$r")$([ -e "$r.accepted" ] && echo ' accepted')"
  [ ! -f "$td/runs/$run/attention" ] || att="$(wc -l < "$td/runs/$run/attention" | tr -d ' ')"
  ! team_tmux_alive "$team-runner" || [ ! -d "$td/lock" ] || runner=up
  echo "$stage|$rec|$att|$runner"
}

check() {
  local team="$1" td="$2" now prev stage role
  now="$(snapshot "$team" "$td")"
  prev="$(cat "$STATE/$team" 2>/dev/null || true)"
  echo "$now" > "$STATE/$team"
  IFS='|' read -r stage rec att runner <<<"$now"
  role="${stage%% *}"
  if [ -z "$prev" ]; then
    echo "WATCH $team: stage $stage · last record $rec · runner $runner"; return 0
  fi
  IFS='|' read -r pstage prec patt prunner <<<"$prev"
  [ "$stage" = "$pstage" ] || echo "STAGE $team: $pstage → $stage"
  [ "$rec" = "$prec" ] || echo "RECORD $team: $rec"
  if [ "$att" -gt "$patt" ] && [ "$role" != idle ]; then
    echo "ATTENTION $team $role: $(tail -n 1 "$td/runs/$(cat "$td/run")/attention" | cut -d' ' -f2-)"
    screen "$team-$role"
  fi
  if [ "$prunner" = up ] && [ "$runner" = down ]; then
    echo "RUNNER $team stopped:"
    screen "$team-runner" 6
  fi
}

while :; do
  for team in "$@"; do
    td="$(dirname "$root")/$(basename "$root")-$team/.agents/team"
    if [ -f "$td/team.json" ]; then check "$team" "$td"; else echo "WATCH $team: no clone"; fi
  done
  [ "$once" = 0 ] || exit 0
  sleep "$POLL"
done
