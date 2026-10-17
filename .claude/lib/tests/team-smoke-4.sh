#!/usr/bin/env bash
# Question escalation (TT-799): team-answer menu actions, team-question ledger, team-escalate.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team TT-799 chore/TT-799-tiers
RUN_ID=alfa-20261006-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
ANSWER="bash .claude/lib/team-answer.sh"
Q="bash .claude/lib/team-question.sh"
ESC="bash .claude/lib/team-escalate.sh"
cat > "$WORK/menu" <<'EOF'
☐ Retry
Which retry design for the worker?
❯ 1. Counter + backoff (Recommended)
  2. Counter only
  3. Dead-letter table
  4. Type something.
Enter to select · ↑/↓ to navigate · Esc to cancel
EOF
{ cat "$WORK/menu"; echo "Review your answers"; } > "$WORK/multi"
printf 'Bash command\n  az webapp deploy --name shell-sk\nDo you want to proceed?\n❯ 1. Yes\n' > "$WORK/perm"
echo "> waiting for the supervisor's answer" > "$WORK/idle"
echo "✻ Working… (esc to interrupt)" > "$WORK/busy"
downs() { grep -c 'send-keys -t =alfa-planner: Down' "$STUB_LOG" || true; }
no_keys() { ! has "send-keys" "$STUB_LOG" || fail "$1: keys were sent"; }
qf() { echo "$RD/questions/$1.md"; }
last_line() { tail -n 1 "$WORK/out"; }

# ---- (29) team-answer menu actions ------------------------------------------------------------
session planner 1 "$BASE"
export STUB_PANE="$WORK/menu" STUB_TMUX_ALIVE=0
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa planner pick 2
expect 0 "sent pick to alfa-planner" "answer pick 2"
[ "$(downs)" = 1 ] || fail "pick 2 did not press Down once"
has "send-keys -t =alfa-planner: Enter" "$STUB_LOG" || fail "pick 2 did not press Enter"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa planner pick 9
expect 1 "option 9 not on screen" "answer pick 9"; no_keys "pick 9"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa planner other "counter only, no table"
expect 0 "sent other" "answer other"
[ "$(downs)" = 3 ] || fail "other did not move to Type something."
has "send-keys -t =alfa-planner: -l -- counter only, no table" "$STUB_LOG" || fail "other did not type"
has "send-keys -t =alfa-planner: Enter" "$STUB_LOG" || fail "other did not press Enter"
: > "$STUB_LOG"; STUB_PANE="$WORK/perm" run "$MAIN" $ANSWER alfa planner pick 2
expect 1 "error:" "pick on a permission prompt"; no_keys "pick on a permission prompt"
: > "$STUB_LOG"; STUB_PANE="$WORK/multi" run "$MAIN" $ANSWER alfa planner pick 2
expect 1 "multi-question menu — answer in the window (tier 3)" "pick on a multi-question menu"
no_keys "pick on a multi-question menu"
run "$MAIN" $ANSWER alfa planner pick
expect 2 "" "pick without a number"

# ---- (30) team-question open + bound answer (blocked) -----------------------------------------
session coder 1 "$BASE"; export STUB_PANE="$WORK/idle"
[ "$(basename "$(record --verdict blocked --message "counter vs dead-letter?")")" = coder-1-1.json ] \
  || fail "fixture: first blocked record"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Which retry design?"
expect 0 "" "open blocked"
head -n 1 "$WORK/out" | grep -q '^q-1 ' || fail "open did not allocate q-1"
has "record: coder-1-1.json" "$(qf q-1)" || fail "q-1 lacks the record binding"
grep -q '^fingerprint: [0-9a-f]\{40\}$' "$(qf q-1)" || fail "q-1 lacks a fingerprint"
has "- last blocker: - [coder 1] counter vs dead-letter?" "$(qf q-1)" || fail "q-1 lacks the blocker"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Which retry design?"
expect 0 "(existing, state=open)" "open again while open"; has "q-1 " "$WORK/out" || fail "reopen id"
[ ! -e "$(qf q-2)" ] || fail "reopen allocated q-2"
cp "$RD/notes.md" "$WORK/notes0"
: > "$STUB_LOG"
STUB_PANE="$WORK/busy" run "$MAIN" $Q alfa answer q-1 --tier 1 --author supervisor --why "inside plan" \
  --text "Counter + backoff." --send say
expect 1 "stale: role is busy" "answer a busy role"; no_keys "answer a busy role"
cmp -s "$RD/notes.md" "$WORK/notes0" || fail "a stale answer wrote notes"
run "$MAIN" $Q alfa answer q-1 --tier 1 --author supervisor --why "inside plan" \
  --text "Counter + backoff." --send say
expect 0 "sent say" "tier 1 answer"
has "send-keys -t =alfa-coder: -l -- Counter + backoff." "$STUB_LOG" || fail "answer not typed"
has "delivery: sent" "$(qf q-1)" || fail "q-1 not marked sent"
has "- q-1 [tier 1, supervisor] Which retry design? → Counter + backoff. — inside plan" "$RD/notes.md" \
  || fail "notes lack the decision line"
[ "$(grep '^## ' "$RD/notes.md" | tail -n 1)" = "## Blockers" ] || fail "## Blockers is not last"
grep '^## ' "$RD/notes.md" | grep -A1 -x '## Supervised decisions' | grep -qx '## Blockers' \
  || fail "## Supervised decisions is not right before ## Blockers"
