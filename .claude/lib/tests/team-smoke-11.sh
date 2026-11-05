#!/usr/bin/env bash
# Advisor no-reply fallback, late-reply wake, orphans. Cases (170)-(186).
# Its fallback and late-read windows are seconds wide: under load they miss, so the suite runner
# keeps it out of a TEAM_SMOKE_PARALLEL batch.
# team-smoke: serial
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-1250 chore/AB-1250-fallback
BG=""
trap 'for p in $BG; do kill "$p" 2>/dev/null || true; done
  [ -z "$SPID" ] || kill "$SPID" 2>/dev/null || true; rm -rf "$WORK"' EXIT
RUN_ID=alfa-20261025-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"
mkdir -p "$RD/questions"
Q="bash .claude/lib/team-question.sh"
ESC="bash .claude/lib/team-escalate.sh"
export TEAM_ESCALATE_UNIT_SECS=1 TEAM_ESCALATE_POLL=0.2 TEAM_ESCALATE_BACKOFF_SECS=0
export TEAM_ESCALATE_LATE_SECS=2 TEAM_ESCALATE_OPINION_SECS=5 TEAM_ESCALATE_PEEK_SECS=1
export TEAM_ESCALATE_OPINION_RECHECK_SECS=1
mkdir -p "$MAIN/.agents/team"
CFG="$MAIN/.agents/team/escalation.local.json"
A6='"$1" "$2" "$3" "$4" "$5" "$6"'
{ echo "⏺ > waiting for the supervisor's answer"; cat "$FIX/idle.txt"; } > "$WORK/idle"
export STUB_PANE="$WORK/idle" STUB_TMUX_ALIVE=0

qf() { echo "$RD/questions/$1.md"; }
last_line() { tail -n 1 "$WORK/out"; }
thread() { echo "esc-$RUN_ID-$QN"; }
esc() { run "$MAIN" $ESC alfa coder "$@"; }
state() {  # state <q id> → its state= from list
  run "$MAIN" $Q alfa list
  sed -n "s/^$1 .* state=\(.*\)\$/\1/p" "$WORK/out"
}
assistant() {  # assistant <sid> <uuid> — the role's last transcript turn (the blocked event)
  mkdir -p "$(dirname "$(transcript "$1")")"
  jq -cn --arg u "$2" '{type: "assistant", uuid: $u, message: {content: [{type: "text",
    text: "waiting"}]}}' >> "$(transcript "$1")"
}
fresh() {  # fresh <summary> → QF, QN: a real open blocked question
  record --verdict blocked --message "$1" >/dev/null
  run "$MAIN" $Q alfa open coder --kind blocked --summary "$1"
  expect 0 "" "open $1"
  QN="$(head -n 1 "$WORK/out" | cut -d' ' -f1)"; QF="$(qf "$QN")"
}
N=100
mkq() {  # mkq <kind> → QF, QN: a hand-written open question for escalation-only cases
  N=$((N + 1)); QN="q-$N"; QF="$(qf "$QN")"
  printf '# %s — alfa coder attempt 1\nrole: coder\nattempt: 1\nrun: %s\nkind: %s\n' \
    "$QN" "$RUN_ID" "$1" > "$QF"
  printf 'record: -\nanchor: x\nfingerprint: v2:none\nopened: 2026-10-25T00:00:00Z\n\n' >> "$QF"
  printf '## Summary\nWhich test design?\n\n## Context\n- last blocker: -\n\n## Screen\n    x\n' \
    >> "$QF"
}
opinion() {  # opinion <id> <marker line or ""> [body lines...] — Reviewer's newest message on QN
  local f="$WORK/mail.opinion.$(thread)" id="$1" m="$2"; shift 2
  { echo "mail-id: $id"; [ -z "$m" ] || echo "$m"; printf '%s\n' "$@"; } > "$f"
}
reply() { printf '%b' "$1" > "$WORK/mail.reply.$(thread)"; }

