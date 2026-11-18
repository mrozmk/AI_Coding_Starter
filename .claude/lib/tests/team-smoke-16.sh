#!/usr/bin/env bash
# team-watch routing: role-bound receivers, single Supervisor (the default, acks and is timed),
# split routing, batch acks, pickup alarms with the terminal rule, handover, the retired global
# TeamLead (never registered, never delivered to, a stale routing reads as the Supervisor).
# Cases (61)-(68c).
# It spawns loops and waits on pickup windows, so the runner keeps it out of a parallel batch.
# team-smoke: serial
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-watch-lib.sh"
smoke_init
smoke_team AB-1118 chore/AB-1118-watch
watch_init
mkrole SUP; mkrole ADV

ack_all() {  # ack_all <role> — every pending batch of that role
  local n
  for n in $(cd "$MAIN" && $W pending "$1"); do run "$MAIN" env TEAM_SESSION_ROLE="$1" $W ack "$n"; done
}
FILTER="$SRC/.claude/lib/team-watch-signals.jq"

# ---- (61) register by role; no routing.json = single Supervisor -----------------------------------
run "$MAIN" $W status; has "routing: single Supervisor" "$WORK/out" || fail "default routing"
run "$MAIN" $W routing split; expect 0 "routing split" "routing split"
as - SUP $W register; expect 1 "TEAM_SESSION_ROLE unset — split routing needs a role session" \
  "register without a role in split"
E1="$(grep '^error:' "$WORK/out")"
run "$MAIN" env -u TEAM_SESSION_ROLE $W ack 1; expect 1 "" "ack without a role in split"
[ "$(grep '^error:' "$WORK/out")" = "$E1" ] || fail "register and ack errors differ"
# A leftover global TeamLead window never registers — not even as the Supervisor.
as TeamLead ADV $W register
expect 1 "TEAM_SESSION_ROLE=TeamLead is not a team-watch receiver (receivers: Supervisor)" \
  "the retired TeamLead registers"
[ ! -e "$TWD/receivers/TeamLead.json" ] && [ ! -e "$TWD/receivers/Supervisor.json" ] \
  || fail "a refused TeamLead wrote a receiver file"
as Advisor ADV $W register; expect 1 "TEAM_SESSION_ROLE=Advisor is not a team-watch receiver" \
  "the Advisor is no receiver"
as Supervisor SUP $W register; expect 0 "Supervisor registered" "register Supervisor"
[ "$(stat -f %Lp "$TWD/receivers")" = 700 ] || fail "receivers dir not mode 700"
sleep 3000 & H=$!; PIDS="$PIDS $H"; setpid Supervisor "$H"
as Supervisor SUP $W register; expect 1 "held by live pid $H" "a live holder refuses"
as Supervisor SUP $W register --takeover; expect 0 "replaced Supervisor pid $H" "takeover"
setpid Supervisor "$(dead_pid)"
as Supervisor SUP $W register; expect 0 "replaced Supervisor pid" "a dead holder is taken"

run "$MAIN" $W routing single Supervisor; expect 0 "routing single Supervisor" "routing single Supervisor"
run "$MAIN" $W routing single Advisor; expect 2 "" "single needs a receiver role"
OLD_RECEIVER=TeamLead
run "$MAIN" $W routing single "$OLD_RECEIVER"; expect 2 "" "the retired TeamLead is no single receiver"
run "$MAIN" $W ping Supervisor; expect 0 "team-watch: ping Supervisor queued (seq" "ping"
wait_recv SUP "PING Supervisor" 10
P="$(last_batch SUP)"
run "$MAIN" $W pending Supervisor; expect 0 "$P" "pending lists the ping batch"
run "$MAIN" env TEAM_SESSION_ROLE=Supervisor $W ack "$P"; expect 0 "picked #$P" "ack the ping"
run "$MAIN" $W pending Supervisor; [ -z "$(cat "$WORK/out")" ] || fail "pending after ack"
# The single Supervisor is a real receiver: its header carries role and ack, and it is timed —
# its own episode is only logged (the terminal rule).
msgs SUP | jq -se 'all(.[]; contains(" · role=Supervisor · ack: bash .claude/lib/team-watch.sh ack ")
  and contains(" · handle per .claude/commands/monitor.md · "))' >/dev/null \
  || fail "the single Supervisor header lacks role/ack/contract"