cp "$STUB_LOG" "$WORK/log0"
run "$MAIN" $Q alfa answer q-1 --tier 1 --author supervisor --why x --text y --send say
expect 1 "already answered" "answer twice"; cmp -s "$STUB_LOG" "$WORK/log0" || fail "second answer sent"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Which retry design?"
expect 0 "(existing, state=sent)" "open again after the answer"; [ ! -e "$(qf q-2)" ] || fail "re-arm q-2"
record --verdict blocked --message "second" >/dev/null
tail -n 1 "$RD/notes.md" | grep -qF -- '- [coder 1] second' || fail "a later blocker missed ## Blockers"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Second view"
expect 0 "q-2 " "open the second record"; has "record: coder-1-2.json" "$(qf q-2)" || fail "q-2 binding"
record --verdict blocked --message "third" >/dev/null
: > "$STUB_LOG"
run "$MAIN" $Q alfa answer q-2 --tier 1 --author supervisor --why x --text y --send say
expect 1 "stale: a newer record exists" "answer an outdated record"; no_keys "outdated record"
! grep -q -- '- q-2 ' "$RD/notes.md" || fail "a stale answer reached notes"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Third"
expect 0 "q-3 " "open the third record"
STUB_PANE="$WORK/menu" run "$MAIN" $Q alfa answer q-3 --tier 1 --author supervisor --why x --text y --send say
expect 1 "stale: screen changed since open" "answer after the screen changed"; no_keys "screen changed"
run "$MAIN" $Q alfa answer q-3 --tier 1 --author supervisor --why x --text y --send none
expect 1 "tier 3 only" "send none at tier 1"
STUB_TMUX_ALIVE=1 run "$MAIN" $Q alfa answer q-3 --tier 1 --author supervisor --why "in plan" \
  --text "Table." --send say
expect 1 "delivery failed" "delivery to a gone session"
grep -q '^delivery: failed' "$(qf q-3)" || fail "q-3 not marked failed"
grep -q -- '- q-3 \[tier 1' "$RD/notes.md" || fail "notes lack the q-3 decision line"
! has "DELIVERY FAILED" "$RD/notes.md" || fail "notes carry a delivery failure"
run "$MAIN" $Q alfa answer q-3 --tier 1 --author supervisor --why x --text y --send say
expect 1 "tier 3 only" "tier 1 after a failed delivery"
true & DEAD=$!; wait $DEAD
mkdir "$(qf q-3).lock"; echo "$DEAD" > "$(qf q-3).lock/pid"; touch -t 202601010000 "$(qf q-3).lock"
TEAM_QUESTION_LOCK_SECS=1 run "$MAIN" $Q alfa answer q-3 --tier 3 --author operator --why "window" \
  --text "Table." --send none
expect 1 "stale: team-question.sh alfa unlock q-3" "answer under a stale lock"
has "busy" "$WORK/out" || fail "stale lock not reported as busy"
run "$MAIN" $Q alfa unlock q-3
expect 0 "removed stale lock" "unlock"; [ ! -d "$(qf q-3).lock" ] || fail "unlock left the lock"
run "$MAIN" $Q alfa answer q-3 --tier 3 --author operator --why "window" --text "Table." --send none
expect 0 "recorded" "tier 3 record after unlock"; has "delivery: recorded only" "$(qf q-3)" || fail "q-3"
run "$MAIN" $Q alfa answer q-2 --run alfa-19990101-000000 --tier 3 --author operator --why x \
  --text y --send none
expect 1 "stale: run changed" "answer from another run"; ! has "## Answer" "$(qf q-2)" || fail "q-2"

# ---- (31) menu anchor binding + none + revoke + list + policy ---------------------------------
session planner 1 "$BASE"; export STUB_PANE="$WORK/menu"
run "$MAIN" $Q alfa open planner --kind menu --anchor "Not on screen" --summary x
expect 1 "anchor not on screen" "open with a missing anchor"
run "$MAIN" $Q alfa open planner --kind menu --anchor "Which retry design for the worker?" \
  --summary "Retry design"
expect 0 "q-4 " "open a menu"
: > "$STUB_LOG"
run "$MAIN" $Q alfa answer q-4 --tier 1 --author supervisor --why "planner recommended" --send pick:1
expect 0 "sent pick" "answer a menu"
has "send-keys -t =alfa-planner: Enter" "$STUB_LOG" || fail "pick:1 no Enter"
[ "$(downs)" = 0 ] || fail "pick:1 pressed Down"
run "$MAIN" $Q alfa open planner --kind menu --anchor "Which retry design for the worker?" \
  --summary "Retry design"
expect 0 "(existing, state=sent)" "reopen an answered menu"
run "$MAIN" $Q alfa open planner --kind menu --anchor "1. Counter + backoff (Recommended)" \
  --summary "Retry v2"
expect 0 "q-5 " "open another anchor"
: > "$STUB_LOG"
run "$MAIN" $Q alfa answer q-5 --tier 1 --author supervisor --why x --text y --send say
expect 1 "--send say does not fit a menu question" "say to a menu"; no_keys "say to a menu"
STUB_PANE="$WORK/perm" run "$MAIN" $Q alfa answer q-5 --tier 1 --author supervisor --why x --send pick:2
expect 1 "stale:" "answer a menu that is gone"; no_keys "menu gone"
run "$MAIN" $Q alfa answer q-5 --tier 3 --author operator --why "answered in window" \
  --text "Counter only" --send none
expect 0 "" "record a window answer"; no_keys "send none"
has "delivery: recorded only" "$(qf q-5)" || fail "q-5 not recorded only"
! grep -q -- '- q-5 ' "$RD/notes.md" || fail "a tier 3 answer reached notes"
cp "$RD/notes.md" "$WORK/notes.before"
: > "$STUB_LOG"
STUB_PANE="$WORK/idle" run "$MAIN" $Q alfa revoke q-4 --why "Operator prefers table"
expect 0 "" "revoke q-4"
has "## Revoked" "$(qf q-4)" && [ "$(grep '^delivery:' "$(qf q-4)" | tail -n 1)" = "delivery: sent" ] \
  || fail "q-4 revoke not recorded as sent"