# fake-mail.sh send|wait|peek|opinion <payload> <team> <role> <qid> <thread> <seq>
cat > "$WORK/fake-mail.sh" <<'EOF'
d="$(dirname "$0")"; store="$d/mail.store"; touch "$store"
case "$1" in
  send) [ ! -e "$d/mail.muteall" ] || exit 0
    id=$(( $(wc -l < "$store") + 1 )); echo "$id $6" >> "$store"
    cp "$2" "$d/sent.$6.payload"
    echo "SENT id=$id thread=$6" ;;
  wait) s="$d/mail.stage.$6"
    # The real adapter's order: publish the staged reply, ack, then print — killable in between.
    if [ -f "$s" ]; then
      id="$(sed -n '1s/^mail-id: //p' "$s")"
      cp "$s" "$(dirname "$2")/$5.reply-$id.md"; rm -f "$s"; sleep 30; exit 0
    fi
    f="$d/mail.reply.$6"; while [ ! -f "$f" ]; do sleep 0.2; done; cat "$f"; rm -f "$f" ;;
  peek) [ ! -e "$d/mail.peek-fail" ] || exit 1
    touch "$d/mail.peeked.$6"
    [ ! -e "$d/mail.peek-slow" ] || sleep 30
    [ ! -e "$d/mail.peek-silent" ] || exit 0
    f="$d/mail.reply.$6"; if [ -f "$f" ]; then cat "$f"; rm -f "$f"; else echo EMPTY; fi ;;
  opinion) [ ! -e "$d/mail.opinion-fail" ] || exit 1
    [ ! -e "$d/mail.opinion-slow" ] || sleep 30
    f="$d/mail.opinion.$6"; [ ! -f "$f" ] || cat "$f"
    # A change made while the opinion is read: runs on the first read only.
    h="$d/mail.opinion-hook"; [ ! -f "$h" ] || { mv "$h" "$h.run"; sh "$h.run"; } ;;
esac
EOF
FM="bash $WORK/fake-mail.sh"
cfg_fb() {
  jq -n --arg s "$FM send $A6" --arg w "$FM wait $A6" --arg o "$FM opinion $A6" \
    --arg p "$FM peek $A6" '{send: $s, wait: $w, opinion: $o, peek: $p, timeout_min: 1}' > "$CFG"
}
cfg_nofb() {
  jq -n --arg s "$FM send $A6" --arg w "$FM wait $A6" '{send: $s, wait: $w, timeout_min: 1}' \
    > "$CFG"
}
bg_esc() {  # bg_esc <args…> → BGP: team-escalate.sh in the background
  (cd "$MAIN" && exec $ESC alfa coder "$@") > "$WORK/bg.out" 2>&1 &
  BGP=$!; BG="$BG $BGP"
}
bg_stop() { sleep 3; kill "$BGP" 2>/dev/null || true; wait "$BGP" 2>/dev/null || true; }
cfg_fb
session coder 1 "$BASE"; assistant sid-coder-1 a-wait-1

# ---- (170) AC1: eligible class, Reviewer agrees, Advisor silent → FALLBACK -----------------------
mkq menu; Q1="$QN"; Q1F="$QF"
opinion 9 "opinion: agree"
esc 2 "$QF" --blocks x --class analysts-condition --recommend "pick:1 Test integracyjny"
expect 0 "FALLBACK" "fallback on agreement"
for l in "send: pick:1" "reviewer: #9" "text: Test integracyjny"; do
  grep -qx "$l" "$WORK/out" || fail "FALLBACK lacks '$l'"
done
for l in "started: " "recommend: pick:1 Test integracyjny" "waited: " "opinion: 9 agree" \
  "fallback: Advisor no-reply — Reviewer #9" "outcome: reviewer-fallback"; do
  has "$l" "$QF" || fail "$QN ledger lacks '$l'"
done
grep -q '^started: .* tier 2 class analysts-condition$' "$QF" || fail "started: lacks the class"
[ "$(state "$Q1")" = escalated ] || fail "$Q1 is not escalated"

# ---- (171) the real first payload advertises the fallback --------------------------------------
P1="$WORK/sent.$(thread).payload"
for l in "class: analysts-condition" "fallback: eligible" "## Recommendation" \
  "pick:1 Test integracyjny" "## Reviewer" 'must be exactly "opinion: agree"' \
  '"opinion: agree" also attests' 'class: <ac|contract|schema|sensitive|harness-rule|conflict>'; do
  has "$l" "$P1" || fail "sent payload lacks '$l'"
done
awk '/^## Recommendation/{r = NR} /^## Reviewer/{a = NR} /^## Screen/{s = NR}
  END{exit !(r && a && s && a < s)}' "$P1" || fail "payload section order"

# ---- (172) producer-built snapshot: timeouts -----------------------------------------------------
run "$MAIN" bash .claude/lib/team-snapshot.sh --out "$WORK/snap.json"
expect 0 "" "snapshot after a fallback"
jq -e --arg q "$Q1" '.teams[] | select(.team == "alfa") | .escalations[]
  | select(.q == $q and (.timeouts | length) == 1 and .replies == []
    and .last_outcome == "reviewer-fallback" and .class == "analysts-condition" and .waiter == "none")' \
  "$WORK/snap.json" >/dev/null \
  || fail "snapshot escalations: $(jq -c '.teams[].escalations' "$WORK/snap.json")"