run "$MAIN" $W ping Supervisor; wait_recv SUP "PING Supervisor" 10 2
: > "$STUB_LOG"
TEAM_WATCH_PICKUP_SECS=1 daemon; sleep 5; stop_daemon
grep -q 'alarm not sent: UNPICKED Supervisor #' "$WORK/daemon.log" || { cp "$WORK/daemon.log" "$WORK/out"; fail "the single Supervisor was not timed"; }
grep -q "UNPICKED Supervisor" "$WORK"/*.recv && fail "an alarm about the Supervisor was sent to a socket"
ack_all Supervisor
echo "team-smoke-16: (61) register by role, single Supervisor OK"

# ---- (62) split routing ---------------------------------------------------------------------------
mailcfg "printf '[agent-mail] #7 2026-10-19 from=Advisor kind=turn awaiting=Supervisor thread=t\\n'"
mkclone omega; echo '{not json' > "$CT/session.json"
NS="$(msgs SUP | wc -l | tr -d ' ')"
run "$MAIN" $W routing split; expect 0 "batches transferred" "routing split again"
run "$MAIN" $W tick --once; expect 0 "" "tick in split"
wait_recv SUP "MAIL Supervisor [agent-mail] #7" 30
wait_recv SUP "ERROR omega: unreadable session.json" 10
B_S="$(last_batch SUP)"
msgs SUP | tail -n +"$((NS + 1))" | jq -se --arg a "ack: bash .claude/lib/team-watch.sh ack $B_S" '
  length > 0 and all(.[]; contains("role=Supervisor")
  and contains("handle per .agents/reference/team-watch.md#supervisor"))
  and (.[-1] | contains($a))' >/dev/null \
  || fail "the split Supervisor got the wrong contract or ack"
# Every non-mail signal and a non-receiver role's mail error go to the Supervisor.
jq -n '{snapshot: {teams: [], errors: ["tmux: no server"]}, mail: {},
  mail_errors: {Supervisor: "x", TeamLead: "y"}, snapshot_error: null,
  roles: {Advisor: {sub: "menu", fp: "f1", anchor: "Pick one", screen: []}},
  routing: {mode: "split", receiver: null, live: {Supervisor: true}}}' \
  | jq -f "$FILTER" > "$WORK/sig.json"
jq -e 'length == 4 and all(.[]; .to == "Supervisor")
  and any(.[]; .key == "err:mail:Supervisor") and any(.[]; .key == "err:mail:TeamLead")
  and any(.[]; .key == "ratt:Advisor:menu:f1") and any(.[]; .key == "err:tmux: no server")' \
  "$WORK/sig.json" >/dev/null || { cp "$WORK/sig.json" "$WORK/out"; fail "split routing of non-mail signals"; }
jq -n '{mail_errors: {Supervisor: "y"}, routing: {mode: "split", live: {}}}' \
  | jq -f "$FILTER" > "$WORK/sig.json"
jq -e '.[0].to == "Supervisor"' "$WORK/sig.json" >/dev/null || fail "a dead receiver's mail error goes to the Supervisor"
# A pre-upgrade render still carrying mail.TeamLead: the key is ignored, never an ERROR.
jq '.mail.TeamLead = "exit 3"' "$MAIN/.agents/team/watch.local.json" > "$WORK/wl" \
  && cp "$WORK/wl" "$MAIN/.agents/team/watch.local.json"
run "$MAIN" $W signals; expect 0 "" "signals with a stale mail.TeamLead"
jq -e 'all(.[]; (.key | contains("TeamLead") | not) and (.head | contains("TeamLead") | not))
  and any(.[]; .key | startswith("mail:Supervisor:"))' "$WORK/out" >/dev/null \
  || fail "a stale mail.TeamLead probe surfaced"
mailcfg "printf '[agent-mail] #7 2026-10-19 from=Advisor kind=turn awaiting=Supervisor thread=t\\n'"
echo "team-smoke-16: (62) split routing OK"

# ---- (63) one batch per receiver, ack by number --------------------------------------------------
jq -se --argjson s "$B_S" 'map(select(.batch == $s and .to == "Supervisor")) | length == 1' \
  "$TWD/deliveries.jsonl" >/dev/null || fail "deliveries do not match the batch"
jq -ne --slurpfile d "$TWD/deliveries.jsonl" --slurpfile e "$TWD/events.jsonl" --argjson b "$B_S" '
  ($d | map(select(.batch == $b and .to == "Supervisor"))[0].seqs) as $s
  | ($s | max) == $b and ($s | length) >= 2
  and [$e[] | select(.to == "Supervisor" and .seq >= ($s | min) and .seq <= $b) | .seq] == $s' \
  >/dev/null || fail "batch seqs differ from the Supervisor events"
run "$MAIN" env TEAM_SESSION_ROLE=Supervisor $W ack 999999; expect 1 "is not Supervisor's" "foreign ack"
run "$MAIN" env TEAM_SESSION_ROLE=TeamLead $W ack "$B_S"; expect 1 "is not a team-watch receiver" \
  "ack by the retired TeamLead"
run "$MAIN" env TEAM_SESSION_ROLE=Supervisor $W ack "$B_S"; expect 0 "picked #$B_S" "ack Supervisor"
ack_all Supervisor
TEAM_WATCH_PICKUP_SECS=2 daemon; sleep 4; stop_daemon
grep -q UNPICKED "$WORK"/*.recv && fail "UNPICKED after every batch was acked"
echo "team-smoke-16: (63) batch ack OK"

# ---- (65) terminal rule: the Supervisor's own episode is only logged -------------------------------
ack_all Supervisor
: > "$STUB_LOG"
NP="$(nrecv SUP "PING Supervisor")"
run "$MAIN" $W ping Supervisor; wait_recv SUP "PING Supervisor" 10 $((NP + 1))
P="$(last_batch SUP)"
TEAM_WATCH_PICKUP_SECS=1 daemon; sleep 6; stop_daemon
grep -q "UNPICKED Supervisor" "$WORK"/*.recv && fail "an alarm about the Supervisor was sent to a socket"
[ "$(grep -c "alarm not sent: UNPICKED Supervisor #$P " "$WORK/daemon.log")" = 1 ] \
  || { cp "$WORK/daemon.log" "$WORK/out"; fail "expected exactly one log line for the Supervisor's episode"; }
! grep -q '^notify ' "$STUB_LOG" || fail "the Supervisor's episode notified someone"
grep -q '^osascript' "$STUB_LOG" && fail "team-watch called osascript directly"
run "$MAIN" env TEAM_SESSION_ROLE=Supervisor $W ack "$P"; expect 0 "" "ack the supervisor ping"
echo "team-smoke-16: (65) terminal rule OK"

# ---- (67) handover ---------------------------------------------------------------------------------
NP="$(nrecv SUP "PING Supervisor")"
run "$MAIN" $W ping Supervisor; wait_recv SUP "PING Supervisor" 10 $((NP + 1))
OLD="$(last_batch SUP)"
jq -cn --argjson s "$(( $(tail -n 1 "$TWD/events.jsonl" | jq .seq) + 1 ))" \
  '{seq: $s, at: "x", to: "Supervisor", label: "", text: "QUEUED never sent"}' >> "$TWD/events.jsonl"
touch "$TWD/alarm.unpicked.Supervisor"
N0="$(nrecv SUP "(current state)")"
run "$MAIN" $W routing single Supervisor; expect 0 "routing single Supervisor —" "handover to single"
[ ! -f "$TWD/alarm.unpicked.Supervisor" ] || fail "episode flag survived the handover"
run "$MAIN" env TEAM_SESSION_ROLE=Supervisor $W ack "$OLD"; expect 1 "transferred" "ack of a transferred batch"
has "handle the (current state) batch instead" "$WORK/out" || fail "transferred refusal text"
jq -se 'any(.[]; .transferred == true and .to == "Supervisor")' "$TWD/deliveries.jsonl" >/dev/null \
  || fail "the undelivered event was not transferred"
run "$MAIN" $W tick --once; run "$MAIN" $W tick --once
wait_recv SUP "(current state)" 30 $((N0 + 1))
[ "$(nrecv SUP "(current state)")" = $((N0 + 1)) ] || fail "re-delivered more than once"
msgs SUP | tail -n 1 | jq -e 'contains("MAIL [agent-mail] #7")' >/dev/null \
  || fail "the single (current state) lacks the open mail"
grep -q "QUEUED never sent" "$WORK/SUP.recv" && fail "a transferred event was sent"
run "$MAIN" $W routing split; run "$MAIN" $W tick --once
wait_recv SUP "(current state)" 30 $((N0 + 2))
msgs SUP | tail -n 1 | jq -e 'contains("MAIL Supervisor [agent-mail] #7")' >/dev/null \
  || fail "split back: no current state"
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

# ---- (68b) retired events never delivered ----------------------------------------------------------
echo "team-smoke-16: (68b) queued att:, ratt:TeamLead: and err:mail:TeamLead events and an event to TeamLead are never delivered; Supervisor mail and an Advisor ratt: in the same queue are"
run "$MAIN" $W tick --once; ack_all Supervisor
S0="$(tail -n 1 "$TWD/events.jsonl" | jq .seq)"
qev() {  # qev <to> <key> <text> — one queued event past the last seq
  jq -cn --argjson s "$(( $(tail -n 1 "$TWD/events.jsonl" | jq .seq) + 1 ))" --arg to "$1" \
    --arg k "$2" --arg t "$3" '{seq: $s, at: "x", to: $to, key: $k, label: "", text: $t}' \
    >> "$TWD/events.jsonl"
}
qev Supervisor "att:alfa:coder:permission" "RETIRED att"
qev Supervisor "ratt:TeamLead:menu:f9" "RETIRED ratt TeamLead"
qev Supervisor "err:mail:TeamLead" "RETIRED err mail TeamLead"
qev TeamLead "mail:TeamLead:x" "RETIRED to TeamLead"
qev Supervisor "mail:Supervisor:[agent-mail] #8" "LIVE mail Supervisor"
qev Supervisor "ratt:Advisor:menu:f2" "LIVE ratt Advisor"
cp "$WORK/SUP.recv" "$WORK/sup.before"
run "$MAIN" $W tick --once; expect 0 "events to retired receiver TeamLead are not delivered" \
  "tick over a queue with retired events"
wait_recv SUP "LIVE ratt Advisor" 10
[ "$(nrecv SUP "LIVE mail Supervisor")" = 1 ] || fail "the Supervisor mail was not delivered once"
grep -q RETIRED "$WORK/SUP.recv" "$WORK/ADV.recv" 2>/dev/null && fail "a retired event was sent"
jq -se --argjson s0 "$S0" '[.[] | select(.to == "TeamLead")] == []
  and ([.[] | select(.to == "Supervisor") | .seqs[]? | select(. > $s0)] | sort)
    == [$s0 + 5, $s0 + 6]' "$TWD/deliveries.jsonl" >/dev/null \
  || { cp "$TWD/deliveries.jsonl" "$WORK/out"; fail "the ledger carries a retired event"; }
ack_all Supervisor
echo "team-smoke-16: (68b) retired events never delivered OK"

# ---- (68c) a routing.json saying single TeamLead reads as single Supervisor ------------------------
jq -n '{mode: "single", receiver: "TeamLead", gen: 99}' > "$TWD/routing.json"
run "$MAIN" $W status
has "routing: single Supervisor" "$WORK/out" || fail "a stale single TeamLead is not read as the Supervisor"
has "routing: stale receiver TeamLead — read as single Supervisor; repair: team-watch.sh routing single Supervisor" \
  "$WORK/out" || fail "status lacks the stale receiver line"
run "$MAIN" $W signals; expect 0 "" "signals under a stale single TeamLead"
jq -e 'length > 0 and all(.[]; .to == "Supervisor")' "$WORK/out" >/dev/null \
  || fail "a stale single TeamLead routed a signal away from the Supervisor"
run "$MAIN" env -u TEAM_SESSION_ROLE $W pending Supervisor; expect 0 "" "pending under a stale routing"
run "$MAIN" $W routing single Supervisor; expect 0 "routing single Supervisor" "repair"
run "$MAIN" $W status; ! has "stale receiver" "$WORK/out" || fail "the stale line survived the repair"
echo "team-smoke-16: (68c) stale single TeamLead OK"
echo "team-smoke-16: OK"
