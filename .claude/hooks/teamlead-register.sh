#!/bin/bash
# SessionStart hook — the per-run TeamLead's identity refresh, socket registration and work list.
#
# After startup, resume, /clear or compact: when this is the lead of the clone's current run, keep
# teamlead.json on the live session id (/clear issues a new one), write teamlead.reg.json (0600:
# the messaging socket and token the runner's doorbell uses) and print the lead's pending list
# (plain stdout enters the context). Only the lead's own claude may move the id: its pid equals
# the registered pid, or the lead's tmux pane owns this process. Silent for every other session.
# Always exits 0. Contract: .agents/reference/team-lead.md

IN="$(cat 2>/dev/null)"
[ "${TEAM_SESSION_ROLE:-}" = TeamLead ] || exit 0
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ROOT/.agents/team/team.json" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)" || exit 0
cd "$ROOT" 2>/dev/null || exit 0
{ . "$LIB/team-lib.sh" && . "$LIB/team-lead-lib.sh"; } 2>/dev/null || exit 0
TD="$ROOT/.agents/team"
sid="$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null)"
[[ "$sid" =~ ^[A-Za-z0-9-]{8,64}$ ]] || exit 0
run="$(cat "$TD/run" 2>/dev/null)"
[ -n "$run" ] && [ "$(team_lead_json run)" = "$run" ] || exit 0
team="$(jq -r '.team // empty' "$TD/team.json" 2>/dev/null)"

ancestors() {  # this process and its parents, one pid per line
  local p=$$ i=0
  while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ] && [ "$i" -lt 30 ]; do
    echo "$p"; p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; i=$((i + 1))
  done
}
A="$(ancestors)"
is_anc() { [ -n "$1" ] && printf '%s\n' "$A" | grep -qx "$1"; }
claude_pid=""
for p in $A; do
  case "$(basename "$(ps -o comm= -p "$p" 2>/dev/null)")" in claude*) claude_pid="$p"; break ;; esac
done
reg_pid="$(jq -r '.pid // empty' "$TD/teamlead.reg.json" 2>/dev/null)"
pane_pid="$(sh_pid "$(team_sess "$(team_tmux_name "$team" lead)")" 2>/dev/null)"
if is_anc "$reg_pid" || { [[ "$pane_pid" =~ ^[0-9]+$ ]] && is_anc "$pane_pid"; }; then
  jq --arg s "$sid" '.session_id = $s' "$TD/teamlead.json" > "$TD/teamlead.json.tmp.$$" 2>/dev/null \
    && mv "$TD/teamlead.json.tmp.$$" "$TD/teamlead.json"
  rm -f "$TD/teamlead.json.tmp.$$"
fi
team_lead_caller "$sid" || exit 0

if [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ]; then
  ( umask 077
    jq -n --arg pid "$claude_pid" --arg sid "$sid" --arg at "$(team_utc)" '
      {socket: env.CLAUDE_CODE_MESSAGING_SOCKET, token: env.CLAUDE_CODE_MESSAGING_TOKEN,
       pid: (if $pid == "" then null else ($pid | tonumber) end), session_id: $sid,
       registered_at: $at}' > "$TD/teamlead.reg.json.tmp.$$" \
      && mv "$TD/teamlead.reg.json.tmp.$$" "$TD/teamlead.reg.json" ) 2>/dev/null
  rm -f "$TD/teamlead.reg.json.tmp.$$"
fi
echo "TeamLead of $team, run $run. Pending (oldest first; the files are the truth):"
p="$(bash "$LIB/team-lead.sh" pending "$team" 2>/dev/null)"
printf '%s\n' "${p:-none}"
exit 0
