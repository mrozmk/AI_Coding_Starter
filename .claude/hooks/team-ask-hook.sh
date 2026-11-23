#!/usr/bin/env bash
# Stage hook of a run with a per-run TeamLead: hands every blocking stop to the ask channel
# (runs/<run>/asks/, .claude/lib/team-ask.sh) and returns the lead's answer as hook JSON.
# Registered by the runner's materialised .agents/team/stage-hooks.settings.json (template
# .claude/team/stage-hooks.json), invoked by absolute path from the MAIN checkout with
# $CLAUDE_PROJECT_DIR = the clone, so a ticket that edits this file cannot change its own run.
#   PreToolUse AskUserQuestion → question · PreToolUse ExitPlanMode → plan ·
#   PermissionRequest → permission (stage and sub-agent) · Stop → text (a blocked record or a
#   plain-text stop) · PreToolUse Edit|Write|NotebookEdit → the asks/ and decisions/ write guard.
# The ask branches fail open (exit 0, no output: the normal prompt shows); the write guard fails
# closed (exit 2, registered with onFailure: block). TEAM_ASK_TIMEOUT = the registration's timeout;
# the hook answers by its own deadline 15 s before it.
# Bash 3.2 + jq. Contract: .agents/reference/team-lead.md §6
set -o pipefail
ENTRY=$(date +%s)
TIMEOUT="${TEAM_ASK_TIMEOUT:-600}"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || TIMEOUT=600
DEADLINE=$((ENTRY + TIMEOUT - 15))
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN="$(cd "$HOOK_DIR/../.." && pwd)"
CLONE="${CLAUDE_PROJECT_DIR:-$PWD}"
TD="$CLONE/.agents/team"

[ -f "$TD/session.json" ] || exit 0
PAYLOAD="$(cat)"

# --- the write guard (fail closed) -----------------------------------------------------------
guard_refuse() { echo "team ask write guard: $1" >&2; exit 2; }
if ! command -v jq >/dev/null 2>&1; then
  case "$PAYLOAD" in *'"PreToolUse"'*'"Edit"'*|*'"PreToolUse"'*'"Write"'*|*'"PreToolUse"'*'"NotebookEdit"'*)
    guard_refuse "jq missing — refused" ;; esac
  exit 0