FILTER="$SRC/.claude/lib/team-watch-signals.jq"
jq -n --slurpfile s "$WORK/snap.json" '{snapshot: $s[0], routing: {mode: "split", live: {}}}' \
  | jq -f "$FILTER" > "$WORK/sig.json"
jq -e '[.[] | select(.key == "advisor-silent:none" and .to == "Supervisor")] | length == 1' \
  "$WORK/sig.json" >/dev/null \
  || fail "no advisor-silent:none from the producer: $(cat "$WORK/sig.json")"

# ---- (173) conditions on a menu → other; send/kind validation; multiSelect --------------------
mkq menu; opinion 9 "opinion: agree" "Warunek: tylko izolowana baza" "" "  i limit 3  "
esc 2 "$QF" --blocks x --class plan-variant --recommend "pick:1 Test integracyjny"
expect 0 "FALLBACK" "fallback with conditions"
grep -qx "send: other" "$WORK/out" || fail "conditions on a pick did not become other"
grep -qx "text: Test integracyjny — Reviewer conditions (#9): Warunek: tylko izolowana baza / i limit 3" \
  "$WORK/out" || fail "conditions text: $(grep '^text: ' "$WORK/out")"
mkq blocked
esc 2 "$QF" --blocks x --class plan-variant --recommend "pick:1 x"
expect 2 "does not fit kind blocked" "pick on a blocked q"
! has "started: " "$QF" || fail "a refused --recommend wrote the ledger"
mkq menu
for s in "pick:0 x" "pick:100 x" "picks:0,1 x" "say x" "pick:1"; do
  esc 2 "$QF" --blocks x --class plan-variant --recommend "$s"
  expect 2 "" "--recommend $s"
done
mkq permission
esc 2 "$QF" --blocks x --class plan-variant --recommend "yes x"
expect 2 "never a fallback" "--recommend on a permission q"
esc 2 "$QF" --blocks x --class nonsense; expect 2 "unknown class" "unknown class"
mkq menu; opinion 9 "opinion: agree" "Warunek"
esc 2 "$QF" --blocks x --class plan-variant --recommend "picks:1,3 Dwie opcje"
expect 3 "NO-REPLY timeout after 1 min" "conditions on a multiSelect"
has "fallback: no — conditions on multiSelect" "$QF" || fail "multiSelect reason"
mkq menu; opinion 9 "opinion: agree"
esc 2 "$QF" --blocks x --class plan-variant --recommend "picks:1,3 Dwie opcje"
expect 0 "send: picks:1,3" "bare agreement on a multiSelect"

# ---- (174) AC3: guard, real FALLBACK → answer path, notes, list --------------------------------
fresh "Which retry design?"; Q3="$QN"; Q3F="$QF"
opinion 9 "opinion: agree" "Warunek: limit 3"
esc 2 "$QF" --blocks x --class plan-variant --recommend "say Counter + backoff."
expect 0 "FALLBACK" "fallback on a blocked q"
T="$(sed -n 's/^text: //p' "$WORK/out")"; [ "$(sed -n 's/^send: //p' "$WORK/out")" = say ] \
  || fail "blocked q: send is not say"
run "$MAIN" $Q alfa answer "$Q1" --run "$RUN_ID" --tier 2 --author analysts --why x --text y \
  --send other
expect 1 "answered with --author TeamLead-fallback" "another author on a recorded fallback"
: > "$STUB_LOG"
run "$MAIN" $Q alfa answer "$QN" --run "$RUN_ID" --tier 2 --author TeamLead-fallback \
  --why "fallback: Advisor no-reply — Reviewer #9" --text "$T" --send say
expect 0 "sent say" "deliver the fallback"
grep -F -- "send-keys -t %1 -l -- " "$STUB_LOG" | grep -qF "Reviewer conditions (#9): Warunek: limit 3" \
  || fail "the conditions were not typed on one line"
has "[tier 2, TeamLead-fallback]" "$RD/notes.md" && has "fallback: Advisor no-reply" "$RD/notes.md" \
  || fail "notes lack the fallback marker"
mkq blocked
run "$MAIN" $Q alfa answer "$QN" --run "$RUN_ID" --tier 2 --author TeamLead-fallback \
  --why "fallback: Advisor no-reply — Reviewer #9" --text x --send say
expect 1 "refused: TeamLead-fallback" "fallback author without a fallback"
run "$MAIN" $Q alfa list
case "$(last_line)" in *" fallback=1") ;; *) fail "list: $(last_line)" ;; esac

