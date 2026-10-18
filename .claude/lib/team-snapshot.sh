#!/usr/bin/env bash
# Print one JSON snapshot of the harness for the live dashboard (schema 1, spec TT-783).
#
# Usage: bash .claude/lib/team-snapshot.sh [--out <file>]
#   e.g. bash .claude/lib/team-snapshot.sh | jq .teams
#
# Reads the supervisor transcript + sub-agents, team clones, tmux panes and live `codex exec` runs.
# Env: TEAM_DASH_SESSION (pin the transcript), TEAM_DASH_PROJECT_DIR, TEAM_DASH_SECS (default 3),
# TEAM_DASH_CACHE / TEAM_DASH_PR_SECS (PR state, team-pr-state.sh).
set -euo pipefail

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
OUT=""
if [ $# -gt 0 ]; then
  [ $# -eq 2 ] && [ "$1" = --out ] || usage
  OUT="$2"
fi

. "$(dirname "$0")/team-lib.sh"
. "$(dirname "$0")/team-roles.sh"
. "$(dirname "$0")/team-modes.sh"
. "$(dirname "$0")/team-pr-state.sh"
. "$(dirname "$0")/team-snapshot-agents.sh"
. "$(dirname "$0")/team-snapshot-teams.sh"

root="$(team_root)"
# The profile is not loaded in this shell and a dashboard must not die on it: read the one field.
TEAM_DASH_PR_PROVIDER="$(jq -r '.teams.pr_provider // "azure-devops"' "$root/.claude/project-profile.json" 2>/dev/null || echo azure-devops)"
export TEAM_DASH_PR_PROVIDER
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
: > "$W/errors"; : > "$W/events"
NOW="$(date -u +%s)"
SECS="${TEAM_DASH_SECS:-3}"
[[ "$SECS" =~ ^[0-9]+$ ]] || SECS=3

err() { printf '%s\n' "$*" >> "$W/errors"; }
event() {  # event <at> <source> <text>
  jq -cn --arg at "$1" --arg source "$2" --arg text "$3" '{at: $at, source: $source, text: $text}' \
    >> "$W/events"
}
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
mtime() { stat -f %m "$1"; }
age() { echo $(( NOW - $(mtime "$1") )); }
# Bounded reads: transcripts reach many MB; the first, cut line fails fromjson and drops out.
jl_tail() { tail -c 262144 "$1" | jq -cR 'fromjson? // empty'; }
jl_first_ts() {
  { head -c 65536 "$1" | jq -rR 'fromjson? | .timestamp? // empty' | head -n 1; } || true
}

# skill_trail <transcript> → the last 8 skill starts [{skill, at}] (Skill calls and typed commands).
# A transcript records when a skill starts, never when it returns — so this is "last invoked".
skill_trail() {
  local raw out rc
  [ -r "$1" ] && raw="$(tail -c 4194304 "$1")" || return 1   # unreadable ≠ empty trail
  set +e; out="$(printf '%s\n' "$raw" | grep -a -e '"name":"Skill"' -e '<command-')"; rc=$?; set -e
  [ "$rc" -le 1 ] || return 1   # 1 = no match: a valid empty trail
  printf '%s\n' "$out" | jq -cR 'fromjson? // empty' | jq -cs '
    [ .[] | (select(.type == "assistant") | .timestamp as $t
             | .message.content[]? | select(.type? == "tool_use" and .name? == "Skill")
             | {skill: ("/" + (.input.skill // "?")), at: $t}),
            (select(.type == "user") | .timestamp as $t
             | (.message.content | if type == "string" then . else (map(.text? // "") | join("")) end)
             | select(startswith("<command-"))
             | capture("<command-name>/?(?<n>[^<]+)</command-name>") | {skill: ("/" + .n), at: $t}) ]
    | .[-8:]'
}

TMUX_OK=1
command -v tmux >/dev/null 2>&1 || { TMUX_OK=0; err "tmux: not on PATH"; }

PROJ="$(team_claude_project_dir "$root")"
SID="$(team_dash_session "$root")"

# ---- supervisor + sub-agents ------------------------------------------------------------------

SUP_UNKNOWN="$(jq -cn --arg s "$SID" \
  '{session_id: (if $s == "" then null else $s end), status: "unknown"}')"

# snap_supervisor, snap_subagents: team-snapshot-agents.sh

# ---- teams ------------------------------------------------------------------------------------

# snap_teams, snap_attention: team-snapshot-teams.sh

# ---- codex ------------------------------------------------------------------------------------

etime_secs() {  # [[dd-]hh:]mm:ss → seconds; 10# because 08/09 are invalid octal
  local e="$1" d=0 h=0 m=0 s=0 a b c
  case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
  IFS=: read -r a b c <<<"$e"
  if [ -n "$c" ]; then h="$a"; m="$b"; s="$c"; else m="$a"; s="${b:-0}"; fi
  echo $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

snap_codex() {
  local pid et cmd out repo effort log bytes last
  local re_cmd='^([^ ]*/)?(node[^ ]* +([^ ]*/)?)?codex[^ /]* +exec '
  local re_out='--output-last-message ([^ ]+)' re_repo=' -C ([^ ]+)'
  local re_effort='model_reasoning_effort="?([a-z]+)'
  ps -Ao pid=,etime=,command= > "$W/ps" 2>/dev/null \
    || { err "codex: ps failed"; echo '[]'; return 0; }
  : > "$W/codex"; : > "$W/codex-seen"
  # Never copy $cmd into the JSON: it carries the full prompt.
  while read -r pid et cmd; do
    [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$cmd" =~ $re_cmd ]] && [[ "$cmd" =~ $re_out ]] || continue
    out="${BASH_REMATCH[1]}"
    ! grep -qxF -- "$out" "$W/codex-seen" || continue
    echo "$out" >> "$W/codex-seen"
    repo=""; effort=""; last=""; bytes=0
    [[ ! "$cmd" =~ $re_repo ]] || repo="${BASH_REMATCH[1]}"
    [[ ! "$cmd" =~ $re_effort ]] || effort="${BASH_REMATCH[1]}"
    log="$(lsof -a -p "$pid" -d 2 -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)" || true
    if [ -n "$log" ] && [ -f "$log" ]; then
      bytes="$(wc -c < "$log" | tr -d ' ')"
      last="$(tail -c 1048576 "$log" | grep -a '^STATUS:' | tail -n 1)" || true
    else
      err "codex: log unknown for pid $pid"; log=unknown
    fi
    et="$(iso $(( NOW - $(etime_secs "$et") )))"
    event "$et" codex "codex started (${effort:-default})"
    jq -cn --argjson pid "$pid" --arg at "$et" --arg repo "$repo" --arg effort "$effort" \
      --arg log "$log" --argjson bytes "$bytes" --arg last "$last" '
      {pid: $pid, started_at: $at, repo: $repo,
       effort: (if $effort == "" then null else $effort end), log: $log, log_bytes: $bytes,
       last_status: (if $last == "" then null else $last end)}' >> "$W/codex"
  done < "$W/ps"
  jq -s . "$W/codex"
}

# ---- assemble ---------------------------------------------------------------------------------

# collect <part> <fallback JSON> <fn> — a failed or malformed part never kills the page, and a
# failed read never passes for data (jq on empty input still prints a well-shaped object).
collect() {
  if ! "$3" > "$W/$1.json"; then
    err "$1: failed"; echo "$2" > "$W/$1.json"
  elif ! jq -se --argjson f "$2" 'length == 1 and (.[0] | type) == ($f | type)' "$W/$1.json" \
    >/dev/null 2>&1; then
    err "$1: invalid output"; echo "$2" > "$W/$1.json"
  fi
}

collect supervisor "$SUP_UNKNOWN" snap_supervisor
collect subagents '[]' snap_subagents
collect teams '[]' snap_teams
collect attention '[]' snap_attention
collect codex '[]' snap_codex
jq -s 'map(select(type == "object" and (.at // "") != "")) | sort_by(.at) | .[-40:]' "$W/events" \
  > "$W/ev.json" 2>/dev/null || { err "events: invalid"; echo '[]' > "$W/ev.json"; }
branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch=""
jq -R . "$W/errors" | jq -s . > "$W/err.json"

jq -n --arg gen "$(iso "$NOW")" --argjson iv "$SECS" --arg root "$root" --arg branch "$branch" \
  --slurpfile sup "$W/supervisor.json" --slurpfile sub "$W/subagents.json" \
  --slurpfile teams "$W/teams.json" --slurpfile codex "$W/codex.json" \
  --slurpfile att "$W/attention.json" --slurpfile ev "$W/ev.json" --slurpfile errs "$W/err.json" '
  {"schema": 1, generated_at: $gen, interval_secs: $iv, repo: {root: $root, branch: $branch},
   supervisor: $sup[0], subagents: $sub[0], teams: $teams[0], codex: $codex[0],
   attention: $att[0], events: $ev[0], errors: $errs[0]}' > "$W/snapshot.json"

if [ -n "$OUT" ]; then
  # tmp + mv in the target dir: the poller never reads a half-written file.
  cp "$W/snapshot.json" "$OUT.tmp.$$" && mv "$OUT.tmp.$$" "$OUT"
else
  cat "$W/snapshot.json"
fi