fi
EV="$(jq -r '.hook_event_name // ""' <<<"$PAYLOAD" 2>/dev/null)"
TOOL="$(jq -r '.tool_name // ""' <<<"$PAYLOAD" 2>/dev/null)"
if [ "$EV" = PreToolUse ]; then
  case "$TOOL" in Edit|Write|NotebookEdit)
    FILE="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"$PAYLOAD" 2>/dev/null)"
    [ -n "$FILE" ] || guard_refuse "no file path in the tool call — refused"
    case "$FILE" in /*) ;; *) FILE="$CLONE/$FILE" ;; esac
    real() { python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
    P="$(real "$FILE")" && [ -n "$P" ] || guard_refuse "cannot resolve $FILE — refused"
    RUNS="$(real "$TD/runs")" || guard_refuse "cannot resolve the runs dir — refused"
    # Case-folded: on a case-insensitive volume `RUNS/x/ASKS` is the same directory.
    P="$(tr '[:upper:]' '[:lower:]' <<<"$P")"; RUNS="$(tr '[:upper:]' '[:lower:]' <<<"$RUNS")"
    case "$P" in "$RUNS"/*/asks|"$RUNS"/*/asks/*|"$RUNS"/*/decisions|"$RUNS"/*/decisions/*)
      jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
        permissionDecisionReason: "asks/ and decisions/ are written by the hook and the TeamLead'"'"'s scripts only"}}'
      exit 0 ;;
    esac
    # The Supervisor's relay ledger (team-lead-decision.sh decision relay), wherever it is reached from.
    case "$P" in */.agents/team/relays|*/.agents/team/relays/*)
      jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
        permissionDecisionReason: "the relay ledger is written by the Supervisor'"'"'s decision relay only"}}'
      exit 0 ;;
    esac
    exit 0 ;;
  esac
fi

# --- the ask branches (fail open) ------------------------------------------------------------
cd "$CLONE" 2>/dev/null || exit 0
LIB="$MAIN/.claude/lib"
. "$LIB/team-lib.sh" >/dev/null 2>&1 || exit 0
. "$LIB/team-lead-lib.sh" >/dev/null 2>&1 || exit 0
. "$LIB/team-ask.sh" || exit 0
sj() { jq -r --arg f "$1" '.[$f] // empty | tostring' "$TD/session.json" 2>/dev/null; }
SID="$(jq -r '.session_id // ""' <<<"$PAYLOAD")"
team_lead_caller "$SID" 2>/dev/null && exit 0
RUN="$(sj run)"; ROLE="$(sj role)"; ATTEMPT="$(sj attempt)"; ROUND="$(sj round)"; STAGE_SID="$(sj session_id)"
[ -n "$RUN" ] && [ -n "$ROLE" ] || exit 0
[ "$(jq -r '.run // empty' "$TD/teamlead.json" 2>/dev/null)" = "$RUN" ] || exit 0
ask_init "$TD" || exit 0
mkdir -p "$ASK_D" 2>/dev/null || exit 0
export ASK_PID=$$
TMP="$ASK_D/.hook-$$"
trap 'rm -f "$TMP".*' EXIT

stopped() { [ -e "$TD/cancel" ] || [ -e "$TD/closing" ]; }
STOP_MSG="the team was stopped — write nothing more"

out_pre_deny() { jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse",
  permissionDecision: "deny", permissionDecisionReason: $r}}'; }
out_perm_deny() { jq -n --arg m "$1" '{hookSpecificOutput: {hookEventName: "PermissionRequest",
  decision: {behavior: "deny", message: $m}}}'; }
out_block() { jq -n --arg r "$1" '{decision: "block", reason: $r}'; }
out_refuse() {  # out_refuse <reason> — the deny/block form of this event
  case "$EV" in PreToolUse) out_pre_deny "$1" ;; PermissionRequest) out_perm_deny "$1" ;;
    Stop) out_block "$1" ;; esac
}

# fallback <id> [state] — the deadline answer of each event (the ask stays open for a retry or a
# wait). state (PermissionRequest only, passed by wait_and_answer, never re-read): ask_timeout's
# result `timed-out` | `withdrawn`; anything else (`unclaimed` after a failed delivery claim, or
# empty when ask_timeout failed) gets a neutral deny that asserts no state. An Operator-tier ask
# is never told to retry now: no lead can answer it and an unattended run would loop (#238).
# Tier and cause: the ones handle() computed for this very call (dynamic scope: its locals `tier`
# and `cause`), the ask file only as a fallback — a failed read must never turn an Operator deny
# into a "retry" (an empty tier would match the lead arms).
fallback() {
  local st="${2:-}" t c stop
  case "$EV" in
    PreToolUse) out_pre_deny "No answer from the TeamLead yet (ask $1 is still open). Ask again with the same input — the answer will be waiting." ;;
    PermissionRequest)
      if stopped; then out_refuse "$STOP_MSG"; return 0; fi
      t="${tier:-}"; [ -n "$t" ] || t="$(ask_get "$1" tier)"
      c="${cause:-}"; [ -n "$c" ] || c="$(ask_get "$1" tier_cause)"; c="${c:+ ($c)}"
      stop="Go on with work that does not depend on it; if your work cannot finish without it, take your own stop path naming $1 (coder, QA, CLI: a \`blocked\` record; planner: ask the TeamLead; a review finder: \`STATUS: failed\`; any other caller: end the turn with a plain-text stop naming $1 and the blocked operation)."
      case "$t:$st" in
        operator:timed-out)
          out_perm_deny "No Operator answer reached ask $1$c before the deadline; it stays open. Do not retry this same command now. $stop Once the answer is relayed to ask $1, a later identical retry from this same session can collect it while the files it names are unchanged and no other open ask matches it." ;;
        operator:withdrawn)
          out_perm_deny "No Operator answer reached ask $1$c before the deadline; the ask is withdrawn. Do not retry this same command — an Operator-tier request is not asked again in a loop. $stop" ;;
        operator:*)
          out_perm_deny "No Operator answer reached this call for ask $1$c. Do not retry this same command now. $stop" ;;
        *:withdrawn)
          out_perm_deny "No answer from the TeamLead yet (ask $1, withdrawn). Retry the same tool call to ask the TeamLead again." ;;
        *)
          out_perm_deny "No answer from the TeamLead reached this call (ask $1). Retry the same tool call to ask the TeamLead again." ;;
      esac ;;
    Stop) out_block "No answer from the TeamLead yet (ask $1). Run \`bash $LIB/team-ask.sh wait $1\` (waits up to 9 min) and follow the answer it prints; repeat while it says pending." ;;
  esac
}

# verify_operator <id> <answer json> — an Operator-authorised answer is re-checked here, from
# main-checkout code: the decision is bound to this ask, answered by the Operator (terminal, or a
# typed `d-<n> …` message in the lead's own transcript) with this very answer.
verify_operator() {
  local id="$1" a="$2" did f via uuid t form val msg p x
  did="$(jq -r '.decision // ""' <<<"$a")"
  [[ "$did" =~ ^d-[0-9]+$ ]] || return 1
  f="$ASK_TD/runs/$ASK_RUN/decisions/$did.md"
  [ -f "$f" ] || return 1
  dfm_h() { sed -n '/^---$/,/^---$/p' "$f" | sed -n "s/^$1: *//p" | head -n 1; }
  [ "$(dfm_h bind_ask)" = "$id" ] || return 1
  case "$(dfm_h status)" in answered|dispatched) ;; *) return 1 ;; esac
  form="$(jq -r .form <<<"$a")"; val="$(jq -r '.value // "" | if type == "string" then . else tojson end' <<<"$a")"
  case "$form" in
    allow|deny) [ "$(dfm_h answer_outcome)" = "$form" ] || return 1 ;;
    answers) [ "$(jq -cS . <<<"$(dfm_h answer_map)" 2>/dev/null)" = "$(jq -cS .value <<<"$a")" ] || return 1 ;;
    *) [ "$(dfm_h answer_value)" = "$val" ] || return 1 ;;
  esac
  case "$form" in deny) [ -z "$val" ] || [ "$(dfm_h answer_value)" = "$val" ] || return 1 ;; esac
  via="$(dfm_h answered_via)"
  case "$via" in
    terminal) return 0 ;;  # the same-uid limit of team-lead.md §7: not re-verifiable from a file
    "teamlead-window "*) uuid="${via#teamlead-window }" ;;
    "supervisor-window "*) verify_relay "$id" "$did" "${via#supervisor-window }" "$form" "$val" "$a"; return ;;
    *) return 1 ;;
  esac
  # The lead session and its config dir from the main checkout's anchor (the runner's lead_sessions),
  # never from the clone's teamlead.json; no answered_session (an older decision) → current_id.
  x="$(team_lead_trusted "$MAIN" "$CLONE" "$RUN" "$(dfm_h answered_session)")" || return 1
  # The clone path as team-lead-decision.sh d_evidence derives it (the git top level).
  t="$(team_role_transcript "$(git -C "$CLONE" rev-parse --show-toplevel 2>/dev/null || echo "$CLONE")" \
    "$(cut -f1 <<<"$x")" "$(cut -f2 <<<"$x")")"
  [ -f "$t" ] || return 1
  # The message must be eligible as the writer's evidence was: typed after the decision opened.
  msg="$(msg_at "$t" "$uuid" "$(dfm_h created_at)")" || return 1
  reply_matches "$id" "$did" "$msg" "$form" "$val" "$a"
}

