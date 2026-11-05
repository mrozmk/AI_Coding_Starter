#!/usr/bin/env bash
# Watch one or more teams and print one line per state change (the event stream for /monitor).
#
# Usage: bash .claude/lib/team-watch.sh [--once] <team> [team...]
#        bash .claude/lib/team-watch.sh mode tiers|answering on|off
#        bash .claude/lib/team-watch.sh mode class <class> on|off
#   e.g. bash .claude/lib/team-watch.sh alfa gamma
#
# Events: WATCH (initial state) · STAGE · RECORD · ATTENTION (+ the role's screen) · RUNNER stopped.
# Polls local files and tmux every TEAM_WATCH_SECS (default 15); never exits on its own unless --once.
# `mode` writes the shared switches in <main>/.agents/team/watch/state.json that team-question.sh
# answer and the tier-1 classes enforce (team-mode.md §10); only the Operator's words set them.
set -euo pipefail

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
once=0
[ "${1:-}" != --once ] || { once=1; shift; }
[ $# -ge 1 ] || usage
. "$(dirname "$0")/team-lib.sh"

root="$(git rev-parse --show-toplevel)"

# set_switch <jq filter> <label> — one writer at a time (mkdir lock), atomic replace; a state file
# that is not a JSON object is refused, never overwritten (its readers treat it as all off).
set_switch() {
  local d="$root/.agents/team/watch" s tries=0
  mkdir -p "$d"
  until mkdir "$d/lock.d" 2>/dev/null; do
    tries=$((tries + 1)); [ "$tries" -lt 50 ] || { echo "error: team-watch state lock busy" >&2; exit 1; }
    sleep 0.1
  done
  TW_LOCKD="$d/lock.d"; trap 'rmdir "$TW_LOCKD" 2>/dev/null || true' EXIT
  if [ -e "$d/state.json" ]; then
    s="$(jq -ce 'objects' "$d/state.json" 2>/dev/null)" \
      || { echo "error: $d/state.json is not a JSON object — fix or remove it" >&2; exit 1; }
  else s='{}'; fi
  jq "$@" <<<"$s" > "$d/state.json.tmp.$$" && mv "$d/state.json.tmp.$$" "$d/state.json"
}

if [ "$1" = mode ]; then
  if [ "${2:-}" = class ]; then
    case " $TEAM_CLASSES " in *" ${3:-x} "*) ;; *) usage ;; esac
    [[ "${4:-}" =~ ^(on|off)$ ]] || usage
    set_switch --arg n "$3" --arg v "$4" \
      '.classes = ((.classes | if type == "object" then . else {} end) + {($n): $v})'
    echo "team-watch: class $3 $4"
  else
    [[ "${2:-}" =~ ^(tiers|answering)$ ]] && [[ "${3:-}" =~ ^(on|off)$ ]] || usage
    set_switch --arg k "$2" --arg v "$3" '.[$k] = $v'
    echo "team-watch: $2 $3"
  fi
  exit 0
fi
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
    clone="$(team_clone_dir "$team" "$root")"
    td="$clone/.agents/team"
    if [ -f "$td/team.json" ]; then check "$team" "$td"; else echo "WATCH $team: no clone"; fi
  done
  [ "$once" = 0 ] || exit 0
  sleep "$POLL"
done