has "-l -- The supervisor's answer to q-4 is revoked by the Operator" "$STUB_LOG" || fail "revoke not typed"
cmp -s "$RD/notes.md" "$WORK/notes.before" || fail "revoke wrote notes"
session coder 2 "$BASE"; : > "$STUB_LOG"
STUB_PANE="$WORK/idle" run "$MAIN" $Q alfa revoke q-1 --why "wrong call"
expect 1 "revoke recorded, not delivered" "revoke after a new attempt"; no_keys "revoke q-1"
has "## Revoked" "$(qf q-1)" && grep -q '^delivery: not sent' "$(qf q-1)" || fail "q-1 revoke"
run "$MAIN" $Q alfa answer q-4 --tier 1 --author supervisor --why x --text y --send say
expect 1 "tier 3 only" "tier 1 after a revoke"
run "$MAIN" $Q alfa list
expect 0 "" "list"
[ "$(last_line)" = "total=5 tier1=0 tier2=0 tier3=2 revoked=2 failed=0 pending=0 open=1 escalating=0 escalated=0 waiting=0" ] \
  || fail "list counts: $(last_line)"
session planner 1 "$BASE"; export STUB_PANE="$WORK/menu"
run "$MAIN" $Q alfa open planner --kind menu --anchor "2. Counter only" --summary "Interrupted"
expect 0 "q-6 " "open a third anchor"
printf '\n## Answer\ntier: 1\nauthor: supervisor\nanswer: x\nwhy: y\nanswered: 2026-10-06T00:00:00Z\ndelivery: pending\n' \
  >> "$(qf q-6)"
run "$MAIN" $Q alfa list
has "q-6 planner menu tier=1 author=supervisor state=pending" "$WORK/out" || fail "q-6 not pending"
run "$MAIN" $Q alfa answer q-6 --tier 1 --author supervisor --why x --text y --send say
expect 1 "delivery unknown" "re-send a pending answer"
run "$MAIN" $Q alfa answer q-6 --tier 3 --author operator --why "checked window" --text x --send none
expect 0 "" "record a pending answer at tier 3"
run "$MAIN" $Q alfa list
[ "$(last_line)" = "total=6 tier1=0 tier2=0 tier3=3 revoked=2 failed=0 pending=0 open=1 escalating=0 escalated=0 waiting=0" ] \
  || fail "list counts after q-6: $(last_line)"
echo '{"permissions":{"ask":["Bash(sqlcmd:*)"],"deny":["Read(**/.env)"]}}' > "$CLONE/.claude/settings.local.json"
run "$MAIN" $Q alfa policy
expect 0 "ask  .claude/settings.local.json: Bash(sqlcmd:*)" "policy ask"
has "deny  .claude/settings.local.json: Read(**/.env)" "$WORK/out" || fail "policy deny"
has "missing: .claude/settings.json" "$WORK/out" || fail "policy missing file"

# ---- (32) team-escalate (TT-852: FableTT reply protocol) --------------------------------------
mkdir -p "$MAIN/.agents/team"
export TEAM_ESCALATE_UNIT_SECS=1 TEAM_ESCALATE_POLL=0.2 TEAM_ESCALATE_BACKOFF_SECS=0
export SENT="$WORK/sent" READY="$WORK/ready" CNT="$WORK/cnt"
CFG="$MAIN/.agents/team/escalation.local.json"
cfg() {  # cfg <send> <wait> [timeout_min]
  jq -n --arg s "$1" --arg w "$2" --argjson t "${3:-2}" '{send: $s, wait: $w, timeout_min: $t}' > "$CFG"
}
gone() {  # gone <pattern> <secs> — no process matches within <secs>
  local i=0
  while pgrep -f "$1" >/dev/null; do [ "$i" -lt "$2" ] || return 1; sleep 1; i=$((i + 1)); done
}
SEND='printf "%s|%s|%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" "$5" "$6" >> "$SENT"'
ANS='printf "status: answer\nauthor: FableTT+AstraTT\n\nUse counter + backoff.\n"'
# First wait call prints pending-operator, the next ones run $1 (a counter in $CNT).
pend() { printf 'n=$(cat "$CNT" 2>/dev/null || echo 0); echo $((n + 1)) > "$CNT"; if [ "$n" = 0 ]; then printf "status: pending-operator\\neta: tonight\\n\\nAsked the Operator.\\n"; else %s; fi' "$1"; }
pf() { echo "$(dirname "$QF")/$QN.payload.md"; }
QF="$(qf q-2)"; QN=q-2
run "$MAIN" $ESC alfa coder 2 "$QF" --blocks "retry design of the worker"
expect 3 "NO-REPLY no config" "escalate without config"
has "outcome: no-reply — no config" "$QF" || fail "q-2 lacks outcome: no-reply"
has "sent: no" "$WORK/out" || fail "no config reported a delivered request"
run "$MAIN" $ESC alfa coder 2 "$QF" --blocks x
expect 2 "use --reping or --resume" "default mode on an escalated question"
cfg "true" "true" 0
run "$MAIN" $ESC alfa coder 2 "$QF" --reping "config fixed"
expect 3 "invalid config: timeout_min" "re-ping with timeout_min 0"
cfg "$SEND" "$ANS"; : > "$SENT"
run "$MAIN" $ESC alfa coder 2 "$QF" --reping "config fixed"
expect 0 "ANSWER" "escalate with an answer"; has "status: answer" "$WORK/out" || fail "no status"
[ "$(cat "$SENT")" = "$(cd "$(dirname "$QF")" && pwd -P)/q-2.payload.md|alfa|coder|q-2|esc-alfa-20261006-000000-q-2|1" ] \
  || fail "send args: $(cat "$SENT")"
for l in "ticket: TT-799" "team: alfa" "role: coder" "run: alfa-20261006-000000" "question: q-2" \
  "tier: 2" "decision-needed-from: analysts" "thread: esc-alfa-20261006-000000-q-2" "seq: 1" \
  "## Question" "## Options" "## Files" "- spec:" "## Screen"; do
  grep -qxF -- "$l" "$(pf)" || grep -qF -- "$l" "$(pf)" || fail "payload lacks '$l'"