# ---- (175) AC2: critical and unclassified classes never fall back ------------------------------
for c in ac contract harness-rule ""; do
  mkq blocked; opinion 999 "opinion: agree"
  esc 2 "$QF" --blocks x ${c:+--class "$c"} --recommend "say x"
  expect 3 "NO-REPLY timeout after 1 min" "class ${c:-missing}"
  has "fallback: no — class" "$QF" || fail "class ${c:-missing}: no class reason"
  ! has "reviewer-fallback" "$QF" || fail "class ${c:-missing} fell back"
done

# ---- (176) AC2: opinion and config refusals ----------------------------------------------------
nofb() {  # nofb <label> <reason> <args…> — eligible q, expect NO-REPLY with that reason
  local l="$1" r="$2"; shift 2
  esc 2 "$QF" --blocks x "$@"
  expect 3 "NO-REPLY timeout after 1 min" "$l"
  has "fallback: no — $r" "$QF" || fail "$l: lacks 'fallback: no — $r'"
  ! has "reviewer-fallback" "$QF" || fail "$l fell back"
}
mkq blocked; opinion 999 "opinion: disagree"
nofb disagree "Reviewer disagree" --class plan-variant --recommend "say x"
has "opinion: 999 disagree" "$QF" || fail "disagree not recorded"
mkq blocked; opinion 999 "" "I think yes"
nofb unmarked "Reviewer unmarked" --class plan-variant --recommend "say x"
mkq blocked; opinion 0 "opinion: agree"
nofb stale "opinion older than the request" --class plan-variant --recommend "say x"
# No channel and no opinion key reads as advisor solo (the renderer's signal); a configured pair
# channel without the key is `opinion adapter off` (part escalation, E6b).
mkq blocked; opinion 999 "opinion: agree"; cfg_nofb
nofb "no opinion key" "advisor solo" --class plan-variant --recommend "say x"
cfg_fb; mkq blocked; opinion 999 "opinion: agree"; touch "$WORK/mail.opinion-fail"
nofb "failing opinion op" "opinion op failed (rc 1)" --class plan-variant --recommend "say x"
rm -f "$WORK/mail.opinion-fail"
mkq blocked
nofb "no opinion" "no Reviewer opinion" --class plan-variant --recommend "say x"
mkq blocked; opinion 999 "opinion: agree"
nofb "no recommendation" "no-recommendation" --class plan-variant

# ---- (177) AC2: tier 3 and waiting: operator --------------------------------------------------
mkq blocked; opinion 999 "opinion: agree"
esc 3 "$QF" --blocks x --class plan-variant --recommend "say x"
expect 3 "NO-REPLY timeout after 1 min" "tier 3"
! has "reviewer-fallback" "$QF" && ! has "fallback: no" "$QF" || fail "tier 3 carried a fallback line"
mkq blocked; opinion 999 "opinion: agree"; reply 'status: pending-operator\n\nAsked the Operator.\n'
bg_esc 2 "$QF" --blocks x --class plan-variant --recommend "say x"; bg_stop
has "waiting: operator" "$QF" || fail "pending-operator not recorded"
! has "reviewer-fallback" "$QF" || fail "a waiting: operator q fell back"
bg_esc 2 "$QF" --resume; bg_stop
! has "reviewer-fallback" "$QF" && ! has "outcome: no-reply" "$QF" \
  || fail "a waiting: operator resume was bounded"

# ---- (178) AC5: late read on an answered q ----------------------------------------------------
QN="$Q3"; QF="$Q3F"
reply 'status: answer\n\nLate: counter + backoff.\n'
esc 2 "$QF" --resume
expect 0 "LATE ANSWER" "late read with a reply"
has "Late: counter + backoff." "$WORK/out" || fail "late body not printed"
has "late: " "$QF" && has "outcome: late-answer" "$QF" || fail "late read not recorded"
[ "$(state "$Q3")" = sent ] || fail "$Q3 left its answered state"
esc 2 "$QF" --resume
expect 0 "LATE NONE" "late read without a reply"
has "outcome: late-none" "$QF" || fail "late-none not recorded"
printf 'mail-id: 41\nstatus: answer\n\nStaged late.\n' > "$WORK/mail.stage.$(thread)"
esc 2 "$QF" --resume
expect 0 "LATE ANSWER" "late read drains a staged reply"
has "Staged late." "$WORK/out" && has "reply: 41 answer" "$QF" || fail "staged late reply lost"

