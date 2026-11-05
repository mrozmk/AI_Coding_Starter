#!/usr/bin/env bash
# a send without a SENT receipt checks the thread first and fails fast. Cases (a)-(f).
# (b) asserts elapsed time against the backoff, so the suite runner keeps it out of a
# TEAM_SMOKE_PARALLEL batch.
# team-smoke: serial
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-1256 chore/AB-1256-no-receipt
BG=""
trap 'for p in $BG; do kill "$p" 2>/dev/null || true; done
  [ -z "$SPID" ] || kill "$SPID" 2>/dev/null || true; rm -rf "$WORK"' EXIT
RUN_ID=alfa-20261104-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"
mkdir -p "$RD/questions"
ESC="bash .claude/lib/team-escalate.sh"
# A backoff of 5 s would show as elapsed time; the fail-fast path must not sleep.
export TEAM_ESCALATE_UNIT_SECS=1 TEAM_ESCALATE_POLL=0.2 TEAM_ESCALATE_BACKOFF_SECS=5
export TEAM_ESCALATE_PEEK_SECS=1
mkdir -p "$MAIN/.agents/team"
CFG="$MAIN/.agents/team/escalation.local.json"
A6='"$1" "$2" "$3" "$4" "$5" "$6"'
session coder 1 "$BASE"

thread() { echo "esc-$RUN_ID-$QN"; }
esc() { run "$MAIN" $ESC alfa coder "$@"; }
N=100
mkq() {  # mkq → QF, QN: a hand-written open blocked question
  N=$((N + 1)); QN="q-$N"; QF="$RD/questions/$QN.md"
  printf '# %s — alfa coder attempt 1\nrole: coder\nattempt: 1\nrun: %s\nkind: blocked\n' \
    "$QN" "$RUN_ID" > "$QF"
  printf 'record: -\nanchor: x\nfingerprint: v2:none\nopened: 2026-11-04T00:00:00Z\n\n' >> "$QF"
  printf '## Summary\nWhich design?\n\n## Context\n- last blocker: -\n\n## Screen\n    x\n' >> "$QF"
}
reply() { printf '%b' "$1" > "$WORK/mail.reply.$(thread)"; }
stored() { grep -c " $(thread) " "$WORK/mail.store" || true; }
bg_esc() {  # bg_esc <args…> → BGP: team-escalate.sh in the background, stopped by bg_stop
  (cd "$MAIN" && exec $ESC alfa coder "$@") > "$WORK/bg.out" 2>&1 &
  BGP=$!; BG="$BG $BGP"
}
bg_stop() { sleep 3; kill "$BGP" 2>/dev/null || true; wait "$BGP" 2>/dev/null || true; }

# fake-mail.sh send|wait|peek <payload> <team> <role> <qid> <thread> <seq> — agent_mail's dedup
cat > "$WORK/fake-mail.sh" <<'EOF'
d="$(dirname "$0")"; store="$d/mail.store"; touch "$store"
case "$1" in
  send) key="$6-$7"
    id="$(awk -v k="$key" '$3 == k {print $1; exit}' "$store")"
    [ -n "$id" ] || { id=$(( $(wc -l < "$store") + 1 )); echo "$id $6 $key" >> "$store"; }
    if [ -e "$d/mail.noreceipt-once" ]; then rm -f "$d/mail.noreceipt-once"; exit 0; fi
    [ ! -e "$d/mail.noreceipt" ] || exit 0
    echo "SENT id=$id thread=$6" ;;
  wait) f="$d/mail.reply.$6"; while [ ! -f "$f" ]; do sleep 0.2; done; cat "$f"; rm -f "$f" ;;
  peek) f="$d/mail.reply.$6"; if [ -f "$f" ]; then cat "$f"; rm -f "$f"; else echo EMPTY; fi ;;
esac
EOF
FM="bash $WORK/fake-mail.sh"; : > "$WORK/mail.store"
jq -n --arg s "$FM send $A6" --arg w "$FM wait $A6" --arg p "$FM peek $A6" \
  '{send: $s, wait: $w, peek: $p, timeout_min: 1}' > "$CFG"

