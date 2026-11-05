#!/usr/bin/env bash
# team-watch routing: role-bound receivers, single Supervisor (the default, acks and is timed),
# split routing, batch acks, pickup alarms with the terminal rule, handover, receiver liveness.
# Cases (61)-(67).
# It spawns loops and waits on pickup windows, so the runner keeps it out of a parallel batch.
# team-smoke: serial
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-watch-lib.sh"
smoke_init
smoke_team AB-1118 chore/AB-1118-watch
watch_init
mkrole SUP; mkrole TEAM

# alfa: a permission prompt; beta: a blocked record; eps: READY.
session coder 1 "$BASE"
echo "2026-10-19T10:00:00Z permission_prompt Claude needs your permission" > "$RD/attention"
mkdir "$TD/lock"; echo $$ > "$TD/lock/pid"
mkclone beta beta-20261019-000000; wrec "$CT" beta beta-20261019-000000 coder blocked "which endpoint?"
mkclone eps eps-20261019-000000
for r in planner coder qa wrapup; do wrec "$CT" eps eps-20261019-000000 "$r" done; done
ack_all() {  # ack_all <role> — every pending batch of that role
  local n
  for n in $(cd "$MAIN" && $W pending "$1"); do run "$MAIN" env TEAM_SESSION_ROLE="$1" $W ack "$n"; done
}

# ---- (61) register by role; no routing.json = single Supervisor -----------------------------------
run "$MAIN" $W status; has "routing: single Supervisor" "$WORK/out" || fail "default routing"
run "$MAIN" $W routing split; expect 0 "routing split" "routing split"
as - TEAM $W register; expect 1 "TEAM_SESSION_ROLE unset or unknown" "register without a role in split"
E1="$(grep '^error:' "$WORK/out")"
run "$MAIN" env -u TEAM_SESSION_ROLE $W ack 1; expect 1 "" "ack without a role in split"
[ "$(grep '^error:' "$WORK/out")" = "$E1" ] || fail "register and ack errors differ"
as TeamLead TEAM $W register; expect 0 "TeamLead registered" "register TeamLead"
[ "$(stat -f %Lp "$TWD/receivers")" = 700 ] || fail "receivers dir not mode 700"
sleep 3000 & H=$!; PIDS="$PIDS $H"; setpid TeamLead "$H"
as TeamLead TEAM $W register; expect 1 "held by live pid $H" "a live holder refuses"
as TeamLead TEAM $W register --takeover; expect 0 "replaced TeamLead pid $H" "takeover"
setpid TeamLead "$(dead_pid)"
as TeamLead TEAM $W register; expect 0 "replaced TeamLead pid" "a dead holder is taken"
ID_T="$(jq -r .id "$TWD/receivers/TeamLead.json")"
as Supervisor SUP $W register; expect 0 "Supervisor registered" "register Supervisor"
[ "$(jq -r .id "$TWD/receivers/TeamLead.json")" = "$ID_T" ] || fail "Supervisor touched TeamLead"
as Advisor TEAM $W register; expect 1 "TEAM_SESSION_ROLE unset or unknown" "the Advisor is no receiver"

