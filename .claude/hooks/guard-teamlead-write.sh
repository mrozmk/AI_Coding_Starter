#!/bin/bash
# PreToolUse(Edit|Write|NotebookEdit) guard — the per-run TeamLead writes only its own files under
# .agents/team/runs/<run>/ (gate findings, rework orders, digest, notes, opinions, acceptance brief,
# blind check, wrapup decision — also in a round dir r<n>/) and the Claude scratchpad. Verdicts, decisions, answers,
# markers and records in the same directory are written only by the scripts that own them.
#
# Problem it solves: the lead judges the team's work and must never change it. A deny rule cannot
# express "every path except one directory" (deny beats allow), so this hook confines the file
# tools. Registered only in the lead's materialised profile (team-lead.sh materialize).
#
# A session with TEAM_SESSION_ROLE=TeamLead in a team clone is always confined: when its identity
# is not current (teamlead.json missing, another run, another session) it is refused outright,
# never treated as an ordinary caller. Every other caller passes. Contract:
# .agents/reference/team-lead.md

[ "${TEAM_SESSION_ROLE:-}" = TeamLead ] || exit 0
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
# The global TeamLead runs in the main checkout with the same role value; it is not a run lead.
[ -f "$ROOT/.agents/team/team.json" ] || exit 0
refuse() { echo "$*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || refuse "TeamLead write guard needs jq — refused"
LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)"
cd "$ROOT" 2>/dev/null || refuse "TeamLead write guard: cannot enter $ROOT — refused"
{ . "$LIB/team-lib.sh" && . "$LIB/team-lead-lib.sh"; } 2>/dev/null \
  || refuse "TeamLead write guard: team-lib.sh or team-lead-lib.sh missing — refused"

PAYLOAD=$(cat)
case "$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null)" in
  Edit|Write|NotebookEdit) ;;
  *) exit 0 ;;
esac
SID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // ""' 2>/dev/null)
# An empty sid would skip the session comparison in team_lead_caller: fail closed.
[ -n "$SID" ] && team_lead_caller "$SID" \
  || refuse "TeamLead identity not current — restart the lead"

FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' \
  2>/dev/null)
[ -n "$FILE" ] || refuse "TeamLead write guard: no file path in the tool call — refused"
real() { python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
case "$FILE" in /*) ;; *) FILE="$ROOT/$FILE" ;; esac
P="$(real "$FILE")" || refuse "TeamLead write guard: cannot resolve $FILE — refused"
RUNS="$(real "$ROOT/.agents/team/runs/$(team_lead_json run)")"
SCRATCH="$(real "/private/tmp/claude-$(id -u)")"
case "$P" in "$SCRATCH"/*) exit 0 ;; esac
# An allowlist, so a new script-owned file is protected by default; same list as team_lead_bash.py OWN.
own='^(r[0-9]+/)?(gate-[a-z]+-[0-9]+\.md|rework-[0-9]+\.md|digest\.md|teamlead-notes\.md|opinion-[0-9]+\.md|acceptance-brief\.md|blind-check\.md|wrapup-decision-[0-9]+\.md)$'
case "$P" in
  "$RUNS"/*) [[ "${P#"$RUNS"/}" =~ $own ]] && exit 0
    refuse "TeamLead writes only its own notes and findings under runs/<run>/ — verdicts, decisions and answers are written by the scripts" ;;
esac
refuse "TeamLead writes only its own files under .agents/team/runs/<run>/ and the scratchpad"
