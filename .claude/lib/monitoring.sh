#!/usr/bin/env bash
# Per-role listening of the supervision sessions: night pause, wake loop, start steps.
# Usage: bash .claude/lib/monitoring.sh start|stop|status [all]
#        bash .claude/lib/monitoring.sh ensure|paused <role>|armed <role>
#   role = TEAM_SESSION_ROLE; `all` = every session role, from the Supervisor or a role-less caller
#   e.g. bash .claude/lib/monitoring.sh stop all    (the Supervisor, at night)
# Runbook: .agents/reference/team-watch.md#pause
set -euo pipefail

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage
LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-watch-lib.sh"
tw_init "$(git rev-parse --show-toplevel)"
cmd="$1"; shift
[ ! -f "$root/.agents/team/team.json" ] \
  || { echo "error: team clone — run monitoring.sh from the main checkout" >&2; exit 1; }
cd "$root"
W="bash .claude/lib/team-watch.sh"

mon_self() {
  tw_session_role_ok "${TEAM_SESSION_ROLE:-}" || {
    echo "error: TEAM_SESSION_ROLE unset or unknown — monitoring.sh runs in a role session" \
      "(start it as TEAM_SESSION_ROLE=<Supervisor|TeamLead|Advisor> claude …)" >&2; exit 2; }
  echo "$TEAM_SESSION_ROLE"
}

mon_roles() {  # mon_roles <all|""> → the roles a start/stop acts on
  [ "${1:-}" = all ] || { mon_self; return 0; }
  if [ -n "${TEAM_SESSION_ROLE:-}" ] && [ "$TEAM_SESSION_ROLE" != Supervisor ]; then
    echo "refused: $TEAM_SESSION_ROLE cannot pause or start other roles — the Supervisor does" >&2
    exit 1
  fi
  echo "$TW_SESSION_ROLES"
}

mon_decl() {  # mon_decl <role> <jq path below .roles[<role>]>
  jq -c --arg r "$1" ".roles[\$r]$2" "$(tw_monitoring_file)" 2>/dev/null || echo null
}

mon_pass_text() {
  local p
  p="$(tw_pause_pass "$1")"
  if [ "$p" = '{}' ]; then echo nothing; else echo "$p"; fi
}

# flag($r) → none | ok | bad; utc holds only for a canonical, real instant (99:99:99 is not one).
MON_PAUSE_DEFS='def utc: type == "string"
    and ((try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | todate) catch "") == .);
  def flag($r): if .paused == null then "none"
    elif (.paused | type) != "object" then "bad"
    elif .paused[$r] == null then "none"
    elif (.paused[$r] | type) == "object" and (.paused[$r].since | utc) then "ok"
    else "bad" end;'

mon_pause_flag() {  # mon_pause_flag <role> → none|ok|bad (unreadable state = bad)
  local s
  s="$(tw_state_json)" || { echo bad; return 0; }
  jq -r --arg r "$1" "$MON_PAUSE_DEFS flag(\$r)" <<<"$s" 2>/dev/null || echo bad
}

# mon_set_pause <role> <UTC|""> — caller holds tw_lock. One durable flag per role with its
# author; an unreadable state.json is refused, never overwritten.
# A stop keeps an existing pause and never re-dates it; a broken flag is refused.
mon_set_pause() {
  local s n
  if [ -n "$2" ]; then
    case "$(mon_pause_flag "$1")" in
      ok) return 0 ;;
      none) ;;
      *) echo "error: $1 pause flag unreadable — fix it by hand" >&2; return 1 ;;
    esac
  fi
  s="$(tw_state_json)" || { echo "error: state.json unreadable — fix it by hand" >&2; return 1; }
  n="$(jq --arg r "$1" --arg v "$2" --arg by "${TEAM_SESSION_ROLE:-operator}" \
    '.paused = ((.paused // {})
      | if $v == "" then del(.[$r]) else .[$r] = {since: $v, by: $by} end)' <<<"$s" \
    2>/dev/null)" || { echo "error: state.json unreadable — fix it by hand" >&2; return 1; }
  printf '%s\n' "$n" | tw_put "$TW_DIR/state.json"
}

# send.d first, then the lock (tw_handover's order): a delivery that already selected routine
# events cannot commit across the pause change.
mon_begin() {
  tw_claim "$TW_DIR/send.d" "$TW_LOCK_SECS" "$(tw_send_max)" \
    || { echo "error: a delivery is in flight — retry" >&2; exit 1; }
  tw_lock || { tw_release "$TW_DIR/send.d"; echo "error: team-watch state lock busy" >&2; exit 1; }
}
mon_end() { tw_unlock; tw_release "$TW_DIR/send.d"; }

