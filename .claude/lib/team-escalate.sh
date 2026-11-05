#!/usr/bin/env bash
# Escalation for /monitor (tiers 2 and 3): send the question to Advisor, wait for his reply.
#
# Usage: bash .claude/lib/team-escalate.sh <team> <role> <2|3> <question-file>
#          [--blocks "<decision>"] [--class <c>] [--recommend "<send> <text>"]
#          [--options "<text>"] [--files "<a,b>"]
#          [--reping "<reason>" | --resume | --retier "<reason>"]
#   e.g. bash .claude/lib/team-escalate.sh alfa coder 2 "$q" --blocks "retry design of the worker"
# Default mode (open question) needs --blocks; --retier needs tier 3 after a tier-2 answer.
# --class/--recommend (default mode only): the escalation class and the recommendation
#   TeamLead would deliver; an eligible tier-2 class may close on Reviewer's "opinion: agree"
#   after a Advisor timeout (.agents/reference/escalation-fallback.md). --resume on an answered
#   q only late-reads a reply (LATE <status> / LATE NONE) and never delivers.
# Config: <main checkout>/.agents/team/escalation.local.json, rendered by /setup:teams from
#   .claude/team/escalation.local.json.tmpl (team-channel.sh render); send/wait/opinion/peek are each
#   `bash|sh <adapter> … "$1" … "$6"` ($1=payload file, $2=team, $3=role, $4=question id,
#   $5=thread esc-<run>-<qid>, $6=seq), parsed without running anything before any adapter runs;
#   a send counts only with a last stdout line `SENT id=<n>`; rc 0 without it is retried once at
#   once, then NO-REPLY invalid adapter (no SENT receipt); before a re-ping and after a failed
#   send the thread is peeked (needs peek); no `opinion` or `peek` key = fallback off, and so is
#   teams.channel.advisor solo (payload `fallback: no (advisor solo)`, no `## Reviewer` section).
# Exit: 0 ANSWER / WITHDRAWN / FALLBACK / LATE <status> + the text · 1 busy (ledger or waiter lock)
#       · 2 usage / refused state / reping limit / tier mismatch
#       · 3 NO-REPLY <reason> (repings: <n>, sent: <yes|no>)
#       · 4 final reply printed, outcome not recorded (ledger lock timeout) · 130/143 cancelled
set -euo pipefail
# Each background job gets its own process group, so the watchdog can kill an adapter's children.
set -m

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
bad() { echo "error: $*" >&2; exit 2; }
[ $# -ge 4 ] || usage
LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-lib.sh"
. "$LIB/team-escalate-lib.sh"
TEAM="$1"; ROLE="$2"; TIER="$3"; QARG="$4"; shift 4
MODE=default; REASON=""; BLOCKS=""; OPTIONS=""; FILES=""; CLASS=""; RECOMMEND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --resume) [ "$MODE" = default ] || bad "one mode at most"; MODE=resume; shift; continue ;;
    --blocks|--options|--files|--class|--recommend|--reping|--retier) [ $# -ge 2 ] || usage ;;
    *) usage ;;
  esac
  case "$1" in
    --blocks) BLOCKS="$2" ;; --options) OPTIONS="$2" ;; --files) FILES="$2" ;;
    --class) CLASS="$2" ;; --recommend) RECOMMEND="$2" ;;
    *) [ "$MODE" = default ] || bad "one mode at most"; MODE="${1#--}"; REASON="$2" ;;
  esac
  shift 2
done
team_check_name "$TEAM" || exit 2
case " $TEAM_ROLES cli " in *" $ROLE "*) ;; *) bad "unknown role $ROLE" ;; esac
case "$TIER" in 2|3) ;; *) bad "tier must be 2 or 3" ;; esac
[ "$MODE" != default ] || [ -n "$BLOCKS" ] || bad "--blocks is required"
[ "$MODE" != retier ] || [ "$TIER" = 3 ] || bad "--retier needs tier 3"
[ -z "$CLASS$RECOMMEND" ] || [ "$MODE" = default ] || bad "--class/--recommend open a question only"
[ -z "$CLASS" ] || case " $ESC_ELIGIBLE $ESC_CRITICAL " in *" $CLASS "*) ;;
  *) bad "unknown class $CLASS" ;; esac
