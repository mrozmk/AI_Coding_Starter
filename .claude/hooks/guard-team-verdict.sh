#!/bin/bash
# PreToolUse(Bash) guard with two rules for a team clone.
#
# 1. Trunk writers — in a role session (.agents/team/session.json exists) a command naming
# team-merge-check.sh, team-integrate.sh, team-integrate-lock.sh, team-automerge-check.sh or
# team-starter-land.sh is refused, whatever the ask rules and workflow.team_merge say: under team_merge=auto the roles lose
# the prompt, and the scripts check only that the *target* team is idle, never the caller. The rule
# is a fail-closed allowlist: when a command names one, every segment of it must be a non-executing
# form (the INSPECT and SYNTAX regexes below) with no $( or backtick and no prefix — a segment without the name
# could run the script piped to it (cat X | bash). Best effort: a path in a variable or a renamed
# copy never shows the name. The main checkout and a clone between stages pass untouched.
#
# 2. Verdicts — only this run's TeamLead session runs team-verdict.sh and team-answer.sh (an ask
# answer, --authority teamlead|operator), and changes the run's pending decisions (team-lead.sh
# decision open|answer|withdraw). 3. The ask channel — a command naming runs/<run>/asks/ or
# decisions/ is the lead's too; a stage may only run `bash <abs>/.claude/lib/team-ask.sh wait a-<n>`.
#
# Problem rule 2 solves: team-verdict.sh proves its caller with the role env and teamlead.json, and any
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
case "$PAYLOAD" in
  *team-verdict.sh*|*team-answer.sh*|*team-lead.sh*|*asks*|*decisions*) ;;
  *team-merge-check.sh*|*team-integrate*|*team-automerge-check.sh*|*team-starter-land.sh*) ;;
  *) exit 0 ;;
esac
refuse() { echo "$*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || refuse "verdict guard needs jq — refused"
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)

TRUNK='team-(merge-check|integrate|integrate-lock|automerge-check|starter-land)\.sh'
if [ -f "$ROOT/.agents/team/session.json" ] && [[ "$CMD" =~ $TRUNK ]]; then
  TRUNK_MSG="team-merge-check.sh, team-integrate.sh, team-integrate-lock.sh, team-automerge-check.sh and team-starter-land.sh are the Supervisor's — run them from the main checkout, never from a role session (refused)"
  # INSPECT is matched on the segment with quoted spans masked (no git grep: -O runs a pager command).
  # SYNTAX on the raw segment: bash|sh -n takes plain path operands only — a quote, $, \, glob or
  # brace could turn one into +n / -c.
  INSPECT='^[[:space:]]*(git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(add|diff|show|log|status|ls-files|blame|commit|rm|mv)([[:space:]]|$)|(cat|head|tail|grep|wc|ls|diff|shellcheck)([[:space:]]|$))'
  SYNTAX='^[[:space:]]*(bash|sh)[[:space:]]+-n([[:space:]]+[[:alnum:]_./][[:alnum:]_./@%:,=+-]*)+[[:space:]]*$'
  { . "$(dirname "$0")/lib/git-segments.sh" && command -v git_segments >/dev/null; } 2>/dev/null \
    || refuse "$TRUNK_MSG — git-segments.sh missing"
  while IFS= read -r seg; do
    case "$seg" in *'$('*|*'`'*) refuse "$TRUNK_MSG" ;; esac
    masked=$(printf '%s' "$seg" | sed -E "s/'[^']*'/Q/g; s/\"([^\"\\\\]|\\\\.)*\"/Q/g")
    [[ "$masked" =~ $INSPECT ]] || [[ "$seg" =~ $SYNTAX ]] || refuse "$TRUNK_MSG"
  done <<EOF_TRUNK
$(git_segments "$CMD")
EOF_TRUNK
fi

# Only an invocation — the script name followed by a gate — is checked, so git add, bash -n, cat or
# grep on the file pass (a team working on the starter itself touches it).
INVOKE='team-verdict\.sh["'"'"']?[[:space:]]+["'"'"']?(spec|plan|acceptance|decision|event|wrapup|run)([^a-z]|$)'
# A sender call on an authority or an ask: the script name, later the option or the ask id.
ANSWER='team-answer\.sh.*(--authority|[[:space:]]a-[0-9])'
DECIDE='team-lead\.sh["'"'"']?[[:space:]]+["'"'"']?decision["'"'"']?[[:space:]]+["'"'"']?(open|answer|withdraw)'
# 3. The ask channel's files — a command naming runs/<run>/asks/ or decisions/ (relative, ./ or
# absolute) is the lead's; a stage only waits on its ask with the main checkout's team-ask.sh.
ASKS='(^|[^[:alnum:]_.-])(\./)?(\.agents/team/runs/|[^[:space:]]*/\.agents/team/runs/)[^[:space:]]*/(asks|decisions)(/|[[:space:]]|$)'
WAITF='^[[:space:]]*bash[[:space:]]+/[^[:space:]]*/\.claude/lib/team-ask\.sh[[:space:]]+wait[[:space:]]+a-[0-9]+([[:space:]]+--secs[[:space:]]+[0-9]+)?[[:space:]]*$'
ASKCMD=""
[[ "$CMD" =~ $ASKS ]] && ! [[ "$CMD" =~ $WAITF ]] && ASKCMD=1
[ -n "$ASKCMD" ] || [[ "$CMD" =~ $INVOKE ]] || [[ "$CMD" =~ $ANSWER ]] || [[ "$CMD" =~ $DECIDE ]] || exit 0

LIB="$(cd "$(dirname "$0")/../lib" 2>/dev/null && pwd)"
cd "$ROOT" 2>/dev/null || refuse "verdict guard: cannot enter $ROOT — refused"
{ . "$LIB/team-lib.sh" && . "$LIB/team-lead-lib.sh"; } 2>/dev/null \
  || refuse "verdict guard: team-lib.sh or team-lead-lib.sh missing — refused"
SID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // ""' 2>/dev/null)
# An empty sid would skip the session comparison in team_lead_caller: fail closed.
[ -n "$SID" ] && team_lead_caller "$SID" \
  || refuse "team-verdict.sh, team-answer.sh, team-lead.sh decision and the runs/<run>/asks/ and decisions/ files are the per-run TeamLead's — this session is not it (refused)"
exit 0