done
grep -A1 -x '## Blocks' "$(pf)" | grep -qx 'retry design of the worker' || fail "payload ## Blocks"
has "Second view" "$(pf)" || fail "payload lacks the question text"
has "outcome: answer" "$QF" && has "reply: - answer" "$QF" || fail "q-2 lacks outcome: answer"
run "$MAIN" $ESC alfa coder 2 "$QF" --reping x
expect 2 "" "re-ping an answered escalation"
RD0="$RD"; RUN_ID=alfa-20261006-000032; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"
mkdir -p "$RD"; session coder 1 "$BASE"; export STUB_PANE="$WORK/idle"
fresh() {  # fresh <summary> → QF, QN: a new open question in this run
  record --verdict blocked --message "$1" >/dev/null
  run "$MAIN" $Q alfa open coder --kind blocked --summary "$1"
  expect 0 "" "open $1"
  QN="$(head -n 1 "$WORK/out" | cut -d' ' -f1)"; QF="$(qf "$QN")"
}
esc() { run "$MAIN" $ESC alfa coder "$@"; }
fresh "disagree"; cfg true 'printf "status: disagree\n\nA: counter. B: table.\n"'
esc 2 "$QF" --blocks x
expect 3 "status: disagree is retired" "escalate with a disagreement"
has "reply: - disagree" "$QF" || fail "disagree reply not recorded"
cfg true 'echo ok'
esc 2 "$QF" --reping "disagree retired"
expect 3 "unparseable answer" "re-ping with an unparseable reply"
has "(repings: 1, sent: yes)" "$WORK/out" || fail "re-ping count"
fresh "deadline"; cfg true 'sleep 31.5'; s=$(date +%s)
esc 2 "$QF" --blocks x
expect 3 "timeout after 2 min" "escalate past the deadline"
[ $(( $(date +%s) - s )) -lt 10 ] || fail "timeout took too long"; gone 'sleep 31.5' 0 || fail "wait survived"
fresh "send deadline"; cfg 'sleep 31.6' true
esc 2 "$QF" --blocks x
expect 3 "send timeout" "send past the deadline"; gone 'sleep 31.6' 0 || fail "send survived"
! has "sent: seq" "$QF" || fail "a timed-out send was recorded as sent"
fresh "wait child"; cfg true 'sleep 31.9 & exit 1'
esc 2 "$QF" --blocks x
expect 3 "wait failed (rc 1)" "wait leaves a child behind"; gone 'sleep 31.9' 3 || fail "child survived"
fresh "pending"; rm -f "$CNT"; cfg true "$(pend 'sleep 3; printf "status: answer\n\nGo with the table.\n"')"
esc 2 "$QF" --blocks x
expect 0 "ANSWER" "pending-operator, then an answer past the deadline"
has "Go with the table." "$WORK/out" || fail "pending answer body"
has "waiting: operator" "$QF" && has "reply: - pending-operator" "$QF" || fail "pending not recorded"
fresh "tier 3"; cfg true 'printf "status: answer\ndecided-by: analysts\n\nTable.\n"'
esc 3 "$QF" --blocks x
expect 3 "tier 3 needs the Operator's decision" "tier-3 answer by the analysts"
cfg true 'printf "status: answer\ndecided-by: operator\n\nTable.\n"'
esc 3 "$QF" --reping "needs the Operator"
expect 3 "tier 3 needs the Operator's decision" "tier-3 answer without operator-ref"
esc 2 "$QF" --reping x
expect 2 "tier mismatch" "re-ping at another tier"
cfg true 'printf "status: answer\ndecided-by: operator\noperator-ref: x sha256:abcd1234\n\nTable.\n"'
esc 3 "$QF" --reping "needs the Operator"
expect 0 "ANSWER" "tier-3 answer with the Operator's decision"
fresh "unverified"; cfg true 'printf "status: unverified-operator-ref\ndecided-by: operator\n\nT.\n"'
esc 3 "$QF" --blocks x
expect 3 "operator-ref not verified" "unverified operator-ref"
fresh "withdrawn"; cfg true 'printf "status: withdrawn\n\nThe coder already decided.\n"'
esc 2 "$QF" --blocks x
expect 0 "WITHDRAWN" "withdrawn"; has "outcome: withdrawn" "$QF" || fail "withdrawn not recorded"
esc 2 "$QF" --reping x
expect 2 "withdrawn" "re-ping a withdrawn escalation"
fresh "sticky"; rm -f "$CNT"; cfg true "$(pend 'exit 1')"
esc 2 "$QF" --blocks x
expect 3 "wait failed" "pending-operator, then a failed wait"; has "sent: yes" "$WORK/out" || fail "sent flag"
run "$MAIN" $Q alfa list
grep -q "^$QN .*state=waiting-operator$" "$WORK/out" || fail "$QN not waiting-operator"
has " waiting=1" "$WORK/out" || fail "list lacks waiting=1"
cfg true 'sleep 3; printf "status: answer\n\nGo.\n"'
esc 2 "$QF" --reping "wait failed"
expect 0 "ANSWER" "sticky wait has no deadline"
has "reping-kind: transport" "$(pf)" && has "reping: wait failed" "$(pf)" || fail "transport re-ping payload"
fresh "failed send"; : > "$SENT"; cfg "$SEND; exit 1" "$ANS"
esc 2 "$QF" --blocks x
expect 3 "send failed (rc 1)" "failed send"; has "sent: no" "$WORK/out" || fail "failed send flag"
[ "$(wc -l < "$SENT" | tr -d ' ')" = 3 ] || fail "send attempts: $(cat "$SENT")"
! has "sent: seq" "$QF" || fail "a failed send was recorded"
: > "$SENT"; cfg "$SEND" "$ANS"
esc 2 "$QF" --reping "send failed"
expect 0 "ANSWER" "re-send after a failed send"
[ "$(tail -n 1 "$SENT" | cut -d'|' -f6)" = 1 ] || fail "re-send changed the seq: $(cat "$SENT")"
grep -q '^sent: seq 1 ' "$QF" || fail "re-send not recorded"
fresh "cap"; cfg "$SEND" 'exit 1'
esc 2 "$QF" --blocks x; expect 3 "wait failed" "cap: first send"
esc 2 "$QF" --reping a; expect 3 "(repings: 1, sent: yes)" "cap: re-ping 1"
esc 2 "$QF" --reping b; expect 3 "(repings: 2, sent: yes)" "cap: re-ping 2"
n0=$(wc -l < "$SENT")
esc 2 "$QF" --reping c; expect 2 "reping limit (2 delivered)" "cap: re-ping 3"
esc 2 "$QF" --resume; expect 3 "wait failed" "resume after the cap"
[ "$(wc -l < "$SENT")" = "$n0" ] || fail "resume sent the question"
grep -q '^resumed: ' "$QF" || fail "resume not recorded"
printf 'mail-id: 77\nstatus: answer\n\nStaged answer.\n' > "$(dirname "$QF")/$QN.reply-77.md"
cfg true 'exit 1'
esc 2 "$QF" --resume
expect 0 "ANSWER" "staged reply replay"; has "Staged answer." "$WORK/out" || fail "staged body"
! has "mail-id:" "$WORK/out" || fail "mail-id leaked into the reply"
grep -A1 -x 'reply: 77 answer' "$QF" | grep -qx 'outcome: answer' || fail "reply 77 not consumed with its outcome"
fresh "replay"; cfg true 'exit 1'
esc 2 "$QF" --blocks x; expect 3 "wait failed" "replay: first send"
D="$(dirname "$QF")"
printf 'mail-id: 50\nstatus: pending-operator\n\nAsked.\n' > "$D/$QN.reply-50.md"
esc 2 "$QF" --resume; expect 3 "wait failed" "replay: staged pending"
has "reply: 50 pending-operator" "$QF" || fail "staged pending not recorded"
printf 'mail-id: 50\nstatus: answer\n\nSTALE-BODY\n' > "$D/$QN.reply-50.md"
printf 'mail-id: 49\nstatus: answer\n\nTMP-BODY\n' > "$D/$QN.reply-49.md.tmp"
printf 'mail-id: 51\nstatus: answer\n\nFresh body.\n' > "$D/$QN.reply-51.md"
esc 2 "$QF" --resume; expect 0 "Fresh body." "replay skips a recorded id"
! has "STALE-BODY" "$WORK/out" && ! has "TMP-BODY" "$WORK/out" || fail "replayed a recorded id or a tmp file"
fresh "waiter"; cfg true 'exit 1'
esc 2 "$QF" --blocks x; expect 3 "wait failed" "waiter: first send"
mkdir "$QF.wait"; sleep 30 & WP=$!; echo "$WP" > "$QF.wait/pid"
esc 2 "$QF" --resume; expect 1 "busy (waiter pid $WP)" "a live waiter"
kill "$WP"; wait "$WP" 2>/dev/null || true
esc 2 "$QF" --resume; expect 3 "wait failed" "a dead waiter is taken over"
[ ! -e "$QF.wait" ] || fail "waiter lock left behind"
fresh "retier"; cfg "$SEND" 'printf "status: answer\n\nAnalysts: use the counter.\n"'
esc 2 "$QF" --blocks x; expect 0 "ANSWER" "retier: tier-2 answer"
cp "$QF" "$WORK/q.before"
esc 2 "$QF" --retier "needs Operator"; expect 2 "" "retier at tier 2"
cmp -s "$QF" "$WORK/q.before" || fail "a refused retier changed the ledger"
cfg "$SEND" 'exit 1'
esc 3 "$QF" --retier "needs Operator"; expect 3 "wait failed" "retier"
for l in "tier: 3" "decision-needed-from: operator" "## Analysts' recommendation" \
  "Analysts: use the counter." "reping: needs Operator"; do
  has "$l" "$(pf)" || fail "retier payload lacks '$l'"