# msg_at <transcript> <uuid> <since> → that typed user message, left-trimmed ("" when not eligible).
msg_at() {
  jq -r -s --arg u "$2" --arg since "$3" '
    map(select(.uuid == $u and .type == "user" and ((.isMeta // false) | not)
        and ((.timestamp // "") >= $since)))
    | map(.message.content | if type == "string" then . elif type == "array"
        then (map(select(.type == "text") | .text) | join(" ")) else "" end
        | sub("^\\s+"; "")) | .[0] // ""' "$1" 2>/dev/null
}

# reply_matches <id> <did> <msg> <form> <val> <answer json> — the Operator's whole reply, parsed by
# the writer's own parser, is this very answer.
reply_matches() {
  local p
  p="$(ask_parse_reply "$1" "$2" "$3")" || return 1
  case "$4" in allow|deny) [ "$(jq -r .outcome <<<"$p")" = "$4" ] || return 1 ;; esac
  case "$4" in
    answers) [ "$(jq -cS .map <<<"$p")" = "$(jq -cS .value <<<"$6")" ] ;;
    allow) [ -z "$(jq -r .value <<<"$p")" ] ;;
    *) [ "$(jq -r .value <<<"$p")" = "$5" ] ;;
  esac
}

# verify_relay <id> <did> <uuid> <form> <val> <answer json> — a decision the Supervisor relayed: the
# team and its active run from the main checkout's anchor, the ledger the relay pinned there, the
# Supervisor's transcript under the declared profile, the message `<team> <d-n> …` at that uuid,
# typed no earlier than the decision opened (the ledger's floor) nor before the run started.
verify_relay() {
  local x team lf cfg t floor rf msg
  x="$(team_anchor_team "$MAIN" "$CLONE")" || return 1
  team="$(cut -f1 <<<"$x")"; [ "$(cut -f2 <<<"$x")" = "$RUN" ] || return 1
  lf="$MAIN/.agents/team/relays/$team-$RUN-$2.json"
  jq -e --arg t "$team" --arg r "$RUN" --arg d "$2" --arg a "$1" --arg u "$3" \
    '.team == $t and .run == $r and .decision == $d and .ask == $a and .uuid == $u' "$lf" >/dev/null 2>&1 \
    || return 1
  cfg="$(team_supervisor_home "$MAIN")" || return 1
  t="$cfg/projects/$(team_project_slug "$(jq -r '.cwd // ""' "$lf")")/$(jq -r '.session_id // ""' "$lf").jsonl"
  [ -f "$t" ] || return 1
  floor="$(jq -r '.created_at // ""' "$lf")"; rf="$(team_run_floor "$RUN")"
  [[ ! "$rf" > "$floor" ]] || floor="$rf"
  [ -n "$floor" ] || return 1
  msg="$(msg_at "$t" "$3" "$floor")" || return 1
  case "$msg" in "$team "*) msg="${msg#"$team "}"; msg="${msg#"${msg%%[![:space:]]*}"}" ;; *) return 1 ;; esac
  reply_matches "$1" "$2" "$msg" "$4" "$5" "$6"
}