mon_old_loops() {  # a fresh loop of another version would ignore the pause
  { tw_fresh beat && ! tw_current beat; } || { tw_fresh dog.beat && ! tw_current dog.beat; }
}

mon_live_teams() {
  local d p names=""
  for d in $(team_clone_dirs "$root"); do
    p="$(grep -oE '[0-9]+' -m1 "$d/lock/pid" 2>/dev/null | head -n 1)" || p=""
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null || continue
    names="$names $(jq -r .team "$d/team.json")"
  done
  [ -z "$names" ] || echo "teams in progress:$names — their questions wait for start"
}

mon_stop() {
  local roles r now kept="" note
  roles="$(mon_roles "${1:-}")"
  if mon_old_loops; then
    echo "refused: team-watch runs an older version — the pause would not be honoured;" \
      "run monitoring.sh start (or team-watch.sh start) first" >&2
    exit 1
  fi
  # Only the flag: a pause acks, supersedes and moves nothing, so UNPICKED/STALLED stay armed.
  mon_begin
  # since only once send.d is held: a delivery still in flight must not land after it.
  now="$(team_utc)"
  # The whole set is checked first: `stop all` writes no role when any flag is broken.
  for r in $roles; do
    case "$(mon_pause_flag "$r")" in
      ok) kept="$kept $r " ;;
      none) ;;
      *) mon_end; echo "error: $r pause flag unreadable — fix it by hand" >&2; exit 1 ;;
    esac
  done
  for r in $roles; do mon_set_pause "$r" "$now" || { mon_end; exit 1; }; done
  mon_end
  for r in $roles; do
    note=""
    case "$kept" in *" $r "*) note=" — already paused" ;; esac
    echo "$r: paused since $(tw_paused "$r")$note (passes: $(mon_pass_text "$r"))"
  done
  [ "${1:-}" != all ] || mon_live_teams
}

mon_live_self() {  # the role's receiver is live and registered to this session's claude
  local p
  tw_live "$1" || return 1
  p="$(tw_sock_pid)"
  [ -n "$p" ] && [ "$(jq -r '.pid // ""' "$(tw_receiver_file "$1")")" = "$p" ]
}

mon_start_steps() {  # declared steps from a fixed allow-list, never executed as shell
  local s
  while IFS= read -r s; do
    case "$s" in
      ""|null) ;;
      "mode tiers on") $W mode tiers on ;;
      *) echo "refused: unknown start step $s" >&2 ;;
    esac
  done <<<"$(mon_decl "$1" '.start // [] | .[]' | jq -r '.' 2>/dev/null)"
}

# Idempotent: only a paused role is rebased onto the replay; a running one keeps its queue.
# tw_rebase sets open.json registrations[<role>] = "replay", forcing the (current state) replay.
mon_start() {
  local roles r
  roles="$(mon_roles "${1:-}")"
  mon_begin
  for r in $roles; do
    tw_paused "$r" >/dev/null || continue
    mon_set_pause "$r" "" || { mon_end; exit 1; }
    ! tw_role_ok "$r" || tw_rebase "$r" replay || tw_log "$r: replay failed"
  done
  mon_end
  if [ "${1:-}" != all ]; then
    if tw_role_ok "$roles" && { ! { tw_current beat && tw_current dog.beat; } \
        || ! mon_live_self "$roles"; }; then
      $W start || echo "error: team-watch.sh start failed — run monitoring.sh start again" >&2
    fi
    mon_start_steps "$roles"
  fi
  for r in $roles; do echo "$r: running · readiness: $(mon_state "$r")"; done
  [ "${1:-}" = all ] || mon_ensure
}

