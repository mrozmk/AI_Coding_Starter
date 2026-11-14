#!/usr/bin/env bash
# Shared per-run TeamLead helpers: the doorbell (the one transport seam a session driver replaces)
# and ending a role session safely. Sourced after team-lib.sh, never executed; the caller sets its
# own shell options. Sourced from the MAIN checkout by team-run.sh; team-lead.sh and the hooks
# source their own checkout's copy. Bash 3.2. Contract: .agents/reference/team-lead.md
TEAM_LEAD_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEAM_LEAD_LIB/team-send-lock.sh"

# The per-run TeamLead's identity: field of teamlead.json, and the caller check — role env
# TeamLead + teamlead.json of the current run (+ the hook's session_id, when given).
team_lead_json() { jq -r --arg f "$1" '.[$f] // empty' "$(team_dir)/teamlead.json" 2>/dev/null; }
team_lead_caller() {
  local d r; [ "${TEAM_SESSION_ROLE:-}" = TeamLead ] && d="$(team_dir 2>/dev/null)" || return 1
  r="$(cat "$d/run" 2>/dev/null)"; [ -n "$r" ] && [ "$(team_lead_json run)" = "$r" ] || return 1
  [ -z "${1:-}" ] || [ "$1" = "$(team_lead_json session_id)" ]
}

# team_pane_idle <tmux name> → 0 when the pane shows a recognised empty idle input. On an open
# prompt Enter would approve the focused option, so keys go only on this.
team_pane_idle() {
  team_pane "$1" 40 | python3 -I "$TEAM_LEAD_LIB/team_prompt.py" parse \
    | jq -e '.complete and .kind == "none" and .input_empty == true' >/dev/null 2>&1
}

# team_end_session <team dir> <tmux name> <lock role> <exit wait secs> → 0 ended (or never ran),
# 1 still alive. /exit + Enter only on an idle input and under the send lock, else a kill.
team_end_session() {
  local td="$1" name="$2" lr="$3" wait="$4" waited=0 h
  team_tmux_alive "$name" || return 0
  if team_send_lock "$td" "$lr" "${TEAM_SEND_LOCK_WAIT:-30}" "runner pid=$$" >/dev/null; then
    if team_pane_idle "$name"; then
      tmux send-keys -t "=$name:" "/exit" Enter || true
      while team_tmux_alive "$name" && [ "$waited" -lt "$wait" ]; do
        sleep 1; waited=$((waited + 1))
      done
    fi
    team_tmux_alive "$name" && tmux kill-session -t "=$name" || true
    team_send_unlock "$td" "$lr"
  else
    h="$(team_send_holder "$td" "$lr")"
    echo "stop-during-send $(team_utc) $h" >> "$td/send-$lr.log"
    echo "warn: stop while sender lock held by $h — session killed without /exit" >&2
    tmux kill-session -t "=$name" || true
  fi
  ! team_tmux_alive "$name"
}

# team_session_doorbell <team dir> <role> <one line> — wake a role session. First Claude's
# messaging socket from the session's own registration (draft- and dialog-safe); else send-keys
# on an idle empty input under the send lock; else skip and log. Pending work is derived from
# files, so a lost doorbell only delays. Always returns 0.
team_session_doorbell() {
  local td="$1" role="$2" text="${3//$'\n'/ }" reg name why=""
  reg="$td/teamlead.reg.json"
  if [ "$role" = lead ] && [ -f "$reg" ] && printf '%s\n' "$text" \
    | python3 -I "$TEAM_LEAD_LIB/team-watch-send.py" "$reg" >/dev/null 2>&1; then
    return 0
  fi
  name="$(team_tmux_name "$(jq -r '.team // empty' "$td/team.json" 2>/dev/null)" "$role")"
  if ! team_tmux_alive "$name"; then
    why="session $name not alive"
  elif team_send_lock "$td" "$role" "${TEAM_SEND_LOCK_WAIT:-30}" "doorbell pid=$$" >/dev/null; then
    if ! team_pane_idle "$name"; then why="input not idle"
    elif ! { tmux send-keys -t "=$name:" -l -- "$text" && tmux send-keys -t "=$name:" Enter; }; then
      why="send-keys failed"
    fi
    team_send_unlock "$td" "$role"
  else
    why="send lock held by $(team_send_holder "$td" "$role")"
  fi
  [ -z "$why" ] || echo "doorbell-skipped $(team_utc) $why — $text" >> "$td/send-$role.log"
  return 0
}