done
grep -q '^retier: .* tier 3 seq 2 — needs Operator$' "$QF" || fail "retier line"
fresh "legacy"
printf '\n## Escalation\nstarted: 2026-10-01T00:00:00Z\noutcome: disagree\nended: 2026-10-01T00:01:00Z\n' >> "$QF"
cp "$QF" "$WORK/q.before"
esc 3 "$QF" --retier x; expect 2 "needs a recorded tier-2 answer" "retier without an answer"
cmp -s "$QF" "$WORK/q.before" || fail "a refused retier changed the legacy ledger"
cfg "$SEND" "$ANS"
esc 2 "$QF" --reping "legacy"; expect 0 "ANSWER" "re-ping a legacy escalation"
grep -A1 -x '## Blocks' "$(pf)" | grep -qF -- '- [coder 1] legacy' || fail "legacy payload ## Blocks"
fresh "rejected then valid"; cfg true 'exit 1'
esc 2 "$QF" --blocks x; expect 3 "wait failed" "rejected: first send"
printf 'mail-id: 77\nstatus: disagree\n\nA or B.\n' > "$(dirname "$QF")/$QN.reply-77.md"
printf 'mail-id: 78\nstatus: answer\n\nB.\n' > "$(dirname "$QF")/$QN.reply-78.md"
esc 2 "$QF" --resume; expect 3 "disagree is retired" "rejected staged reply"
has "reply: 77 disagree" "$QF" || fail "rejected reply not recorded"
esc 2 "$QF" --resume; expect 0 "ANSWER" "the next staged reply"
fresh "cap, then retier"; cfg "$SEND" 'exit 1'
esc 2 "$QF" --blocks x; esc 2 "$QF" --reping a
cfg "$SEND" "$ANS"; esc 2 "$QF" --reping b; expect 0 "ANSWER" "cap+retier: answer"
cfg "exit 1" 'exit 1'
esc 3 "$QF" --retier "needs Operator"; expect 3 "sent: no" "retier with a failing send"
: > "$SENT"; cfg "$SEND" 'exit 1'
esc 3 "$QF" --reping "send failed"; expect 3 "wait failed" "re-send a retier past the cap"
[ "$(tail -n 1 "$SENT" | cut -d'|' -f6)" = 4 ] || fail "retier re-send seq: $(cat "$SENT")"
grep -q '^sent: seq 4 ' "$QF" && has "tier: 3" "$(pf)" || fail "retier re-send not recorded"
fresh "staged pending"; cfg "$SEND" 'exit 1'
esc 2 "$QF" --blocks x; expect 3 "wait failed" "staged pending: first send"
printf 'mail-id: 90\nstatus: pending-operator\n\nAsked.\n' > "$(dirname "$QF")/$QN.reply-90.md"
esc 2 "$QF" --reping "still nothing"; expect 3 "wait failed" "staged pending before a re-ping"
awk '/^waiting: /{w = NR} /^sent: seq 2 /{s = NR} END{exit !(w && s && w < s)}' "$QF" \
  || fail "staged pending not drained before the send"