# mon_armed <role> → "pid <p> claude <c> since <UTC>"; rc 1 unless both pids live and the loop
# beat within 3 of its ticks — a live pid alone does not prove the loop still listens.
mon_armed() {
  local f="$TW_DIR/wake/$1.json" p c s t b
  [ -f "$f" ] || return 1
  IFS=$'\t' read -r p c s t <<<"$(jq -r '[.pid, .claude_pid, .since, (.secs // 3)]
    | map(tostring) | @tsv' "$f" 2>/dev/null)" || return 1
  [[ "$p" =~ ^[0-9]+$ ]] && [[ "$c" =~ ^[0-9]+$ ]] && [[ "$t" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$p" 2>/dev/null && kill -0 "$c" 2>/dev/null || return 1
  b="$(tw_num "$(cat "$TW_DIR/wake/$1.beat" 2>/dev/null)" 0 '^[0-9]+$')"
  [ $(( $(tw_now) - b )) -le $(( 3 * t + 5 )) ] || return 1
  echo "pid $p claude $c since $s"
}

mon_wake_state() {  # → none declared | armed (…) | dormant (paused) | not armed
  local a
  if [ "$(mon_decl "$1" '.wake // {} | length')" = 0 ]; then echo "none declared"; return 0; fi
  if ! a="$(mon_armed "$1")"; then echo "not armed"
  elif tw_paused "$1" >/dev/null; then echo "dormant (paused)"
  else echo "armed ($a)"; fi
}

mon_mail_missing() {  # the role declares a mail source but watch.local.json has no probe for it
  local cfg="$root/.agents/team/watch.local.json"
  [ "$(mon_decl "$1" '.wake.mail // null')" != null ] || return 1
  [ -z "$(jq -r --arg r "$1" '.mail[$r] // .wake_mail[$r] // ""' "$cfg" 2>/dev/null)" ]
}

mon_ensure() {
  local r a
  r="$(mon_self)"
  if [ "$(mon_decl "$r" '.wake // {} | length')" = 0 ]; then
    echo "wake: none declared"; return 0
  fi
  if a="$(mon_armed "$r")"; then
    echo "wake: armed (pid $(echo "$a" | cut -d' ' -f2), since ${a##* })"
  else
    echo "wake: not armed — start in the background (Bash, run_in_background: true):" \
      "bash .claude/lib/session-wake.sh"
  fi
  ! mon_mail_missing "$r" || echo "mail: not configured"
}

# mon_state <role> → paused (…) | running | missing (…) | degraded (…)
mon_state() {
  local r="$1" why="" a
  if a="$(tw_paused "$r")"; then echo "paused ($a)"; return 0; fi
  if tw_role_ok "$r"; then
    [ "$(jq -r '.active // false' "$(tw_receiver_file "$r")" 2>/dev/null)" = true ] \
      || { echo "missing (no active team-watch receiver)"; return 0; }
    tw_live "$r" || why="$why, receiver not live"
    { tw_current beat && tw_current dog.beat; } || why="$why, team-watch loops not current"
  elif ! mon_armed "$r" >/dev/null && ! team_tmux_alive "$(tw_tmux_name "$r")"; then
    echo "missing (no tmux $(tw_tmux_name "$r"), no wake loop)"; return 0
  fi
  [ "$(mon_decl "$r" '.wake // {} | length')" = 0 ] || mon_armed "$r" >/dev/null \
    || why="$why, wake loop not armed or silent"
  ! mon_mail_missing "$r" || why="$why, mail probe not configured"
  if [ -z "$why" ]; then echo running; else echo "degraded (${why#, })"; fi
}

mon_status() {
  local roles r l u
  if [ "${1:-}" = all ]; then roles="$TW_SESSION_ROLES"; else roles="$(mon_self)"; fi
  touch "$TW_DIR/events.jsonl" "$TW_DIR/deliveries.jsonl"
  for r in $roles; do
    echo "$r: $(mon_state "$r")"
    ! tw_paused "$r" >/dev/null || echo "  passes: $(mon_pass_text "$r")"
    if tw_role_ok "$r"; then
      l="$(tw_receiver_line "$r")" || l="receiver $r: none registered"
      u="$(jq -s --arg r "$r" --argjson c "$(tw_cursor "$r")" \
        --slurpfile d "$TW_DIR/deliveries.jsonl" "$TW_DELIVER_DEFS unsent(\$r; \$c; \$d) | length" \
        "$TW_DIR/events.jsonl")" || u="?"
      echo "  $l · undelivered: $u"
    fi
    echo "  wake: $(mon_wake_state "$r")"
  done
}

case "$cmd" in
  start|stop|status)
    [ $# -le 1 ] && { [ -z "${1:-}" ] || [ "$1" = all ]; } || usage
    "mon_$cmd" "${1:-}" ;;
  ensure) [ $# = 0 ] || usage; mon_ensure ;;
  paused) tw_session_role_ok "${1:-}" || usage; tw_paused "$1" ;;
  armed)  # no wake declared (or no readable declaration) = nothing to arm, for the Stop hook
    tw_session_role_ok "${1:-}" || usage
    case "$(mon_decl "$1" '.wake // {} | length')" in 0|null) exit 0 ;; esac
    mon_armed "$1" ;;
  *) usage ;;
esac