# deliver <id> <answer json> — emits the hook output of this event for the answer.
# check_input <{tool_name, tool_input, cwd} file> — the checker's tier line and `retry: <key>|none`.
check_input() { python3 -I "$LIB/team_prompt_check.py" "$CLONE" --input-json "$1" --main "$MAIN" 2>/dev/null; }

deliver() {
  local id="$1" a="$2" kind form val q1
  kind="$(ask_get "$id" kind)"; form="$(jq -r .form <<<"$a")"
  # ${tier:-}: the tier this hook computed for a permission (handle's local), whatever the file says.
  if [ "$(jq -r .authority <<<"$a")" = operator ] || [ "$(ask_get "$id" tier)" = operator ] \
      || [ "${tier:-}" = operator ] \
      || [ -n "$(ask_get "$id" requires_decision)" ]; then
    if ! verify_operator "$id" "$a"; then
      ask_reject "$id" >/dev/null 2>&1 || true
      out_refuse "Operator approval could not be verified for $id"
      return 0
    fi
  fi
  if stopped; then
    ask_cas "$id" "waiting timed-out answered delivering" withdrawn || true
    out_refuse "$STOP_MSG"; return 0
  fi
  # An allow rides only the inputs the Operator saw: the checker's key must still be the stored one.
  local rk now
  rk="$(ask_get "$id" retry_key)"
  if [ "$kind:$form" = permission:allow ] && [ -n "$rk" ] && [ "$rk" != none ]; then
    jq -c .payload "$ASK_D/$id.json" > "$TMP.re" 2>/dev/null
    now="$(check_input "$TMP.re" | sed -n 's/^retry: //p')"
    if [ "$now" != "$rk" ]; then
      ask_cas "$id" "delivering" withdrawn || true
      out_perm_deny "the operation's inputs changed since the decision — retry the call"; return 0
    fi
  fi
  case "$kind:$form" in
    question:answers)
      jq -c --argjson a "$(jq -c .value <<<"$a")" '{hookSpecificOutput: {hookEventName: "PreToolUse",
        permissionDecision: "allow", updatedInput: (.tool_input + {answers: $a})}}' <<<"$PAYLOAD" ;;
    question:pick)
      jq -c --arg v "$(jq -r .value <<<"$a")" '{hookSpecificOutput: {hookEventName: "PreToolUse",
        permissionDecision: "allow", updatedInput: (.tool_input
          + {answers: {(.tool_input.questions[0].question): $v}})}}' <<<"$PAYLOAD" ;;
    question:text)
      q1="$(jq -r '.tool_input.questions[0].question // "your question"' <<<"$PAYLOAD")"
      out_pre_deny "The TeamLead answered: \"$q1\" → $(jq -r .value <<<"$a")" ;;
    plan:allow)
      jq -c '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow",
        updatedInput: .tool_input}}' <<<"$PAYLOAD" ;;
    plan:deny) out_pre_deny "The TeamLead asks for a change to the plan: $(jq -r '.value // ""' <<<"$a")" ;;
    permission:allow)
      jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"}}}' ;;
    permission:deny) out_perm_deny "The TeamLead denied this: $(jq -r '.value // ""' <<<"$a")" ;;
    text:text) out_block "$(ask_text_form "$a")" ;;
    *) out_refuse "The TeamLead's answer ($form) does not fit this $kind ask $id" ;;
  esac
  ask_delivered "$id" || true
  ask_follow_up "$id"
}