has "reping-kind: transport" "$(pf)" || fail "staged pending re-ping kind"
fresh "cancel"; rm -f "$CNT" "$READY"
cfg true "$(pend 'trap "" TERM; touch "$READY"; sleep 31.8')"
( cd "$MAIN" && exec bash .claude/lib/team-escalate.sh alfa coder 2 "$QF" --blocks x ) > "$WORK/esc" 2>&1 & EP=$!
i=0; until [ -e "$READY" ] && pgrep -f 'sleep 31.8' >/dev/null; do
  [ "$i" -lt 50 ] || fail "escalation adapter did not start"; sleep 0.2; i=$((i + 1))
done
kill -TERM "$EP"; set +e; wait "$EP"; rc=$?; set -e
[ "$rc" = 143 ] || fail "cancelled escalation exit $rc"
gone 'sleep 31.8' 5 || fail "TERM-ignoring adapter survived"
[ "$(grep '^outcome:' "$QF" | tail -n 1)" = "outcome: cancelled" ] || fail "no outcome: cancelled"
run "$MAIN" $Q alfa list
grep -q "^$QN .*state=waiting-operator$" "$WORK/out" || fail "TERM left $QN outside waiting-operator"
esc 2 "$RD0/questions/q-1.md" --blocks x
expect 2 "already answered" "escalate a revoked question"
fresh "locked"; mkdir "$QF.lock"
TEAM_QUESTION_LOCK_SECS=1 esc 2 "$QF" --blocks x
[ "$RC" != 0 ] && has "busy (lock held" "$WORK/out" || fail "escalate ignored the lock"
! grep -q '^started:' "$QF" || fail "escalate started under a lock"
rmdir "$QF.lock"
cfg true 'mkdir "$(dirname "$1")/$4.md.lock"; printf "status: answer\n\nUse the table.\n"'
TEAM_QUESTION_LOCK_SECS=1 esc 2 "$QF" --blocks x
expect 4 "ANSWER" "escalate when the outcome cannot be recorded"
has "Use the table." "$WORK/out" && has "outcome not recorded" "$WORK/out" || fail "exit 4 output"
! grep -q '^reply: ' "$QF" || fail "exit 4 recorded the reply"
rmdir "$QF.lock"
esc 1 "$QF" --blocks x
expect 2 "" "escalate at tier 1"
echo x > "$WORK/q-9.md"
esc 2 "$WORK/q-9.md" --blocks x
expect 2 "" "escalate a file outside the clone"
RUN_ID=alfa-20261006-000000; echo "$RUN_ID" > "$TD/run"; RD="$RD0"
session planner 1 "$BASE"; export STUB_PANE="$WORK/menu"

# ---- (33) busy role: deferred fingerprint, author, dash text ----------------------------------
session coder 3 "$BASE"; export STUB_PANE="$WORK/idle"
record --verdict blocked --message "busy case" >/dev/null
STUB_PANE="$WORK/busy" run "$MAIN" $Q alfa open coder --kind blocked --summary "Busy"
expect 0 "fingerprint deferred: role is busy" "open blocked on a busy role"
head -n 1 "$WORK/out" | grep -q '^q-7 ' || fail "busy open did not allocate q-7"
grep -q '^fingerprint: -$' "$(qf q-7)" || fail "q-7 fingerprint not deferred"
STUB_PANE="$WORK/busy" run "$MAIN" $Q alfa open coder --kind idle --anchor "esc to interrupt" \
  --summary x
expect 1 "is busy" "open idle on a busy role"
: > "$STUB_LOG"
run "$MAIN" $Q alfa answer q-7 --tier 1 --author supervisor --why x --text y --send say
expect 1 "stale: fingerprint not recorded" "answer a deferred question"; no_keys "deferred"
run "$MAIN" $Q alfa answer q-7 --tier 1 --author $'super\nvisor' --why x --text y --send say
expect 1 "--author must be one line" "two-line author"; no_keys "two-line author"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Busy"
expect 0 "(existing, state=open)" "re-open a deferred question"
grep -q '^fingerprint: [0-9a-f]\{40\}$' "$(qf q-7)" || fail "q-7 fingerprint not refreshed"
[ ! -e "$(qf q-8)" ] || fail "re-open allocated q-8"
run "$MAIN" $Q alfa answer q-7 --tier 1 --author supervisor --why "in plan" --text "Counter." \
  --send say
