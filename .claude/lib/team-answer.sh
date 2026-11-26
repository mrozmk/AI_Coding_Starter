#!/usr/bin/env bash
# The per-run TeamLead answers an ask of its stage: runs/<run>/asks/a-<n>.json → a-<n>.answer.json,
# which the stage hook returns to Claude Code (team-ask.sh, .claude/hooks/team-ask-hook.sh).
#
# Usage: bash .claude/lib/team-answer.sh <team> a-<n> <form> --authority teamlead|operator|delegated
#          --why "<line>" [--decision <answered d-<n>.md>]
#   delegated: a decision the Supervisor answered under the Operator's mandate (team-mandate.sh);
#   recorded as `authority supervisor (delegated)`, never as the Operator's.
# Forms: --answers '<json: question text → label>' | --pick "<label>" | --text "<free text>"
#        | --allow | --deny "<what to do instead>"
#   question: --answers, --pick (a single-question ask; one of its labels), --text (free text)
#   permission, plan: --allow, --deny · text (a stop): --text
#   e.g. bash .claude/lib/team-answer.sh alfa a-3 --pick "Option A" --authority teamlead --why "the order says A"
# #322: an operator-tier permission ask whose tier cause starts `egress:` (never `refuse (egress
#   denied)`) and to which no decision is bound may be denied or reformulated by the lead itself:
#   --deny "<what to do instead>" --authority teamlead (checked and written under the run's ask
#   lock, recorded `authority teamlead`); its --allow stays the Operator's (9).
# Run from the team's clone (the lead's cwd): its .agents/team/team.json must name <team>.
# Exit: 0 written · 2 usage · 6 stale, replaced or already answered · 7 caller or decision rule
#   · 9 operator tier (open a decision: team-lead.sh decision open <team> --ask a-<n>).
set -euo pipefail

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 3 ] || usage
TEAM="$1"; ASK="$2"; shift 2
FORM=""; VALUE=""; AUTH=""; WHY=""; DECISION=""; DEC_ID=""; DEC_FILE=""
setform() { [ -z "$FORM" ] || { echo "error: one answer form only" >&2; exit 2; }; FORM="$1"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --allow) setform allow; shift; continue ;;
    --answers|--pick|--text|--deny|--authority|--why|--decision) [ $# -ge 2 ] || usage ;;
    *) usage ;;
  esac
  case "$1" in
    --answers) setform answers; VALUE="$2" ;; --pick) setform pick; VALUE="$2" ;;
    --text) setform text; VALUE="$2" ;; --deny) setform deny; VALUE="$2" ;;
    --authority) AUTH="$2" ;; --why) WHY="$2" ;; --decision) DECISION="$2" ;;
  esac
  shift 2
done
[[ "$TEAM" =~ ^[a-z0-9-]+$ ]] || { echo "error: bad team name $TEAM" >&2; exit 2; }
[[ "$ASK" =~ ^a-[0-9]+$ ]] || { echo "error: the ask id must be a-<n>" >&2; exit 2; }
[ -n "$FORM" ] || { echo "error: an answer form is required" >&2; exit 2; }
case "$FORM" in
  answers) jq -e 'type == "object" and length > 0 and all(.[]; type == "string" and length > 0)' \
    <<<"$VALUE" >/dev/null 2>&1 || { echo "error: --answers needs a JSON object of question → label" >&2; exit 2; } ;;
  pick|text) [ -n "$VALUE" ] || { echo "error: --$FORM needs a value" >&2; exit 2; } ;;
esac
LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-lib.sh"
. "$LIB/team-answer-lead.sh"
. "$LIB/team-ask.sh"
refuse() { local rc="$1"; shift; echo "error: $* — nothing written" >&2; exit "$rc"; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || refuse 7 "not in a team clone"
TD="$ROOT/.agents/team"
[ "$(jq -r '.team // empty' "$TD/team.json" 2>/dev/null)" = "$TEAM" ] \
  || refuse 7 "this checkout is not team $TEAM's clone — a TeamLead answers only its own team"
[ ! -e "$TD/cancel" ] || refuse 6 "team stopped"
auth_preflight
sj() { jq -r --arg f "$1" '.[$f] // empty | tostring' "$TD/session.json" 2>/dev/null || true; }
ask_init "$TD" || refuse 6 "no current run"
AF="$ASK_D/$ASK.json"
[ -f "$AF" ] || refuse 6 "no ask $ASK in runs/$ASK_RUN/asks/"
[ "$(ask_get "$ASK" session_id)" = "$(sj session_id)" ] && [ "$(ask_get "$ASK" attempt)" = "$(sj attempt)" ] \
  || refuse 6 "ask $ASK belongs to a replaced session"
case "$(ask_state "$ASK")" in
  delivered|delivering) refuse 6 "ask $ASK already answered and delivered" ;;
  withdrawn) refuse 6 "ask $ASK withdrawn — answer the newer ask" ;;
  answered) refuse 6 "ask $ASK already answered" ;;
esac
[ ! -e "$TD/closing" ] || refuse 6 "the run is closing"