# ---- (179) check_start and round-2 sticky exclusions -----------------------------------------
esc 2 "$Q1F" --resume
expect 2 "recorded fallback" "--resume on an undelivered fallback"
mkq blocked; reply 'status: disagree\n\nA: x. B: y.\n'
esc 2 "$QF" --blocks x --class plan-variant --recommend "say x"
expect 3 "status: disagree is retired" "Advisor disagree"
opinion 999 "opinion: agree"
esc 2 "$QF" --resume
expect 3 "NO-REPLY timeout after 1 min" "resume after a disagreement"
has "fallback: no — analyst-disagree" "$QF" || fail "analyst-disagree reason"
mkq blocked; opinion 999 "opinion: agree"
printf 'mail-id: 42\nstatus: pending-operator\n\nAsked.\n' > "$WORK/mail.stage.$(thread)"
bg_esc 2 "$QF" --blocks x --class plan-variant --recommend "say x"; bg_stop
has "waiting: operator" "$QF" && ! has "reviewer-fallback" "$QF" \
  || fail "staged pending-operator then timeout fell back"
mkq blocked; touch "$WORK/mail.muteall"
esc 2 "$QF" --blocks x --class plan-variant --recommend "say x"
expect 3 "invalid adapter (no SENT receipt)" "send without a receipt"
rm -f "$WORK/mail.muteall"; opinion 999 "opinion: agree"
esc 2 "$QF" --resume
expect 3 "NO-REPLY timeout after 1 min" "resume of an undelivered request"
has "fallback: no — no delivered request" "$QF" || fail "no delivered request reason"

# ---- (180) AC6: orphans -----------------------------------------------------------------------
mkq blocked; QD="$QN"; printf '\n## Escalation\nstarted: 2026-10-25T00:00:00Z tier 2\n' >> "$QF"
sleep 0 & dead=$!; wait "$dead"; mkdir "$QF.wait"; echo "$dead" > "$QF.wait/pid"
mkq blocked; QL="$QN"; printf '\n## Escalation\nstarted: 2026-10-25T00:00:00Z tier 2\n' >> "$QF"
sleep 30 & BG="$BG $!"; mkdir "$QF.wait"; echo "$!" > "$QF.wait/pid"
printf 'mail-id: 77\nstatus: answer\n\nLost.\n' > "$RD/questions/$Q3.reply-77.md"
run "$MAIN" $Q alfa orphans
expect 0 "" "orphans"
grep -q "^$QD role=coder tier=2 state=escalating outcome=- reason=dead-waiter path=" "$WORK/out" \
  || fail "dead waiter not listed"
grep -q "^q-1[0-9][0-9] .* state=escalated outcome=no-reply — timeout after 1 min reason=no-reply " \
  "$WORK/out" || fail "no-reply not listed"
grep -q "^$Q3 .* reason=staged-reply " "$WORK/out" || fail "staged reply not listed"
! grep -q "^$QL " "$WORK/out" || fail "a live waiter was listed"
! grep -q "^$Q1 " "$WORK/out" || fail "an reviewer-fallback q was listed"

# ---- (181) escreply and silence signals over a hand-written in.json; silence never reminded -----
E='{"q": "q-1", "role": "coder", "tier": 2, "class": "ac", "thread": "esc-r-q-1",
  "state": "escalated", "last_outcome": "no-reply — x", "waiter": "dead",
  "timeouts": ["2026-10-25T10:00:00Z"], "replies": ["2026-10-25T09:00:00Z"]}'