expect 0 "sent say" "answer after re-open"
: > "$STUB_LOG"
run "$MAIN" $ANSWER alfa coder say "-x starts with a dash"
expect 0 "sent say" "say text with a leading dash"
has "send-keys -t =alfa-coder: -l -- -x starts with a dash" "$STUB_LOG" || fail "dash not typed"
record --verdict blocked --message "busy then escalated" >/dev/null
STUB_PANE="$WORK/busy" run "$MAIN" $Q alfa open coder --kind blocked --summary "Busy, tier 2"
head -n 1 "$WORK/out" | grep -q '^q-8 .*fingerprint deferred' || fail "busy open did not defer q-8"
cfg true 'printf "status: answer\n\nUse the counter.\n"'
run "$MAIN" $ESC alfa coder 2 "$(qf q-8)" --blocks x
expect 0 "ANSWER" "escalate a deferred question"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Busy, tier 2"
expect 0 "(existing, state=escalated)" "re-open an escalated deferred question"
grep -q '^fingerprint: [0-9a-f]\{40\}$' "$(qf q-8)" || fail "q-8 fingerprint not refreshed"
run "$MAIN" $Q alfa answer q-8 --tier 2 --author FableTT+AstraTT --why x --text "Counter." \
  --send say
expect 0 "sent say" "tier-2 answer after an escalated re-open"
record --verdict blocked --message "escalated, then the screen changed" >/dev/null
run "$MAIN" $Q alfa open coder --kind blocked --summary "Idle, tier 2"
head -n 1 "$WORK/out" | grep -q '^q-9 ' || fail "idle open did not allocate q-9"
fp9="$(grep '^fingerprint: ' "$(qf q-9)")"
run "$MAIN" $ESC alfa coder 2 "$(qf q-9)" --blocks x
expect 0 "ANSWER" "escalate a bound question"
STUB_PANE="$WORK/menu" run "$MAIN" $Q alfa open coder --kind blocked --summary "Idle, tier 2"
expect 0 "(existing, state=escalated)" "re-open an escalated question on a new screen"
[ "$(grep '^fingerprint: ' "$(qf q-9)")" = "$fp9" ] || fail "q-9 fingerprint overwritten"

# ---- (34) single-question multiSelect: live-probe renderer and exact delivery -----------------
cat > "$WORK/checkbox" <<'PANE'
←  ☐ Probe  ✔ Submit  →
Pick fruits
❯ 1. [ ] Apple
         <description>
  2. [ ] Banana
  3. [ ] Cherry
  4. [ ] Type something
     Submit
──────────────────
  5. Chat about this
Enter to select · ↑/↓ to navigate · Esc to cancel
PANE
cat > "$WORK/review" <<'PANE'
←  ☒ Probe  ✔ Submit  →
Review your answers
 ● Pick fruits
   → Apple, Cherry
Ready to submit your answers?
❯ 1. Submit answers
  2. Cancel
PANE
sed 's/Apple, Cherry/none - skip all/' "$WORK/review" > "$WORK/review-none"
sed 's/Apple, Cherry/Banana/' "$WORK/review" > "$WORK/review-wrong"
sed 's/☐ Probe/☒ Probe/; s/2\. \[ \]/2. [✔]/' "$WORK/checkbox" > "$WORK/preselected"
sed 's/❯ 1\./  1./; s/  2\./❯ 2./' "$WORK/checkbox" > "$WORK/cursor2"
sed 's/☐ Probe/☒ Probe ☒ Another/' "$WORK/checkbox" > "$WORK/completed-multi"
sed 's/☐ Retry/←  ☐ Nadzorca  ☐ \/mail-tt  ☐ Koniec etapu  ✔ Submit  →/' \
  "$WORK/menu" > "$WORK/multi-question"
sed 's/4\. \[ \]/4. [✔]/' "$WORK/checkbox" > "$WORK/selected-other"
sed 's/  2\. \[ \]/  8. [ ]/' "$WORK/checkbox" > "$WORK/gap"
tail -n +2 "$WORK/checkbox" > "$WORK/truncated"
# The terminal returns the review only after the expected Submit key. All keys remain logged.
cp "$WORK/bin/tmux" "$WORK/bin/tmux-base"
cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = capture-pane ] && [ "${STUB_MULTI:-0}" = 1 ]; then
  n=$(awk '/^tmux send-keys /{n++} END{print n+0}' "$STUB_LOG")
  [ "$n" -lt "$STUB_REVIEW_AFTER" ] || export STUB_PANE="$STUB_REVIEW"
fi
exec "$(dirname "$0")/tmux-base" "$@"
STUB
chmod +x "$WORK/bin/tmux"
keys() { sed -n 's/^tmux send-keys -t =alfa-planner: //p' "$STUB_LOG"; }
ms() {  # fixture, review, expected pre-confirmation key count
  export STUB_MULTI=1 STUB_PANE="$WORK/$1" STUB_REVIEW="$WORK/$2" STUB_REVIEW_AFTER="$3"
  : > "$STUB_LOG"
}
exact_keys() { [ "$(keys)" = "$1" ] || fail "checkbox keys: $(keys)"; }
ms checkbox review 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 0 "sent picks" "choose 1 and 3 then confirm review"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter\nEnter'
ms preselected review 8
run "$MAIN" $ANSWER alfa planner picks 3,1
expect 0 "sent picks" "normalize preselected Banana and unsorted requested set"
exact_keys $'Enter\nDown\nEnter\nDown\nEnter\nDown\nDown\nEnter\nEnter'
ms preselected review-none 8
run "$MAIN" $ANSWER alfa planner picks none
expect 0 "sent picks" "explicit skip clears earlier selection and types Other"
exact_keys $'Down\nEnter\nDown\nDown\nEnter\n-l -- none - skip all\nDown\nEnter\nEnter'
ms checkbox review 7
run "$MAIN" $ANSWER alfa planner picks
expect 2 "Usage:" "picks missing argument"; no_keys "missing picks argument"
for selection in '' '1,' '0' '1;3'; do
  : > "$STUB_LOG"; run "$MAIN" $ANSWER alfa planner picks "$selection"
  expect 2 "picks needs" "invalid picks syntax $selection"; no_keys "bad picks syntax"