KIND="$(ask_get "$ASK" kind)"; TIER="$(ask_get "$ASK" tier)"; REQ="$(ask_get "$ASK" requires_decision)"
case "$TIER" in class|lead|operator) ;; *) refuse 6 "ask $ASK is not classified" ;; esac
# #322: the lead's own deny of an unbound egress permission ask (re-checked under the lock below).
EGRESS_DENY=""
case "$(ask_get "$ASK" tier_cause)" in "egress: "*)
  [ "$TIER" = operator ] && [ "$AUTH" = teamlead ] && [ "$FORM" = deny ] && [ "$KIND" = permission ] \
    && [ -z "$REQ" ] && [ -z "$DEC_ID" ] && EGRESS_DENY=1 ;;
esac
# bound_decision → the id of a decision bound to this ask and not withdrawn, or nothing.
bound_decision() {
  local v
  for v in "$ASK_TD/runs/$ASK_RUN/decisions"/d-*.md; do
    [ -f "$v" ] || continue
    sed -n '/^---$/,/^---$/p' "$v" | grep -qx "bind_ask: $ASK" || continue
    sed -n '/^---$/,/^---$/p' "$v" | grep -qx "status: withdrawn" && continue
    basename "$v" .md; return 0
  done
}
if [ -z "$EGRESS_DENY" ] && { [ "$TIER" = operator ] || [ -n "$REQ" ]; }; then
  [ "$AUTH" != teamlead ] && [ -n "$DEC_ID" ] \
    || refuse 9 "ask $ASK is the Operator's${REQ:+ (decision $REQ)} — open a decision: team-lead.sh decision open $TEAM --ask $ASK"
  [ -z "$REQ" ] || [ "$REQ" = "$DEC_ID" ] || refuse 7 "ask $ASK waits for decision $REQ, not $DEC_ID"
fi

# The form must fit the ask's kind and payload.
case "$KIND:$FORM" in
  question:answers)
    jq -e --argjson a "$VALUE" '[.payload.tool_input.questions[].question] | sort == ($a | keys | sort)' \
      "$AF" >/dev/null 2>&1 || refuse 7 "--answers keys must be exactly the asked question texts" ;;
  question:pick)
    jq -e --arg v "$VALUE" '(.payload.tool_input.questions | length) == 1
      and any(.payload.tool_input.questions[0].options[]; .label == $v)' "$AF" >/dev/null 2>&1 \
      || refuse 7 "--pick needs one of the labels of a single-question ask" ;;
  question:text|permission:allow|permission:deny|plan:allow|plan:deny|text:text) ;;
  *) refuse 7 "--$FORM does not answer a $KIND ask" ;;
esac

# An Operator decision is relayed, never reworded: the form equals the decision's stored answer.
if [ -n "$DEC_ID" ]; then
  case "$FORM" in
    allow|deny) [ "$(auth_fm "$DEC_FILE" answer_outcome)" = "$FORM" ] \
      || refuse 7 "decision $DEC_ID reads ${DEC_ID} $(auth_fm "$DEC_FILE" answer_outcome), not --$FORM" ;;
  esac
  case "$FORM" in
    answers) [ "$(jq -cS . <<<"$(auth_fm "$DEC_FILE" answer_map)" 2>/dev/null)" = "$(jq -cS . <<<"$VALUE")" ] \
      || refuse 7 "--answers differs from decision $DEC_ID's answer" ;;
    pick|text|deny) [ "$(auth_fm "$DEC_FILE" answer_value)" = "$VALUE" ] \
      || refuse 7 "the value differs from decision $DEC_ID's answer" ;;
  esac
fi

if [ "$FORM" = answers ]; then V="$(jq -c . <<<"$VALUE")"; else V="$(jq -n --arg v "$VALUE" '$v')"; fi
# The answer file and the answers.md line name a delegated answer in full, apart from the Operator's.
[ "$AUTH" != delegated ] || AUTH="supervisor (delegated)"
ANSWER="$(jq -n --arg id "$ASK" --arg form "$FORM" --argjson v "$V" --arg auth "$AUTH" --arg why "$WHY" \
  --arg dec "$DEC_ID" --arg at "$(team_utc)" --arg lsid "$(jq -r '.session_id // ""' "$TD/teamlead.json")" \
  '{id: $id, form: $form, value: $v, authority: $auth, why: $why, decision: $dec, answered_at: $at,
    lead_session_id: $lsid}')"
rc=0
if [ -n "$EGRESS_DENY" ]; then
  # One locked section with decision open --ask: the ask still open, no decision bound, the write.
  ask_lock || refuse 6 "cannot take the ask lock of run $ASK_RUN"
  ask_reconcile "$ASK"; st="$(ask_get "$ASK" state)"
  case "$st" in waiting|timed-out) ;; *) ask_unlock; refuse 6 "ask $ASK is $st, not open" ;; esac
  bd="$(bound_decision)"
  [ -z "$bd" ] || { ask_unlock; refuse 9 "ask $ASK is bound to decision $bd — the Operator answers it"; }
  ask_answer_write "$ASK" "$ANSWER" || rc=$?
  ask_unlock
else
  ask_answer_write "$ASK" "$ANSWER" || rc=$?
fi
[ "$rc" = 0 ] || refuse 6 "ask $ASK already answered"
ask_cas "$ASK" "waiting timed-out" answered || true
auth_dispatch
# The answers.md line and a record's .answered marker (the runner re-derives the same after an
# interrupted sender).
ask_follow_up "$ASK"
echo "answered: $ASK ($FORM) — the stage hook returns it${DEC_ID:+ [decision $DEC_ID]}"
