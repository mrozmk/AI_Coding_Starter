#!/bin/bash
# PreToolUse(Bash) guard — the per-run TeamLead neither writes the files the scripts own nor
# presses a key in a session.
#
# Problem it solves: guard-teamlead-write.sh confines the file tools, but a Bash redirect reaches
# the same verdict, decision and answer files, and a key sent into a stage window would answer a
# human-only prompt that only the Operator may answer there. The rules are in team_lead_bash.py.
# Registered only in the lead's materialised profile (team-lead.sh materialize), beside the write
# guard. Best effort on command text — the limits are in .agents/reference/team-lead.md §7.
#
# Identity as in the write guard: TEAM_SESSION_ROLE=TeamLead in a team clone is always checked and
# an identity that is not current is refused; every other caller passes.

[ "${TEAM_SESSION_ROLE:-}" = TeamLead ] || exit 0
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ROOT/.agents/team/team.json" ] || exit 0
refuse() { echo "$*" >&2; [ -f "$(dirname "$0")/../lib/touches.sh" ] && bash "$(dirname "$0")/../lib/touches.sh" block --source guard-teamlead-bash --what "$*" >/dev/null 2>&1; exit 2; }
command -v jq >/dev/null 2>&1 || refuse "TeamLead Bash guard needs jq — refused"
LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)"
cd "$ROOT" 2>/dev/null || refuse "TeamLead Bash guard: cannot enter $ROOT — refused"
{ . "$LIB/team-lib.sh" && . "$LIB/team-lead-lib.sh"; } 2>/dev/null \
  || refuse "TeamLead Bash guard: team-lib.sh or team-lead-lib.sh missing — refused"

PAYLOAD=$(cat)
[ "$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null)" = Bash ] || exit 0
SID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // ""' 2>/dev/null)
[ -n "$SID" ] && team_lead_caller "$SID" || refuse "TeamLead identity not current — restart the lead"
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -n "$CMD" ] || exit 0
# The guard trusts the checkout it runs from: registered from the main checkout (materialize) its
# own checkout is the main one and the owning scripts are main's; registered from the clone (an
# older profile) it keeps the clone's scripts (--trust clone) until the profile is re-materialised.
OWN="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd -P)" || refuse "TeamLead Bash guard: cannot resolve its checkout — refused"
PROOT="$(pwd -P)"
MR="$(team_lead_json main_root)"
if [ "$OWN" != "$PROOT" ]; then
  if [ -n "$MR" ] && [ "$( (cd "$MR" 2>/dev/null && pwd -P) || echo "$MR")" != "$OWN" ]; then
    refuse "TeamLead identity: main_root differs from the guard's checkout — the profile and the main checkout disagree; the Operator re-materialises it from the main checkout: bash .claude/lib/team-run.sh <team> stop, then bash .claude/lib/team-lead.sh end <team>, then /start-team <team> (never team-lead.sh relaunch on a live lead)"
  fi
  WHY=$(printf '%s' "$CMD" | python3 -I "$LIB/team_lead_bash.py" "$ROOT" "$(team_lead_json run)" "$OWN" 2>&1) \
    || refuse "${WHY:-TeamLead Bash guard: check failed — refused}"
else
  WHY=$(printf '%s' "$CMD" | python3 -I "$LIB/team_lead_bash.py" "$ROOT" "$(team_lead_json run)" \
    "$MR" --trust clone 2>&1) || refuse "${WHY:-TeamLead Bash guard: check failed — refused}"
fi
exit 0