# ---- (a) AC1: a reply on the thread, an adapter without the SENT line → ANSWER ---------------
# The peek after the first failed send must find the staged reply: under load a 1 s peek bound can
# expire first (the child is killed, rc 124) and a second send runs. The reply is already on the
# thread, so a wide bound costs nothing here; (b) keeps the 1 s bound for the fail-fast path.
mkq; touch "$WORK/mail.noreceipt"; reply 'mail-id: 31\nstatus: answer\n\nA.\n'
run "$MAIN" env TEAM_ESCALATE_PEEK_SECS=15 $ESC alfa coder 2 "$QF" --blocks x
expect 0 "ANSWER" "reply on the thread without a receipt"
has "A." "$WORK/out" || fail "(a) answer text"
has "reply: 31 answer" "$QF" || fail "(a) reply not recorded"
! grep -q '^sent: ' "$QF" || fail "(a) recorded as sent"
! grep -q '^reping: ' "$QF" || fail "(a) re-pinged"
[ "$(grep -c '^failed: ' "$QF")" = 1 ] || fail "(a) failed lines: $(grep -c '^failed: ' "$QF")"
[ "$(stored)" = 1 ] || fail "(a) store: $(cat "$WORK/mail.store")"
QA="$QF"; QNA="$QN"

# ---- (b) AC2: a contract-breaking adapter → one fail-fast NO-REPLY, no backoff ---------------
mkq; t0=$(date +%s)
esc 2 "$QF" --blocks x
el=$(( $(date +%s) - t0 ))
expect 3 "NO-REPLY invalid adapter (no SENT receipt)" "adapter without a receipt"
[ "$(wc -l < "$WORK/out" | tr -d ' ')" = 1 ] || fail "(b) more than one line"
[ "$(grep -c '^failed: seq 1 .* — no receipt$' "$QF")" = 2 ] || fail "(b) attempts"
[ "$el" -lt "$TEAM_ESCALATE_BACKOFF_SECS" ] || fail "(b) backoff slept (${el}s)"
[ "$(stored)" = 1 ] || fail "(b) dedup: $(cat "$WORK/mail.store")"
u="$( . "$MAIN/.claude/lib/team-escalate-lib.sh"; esc_unsent "$QF" )"
[[ "$u" == $'1\t'*$'\tfailed\tinvalid adapter (no SENT receipt)' ]] || fail "(b) esc_unsent: $u"

# ---- (c) a re-ping finds the reply on the thread and sends nothing ---------------------------
reply 'mail-id: 32\nstatus: answer\n\nC.\n'
esc 2 "$QF" --reping "transport"
expect 0 "ANSWER" "re-ping with a reply on the thread"
has "reply: 32 answer" "$QF" || fail "(c) reply not recorded"
[ "$(stored)" = 1 ] || fail "(c) the re-ping sent: $(cat "$WORK/mail.store")"
[ "$(grep -c '^failed: ' "$QF")" = 2 ] || fail "(c) the re-ping tried a send"

# ---- (d) --retier after a receipt-less answer takes a fresh seq ------------------------------
QF="$QA"; QN="$QNA"; rm -f "$WORK/mail.noreceipt"
bg_esc 3 "$QF" --retier "operator"; bg_stop
grep -q '^retier: .* tier 3 seq 2 — operator$' "$QF" || fail "(d) retier seq: $(cat "$QF")"
grep -q "^sent: seq 2 .* thread $(thread)$" "$QF" || fail "(d) retier not sent"
grep -q " $(thread)-2$" "$WORK/mail.store" || fail "(d) no new key: $(cat "$WORK/mail.store")"
[ "$(stored)" = 2 ] || fail "(d) store: $(cat "$WORK/mail.store")"

# ---- (e) a recovered pending-operator keeps an unbounded wait across --resume -----------------
mkq; touch "$WORK/mail.noreceipt"; reply 'mail-id: 33\nstatus: pending-operator\neta: x\n\nAsked.\n'
bg_esc 2 "$QF" --blocks x; bg_stop
has "reply: 33 pending-operator" "$QF" && grep -q '^waiting: operator ' "$QF" \
  || fail "(e) pending-operator not recorded: $(cat "$QF")"
! grep -q '^outcome: no-reply' "$QF" || fail "(e) the first wait was bounded"
bg_esc 2 "$QF" --resume; bg_stop
grep -q '^resumed: ' "$QF" || fail "(e) resume did not start: $(cat "$WORK/bg.out")"
! grep -q '^outcome: no-reply' "$QF" || fail "(e) --resume re-armed the deadline: $(cat "$QF")"

# ---- (f) one lost receipt is recovered by the immediate retry (dedup), no backoff ------------
mkq; rm -f "$WORK/mail.noreceipt"; touch "$WORK/mail.noreceipt-once"
bg_esc 2 "$QF" --blocks x; bg_stop
[ "$(grep -c '^failed: seq 1 .* — no receipt$' "$QF")" = 1 ] || fail "(f) failed: $(cat "$QF")"
grep -q "^sent: seq 1 .* thread $(thread)$" "$QF" || fail "(f) not sent within the 3 s window"
[ "$(stored)" = 1 ] || fail "(f) dedup: $(cat "$WORK/mail.store")"

echo "team-smoke-13: OK"