# wait_and_answer <id> — poll to the deadline, then deliver or fall back.
wait_and_answer() {
  local id="$1" a rc st
  a="$(ask_poll "$id" "$DEADLINE")"; rc=$?
  if [ "$rc" = 1 ]; then
    st="$(ask_timeout "$id")"
    if [ "$st" != answered ]; then fallback "$id" "$st"; return 0; fi
    a="$(cat "$ASK_D/$id.answer.json")"
  elif [ "$rc" = 2 ]; then
    out_refuse "$STOP_MSG"; return 0
  fi
  if ! ask_claim_delivery "$id"; then fallback "$id" unclaimed; return 0; fi
  deliver "$id" "$a"
}

ring() {  # ring <id> — detached, so a busy send lock never eats the wait
  ( team_session_doorbell "$TD" lead "$(ask_ring_line "$1")" ) >/dev/null 2>&1 &
}

# file_ask <kind> <payload json> <tier> <tier cause> → ASK_ID set, ASK_NEW
file_ask() {
  jq -n --arg kind "$1" --arg role "$ROLE" --arg att "$ATTEMPT" --arg round "${ROUND:-1}" \
    --arg sid "$STAGE_SID" --arg aid "$(jq -r '.agent_id // ""' <<<"$PAYLOAD")" \
    --arg aty "$(jq -r '.agent_type // ""' <<<"$PAYLOAD")" --argjson p "$2" --arg tier "$3" \
    --arg cause "$4" --arg rk "${RETRY_KEY:-}" --arg hsid "$SID" '{kind: $kind, role: $role,
      attempt: ($att | tonumber? // $att), round: ($round | tonumber? // 1), session_id: $sid,
      hook_session_id: $hsid, agent_id: $aid, agent_type: $aty, payload: $p, tier: $tier,
      tier_cause: $cause} + (if $rk == "" then {} else {retry_key: $rk} end)' > "$TMP.ask" || return 1
  ask_file "$TMP.ask" >/dev/null || return 1
}

