#!/usr/bin/env bash
# Escalation for /monitor (tiers 2 and 3): send the question to FableTT, wait for his reply.
#
# Usage: bash .claude/lib/team-escalate.sh <team> <role> <2|3> <question-file>
#          [--blocks "<decision>"] [--options "<text>"] [--files "<a,b>"]
#          [--reping "<reason>" | --resume | --retier "<reason>"]
#   e.g. bash .claude/lib/team-escalate.sh alfa coder 2 "$q" --blocks "retry design of the worker"
# Default mode (open question) needs --blocks; --retier needs tier 3 after a tier-2 answer.
# Config: <main checkout>/.agents/team/escalation.local.json (shape:
#   .claude/team/escalation.local.json.example); send/wait get $1=payload file, $2=team, $3=role,
#   $4=question id, $5=thread esc-<run>-<qid>, $6=seq.
# Exit: 0 ANSWER / WITHDRAWN + the reply · 1 busy (ledger or waiter lock)
#       · 2 usage / refused state / reping limit / tier mismatch
#       · 3 NO-REPLY <reason> (repings: <n>, sent: <yes|no>)
#       · 4 final reply printed, outcome not recorded (ledger lock timeout) · 130/143 cancelled
set -euo pipefail
# Each background job gets its own process group, so the watchdog can kill an adapter's children.
set -m

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
bad() { echo "error: $*" >&2; exit 2; }
[ $# -ge 4 ] || usage
LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-lib.sh"
. "$LIB/team-escalate-lib.sh"
TEAM="$1"; ROLE="$2"; TIER="$3"; QARG="$4"; shift 4
MODE=default; REASON=""; BLOCKS=""; OPTIONS=""; FILES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --resume) [ "$MODE" = default ] || bad "one mode at most"; MODE=resume; shift; continue ;;
    --blocks|--options|--files|--reping|--retier) [ $# -ge 2 ] || usage ;;
    *) usage ;;
  esac
  case "$1" in
    --blocks) BLOCKS="$2" ;; --options) OPTIONS="$2" ;; --files) FILES="$2" ;;
    *) [ "$MODE" = default ] || bad "one mode at most"; MODE="${1#--}"; REASON="$2" ;;
  esac
  shift 2
done
team_check_name "$TEAM" || exit 2
case " $TEAM_ROLES cli " in *" $ROLE "*) ;; *) bad "unknown role $ROLE" ;; esac
case "$TIER" in 2|3) ;; *) bad "tier must be 2 or 3" ;; esac
[ "$MODE" != default ] || [ -n "$BLOCKS" ] || bad "--blocks is required"
[ "$MODE" != retier ] || [ "$TIER" = 3 ] || bad "--retier needs tier 3"
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
TICKET="$(jq -r .ticket "$CLONE/.agents/team/team.json")"
CFG="$root/.agents/team/escalation.local.json"
CHILD=""; LOCKED=""; WAITER=""; STARTED=0; FINISHED=0; DRAINING=0; SEEN=" "; TMP="$(mktemp -d)"

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
  append "outcome: cancelled" "ended: $(team_utc)" || true
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
  case "$MODE:$st" in
    *:sent|*:recorded|*:failed|*:pending|*:revoked) refuse "already answered" ;;
    *:escalated) [ "$last" != withdrawn ] || refuse "withdrawn" ;;
  esac
  case "$MODE:$st:$last" in
    default:open:*) return 0 ;;
    default:*) refuse "already escalated — use --reping or --resume" ;;
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
    default) SEQ=1; ledger "started: $(team_utc) tier $TIER" ;;
    reping) RESEND="$out"; SEQ="${out:-$(esc_next_seq "$Q")}"
      ledger "reping: $(team_utc) seq $SEQ — $REASON" ;;
    retier) SEQ="$(esc_next_seq "$Q")"; ledger "retier: $(team_utc) tier 3 seq $SEQ — $REASON" ;;
    resume) SEQ="$(esc_sent_count "$Q")"; [ "$SEQ" -ge 1 ] || SEQ=1
      ledger "resumed: $(team_utc)" ;;
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

