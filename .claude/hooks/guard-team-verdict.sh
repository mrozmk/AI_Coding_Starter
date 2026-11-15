#!/bin/bash
# PreToolUse(Bash) guard — in a team clone only this run's TeamLead session runs team-verdict.sh
# and team-answer.sh on an authority (--authority class|teamlead|operator), and changes the run's
# pending decisions (team-lead.sh decision open|answer|withdraw).
#
# Problem it solves: team-verdict.sh proves its caller with the role env and teamlead.json, and any
# stage session can prefix TEAM_SESSION_ROLE=TeamLead to its own command — the planner could
# approve the spec it is gated on. The hook payload's session_id is chosen by Claude Code, not by
# the command, and this hook runs with the session's real environment, so team_lead_caller with
# that id is an identity the stage cannot forge. Any invocation (bash, sh, an absolute path, an env
# prefix: the script name followed by a gate) is checked; every other command passes untouched.
# Outside a team clone it is a no-op. Contract: .agents/reference/team-lead.md §4

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ROOT/.agents/team/team.json" ] || exit 0
PAYLOAD=$(cat)
# Cheap pre-filter: this hook runs on every Bash call in a clone.
case "$PAYLOAD" in *team-verdict.sh*|*team-answer.sh*|*team-lead.sh*) ;; *) exit 0 ;; esac
refuse() { echo "$*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || refuse "verdict guard needs jq — refused"
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)
# Only an invocation — the script name followed by a gate — is checked, so git add, bash -n, cat or
# grep on the file pass (a team working on the starter itself touches it).
INVOKE='team-verdict\.sh["'"'"']?[[:space:]]+["'"'"']?(spec|plan|acceptance|decision|event)([^a-z]|$)'
# A sender call on an authority: the script name, later the option (plain stage use passes).
ANSWER='team-answer\.sh.*--authority'
DECIDE='team-lead\.sh["'"'"']?[[:space:]]+["'"'"']?decision["'"'"']?[[:space:]]+["'"'"']?(open|answer|withdraw)'
[[ "$CMD" =~ $INVOKE ]] || [[ "$CMD" =~ $ANSWER ]] || [[ "$CMD" =~ $DECIDE ]] || exit 0

LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)"
cd "$ROOT" 2>/dev/null || refuse "verdict guard: cannot enter $ROOT — refused"
{ . "$LIB/team-lib.sh" && . "$LIB/team-lead-lib.sh"; } 2>/dev/null \
  || refuse "verdict guard: team-lib.sh or team-lead-lib.sh missing — refused"
SID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // ""' 2>/dev/null)
# An empty sid would skip the session comparison in team_lead_caller: fail closed.
[ -n "$SID" ] && team_lead_caller "$SID" \
  || refuse "team-verdict.sh, team-answer.sh --authority and team-lead.sh decision are the per-run TeamLead's — this session is not it (refused)"
exit 0
