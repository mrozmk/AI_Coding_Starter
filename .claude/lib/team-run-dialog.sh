#!/usr/bin/env bash
# The runner's startup-dialog watch: a TeamLead or stage session held at Claude's folder trust dialog
# or its MCP servers dialog (session-host.md §11, the driver's screen recognition) is reported, never
# answered — accepting it is the Operator's step. Per session, once: a `warn:` line and one
# human_decision event through notify.sh (decision dialog-[r<n>-]<role>-<attempt>, or
# dialog-lead-<launch>), resolved through `notify.sh resolve` (#97) once the dialog is gone. While a
# stage's own dialog is open its execution-time limit pauses; the session is alive, so no attempt is
# spent. runs/<run>/dialog-<who> holds the decision already sent, so a resumed runner neither sends
# it again nor forgets to resolve it.
# Sourced by team-run.sh from the MAIN checkout, never executed; uses the runner's globals (TEAM, RUN,
# TD, CLONE, root, sess_name, team_json, rp, team_lead_on). Bash 3.2.
# Contract: .agents/reference/session-host.md §11

# dialog_screen <address> → trust | mcp | "" — read only while the session reports no status yet
# (Herdr: no program status; tmux: no hook state file), so a session past its start never reads as a
# dialog, whatever its screen shows.
dialog_screen() {
  local st scr
  st="$(sh_status "$1" 2>/dev/null | jq -r '.state // ""' 2>/dev/null)" || return 0
  [ "$st" = starting ] || return 0
  scr="$(sh_read "$1" --lines 40 2>/dev/null)" || return 0
  case "$(sh_screen_state "$scr" claude)" in trust) echo trust ;; mcp) echo mcp ;; esac
}
dialog_what() { if [ "$1" = trust ]; then echo "the folder trust dialog"; else echo "the MCP servers dialog"; fi; }
dialog_how() { if [ "$1" = trust ]; then echo "pick 'Yes, I trust this folder' (Enter alone exits)"; else echo "answer it"; fi; }
dialog_where() {  # dialog_where <address> → how to reach it; Herdr: also the team's tab
  local h; h="$(sh_hint "$1" 2>/dev/null)" || h="bash .claude/lib/session-host.sh hint $1"
  [ "$(sh_record_get "$root" "$1" backend)" != herdr ] || h="$h, tab $TEAM"
  echo "$h"
}
# dialog_word <address> → "alive", or what the session waits at and how to answer it (status lines).
dialog_word() {
  local k; k="$(dialog_screen "$1")"
  if [ -z "$k" ]; then echo alive; else echo "waiting at $(dialog_what "$k") — $(dialog_how "$k") in $(dialog_where "$1")"; fi
}
# dialog_label <address> → "<backend>: <address> <dialog_word>" (team-run.sh status).
dialog_label() { local b; b="$(sh_record_get "$root" "$1" backend)"; echo "${b:-tmux}: $1 $(dialog_word "$1")"; }

# dialog_tick <who> <address> <decision> → 0 while the session is at a startup dialog, else 1.
# A failed notify.sh is retried on the next ticks, three tries per decision, then one warn:.
DIALOG_WARNED=" " DIALOG_FAILS=" "
dialog_tick() {
  local f="$TD/runs/$RUN/dialog-$1" k o p rc n w
  k="$(dialog_screen "$2")"; o="$(cat "$f" 2>/dev/null || true)"
  if [ -n "$o" ] && { [ -z "$k" ] || [ "$o" != "$3" ]; }; then
    bash "$root/.claude/lib/notify.sh" resolve --team "$TEAM" --run "$RUN" --decision "$o" >/dev/null 2>&1 || true
    rm -f "$f"; o=""
    [ -n "$k" ] || echo "startup dialog gone: $2"
  fi
  [ -n "$k" ] || return 1
  # Operator touches (team-lead.md §10): one durable line per dialog kind and session, written at
  # first sight — the dialog-<who> marker above is removed when the dialog clears — and one
  # touch-log entry per session (decision id) and dialog kind (`<decision>-<kind>.touched`).
  mkdir -p "$TD/runs/$RUN"
  grep -qF " dialog $1:$k" "$TD/runs/$RUN/operator-touches" 2>/dev/null \
    || echo "$(team_utc) dialog $1:$k" >> "$TD/runs/$RUN/operator-touches"
  if [ ! -e "$TD/runs/$RUN/$3-$k.touched" ]; then
    w="$1"; [ "$w" != lead ] || w=TeamLead
    if bash "$root/.claude/lib/touches.sh" add --main "$root" --where "team $TEAM / $(team_json ticket) / $w" \
      --kind other --reason direct --what "startup dialog $k in $w" >/dev/null 2>&1; then
      : > "$TD/runs/$RUN/$3-$k.touched"
    else echo "warn: touch not recorded (dialog $1)"; fi
  fi
  case "$DIALOG_WARNED" in *" $3 "*) ;; *)
    echo "warn: $2: waiting at $(dialog_what "$k") — $(dialog_how "$k") in $(dialog_where "$2")"
    DIALOG_WARNED="$DIALOG_WARNED$3 " ;;
  esac
  [ -z "$o" ] || return 0
  mkdir -p "$TD/runs/$RUN"
  team_channel_names "$root" 2>/dev/null || unset TEAM_CHANNEL_TMUX_PREFIX  # the project id, as lead_notify
  p="${TEAM_CHANNEL_TMUX_PREFIX:-$(basename "$root" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._\n-' '-')}"
  rc=0; bash "$root/.claude/lib/notify.sh" human_decision --project "$p" --team "$TEAM" \
    --ticket "$(team_json ticket)" --run "$RUN" --decision "$3" \
    --summary "$TEAM $1 waits at $(dialog_what "$k") in $(basename "$CLONE") — $(dialog_how "$k")" \
    --answer "$2" --hint "$(dialog_where "$2")" --source runner --main "$root" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then printf '%s\n' "$3" > "$f"; return 0; fi
  DIALOG_FAILS="$DIALOG_FAILS$3 "
  n="$(printf '%s' "$DIALOG_FAILS" | tr ' ' '\n' | grep -cxF "$3")" || n=0
  [ "$n" -ge 3 ] || return 0
  echo "warn: notify.sh failed 3× for $3 (exit $rc) — the dialog waits in $2"
  printf '%s\n' "$3" > "$f"
}

# dialog_watch <role> <attempt> → 0 while the stage's own session is at a startup dialog. The lead's
# dialog is reported the same way but holds no stage clock (the stage runs on its own).
dialog_watch() {
  local n
  if team_lead_on; then
    n="$(team_lead_json launch)"; dialog_tick lead "$(sess_name lead)" "dialog-lead-${n:-1}" || true
  fi
  dialog_tick "$1" "$(sess_name "$1")" "dialog-$(rp | tr / -)$1-$2"
}