case "$RECOMMEND" in *$'\n'*) bad "--recommend must be one line" ;; esac
root="$(git rev-parse --show-toplevel)"
RUNS="$(cd "$(team_clone_dir "$TEAM" "$root")/.agents/team/runs" 2>/dev/null && pwd -P)" \
  || bad "no team runs for $TEAM"
[ -f "$QARG" ] || bad "no question file $QARG"
QDIR="$(cd "$(dirname "$QARG")" && pwd -P)"; Q="$QDIR/$(basename "$QARG")"
case "$Q" in "$RUNS"/*) ;; *) bad "question file is not in $TEAM's runs" ;; esac
[[ "$(basename "$Q")" =~ ^q-[0-9]+\.md$ ]] || bad "question file must be q-<n>.md"
QID="$(basename "$Q" .md)"
CLONE="$(cd "$RUNS/../../.." && pwd -P)"
THREAD="esc-$(esc_field "$Q" run)-$QID"; PAYLOAD="$QDIR/$QID.payload.md"
check_recommend() {  # the pairs `team-question.sh answer` enforces, so a FALLBACK is deliverable
  local send="${RECOMMEND%% *}" kind
  [ -n "$RECOMMEND" ] || return 0
  [[ "$RECOMMEND" == *" "*[^\ ]* ]] || bad "--recommend needs \"<send> <text>\""
  [[ "$send" =~ ^(yes|say|other|pick:[1-9][0-9]?|picks:(none|[1-9][0-9]?(,[1-9][0-9]?)*))$ ]] \
    || bad "--recommend: bad send $send"
  kind="$(esc_field "$Q" kind)"
  [ "$kind" != permission ] || bad "--recommend: a permission prompt is never a fallback"
  case "$kind:$send" in
    menu:pick:*|menu:picks:*|menu:other|blocked:say|idle:say) ;;
    *) bad "--recommend $send does not fit kind $kind" ;;
  esac
}
check_recommend
TICKET="$(jq -r .ticket "$CLONE/.agents/team/team.json")"
CFG="$root/.agents/team/escalation.local.json"
ADVISOR_MODE="$(esc_advisor_mode "$root" "$CFG")"
CHILD=""; LOCKED=""; WAITER=""; STARTED=0; FINISHED=0; DRAINING=0; SEEN=" "; TMP="$(mktemp -d)"
OPINION=""; PEEK=""; PENDING=0; FB_REPLY=""

q_lock() { team_q_lock "$Q" "$TEAM" || return 1; LOCKED="$Q.lock"; }
q_unlock() { rm -rf "$Q.lock" 2>/dev/null || true; LOCKED=""; }

# A late outcome may follow an answer the Operator gave meanwhile; it re-opens its own heading.
ledger() {  # caller holds the q lock
  [ "$(awk '/^## /{h = $0} END{print h}' "$Q")" = "## Escalation" ] || printf '\n## Escalation\n' >> "$Q"
  printf '%s\n' "$@" >> "$Q"
}
append() { q_lock || return 1; ledger "$@"; q_unlock; }

stop_child() {
  local i=0
  [ -n "${CHILD:-}" ] || return 0
  kill -TERM -- "-$CHILD" 2>/dev/null || true
  while kill -0 "$CHILD" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 0.2; i=$((i + 1)); done
  kill -KILL -- "-$CHILD" 2>/dev/null || true
  wait "$CHILD" 2>/dev/null || true
  CHILD=""
}

cleanup() {
  stop_child || true
  [ -z "$LOCKED" ] || rm -rf "$LOCKED" 2>/dev/null || true
  [ -z "$WAITER" ] || [ "$(cat "$WAITER/pid" 2>/dev/null)" != "$$" ] || rm -rf "$WAITER" || true
  rm -rf "$TMP" || true
}

cancelled() {
  [ "$STARTED" = 1 ] && [ "$FINISHED" = 0 ] || return 0
  FINISHED=1
  stop_child || true
  # Killed at the fallback commit point, the q lock is ours: write without re-taking it.
  if [ -n "$LOCKED" ]; then ledger "outcome: cancelled" "ended: $(team_utc)" || true
  else append "outcome: cancelled" "ended: $(team_utc)" || true; fi
}

no_reply() {  # no_reply <reason> [ledger lines recorded with the outcome]
  local reason="$1" sent=yes; shift
  FINISHED=1
  append "$@" "outcome: no-reply — $reason" "ended: $(team_utc)" || true
  [ -z "$(esc_outstanding "$Q")" ] || sent=no
  echo "NO-REPLY $reason (repings: $(esc_repings "$Q"), sent: $sent)"
  exit 3
}

run_bounded() {  # run_bounded <cmd> <out> → the command's rc, 124 past $DEADLINE (0 = none)
  local rc=0
  bash -c "$1" team-escalate "$PAYLOAD" "$TEAM" "$ROLE" "$QID" "$THREAD" "$SEQ" \
    > "$2" 2> "$2.err" < /dev/null &
  CHILD=$!
  while kill -0 "$CHILD" 2>/dev/null; do
    if [ "$DEADLINE" != 0 ] && [ "$(date +%s)" -ge "$DEADLINE" ]; then stop_child; return 124; fi
    sleep "${TEAM_ESCALATE_POLL:-1}"
  done
  wait "$CHILD" || rc=$?
  # The leader may exit while children it backgrounded live on in its group.
  stop_child
  return "$rc"
}

trap cleanup EXIT
trap 'cancelled; cleanup; exit 143' TERM
trap 'cancelled; cleanup; exit 130' INT

refuse() { q_unlock; bad "$QID $*"; }

check_start() {  # under the q lock: every refusal before anything is appended
  local st last
  st="$(team_q_state "$Q" | cut -f1)"; last="$(esc_last_outcome "$Q")"
  # A reply that arrives after an answer is only read and recorded, never delivered.
  if [ "$MODE" = resume ] && esc_lines "$Q" | grep -q '^started: '; then
    case "$st" in
      sent|consumed|recorded|not-sent|not-sent-stale|failed|pending|unknown|revoked) MODE=late ;;
    esac
  fi
  case "$MODE:$st" in
    late:*) [ "$(esc_tier "$Q")" = "$TIER" ] || refuse "tier mismatch"; return 0 ;;
    *:sent|*:consumed|*:recorded|*:failed|*:pending|*:unknown|*:not-sent|*:not-sent-stale|*:revoked)
      refuse "already answered" ;;
    *:escalated) [ "$last" != withdrawn ] || refuse "withdrawn" ;;
  esac
  case "$MODE:$st:$last" in
    default:open:*) return 0 ;;
    default:*) refuse "already escalated — use --reping or --resume" ;;
    *:escalated:reviewer-fallback) refuse "has a recorded fallback — deliver it first" ;;
    retier:escalated:answer) [ "$(esc_tier "$Q")" = 2 ] || refuse "tier mismatch"; return 0 ;;
    retier:*) refuse "--retier needs a recorded tier-2 answer" ;;
    *:escalating:*|*:waiting-operator:*) ;;
    *:escalated:no-reply*|*:escalated:cancelled|*:escalated:fallback*|*:escalated:disagree) ;;
    *) refuse "is $st — nothing to $MODE" ;;
  esac
  [ "$(esc_tier "$Q")" = "$TIER" ] || refuse "tier mismatch"
  [ "$MODE" = reping ] && [ -z "$(esc_outstanding "$Q")" ] \
    && [ "$(esc_repings "$Q")" -ge "$ESC_REPING_CAP" ] \
    && refuse "reping limit ($ESC_REPING_CAP delivered)"
  return 0
}

take_waiter() {  # two /monitor sessions never wait on one thread; a dead waiter is taken over
  local p
  if ! mkdir "$Q.wait" 2>/dev/null; then
    p="$(cat "$Q.wait/pid" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      q_unlock; echo "error: $QID busy (waiter pid $p)" >&2; exit 1
    fi
  fi
  echo $$ > "$Q.wait/pid"; WAITER="$Q.wait"
}

begin() {
  local out
  q_lock || exit 1
  check_start
  take_waiter
  out="$(esc_outstanding "$Q")"; RESEND=""
  case "$MODE" in
    default) SEQ=1; ledger "started: $(team_utc) tier $TIER${CLASS:+ class $CLASS}"
      [ -z "$RECOMMEND" ] || ledger "recommend: $RECOMMEND" ;;
    reping) RESEND="$out"; SEQ="${out:-$(esc_next_seq "$Q")}"
      ledger "reping: $(team_utc) seq $SEQ — $REASON" ;;
    retier) SEQ="$(esc_next_seq "$Q")"; ledger "retier: $(team_utc) tier 3 seq $SEQ — $REASON" ;;
    resume) SEQ="$(esc_sent_count "$Q")"; [ "$SEQ" -ge 1 ] || SEQ=1
      ledger "resumed: $(team_utc)" ;;
    late) SEQ="$(esc_sent_count "$Q")"; [ "$SEQ" -ge 1 ] || SEQ=1; ledger "late: $(team_utc)" ;;
  esac
  STARTED=1
  q_unlock
}

finish() {  # finish <reply file> <id> <status> — the one append that consumes a final reply
  local rc=0
  FINISHED=1
  grep -v '^mail-id: ' "$1" > "$TMP/final" || true
  append "reply: $2 $3" "outcome: $3" "ended: $(team_utc)" "$(sed 's/^./    &/' "$TMP/final")" \
    || { rc=4; echo "warn: ledger busy — outcome not recorded" >&2; }
  echo "$3" | tr '[:lower:]' '[:upper:]'
  cat "$TMP/final"
  exit "$rc"
}

reject() {  # reject <id> <status> <reason>; while draining before a send, record and go on
  if [ "$DRAINING" = 1 ]; then
    append "reply: $1 $2" || true
    echo "warn: staged reply $1 rejected — $3" >&2
    return 0
  fi
  no_reply "$3" "reply: $1 $2"
}

late_finish() {  # late_finish <reply file> <id> — records any late reply; never delivers
  local rc=0 st=unparseable
  FINISHED=1
  ! esc_parse "$1" || st="$R_STATUS"
  grep -v '^mail-id: ' "$1" > "$TMP/final" || true
  append "reply: $2 $st" "outcome: late-$st" "ended: $(team_utc)" \
    "$(sed 's/^./    &/' "$TMP/final")" \
    || { rc=4; echo "warn: ledger busy — outcome not recorded" >&2; }
  echo "LATE $st" | tr '[:lower:]' '[:upper:]'
  cat "$TMP/final"
  exit "$rc"
}

consume() {  # consume <reply file> <id>
  SEEN="$SEEN$2 "
  if ! esc_parse "$1"; then reject "$2" unparseable "unparseable answer"; return 0; fi
  case "$R_STATUS" in
    pending-operator) PENDING=1
      append "reply: $2 pending-operator" "waiting: operator $(team_utc) eta ${R_ETA:--}" \
        || echo "warn: ledger busy — pending-operator not recorded, it replays" >&2 ;;
    disagree) reject "$2" disagree "status: disagree is retired — escalate both positions \
with a recommendation to the Operator" ;;
    unverified-operator-ref) reject "$2" "$R_STATUS" "operator-ref not verified (note must hold \
the line thread: $THREAD and an Operator decision: line)" ;;
    answer)
      if [ "$TIER" = 3 ] && { [ "$R_DECIDED" != operator ] || [ -z "$R_REF" ]; }; then
        reject "$2" answer \
          "tier 3 needs the Operator's decision (decided-by: operator + operator-ref)"
      else finish "$1" "$2" answer; fi ;;
    withdrawn) finish "$1" "$2" withdrawn ;;
    *) reject "$2" "$R_STATUS" "unparseable answer" ;;
  esac
}

next_staged() {  # the oldest staged reply not yet consumed → "<id> <file>"
  local id
  for id in $(esc_staged_unconsumed "$Q"); do
    case "$SEEN" in *" $id "*) continue ;; esac
    echo "$id $QDIR/$QID.reply-$id.md"; return 0
  done
  return 1
}

drain() {
  local id f
  while read -r id f <<<"$(next_staged)" && [ -n "$id" ]; do consume "$f" "$id"; done
}

cfg_op() { jq -r --arg k "$1" '.[$k] // empty | strings' "$CFG" 2>/dev/null || true; }

prepare_payload() {
  local blk="$BLOCKS" kind=decision elig o p
  if [ "$MODE" = default ] || [ ! -f "$PAYLOAD" ]; then
    [ -n "$blk" ] || blk="$(esc_section "$Q" Context | sed -n 's/^- last blocker: //p')"
    # Best-effort config read: a payload must exist even when the config is missing.
    elig=no; o="$(cfg_op opinion)"; p="$(cfg_op peek)"
    [ "$ADVISOR_MODE" = pair ] || elig="no (advisor solo)"
    [ "$ADVISOR_MODE" = pair ] && [ -n "$o" ] && esc_config_ok "$o" && [ -n "$p" ] \
      && esc_config_ok "$p" && esc_fallback_check "$Q" "$TIER" advertise >/dev/null && elig=eligible
    esc_payload_build "$Q" "$PAYLOAD" "$TICKET" "$TEAM" "$TIER" "$THREAD" "$SEQ" \
      "${blk:-see Question}" "$OPTIONS" "$FILES" "$(esc_class "$Q")" "$(esc_recommend "$Q")" "$elig"
  fi
  ! esc_asked "$Q" || kind=transport
  case "$MODE" in
    reping) [ -n "$RESEND" ] || esc_payload_header "$PAYLOAD" "$TIER" "$SEQ" "$REASON" "$kind" ;;
    retier) esc_payload_header "$PAYLOAD" 3 "$SEQ" "$REASON" ""
      esc_payload_recommend "$PAYLOAD" "$(esc_last_answer "$Q")" ;;
  esac
}

load_config() {
  local k
  [ -f "$CFG" ] || no_reply "no config ($CFG)"
  jq -e 'type == "object"' "$CFG" >/dev/null 2>&1 || no_reply "invalid config: not a JSON object"
  for k in send wait; do
    jq -e --arg k "$k" '.[$k] | type == "string" and length > 0' "$CFG" >/dev/null \
      || no_reply "invalid config: $k"
    esc_config_ok "$(jq -r --arg k "$k" '.[$k]' "$CFG")" \
      || no_reply "invalid config: adapter does not forward thread/seq"
  done
  TMIN="$(jq -r '.timeout_min | if type == "number" and . == floor and . >= 1 and . <= 240
    then . else empty end' "$CFG")"
  [ -n "$TMIN" ] || no_reply "invalid config: timeout_min"
  if jq -e 'has("opinion")' "$CFG" >/dev/null; then
    OPINION="$(cfg_op opinion)"
    [ -n "$OPINION" ] && esc_config_ok "$OPINION" || no_reply "invalid config: opinion"
  fi
  if jq -e 'has("peek")' "$CFG" >/dev/null; then
    PEEK="$(cfg_op peek)"
    [ -n "$PEEK" ] && esc_config_ok "$PEEK" || no_reply "invalid config: peek"
  fi
  # Only the smoke suite shrinks the minute: the ledger's "<n> min" is a wall-clock minimum.
  UNIT=60; [ "${TEAM_SMOKE:-}" != 1 ] || UNIT="${TEAM_ESCALATE_UNIT_SECS:-60}"
}

# A failed send keeps its seq (same adapter dedup key); rc 0 without a receipt is retried once at
# once (a dedup hit returns the lost receipt), a second one breaks the contract.
send() {
  local k rc=0 id why="" norec=0
  for k in 1 2 3; do
    [ "$k" = 1 ] || [ "$why" = "no receipt" ] \
      || sleep $(( (k - 1) * ${TEAM_ESCALATE_BACKOFF_SECS:-60} ))
    DEADLINE=$(( $(date +%s) + TMIN * UNIT )); rc=0
    run_bounded "$(jq -r .send "$CFG")" "$TMP/send" || rc=$?
    id="$(tail -n 1 "$TMP/send" | sed -nE 's/^SENT id=([0-9]+)( .*)?$/\1/p')"
    if [ "$rc" = 0 ] && [ -n "$id" ]; then
      append "sent: seq $SEQ $(team_utc) id $id thread $THREAD" || true; return 0
    fi
    case "$rc" in 0) why="no receipt" ;; 124) why=timeout ;; *) why="rc $rc" ;; esac
    append "failed: seq $SEQ $(team_utc) — $why" || true
    ! thread_reply || return 0
    [ "$why" != "no receipt" ] || norec=$((norec + 1))
    [ "$norec" -lt 2 ] || no_reply "invalid adapter (no SENT receipt)"
  done
  [ "$why" != timeout ] || no_reply "send timeout"
  no_reply "send failed ($why)"
}

read_opinion() {  # read_opinion <secs> → rc 0 with R_OID R_OPINION R_OBODY, else 1 + FB_REASON
  local rc=0
  DEADLINE=$(( $(date +%s) + $1 ))
  run_bounded "$OPINION" "$TMP/opinion" || rc=$?
  [ "$rc" = 0 ] || { FB_REASON="opinion op failed (rc $rc)"; return 1; }
  esc_opinion_parse "$TMP/opinion" || { FB_REASON="no Reviewer opinion"; return 1; }
}

fresh_reply() {  # one adapter peek proves Advisor's silence: rc 0 on EMPTY or a reply (FB_REPLY)
  local rc=0 id f
  if read -r id f <<<"$(next_staged)" && [ -n "$id" ]; then FB_REPLY="$id $f"; return 0; fi
  DEADLINE=$(( $(date +%s) + ${TEAM_ESCALATE_PEEK_SECS:-10} ))
  run_bounded "$PEEK" "$TMP/peek" || rc=$?
  # The adapter stages and acks before it prints: a killed peek may leave a staged reply.
  if read -r id f <<<"$(next_staged)" && [ -n "$id" ]; then FB_REPLY="$id $f"; return 0; fi
  case "$rc" in
    0) ;;
    124) FB_REASON="evidence changed (peek timeout)"; return 1 ;;
    *) FB_REASON="evidence changed (peek failed rc $rc)"; return 1 ;;
  esac
  [ "$(cat "$TMP/peek")" != EMPTY ] || return 0
  [ -s "$TMP/peek" ] || { FB_REASON="evidence changed (peek: no EMPTY)"; return 1; }
  id="$(sed -n '1s/^mail-id: //p' "$TMP/peek")"; FB_REPLY="${id:--} $TMP/peek"
}

# thread_reply — consumes a reply already on the thread: answer/withdrawn exit, rc 0 = recorded
# pending-operator; rc 1 = none (no peek, EMPTY, a failed peek never blocks the send). A peek acks.
thread_reply() {
  local id f
  [ -n "$PEEK" ] || return 1
  FB_REPLY=""; PENDING=0
  fresh_reply || return 1
  [ -n "$FB_REPLY" ] || return 1
  read -r id f <<<"$FB_REPLY"; consume "$f" "$id"
  [ "$PENDING" = 1 ]
}

# evidence_holds <recommend> <opinion id> — the commit point, run holding the q lock:
# the ledger, Advisor's silence and Reviewer's newest opinion are what was decided on. Both
# bounds (12 s + 10 s) stay under TEAM_QUESTION_LOCK_SECS (30 s), so `answer` never reads busy.
evidence_holds() {
  FB_REASON="evidence changed"
  esc_fallback_check "$Q" "$TIER" >/dev/null && [ "$(esc_recommend "$Q")" = "$1" ] \
    && [ "$(team_q_state "$Q" | cut -f1)" = escalating ] \
    && read_opinion "${TEAM_ESCALATE_OPINION_RECHECK_SECS:-12}" \
    && [ "$R_OPINION" = agree ] && [ "$R_OID" = "$2" ] && fresh_reply && [ -z "$FB_REPLY" ]
}

# opinion_refused — rc 0 + FB_REASON when Reviewer's opinion closes no fallback. A class line under
# agree is an attestation, not a condition: an eligible one is cut from R_OBODY, any other refuses.
opinion_refused() {
  local cls=""
  [ "$R_OPINION" = unmarked ] || cls="$(esc_opinion_class "$R_OBODY")"
  case "$R_OPINION:$cls" in
    agree:) return 1 ;;
    agree:*)
      case " $ESC_ELIGIBLE " in
        *" $cls "*) R_OBODY="$(awk 'f {print; next} NF {f = 1}' <<<"$R_OBODY")"; return 1 ;;
      esac
      FB_REASON="Reviewer agree names class $cls" ;;
    disagree:*)
      case " $ESC_CRITICAL " in *" ${cls:-none} "*) ;; *) cls="" ;; esac
      FB_REASON="Reviewer disagree${cls:+ (class $cls)}" ;;
    *) FB_REASON="Reviewer $R_OPINION" ;;
  esac
  append "opinion: $R_OID $R_OPINION${cls:+ class $cls}" || true
}

# try_fallback — exits FALLBACK when Reviewer agreed and nothing changed until the commit; else
# returns with FB_REASON set, and FB_REPLY when a Advisor reply came in meanwhile.
try_fallback() {
  local sid rec send text conds oid
  local -a body=()
  FB_REPLY=""
  FB_REASON="$(esc_fallback_check "$Q" "$TIER")" || return 0
  [ "$ADVISOR_MODE" = pair ] || { FB_REASON="advisor solo"; return 0; }
  [ -n "$OPINION" ] || { FB_REASON="opinion adapter off"; return 0; }
  [ -n "$PEEK" ] || { FB_REASON="peek adapter off"; return 0; }
  rec="$(esc_recommend "$Q")"; send="${rec%% *}"; text="${rec#* }"
  read_opinion "${TEAM_ESCALATE_OPINION_SECS:-60}" || return 0
  ! opinion_refused || return 0
  sid="$(esc_first_sent_id "$Q")"
  [[ "$R_OID" =~ ^[0-9]+$ ]] && [ "$R_OID" -gt "$sid" ] \
    || { FB_REASON="opinion older than the request"; return 0; }
  if [ -n "$R_OBODY" ]; then
    case "$send" in
      picks:*) FB_REASON="conditions on multiSelect"; return 0 ;;
      pick:*) send=other ;;
    esac
    conds="$(awk 'NF { gsub(/^[ \t]+|[ \t\r]+$/, ""); printf "%s%s", (n++ ? " / " : ""), $0 }' \
      <<<"$R_OBODY")"
    text="$text — Warunki Reviewer (#$R_OID): $conds"
    body=("$(sed 's/^./    &/' <<<"$R_OBODY")")
  fi
  text="$(esc_one_line "$text")"; oid="$R_OID"
  q_lock || { FB_REASON="ledger busy"; return 0; }
  if ! evidence_holds "$rec" "$oid"; then
    q_unlock
    [ -z "$FB_REPLY" ] || append "fallback: no — evidence changed" || true
    return 0
  fi
  FINISHED=1
  ledger "opinion: $oid agree" "$ESC_FALLBACK_WHY$oid" \
    "outcome: reviewer-fallback" "ended: $(team_utc)" "    send: $send" "    reviewer: #$oid" \
    "    text: $text" ${body[@]+"${body[@]}"}
  q_unlock
  printf 'FALLBACK\nsend: %s\nreviewer: #%s\ntext: %s\n' "$send" "$oid" "$text"
  exit 0
}

wait_loop() {
  local rc id f
  DEADLINE=0
  # A request Advisor never got (a --resume after a killed send) must still end in NO-REPLY; a
  # `waiting: operator` q keeps its unbounded wait even with an outstanding seq.
  if ! esc_asked "$Q" && { [ -n "$(esc_outstanding "$Q")" ] \
    || [ "$(esc_repings "$Q")" -lt "$ESC_REPING_CAP" ]; }; then
    DEADLINE=$(( $(date +%s) + TMIN * UNIT ))
  fi
  # An eligible q's wait is bounded on every resume, so the Reviewer opinion is re-checked.
  [ "$ADVISOR_MODE" != pair ] || [ -z "$OPINION" ] || [ -z "$PEEK" ] \
    || ! esc_fallback_check "$Q" "$TIER" >/dev/null \
    || DEADLINE=$(( $(date +%s) + TMIN * UNIT ))
  # Here consume returns only on pending-operator: the Operator's wait has no deadline.
  while :; do
    if read -r id f <<<"$(next_staged)" && [ -n "$id" ]; then
      consume "$f" "$id"; DEADLINE=0; continue
    fi
    rc=0; run_bounded "$(jq -r .wait "$CFG")" "$TMP/wait" || rc=$?
    if [ "$rc" = 124 ]; then
      # The adapter stages and acks before it prints: a killed wait may leave a staged reply.
      if read -r id f <<<"$(next_staged)" && [ -n "$id" ]; then
        consume "$f" "$id"; DEADLINE=0; continue
      fi
      append "waited: $(team_utc) timeout after $TMIN min" || true
      try_fallback
      if [ -n "$FB_REPLY" ]; then
        read -r id f <<<"$FB_REPLY"; consume "$f" "$id"; DEADLINE=0; continue
      fi
      [ "$TIER" != 2 ] || no_reply "timeout after $TMIN min" "fallback: no — $FB_REASON"
      no_reply "timeout after $TMIN min"
    fi
    [ "$rc" = 0 ] || no_reply "wait failed (rc $rc)"
    id="$(sed -n '1s/^mail-id: //p' "$TMP/wait")"
    consume "$TMP/wait" "${id:--}"; DEADLINE=0
  done
}

late_read() {  # one bounded read after an answer: records any reply, never delivers
  local rc=0 id f
  if read -r id f <<<"$(next_staged)" && [ -n "$id" ]; then late_finish "$f" "$id"; fi
  DEADLINE=$(( $(date +%s) + ${TEAM_ESCALATE_LATE_SECS:-120} ))
  run_bounded "$(jq -r .wait "$CFG")" "$TMP/wait" || rc=$?
  if [ "$rc" = 124 ]; then
    # The adapter stages and acks before it prints: a killed wait may leave a staged reply.
    if read -r id f <<<"$(next_staged)" && [ -n "$id" ]; then late_finish "$f" "$id"; fi
    FINISHED=1; append "outcome: late-none" "ended: $(team_utc)" || true
    echo "LATE NONE"; exit 0
  fi
  [ "$rc" = 0 ] || no_reply "wait failed (rc $rc)"
  id="$(sed -n '1s/^mail-id: //p' "$TMP/wait")"
  late_finish "$TMP/wait" "${id:--}"
}

begin
# Before a send a rejected staged reply must not stop the re-ping; --resume rejects in the loop.
case "$MODE" in resume|late) ;; *) DRAINING=1; drain; DRAINING=0 ;; esac
prepare_payload
load_config
case "$MODE" in
  late) late_read ;;
  resume) wait_loop ;;
  # A reply already on the thread ends the re-ping; a rejected one is recorded and it goes on.
  reping) DRAINING=1; pre=0; thread_reply || pre=$?; DRAINING=0
    [ "$pre" = 0 ] || send; wait_loop ;;
  *) send; wait_loop ;;
esac