done
for selection in 5 4 '1,99' '1,1'; do
  : > "$STUB_LOG"; run "$MAIN" $ANSWER alfa planner picks "$selection"
  expect 1 "tier 3" "invalid option set $selection"; no_keys "bad option set"
done
for fixture in cursor2 completed-multi multi-question selected-other gap truncated multi menu perm
do
  ms "$fixture" review 7; run "$MAIN" $ANSWER alfa planner picks 1,3
  expect 1 "" "unsafe checkbox fixture $fixture"; no_keys "unsafe checkbox fixture"
done
for action in pick other; do
  ms checkbox review 7; run "$MAIN" $ANSWER alfa planner "$action" 1
  expect 1 "" "legacy $action refuses multiSelect"; no_keys "legacy checkbox refusal"
done
ms checkbox review-wrong 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 1 "final Enter not sent" "refuse wrong answer in review"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter'
ms checkbox review-none 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 1 "final Enter not sent" "refuse unintended skip in review"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter'
sed 's/Ready to submit your answers?/⚠ You have not answered all questions/' \
  "$WORK/review" > "$WORK/review-unanswered"
ms checkbox review-unanswered 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 1 "final Enter not sent" "refuse unanswered review"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter'
sed 's/❯ 1\./  1./; s/  2\./❯ 2./' "$WORK/review" > "$WORK/review-cursor2"
ms checkbox review-cursor2 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 1 "final Enter not sent" "refuse wrong review cursor"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter'

# Ledger must bind picks to a menu and distinguish picks:none from recorded-only send none.
session planner 1 "$BASE"; ms checkbox review 7
run "$MAIN" $Q alfa open planner --kind menu --anchor "Pick fruits" --summary "Pick fruits"
expect 0 "q-10 " "open checkbox question"
: > "$STUB_LOG"
run "$MAIN" $Q alfa answer q-10 --tier 1 --author supervisor --why "in plan" \
  --text "approved subset" --send picks:1,3
expect 0 "sent picks" "ledger delivers checkbox set"
has 'answer: (menu options 1,3) — approved subset' "$(qf q-10)" || fail "ledger lost selected set"
has 'delivery: sent' "$(qf q-10)" || fail "checkbox delivery not sent"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter\nEnter'
ms checkbox review-none 7
run "$MAIN" $Q alfa open planner --kind menu --anchor "1. [ ] Apple" --summary "Skip fruits"
expect 0 "q-11 " "open explicit skip question"
run "$MAIN" $Q alfa answer q-11 --tier 1 --author supervisor --why "skip all" --send picks:none
expect 0 "sent picks" "ledger delivers explicit skip"
has 'answer: (skip all: none - skip all)' "$(qf q-11)" || fail "skip not explicit in ledger"
exact_keys $'Down\nDown\nDown\nEnter\n-l -- none - skip all\nDown\nEnter\nEnter'
ms idle review 7
run "$MAIN" $Q alfa open planner --kind idle --anchor "> waiting" --summary "Not a menu"
expect 0 "q-12 " "open idle question"
run "$MAIN" $Q alfa answer q-12 --tier 1 --author supervisor --why x --send picks:1,3
expect 1 "does not fit a idle question" "ledger refuses picks on idle"; no_keys "picks on idle"
run "$MAIN" $Q alfa answer q-12 --tier 1 --author supervisor --why x --send picks:
expect 1 "picks needs" "ledger syntax preflight"; no_keys "ledger bad syntax"

# C1: picks:none must refuse every non-menu kind before any ledger/notes write, at every tier.
for tier in 1 2 3; do
  cp "$(qf q-12)" "$WORK/question-before"; cp "$RD/notes.md" "$WORK/notes-before"
  run "$MAIN" $Q alfa answer q-12 --tier "$tier" --author supervisor --why x --send picks:none
  expect 1 "does not fit a idle question" "explicit skip on idle at tier $tier"
  no_keys "explicit skip on idle"
  cmp -s "$(qf q-12)" "$WORK/question-before" || fail "idle skip wrote ledger"
  cmp -s "$RD/notes.md" "$WORK/notes-before" || fail "idle skip wrote notes"
done
ms perm review 7
run "$MAIN" $Q alfa open planner --kind permission --anchor "az webapp deploy" \
  --summary "Permission"
expect 0 "q-13 " "open permission for skip refusal"
ms idle review 7; session coder 3 "$BASE"
record --verdict blocked --message "skip guard" >/dev/null
run "$MAIN" $Q alfa open coder --kind blocked --summary "Blocked for skip refusal"
expect 0 "q-14 " "open blocked for skip refusal"
for kind in permission blocked; do
  case "$kind" in permission) id=q-13 ;; blocked) id=q-14 ;; esac
  cp "$(qf "$id")" "$WORK/question-before"; cp "$RD/notes.md" "$WORK/notes-before"
  : > "$STUB_LOG"
  run "$MAIN" $Q alfa answer "$id" --tier 1 --author supervisor --why x --send picks:none
  expect 1 "does not fit a $kind question" "explicit skip on $kind"
  no_keys "explicit skip on $kind"
  cmp -s "$(qf "$id")" "$WORK/question-before" || fail "$kind skip wrote ledger"
  cmp -s "$RD/notes.md" "$WORK/notes-before" || fail "$kind skip wrote notes"
done

# C2: missing tab icons still produce diagnostics, including after the first Submit Enter.
sed 's/☐ Probe/Probe/' "$WORK/checkbox" > "$WORK/no-icon"
sed 's/☒ Probe/Probe/' "$WORK/review" > "$WORK/review-no-icon"
ms no-icon review 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 1 "not a single-question checkbox menu" "missing initial tab icon"
no_keys "missing initial tab icon"
ms checkbox review-no-icon 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 1 "not a single-question checkbox menu" "missing review tab icon"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter'
unset STUB_MULTI STUB_REVIEW STUB_REVIEW_AFTER

echo "team-smoke-4: OK"