sigs() {  # sigs <escalations json> [esc_mail json] → $WORK/sig.json
  jq -n --argjson e "$1" --argjson m "${2:-[]}" '{routing: {mode: "split", live: {}},
    snapshot: {teams: [{team: "alfa", run: "r", runner: "up", roles: [], escalations: $e}]},
    esc_mail: $m}' | jq -f "$FILTER" > "$WORK/sig.json"
}
cnt() { jq "[.[] | select($1)] | length" "$WORK/sig.json"; }
L='"[agent-mail] #55 2026-10-25 from=Advisor kind=turn awaiting=- thread=esc-r-q-1 state=x refs="'
sigs "[$E]" "[$L]"
[ "$(cnt '.key == "escreply:55" and .to == "TeamLead"
  and .head == "ESCALATION alfa q-1: Advisor reply #55 without a waiter (escalated)"')" = 1 ] \
  || fail "escreply for a dead waiter: $(cat "$WORK/sig.json")"
sigs "[$(jq -c '.waiter = "live"' <<<"$E")]" "[$L]"
[ "$(cnt '.kind == "escreply"')" = 0 ] || fail "escreply despite a live waiter"
sigs "[$E]" "[$(jq -c 'sub("esc-r-q-1"; "esc-old-q-9")' <<<"$L")]"
[ "$(cnt '.kind == "escreply" and .head == "ESCALATION esc-old-q-9: Advisor reply #55 without a current q"')" = 1 ] \
  || fail "escreply for an unknown thread"
E2="$(jq -c '.q = "q-2" | .thread = "esc-r-q-2" | .timeouts = ["2026-10-25T10:30:00Z"]' <<<"$E")"
sigs "[$E, $E2]"
[ "$(cnt '.key == "advisor-silent:2026-10-25T09:00:00Z" and .to == "Supervisor"
  and .head == "ADVISOR silent since 2026-10-25T10:00:00Z: 2 escalation(s) waiting"
  and (.screen | length) == 2')" = 1 ] || fail "silence of two: $(cat "$WORK/sig.json")"
sigs "[$(jq -c '.state = "consumed"' <<<"$E")]"
[ "$(cnt '.key == "advisor-silent:2026-10-25T09:00:00Z" and (.head | test(": 0 escalation\\(s\\) waiting$"))')" = 1 ] \
  || fail "an Operator answer ended the episode"
sigs "[$(jq -c '.last_outcome = "reviewer-fallback"' <<<"$E")]"
[ "$(cnt '.kind == "silence" and (.screen | length) == 0')" = 1 ] || fail "a reviewer fallback still listed as waiting"
sigs "[$E, $(jq -c '.replies = ["2026-10-25T11:00:00Z"]' <<<"$E2")]"
[ "$(cnt '.kind == "silence"')" = 0 ] || fail "a reply after the timeouts kept the silence"
mkq blocked
printf '%s\n' "" "## Escalation" "started: 2026-10-25T00:00:00Z tier 2" \
  "sent: seq 1 2026-10-25T00:00:01Z id 5 thread t" "waited: 2026-10-25T10:00:00Z timeout after 1 min" \
  "late: 2026-10-25T11:00:00Z" "outcome: late-none" "ended: 2026-10-25T11:00:02Z" >> "$QF"
run "$MAIN" bash .claude/lib/team-snapshot.sh --out "$WORK/snap.json"
jq -e --arg q "$QN" '.teams[].escalations[] | select(.q == $q) | .replies == []
  and .timeouts == ["2026-10-25T10:00:00Z"]' "$WORK/snap.json" >/dev/null \
  || fail "late-none counted as an Advisor reply"
for f in team-watch-lib.sh team-watch-route.sh team-watch-inputs.sh team-watch-deliver.sh team-channel.sh; do
  cp "$SRC/.claude/lib/$f" "$MAIN/.claude/lib/"
done
lib() { run "$MAIN" bash -c ". .claude/lib/team-watch-lib.sh && tw_init \"\$PWD\" && $1"; }
sg() { jq -cn --arg k "$1" --arg kind "$2" '{key: $k, kind: $kind, team: null, role: null,
  head: $k, screen: [], to: "Supervisor"}'; }
mkdir -p "$WORK/sigd"
echo "[$(sg advisor-silent:none silence), $(sg ready:x ready)]" > "$WORK/sigd/sig.json"
export TEAM_WATCH_REMIND_SECS=1
lib 'tw_lock && tw_update "'"$WORK"'/sigd/sig.json"; tw_unlock'; expect 0 "" "tw_update 1"
sleep 2
lib 'tw_lock && tw_update "'"$WORK"'/sigd/sig.json"; tw_unlock'; expect 0 "" "tw_update 2"
unset TEAM_WATCH_REMIND_SECS
EV="$MAIN/.agents/team/watch/events.jsonl"
[ "$(jq -s '[.[] | select(.key == "ready:x" and .label == "(reminder)")] | length' "$EV")" = 1 ] \
  || fail "the control signal was not reminded: $(cat "$EV")"
[ "$(jq -s '[.[] | select(.key == "advisor-silent:none")] | length' "$EV")" = 1 ] \
  || fail "the silence signal was reminded: $(cat "$EV")"

# ---- (182) a delivery must be the recorded fallback, field for field -------------------------
mkq menu; QA="$QN"; QAF="$QF"; opinion 500 "opinion: agree"
esc 2 "$QF" --blocks x --class plan-variant --recommend "pick:1 Keep contract"
expect 0 "FALLBACK" "fallback to bind"
fbw="fallback: Advisor no-reply — Reviewer #"
deliver_fb() {  # deliver_fb <label> <expected> <answer args…> — a refusal leaves the q as is
  local l="$1" e="$2"; shift 2
  cp "$QAF" "$WORK/qa.before"
  run "$MAIN" $Q alfa answer "$QA" --run "$RUN_ID" "$@"
  expect 1 "$e" "$l"
  cmp -s "$QAF" "$WORK/qa.before" || fail "$l changed the ledger"
}
deliver_fb "another send" "--send pick:2 differs from the recorded fallback (pick:1)" \
  --tier 2 --author TeamLead-fallback --why "${fbw}500" --text "Keep contract" --send pick:2
deliver_fb "another text" "--text differs from the recorded fallback" --tier 2 \
  --author TeamLead-fallback --why "${fbw}500" --text "Change contract without conditions" \
  --send pick:1
deliver_fb "another Reviewer id" "must name the recorded Reviewer #500" --tier 2 \
  --author TeamLead-fallback --why "${fbw}999" --text "Keep contract" --send pick:1
deliver_fb "an id suffix" "must name the recorded Reviewer #500" --tier 2 \
  --author TeamLead-fallback --why "${fbw}500 or 999" --text "Keep contract" --send pick:1
deliver_fb "tier 1 on a fallback" "answered with --author TeamLead-fallback" --tier 1 \
  --author supervisor --why x --text "Keep contract" --send pick:1
[ "$(state "$QA")" = escalated ] || fail "$QA left escalated after refused deliveries"
run "$MAIN" $Q alfa answer "$QA" --run "$RUN_ID" --tier 3 --author operator --why x --send none
expect 0 "recorded (tier 3)" "the Operator's tier 3 on a recorded fallback"

# ---- (183) evidence that changes before the commit point → no fallback -----------------------
hook() { printf '%s\n' "$1" > "$WORK/mail.opinion-hook"; }
changed() {  # changed <label> — the q timed out, Reviewer agreed, the hook changed the evidence
  esc 2 "$QF" --blocks x --class plan-variant --recommend "say Counter."
  expect 3 "NO-REPLY timeout after 1 min" "$1"
  has "fallback: no — evidence changed" "$QF" || fail "$1: no evidence-changed reason"
  ! has "reviewer-fallback" "$QF" || fail "$1 fell back"
  [ ! -e "$WORK/mail.opinion-hook" ] || fail "$1: the opinion op never ran"
}
mkq blocked; opinion 999 "opinion: agree"
hook "printf 'waiting: operator 2026-10-25T00:00:00Z eta -\n' >> '$QF'"
changed "waiting: operator during the opinion read"
mkq blocked; opinion 999 "opinion: agree"
hook "printf 'recommend: say Something else.\n' >> '$QF'"
changed "a new recommendation with the old opinion"
mkq blocked; opinion 999 "opinion: agree"
hook "printf 'mail-id: 1000\nopinion: agree\n' > '$WORK/mail.opinion.$(thread)'"
changed "a newer Reviewer opinion"
mkq blocked; opinion 999 "opinion: agree"
hook "printf '\n## Answer\ntier: 3\nauthor: operator\ndelivery: recorded only\n' >> '$QF'"
changed "an Operator answer during the opinion read"
mkq blocked; opinion 999 "opinion: agree"
hook "printf 'mail-id: 1001\nstatus: answer\n\nAdvisor: B.\n' > '$WORK/mail.reply.$(thread)'"
esc 2 "$QF" --blocks x --class plan-variant --recommend "say Counter."
expect 0 "ANSWER" "a Advisor reply at the commit point"
has "Advisor: B." "$WORK/out" || fail "the Advisor reply was not printed"
has "fallback: no — evidence changed" "$QF" && has "reply: 1001 answer" "$QF" \
  && ! has "reviewer-fallback" "$QF" || fail "a Advisor reply at the commit point fell back"
mkq blocked; opinion 999 "opinion: agree"
printf '%s\n' "printf 'mail-id: 1002\\nstatus: answer\\n\\nAdvisor: late B.\\n' \\
  > '$WORK/mail.reply.$(thread)'" > "$WORK/hook2"
hook "cp '$WORK/hook2' '$WORK/mail.opinion-hook'"
esc 2 "$QF" --blocks x --class plan-variant --recommend "say Counter."
expect 0 "ANSWER" "a Advisor reply during the opinion re-read"
[ ! -e "$WORK/mail.opinion-hook" ] || fail "the opinion re-read never ran"
has "fallback: no — evidence changed" "$QF" && has "reply: 1002 answer" "$QF" \
  && ! has "reviewer-fallback" "$QF" || fail "a Advisor reply during the opinion re-read fell back"
mkq blocked; opinion 999 "opinion: agree"; hook "touch '$WORK/mail.opinion-fail'"
esc 2 "$QF" --blocks x --class plan-variant --recommend "say Counter."
expect 3 "NO-REPLY timeout after 1 min" "a failing opinion re-read"
rm -f "$WORK/mail.opinion-fail"
has "fallback: no — opinion op failed (rc 1)" "$QF" && ! has "reviewer-fallback" "$QF" \
  || fail "a failing opinion re-read fell back"
mkq blocked; opinion 999 "opinion: agree"; hook "touch '$WORK/mail.opinion-slow'"
SECONDS=0
TEAM_ESCALATE_OPINION_RECHECK_SECS=20 bg_esc 2 "$QF" --blocks x --class plan-variant \
  --recommend "say Counter."
sleep 6; kill "$BGP" 2>/dev/null || true; wait "$BGP" 2>/dev/null || true
rm -f "$WORK/mail.opinion-slow"
[ "$SECONDS" -lt 15 ] || fail "a TERM at the commit point waited on its own lock (${SECONDS}s)"
has "outcome: cancelled" "$QF" && [ ! -d "$QF.lock" ] && ! has "reviewer-fallback" "$QF" \
  || fail "a TERM at the commit point: $(cat "$WORK/bg.out")"

# ---- (184) Reviewer names the class it checked ------------------------------------------------
mkq blocked; opinion 999 "opinion: disagree" "class: contract — the DTO changes"
nofb "disagree with a class" "Reviewer disagree (class contract)" --class plan-variant \
  --recommend "say x"
has "opinion: 999 disagree class contract" "$QF" || fail "the class was not recorded"
mkq blocked; opinion 999 "opinion: disagree" "class: plan-variant — fine"
nofb "disagree with an eligible class" "Reviewer disagree" --class plan-variant --recommend "say x"
! has "disagree class" "$QF" || fail "an eligible class was recorded as the reason"
mkq blocked; opinion 999 "opinion: disagree" "Class: <Contract> — the DTO changes"
nofb "a bracketed class" "Reviewer disagree (class contract)" --class plan-variant \
  --recommend "say x"
mkq blocked; opinion 999 "opinion: agree" "class: contract — the DTO changes"
nofb "agree naming a critical class" "Reviewer agree names class contract" --class plan-variant \
  --recommend "say x"
mkq menu; opinion 999 "opinion: agree" "class: plan-variant — checked"
esc 2 "$QF" --blocks x --class plan-variant --recommend "picks:1,3 Dwie opcje"
expect 0 "send: picks:1,3" "agree echoing an eligible class"
grep -qx "text: Dwie opcje" "$WORK/out" || fail "the class line became a condition"

# ---- (185) the minute shrinks only under the smoke marker ------------------------------------
mkq blocked; opinion 999 "opinion: agree"
(cd "$MAIN" && exec env -u TEAM_SMOKE $ESC alfa coder 2 "$QF" --blocks x --class plan-variant \
  --recommend "say x") > "$WORK/bg.out" 2>&1 &
BGP=$!; BG="$BG $BGP"; bg_stop
has "sent: seq 1" "$QF" || fail "no-marker escalation never sent: $(cat "$WORK/bg.out")"
! has "waited: " "$QF" && ! has "reviewer-fallback" "$QF" \
  || fail "TEAM_ESCALATE_UNIT_SECS shortened the timeout without the smoke marker"

# ---- (186) Advisor's silence needs a completed peek: EMPTY or no fallback --------------------
mkq blocked; opinion 999 "opinion: agree"
esc 2 "$QF" --blocks x --class plan-variant --recommend "say Counter."
expect 0 "FALLBACK" "a completed empty peek"
[ -e "$WORK/mail.peeked.$(thread)" ] || fail "the fallback was written without a peek"
mkq blocked; opinion 999 "opinion: agree"
hook "touch '$WORK/mail.peek-slow'; printf 'mail-id: 1003\nstatus: answer\n\nB.\n' \
  > '$WORK/mail.reply.$(thread)'"
changed "a peek slower than its bound with a reply waiting"
rm -f "$WORK/mail.peek-slow" "$WORK/mail.reply.$(thread)"
has "fallback: no — evidence changed (peek timeout)" "$QF" || fail "peek timeout reason"
mkq blocked; opinion 999 "opinion: agree"; hook "touch '$WORK/mail.peek-fail'"
changed "a failing peek"; rm -f "$WORK/mail.peek-fail"
has "fallback: no — evidence changed (peek failed rc 1)" "$QF" || fail "peek failed reason"
mkq blocked; opinion 999 "opinion: agree"; hook "touch '$WORK/mail.peek-silent'"
changed "a peek without EMPTY"; rm -f "$WORK/mail.peek-silent"
has "fallback: no — evidence changed (peek: no EMPTY)" "$QF" || fail "no EMPTY reason"
jq 'del(.peek)' "$CFG" > "$WORK/cfg.nopeek" && mv "$WORK/cfg.nopeek" "$CFG"
mkq blocked; opinion 999 "opinion: agree"
nofb "no peek key" "peek adapter off" --class plan-variant --recommend "say x"
cfg_fb

echo "team-smoke-11: OK"
