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
  # The driver's graceful kill (session-host-lib.sh sh_kill): the same lock, log and messages; the
  # lock role is the address's role, which every caller passes as <lock role>.
  sh_kill "$2" --team-dir "$1" --owner "runner pid=$$" --graceful "$4"
}

# team_session_doorbell <team dir> <role> <one line> — wake a role session. First Claude's
# messaging socket from the session's own registration (draft- and dialog-safe); else send-keys
# on an idle empty input under the send lock; else skip and log. Pending work is derived from
# files, so a lost doorbell only delays. Always returns 0.
team_session_doorbell() {
  local td="$1" role="$2" name
  name="$(team_tmux_name "$(jq -r '.team // empty' "$td/team.json" 2>/dev/null)" "$role")"
  # The driver's doorbell (sh_send): socket → idle input under the send lock → skip and log.
  sh_send "$name" "$3" --team-dir "$td" >/dev/null 2>&1 || true
  return 0
}

# team_lead_trusted <main> <clone> <run> [session id] → "<session id>\t<config dir>" of a lead
# session of <run> recorded by the runner in the main checkout's anchor (found by the clone's
# physical path, never by a clone-written name); no id → the anchor's current_id. rc 1 otherwise.
team_lead_trusted() {
  local phys anc="" x sess
  phys="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  for x in "$1"/.agents/team/anchors/*.json; do
    [ -f "$x" ] && [ "$(jq -r '.clone // ""' "$x" 2>/dev/null)" = "$phys" ] || continue
    [ -z "$anc" ] || return 1; anc="$x"
  done
  # A run launched by a runner from before lead_sessions (no anchor here, or another run):
  # today's evidence — the clone's teamlead.json, marked legacy (no answered_session written).
  if [ -z "$anc" ] || ! jq -e --arg r "$3" '.lead_sessions.run == $r' "$anc" >/dev/null 2>&1; then
    jq -er '"\(.session_id)\t\(.claude_config_dir // "")\tlegacy"' "$2/.agents/team/teamlead.json" 2>/dev/null
    return
  fi
  sess="${4:-$(jq -r '.lead_sessions.current_id // ""' "$anc")}"
  jq -er --arg s "$sess" 'select(.lead_sessions.ids | index($s)) | "\($s)\t\(.lead_sessions.config_dir // "")"' "$anc"
}

# team_anchor_team <main> <clone> → "<team>\t<run>" of the one anchor in the main checkout whose
# clone is this clone's physical path (<run>: the anchor's active run); rc 1 on none or several.
team_anchor_team() {
  local phys anc="" x
  phys="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  for x in "$1"/.agents/team/anchors/*.json; do
    [ -f "$x" ] && [ "$(jq -r '.clone // ""' "$x" 2>/dev/null)" = "$phys" ] || continue
    [ -z "$anc" ] || return 1; anc="$x"
  done
  [ -n "$anc" ] || return 1
  # .run is set at a stage launch; before the mode choice only the lead's launch named the run.
  jq -er 'select((.team // "") != "") | "\(.team)\t\(if (.run // "") != "" then .run else (.lead_sessions.run // "") end)"' "$anc" 2>/dev/null
}

# team_supervisor_home <main> → the Claude config dir of the Supervisor's transcript: the declared
# .claude/claude-profile, else ~/.claude — never the caller's CLAUDE_CONFIG_DIR. rc 1: unresolvable.
team_supervisor_home() {
  local c; c="$(CLAUDE_CONFIG_DIR="" team_claude_home "$1")" || return 1
  printf '%s\n' "${c:-$HOME/.claude}"
}

# team_run_floor <run id> [<created_at>] → the later of <created_at> and the run's start
# (YYYY-MM-DDTHH:MM:SSZ, from <team>-<YYYYMMDD>-<HHMMSS>); either alone when the other is empty or
# the id carries no such suffix — the relay's evidence floor, for the writer and the hook alike.
team_run_floor() {
  local f="${2:-}" rf=""
  if [[ "$1" =~ -([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
    rf="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}T${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}Z"
  fi
  [[ ! "$rf" > "$f" ]] || f="$rf"
  [ -z "$f" ] || printf '%s\n' "$f"
}

# team_relay_pins <ledger> <team> <run> <d-n> <ask> [<uuid>] — the relay ledger pins this team, run,
# decision and ask (and this uuid when given); the relay writer and the stage hook share it.
team_relay_pins() {
  jq -e --arg t "$2" --arg r "$3" --arg d "$4" --arg a "$5" --arg u "${6:-}" \
    '.team == $t and .run == $r and .decision == $d and .ask == $a and ($u == "" or .uuid == $u)' \
    "$1" >/dev/null 2>&1
}

# team_delegate_args <team> <d-n> <run> <ask> <attempt> <stage session> <request digest> <text>
# <mandate id> <class> — the canonical argument text of the Supervisor's delegated answer
# (`team-lead.sh decision answer … --delegated`), up to the opening of --why: what its own tool
# call must read, binding the run, the decision, the ask, the stage's attempt and session, the
# request, the mandate it answers under (m-<uuid of the Operator's message>), the class and the
# reply. One spelling
# for the inbox message, the writer and the stage hook's re-check.
team_delegate_args() {
  printf 'decision answer %s %s --delegated --run %s --ask %s --attempt %s --session %s --request %s --mandate %s --class %s --text "%s" --why "' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$9" "${10}" "$8"
}

# team_lead_shell_word <path> — the path as the lead types it and as its permission rules spell it:
# single-quoted when it holds a character a word would split on; rc 1 on an embedded quote.
team_lead_shell_word() {
  case "$1" in
    *"'"*) return 1 ;;
    *[!A-Za-z0-9._/+@-]*) printf "'%s'" "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# team_lead_lib_prefix <main> — the main checkout's .claude/lib/ as a shell word.
team_lead_lib_prefix() { team_lead_shell_word "$1/.claude/lib/"; }