# handle <kind> <payload json> [tier] [cause]
handle() {
  local kind="$1" p="$2" tier="${3:-lead}" cause="${4:-}"
  if stopped; then [ "$EV" = Stop ] || out_refuse "$STOP_MSG"; return 0; fi
  file_ask "$kind" "$p" "$tier" "$cause" || return 0
  local id="$ASK_ID"
  if [ "$tier" = class ] && [ "$ASK_NEW" = 1 ]; then
    ask_answer_write "$id" "$(jq -n --arg id "$id" --arg why "deterministic class $cause" \
      --arg at "$(ask_utc)" '{id: $id, form: "allow", value: "", authority: "class", why: $why,
        decision: "", answered_at: $at, lead_session_id: ""}')" 2>/dev/null || true
    ask_follow_up "$id"
  elif [ "$ASK_NEW" = 1 ]; then
    ring "$id"
  fi
  wait_and_answer "$id"
}

stop_branch() {
  local mark="$ASK_D/.stop-$STAGE_SID" prev ref rd rec v id msg p fp done_turn="" newid
  prev="$(cat "$mark" 2>/dev/null || echo 0)"; [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
  echo "$ENTRY" > "$mark" 2>/dev/null
  stopped && return 0
  # 1. this session's Stop fallback ask is still open: its answer now, or the same fallback again.
  for id in $(ask_ids); do
    [ "$(ask_get "$id" session_id)" = "$STAGE_SID" ] && [ "$(ask_get "$id" kind)" = text ] || continue
    case "$(ask_state "$id")" in
      timed-out) fallback "$id"; return 0 ;;
      answered) ask_claim_delivery "$id" && { deliver "$id" "$(cat "$ASK_D/$id.answer.json")"; return 0; } ;;
    esac
  done
  ref="$(team_run_ref "$TD" "$RUN")"; rd="$TD/runs/$ref"
  rec="$(team_newest_record "$TD" "$ref" "$ROLE" "$ATTEMPT")"
  if [ -n "$rec" ]; then
    v="$(jq -r '.verdict // ""' "$rd/$rec" 2>/dev/null)"
    local rel="${ref#"$RUN"}"; rel="${rel#/}"; rel="${rel:+$rel/}$rec"
    # 2. a blocked record nobody answered yet → its message is the ask.
    if [ "$v" = blocked ] && [ ! -e "$rd/$rec.answered" ] && [ -z "$(ask_open_for_record "$rel")" ]; then
      msg="$(jq -r '.message // "blocked"' "$rd/$rec")"
      handle text "$(jq -n --arg t "$msg" --arg s "record:$rel" '{text: $t, source: $s}')"
      return 0
    fi
    # 3. the turn wrote its final record → the stage ends.
    if [ "$(team_epoch "$(jq -r '.written_at // ""' "$rd/$rec")")" -gt "$prev" ]; then
      done_turn=1
      case "$v" in done|failed) return 0 ;; esac
    fi
  fi
  msg="$(jq -r '.last_assistant_message // ""' <<<"$PAYLOAD")"
  [ -n "$msg" ] || msg="(the stage stopped without a message)"
  p="$(jq -n --arg t "$msg" '{text: $t, source: "message"}')"
  # 4. the loop guard: the stop repeats the one just answered.
  if [ "$(jq -r '.stop_hook_active // false' <<<"$PAYLOAD")" = true ] && [ -z "$done_turn" ]; then
    fp="$(ask_fp text "" "$p")"
    newid=""
    for id in $(ask_ids); do
      [ "$(ask_get "$id" session_id)" = "$STAGE_SID" ] && [ "$(ask_get "$id" kind)" = text ] \
        && [ "$(ask_get "$id" state)" = delivered ] && newid="$id"
    done
    [ -z "$newid" ] || [ "$(ask_get "$newid" fp)" != "$fp" ] || return 0
  fi
  # 5. a self-wake is pending (background task, sub-agent, cron or wakeup) → no ask.
  if [ -z "$done_turn" ] && jq -e '((.background_tasks // []) | length) > 0
      or ((.session_crons // []) | length) > 0' <<<"$PAYLOAD" >/dev/null 2>&1; then
    return 0
  fi
  # 6. a plain-text stop: the lead answers how to go on.
  handle text "$p"
}

case "$EV:$TOOL" in
  PreToolUse:AskUserQuestion) handle question "$(jq -c '{tool_name, tool_input}' <<<"$PAYLOAD")" ;;
  PreToolUse:ExitPlanMode) handle plan "$(jq -c '{tool_name, tool_input}' <<<"$PAYLOAD")" ;;
  PermissionRequest:AskUserQuestion|PermissionRequest:ExitPlanMode) exit 0 ;;
  PermissionRequest:*)
    # The channel's own wait, as the Stop fallback names it (a main-checkout path the checker would
    # tier operator as outside the clone): this exact form only → allow.
    if [ "$TOOL" = Bash ]; then
      cmd="$(jq -r '.tool_input.command // ""' <<<"$PAYLOAD")"
      case "$cmd" in "bash $LIB/team-ask.sh wait "*)
        if [[ "${cmd#"bash $LIB/team-ask.sh wait "}" =~ ^a-[0-9]+( --secs [0-9]+)?$ ]]; then
          jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"}}}'
          exit 0
        fi ;;
      esac
    fi
    # The filed payload carries the canonical cwd: a retry claims an ask only from the same cwd.
    c="$(jq -r '.cwd // ""' <<<"$PAYLOAD")"; c="$( (cd "$c" 2>/dev/null && pwd -P) || printf '%s' "$c")"
    jq -c --arg c "$c" '{tool_name, tool_input, cwd: $c}' <<<"$PAYLOAD" > "$TMP.in" || exit 0
    out="$(check_input "$TMP.in")" || exit 0
    line="$(sed -n 1p <<<"$out")"
    # An operator-tier ask with a retry key outlives the deadline (timed-out, claimable); none → withdrawn.
    RETRY_KEY="$(sed -n 's/^retry: //p' <<<"$out")"; [ -n "$RETRY_KEY" ] || RETRY_KEY=none
    case "$line" in
      "tier: class "*) tier=class; cause="${line#tier: class }" ;;
      "tier: lead") tier=lead; cause="" ;;
      "tier: operator — "*) tier=operator; cause="${line#tier: operator — }" ;;
      *) exit 0 ;;
    esac
    handle permission "$(cat "$TMP.in")" "$tier" "$cause" ;;
  Stop:*)
    if ! stop_branch; then
      echo "$(ask_utc) stop-failed $ROLE $ATTEMPT" >> "$TD/runs/$RUN/attention" 2>/dev/null || true
    fi ;;
esac
exit 0