run "$MAIN" $W routing single Supervisor; expect 0 "routing single Supervisor" "routing single Supervisor"
run "$MAIN" $W routing single Advisor; expect 2 "" "single needs a receiver role"
as TeamLead TEAM $W register; expect 0 "standby — routing single Supervisor" "standby"
run "$MAIN" $W ping TeamLead; expect 0 "" "ping"
wait_recv TEAM "PING TeamLead" 10
run "$MAIN" $W tick --once
wait_recv SUP "ATTENTION alfa coder (permission)" 30
[ "$(nrecv TEAM "ATTENTION alfa")" = 0 ] || fail "standby got a routed signal"
[ "$(nrecv SUP "PING TeamLead")" = 0 ] || fail "the ping reached the routed receiver"
P="$(last_batch TEAM)"
run "$MAIN" $W pending TeamLead; expect 0 "$P" "pending lists the ping batch"
run "$MAIN" env TEAM_SESSION_ROLE=TeamLead $W ack "$P"; expect 0 "picked #$P" "ack the ping"
run "$MAIN" $W pending TeamLead; [ -z "$(cat "$WORK/out")" ] || fail "pending after ack"
# The single Supervisor is a real receiver: its header carries role and ack, and it is timed —
# its own episode is a platform notification only (the terminal rule).
msgs SUP | jq -se 'all(.[]; contains(" · role=Supervisor · ack: bash .claude/lib/team-watch.sh ack ")
  and contains(" · handle per .claude/commands/monitor.md · "))' >/dev/null \
  || fail "the single Supervisor header lacks role/ack/contract"