consume() {  # consume <reply file> <id>
  SEEN="$SEEN$2 "
  if ! esc_parse "$1"; then reject "$2" unparseable "unparseable answer"; return 0; fi
  case "$R_STATUS" in
    pending-operator)
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
  for id in $(ls -1 "$QDIR" | sed -n "s/^$QID\.reply-\(.*\)\.md\$/\1/p" | sort -n); do
    case "$SEEN" in *" $id "*) continue ;; esac
    esc_seen_reply "$Q" "$id" && continue
    echo "$id $QDIR/$QID.reply-$id.md"; return 0
  done
  return 1
}

drain() {
  local id f
  while read -r id f <<<"$(next_staged)" && [ -n "$id" ]; do consume "$f" "$id"; done
}

prepare_payload() {
  local blk="$BLOCKS" kind=decision
  if [ "$MODE" = default ] || [ ! -f "$PAYLOAD" ]; then
    [ -n "$blk" ] || blk="$(esc_section "$Q" Context | sed -n 's/^- last blocker: //p')"
    esc_payload_build "$Q" "$PAYLOAD" "$TICKET" "$TEAM" "$TIER" "$THREAD" "$SEQ" \
      "${blk:-see Question}" "$OPTIONS" "$FILES"
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
  done
  TMIN="$(jq -r '.timeout_min | if type == "number" and . == floor and . >= 1 and . <= 240
    then . else empty end' "$CFG")"
  [ -n "$TMIN" ] || no_reply "invalid config: timeout_min"
  UNIT="${TEAM_ESCALATE_UNIT_SECS:-60}"
}

send() {  # a failed send keeps its seq, so the adapter's dedup key stays the same
  local k rc=0
  for k in 1 2 3; do
    [ "$k" = 1 ] || sleep $(( (k - 1) * ${TEAM_ESCALATE_BACKOFF_SECS:-60} ))
    DEADLINE=$(( $(date +%s) + TMIN * UNIT )); rc=0
    run_bounded "$(jq -r .send "$CFG")" "$TMP/send" || rc=$?
    if [ "$rc" = 0 ]; then append "sent: seq $SEQ $(team_utc)" || true; return 0; fi
  done
  [ "$rc" != 124 ] || no_reply "send timeout"
  no_reply "send failed (rc $rc)"
}

wait_loop() {
  local rc id f
  DEADLINE=0
  # A request FableTT never got (a --resume after a killed send) must still end in NO-REPLY.
  if [ -n "$(esc_outstanding "$Q")" ] \
    || { ! esc_asked "$Q" && [ "$(esc_repings "$Q")" -lt "$ESC_REPING_CAP" ]; }; then
    DEADLINE=$(( $(date +%s) + TMIN * UNIT ))
  fi
  # Here consume returns only on pending-operator: the Operator's wait has no deadline.
  while :; do
    if read -r id f <<<"$(next_staged)" && [ -n "$id" ]; then
      consume "$f" "$id"; DEADLINE=0; continue
    fi
    rc=0; run_bounded "$(jq -r .wait "$CFG")" "$TMP/wait" || rc=$?
    [ "$rc" != 124 ] || no_reply "timeout after $TMIN min"
    [ "$rc" = 0 ] || no_reply "wait failed (rc $rc)"
    id="$(sed -n '1s/^mail-id: //p' "$TMP/wait")"
    consume "$TMP/wait" "${id:--}"; DEADLINE=0
  done
}

begin
# Before a send a rejected staged reply must not stop the re-ping; --resume rejects in the loop.
[ "$MODE" = resume ] || { DRAINING=1; drain; DRAINING=0; }
prepare_payload
load_config
[ "$MODE" = resume ] || send
wait_loop
