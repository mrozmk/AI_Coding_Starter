#!/bin/bash
# Stop hook: refuse to end a turn while this role's wake loop is not armed — re-arming is the
# harness's job, not the model's memory. Exits before any work unless TEAM_SESSION_ROLE is a
# session role; silent on every allow path; no network, no lock. Always exits 0.

in="$(cat)"
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ ! -f "$ROOT/.agents/team/team.json" ] || exit 0
role="${TEAM_SESSION_ROLE:-}"
[ -n "$role" ] && [ -f "$ROOT/.claude/lib/team-watch-route.sh" ] || exit 0
. "$ROOT/.claude/lib/team-watch-route.sh"
tw_session_role_ok "$role" || exit 0
! jq -e '.stop_hook_active == true' <<<"$in" >/dev/null 2>&1 || exit 0
armed() { (cd "$ROOT" && bash .claude/lib/monitoring.sh armed "$role") >/dev/null 2>&1; }
armed && exit 0
# A loop started with run_in_background in this same turn may not have written its pidfile yet.
sleep 2
armed && exit 0
r="Wake loop of role $role is not armed. Start it in the background (Bash,"
r="$r run_in_background: true): bash .claude/lib/session-wake.sh — then end the turn."
jq -n --arg r "$r" '{decision: "block", reason: $r}'
exit 0