: > "$STUB_LOG"
TEAM_WATCH_PICKUP_SECS=1 daemon; sleep 5; stop_daemon
[ "$(nnotify "UNPICKED Supervisor #")" -ge 1 ] || { cp "$STUB_LOG" "$WORK/out"; fail "the single Supervisor was not timed"; }
grep -q "UNPICKED Supervisor" "$WORK"/*.recv && fail "an alarm about the Supervisor was sent to a socket"
ack_all Supervisor
echo "team-smoke-16: (61) register by role, single Supervisor OK"

# ---- (62) split routing ---------------------------------------------------------------------------
mailcfg "printf '[agent-mail] #7 2026-10-19 from=Advisor kind=turn awaiting=Supervisor thread=t\\n'"
NS="$(msgs SUP | wc -l | tr -d ' ')"
run "$MAIN" $W routing split; expect 0 "batches transferred" "routing split again"
run "$MAIN" $W tick --once; expect 0 "" "tick in split"
wait_recv TEAM "ATTENTION alfa coder (permission)" 30
wait_recv SUP "MAIL Supervisor [agent-mail] #7" 10
B_T="$(last_batch TEAM)"; B_S="$(last_batch SUP)"
M="$(msgs TEAM | tail -n 1)"
for x in "RECORD beta coder: coder-1-1.json blocked" "READY eps: PR 8571" "RUNNER beta stopped" \
  "role=TeamLead · ack: bash .claude/lib/team-watch.sh ack $B_T" "handle per .claude/commands/monitor.md"; do
  jq -e --arg x "$x" 'contains($x)' <<<"$M" >/dev/null || { echo "$M" > "$WORK/out"; fail "TeamLead lacks: $x"; }
done
msgs SUP | tail -n +"$((NS + 1))" | jq -se 'length > 0 and all(.[]; contains("role=Supervisor")
  and contains("handle per .agents/reference/team-watch.md#supervisor")
  and (contains("ATTENTION") | not) and (contains("READY") | not))' >/dev/null \
  || fail "the split Supervisor got a team signal or the wrong contract"
jq -e 'contains("MAIL")' <<<"$M" >/dev/null && fail "TeamLead got the Supervisor's mail"
jq -n '{snapshot: {teams: []}, mail: {}, mail_errors: {Supervisor: "x", TeamLead: "y"},
  snapshot_error: null, routing: {mode: "split", receiver: null, live: {TeamLead: true}}}' \
  | jq -f "$SRC/.claude/lib/team-watch-signals.jq" > "$WORK/sig.json"
jq -e 'any(.[]; .key == "err:mail:Supervisor" and .to == "Supervisor")
  and any(.[]; .key == "err:mail:TeamLead" and .to == "TeamLead")' "$WORK/sig.json" >/dev/null \
  || { cp "$WORK/sig.json" "$WORK/out"; fail "mail error routing"; }
jq -n '{mail_errors: {TeamLead: "y"}, routing: {mode: "split", live: {}}}' \
  | jq -f "$SRC/.claude/lib/team-watch-signals.jq" > "$WORK/sig.json"
jq -e '.[0].to == "Supervisor"' "$WORK/sig.json" >/dev/null || fail "a dead receiver's mail error goes to the Supervisor"
echo "team-smoke-16: (62) split routing OK"

# ---- (63) one batch per receiver, ack by number --------------------------------------------------
jq -se --argjson b "$B_T" --argjson s "$B_S" '
  (map(select(.batch == $b and .to == "TeamLead")) | length == 1)
  and (map(select(.batch == $s and .to == "Supervisor")) | length == 1)' \
  "$TWD/deliveries.jsonl" >/dev/null || fail "deliveries do not match the batches"
jq -ne --slurpfile d "$TWD/deliveries.jsonl" --slurpfile e "$TWD/events.jsonl" --argjson b "$B_T" '
  ($d | map(select(.batch == $b and .to == "TeamLead"))[0].seqs) as $s
  | ($s | max) == $b and ($s | length) >= 3
  and [$e[] | select(.to == "TeamLead" and .seq >= ($s | min) and .seq <= $b) | .seq] == $s' \
  >/dev/null || fail "batch seqs differ from the TeamLead events"
run "$MAIN" env TEAM_SESSION_ROLE=TeamLead $W ack "$B_S"; expect 1 "is not TeamLead's" "foreign ack"
run "$MAIN" env TEAM_SESSION_ROLE=TeamLead $W ack "$B_T"; expect 0 "picked #$B_T" "ack TeamLead"
ack_all TeamLead; ack_all Supervisor
TEAM_WATCH_PICKUP_SECS=2 daemon; sleep 4; stop_daemon
grep -q UNPICKED "$WORK"/*.recv && fail "UNPICKED after every batch was acked"
echo "team-smoke-16: (63) batch ack OK"

# ---- (64) UNPICKED, one alarm per episode ---------------------------------------------------------
: > "$STUB_LOG"
run "$MAIN" $W ping TeamLead; wait_recv TEAM "PING TeamLead" 10 2
P="$(last_batch TEAM)"
TEAM_WATCH_PICKUP_SECS=2 daemon
wait_recv SUP "UNPICKED TeamLead #$P" 15
sleep 3
[ "$(nrecv SUP "UNPICKED TeamLead #")" = 1 ] || fail "more than one UNPICKED per episode"
grep -q '^notify --backend osascript --alarm team-watch: alarm UNPICKED TeamLead' "$STUB_LOG" \
  || { cp "$STUB_LOG" "$WORK/out"; fail "no kit notification for UNPICKED"; }
run "$MAIN" env TEAM_SESSION_ROLE=TeamLead $W ack "$P"
wait_recv SUP "UNPICKED TeamLead recovered" 10
sleep 2; stop_daemon
[ "$(nrecv SUP "UNPICKED TeamLead recovered")" = 1 ] || fail "more than one recovered"
echo "team-smoke-16: (64) UNPICKED episode OK"

# ---- (65) terminal rule: the Supervisor's own episode is a notification only ---------------------
ack_all Supervisor   # the alarms of (64) were never picked up
: > "$STUB_LOG"
run "$MAIN" $W ping Supervisor; wait_recv SUP "PING Supervisor" 10
P="$(last_batch SUP)"
TEAM_NOTIFY=0 TEAM_WATCH_PICKUP_SECS=1 daemon; sleep 6; stop_daemon
grep -q "UNPICKED Supervisor" "$WORK"/*.recv && fail "an alarm about the Supervisor was sent to a socket"
[ "$(grep -c '^notify --backend osascript --alarm team-watch: alarm UNPICKED Supervisor #' "$STUB_LOG")" = 1 ] \
  || { cp "$STUB_LOG" "$WORK/out"; fail "expected exactly one notification for the Supervisor's episode"; }
grep -q '^osascript' "$STUB_LOG" && fail "team-watch called osascript directly"
run "$MAIN" env TEAM_SESSION_ROLE=Supervisor $W ack "$P"; expect 0 "" "ack the supervisor ping"
echo "team-smoke-16: (65) terminal rule OK"

# ---- (67) handover ---------------------------------------------------------------------------------
run "$MAIN" $W ping TeamLead; wait_recv TEAM "PING TeamLead" 10 3
OLD="$(last_batch TEAM)"
jq -cn --argjson s "$(( $(tail -n 1 "$TWD/events.jsonl" | jq .seq) + 1 ))" \
  '{seq: $s, at: "x", to: "TeamLead", label: "", text: "QUEUED never sent"}' >> "$TWD/events.jsonl"
touch "$TWD/alarm.unpicked.TeamLead"
N0="$(nrecv SUP "ATTENTION alfa coder (permission)")"
run "$MAIN" $W routing single Supervisor; expect 0 "routing single Supervisor —" "handover to single"
[ ! -f "$TWD/alarm.unpicked.TeamLead" ] || fail "episode flag survived the handover"
run "$MAIN" env TEAM_SESSION_ROLE=TeamLead $W ack "$OLD"; expect 1 "transferred" "ack of a transferred batch"
has "handle the (current state) batch instead" "$WORK/out" || fail "transferred refusal text"
jq -se 'any(.[]; .transferred == true and .to == "TeamLead")' "$TWD/deliveries.jsonl" >/dev/null \
  || fail "the undelivered event was not transferred"
run "$MAIN" $W tick --once; run "$MAIN" $W tick --once
wait_recv SUP "ATTENTION alfa coder (permission)" 30 $((N0 + 1))
[ "$(nrecv SUP "ATTENTION alfa coder (permission)")" = $((N0 + 1)) ] || fail "re-delivered more than once"
msgs SUP | tail -n 1 | jq -e 'contains("(current state)")' >/dev/null || fail "no (current state) to the Supervisor"
grep -q "QUEUED never sent" "$WORK/SUP.recv" "$WORK/TEAM.recv" && fail "a transferred event was sent"
N1="$(nrecv TEAM "ATTENTION alfa coder (permission)")"
run "$MAIN" $W routing split; run "$MAIN" $W tick --once
wait_recv TEAM "(current state)" 30 1
[ "$(nrecv TEAM "ATTENTION alfa coder (permission)")" -gt "$N1" ] || fail "split back: no current state"
rm -f "$TWD/routing.json"
run "$MAIN" $W status; has "routing: single Supervisor" "$WORK/out" || fail "no routing.json is not single Supervisor"
run "$MAIN" $W routing split

# The collect-then-lock race: a result routed with the old generation is discarded.
(cd "$MAIN" && . .claude/lib/team-watch-lib.sh && tw_init "$MAIN"
  w="$(mktemp -d "$TWD/work.XXXXXX")"; tw_signals "$w"
  bash .claude/lib/team-watch.sh routing single Supervisor >/dev/null
  n0="$(wc -l < "$TWD/events.jsonl")"; tw_lock; tw_update "$w/sig.json" >/dev/null; tw_unlock
  [ "$(wc -l < "$TWD/events.jsonl")" = "$n0" ]) || fail "a stale-generation result was applied"
run "$MAIN" $W routing split
echo "team-smoke-16: (67) handover OK"

# ---- (66) RECEIVER down ---------------------------------------------------------------------------
ack_all Supervisor; ack_all TeamLead
kill "$TEAM_PID"; wait "$TEAM_PID" 2>/dev/null || true
daemon; wait_recv SUP "RECEIVER TeamLead down" 15; sleep 2; stop_daemon
[ "$(nrecv SUP "RECEIVER TeamLead down")" = 1 ] || fail "RECEIVER down more than once"
echo "team-smoke-16: (66) RECEIVER down OK"
echo "team-smoke-16: OK"
