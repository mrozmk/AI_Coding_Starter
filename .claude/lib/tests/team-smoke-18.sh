#!/usr/bin/env bash
# team-watch delivery and pause: bounded batches and backlog collapse; the per-role pause with
# its pass-through (no ack, no cursor move, dedup by the delivery ledger); replay at start;
# version guards.
# One receiver (the Supervisor): its pause policies run as sequential phases.
# Cases (160)-(164), (168b).
# It runs the team-watch loops, so the runner keeps it out of a parallel batch.
# team-smoke: serial
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-watch-lib.sh"
smoke_init
smoke_team AB-1245 chore/AB-1245-x
watch_init
mkrole SU; mkrole AD
MON="bash .claude/lib/monitoring.sh"
# Fixture policies: the shipped one (the Supervisor's pause passes alarms and incident- threads)
# and an incident-only one (incident- threads, no alarms) for the first pause phase.
cp "$MAIN/.claude/team/sessions/monitoring.json" "$WORK/mon.json"
jq '.roles.Supervisor.pause.pass = {mail_threads: ["incident-"]}' "$WORK/mon.json" > "$WORK/incident.json"
export TEAM_MONITORING_JSON="$WORK/mon.json"

# The size the real sender writes (json.dumps, ensure_ascii); a socket refusing > 70000 bytes.
cat > "$WORK/send" <<EOF
#!/usr/bin/env bash
in="\$(cat; echo x)"; in="\${in%x}"
n="\$(printf '%s' "\$in" | python3 -I -c 'import json,sys; print(len(json.dumps({"type":"user","message":{"role":"user","content":sys.stdin.read()}})))')"
echo "\$n" >> "$WORK/send.log"
[ "\$n" -le "\${SEND_LIMIT:-70000}" ] || exit 1
printf '%s' "\$in" | python3 -I "$SRC/.claude/lib/team-watch-send.py" "\$1"
EOF
chmod +x "$WORK/send"
export TEAM_WATCH_SENDER="$WORK/send"
: > "$WORK/send.log"; : > "$WORK/daemon.log"

bulk() {  # bulk <role> <n> <text> [class] — n events through the producer
  run "$MAIN" env R="$1" N="$2" BT="$3" C="${4:-}" bash -c '. .claude/lib/team-watch-lib.sh \
    && tw_init "$PWD" && tw_lock && for i in $(seq 1 "$N"); do
      tw_append_to "$R" "" "$BT $i" $C; done; tw_unlock'
  [ "$RC" = 0 ] || fail "bulk $1 $2"
}
sigupd() {  # sigupd <signals json> — tw_update, the producer of keyed events and open.json
  mkdir -p "$WORK/sigd"; echo "$1" > "$WORK/sigd/sig.json"
  lib 'tw_lock && tw_update "'"$WORK"'/sigd/sig.json"; tw_unlock'
  [ "$RC" = 0 ] || fail "tw_update"
}
sg() {  # sg <key> <to> <head> [kind]
  jq -cn --arg k "$1" --arg to "$2" --arg h "$3" --arg kind "${4:-mail}" \
    '{key: $k, kind: $kind, team: null, role: null, head: $h, screen: [], to: $to}'
}
deliver() { lib 'tw_deliver'; }
cur() { cat "$TWD/cursor.$1" 2>/dev/null || echo 0; }
lastseq() { tail -n 1 "$TWD/events.jsonl" | jq .seq; }
nmsg() { msgs "$1" | wc -l | tr -d ' '; }
long() { printf "${2:-x}%.0s" $(seq 1 "$1"); }
fresh_beats() { echo "$(date -u +%s) 1 v$TWV" > "$TWD/beat"; echo "$(date -u +%s) 1 v$TWV" > "$TWD/dog.beat"; }

run "$MAIN" $W routing split; expect 0 "" "routing split"
as Supervisor SU $W register; expect 0 "Supervisor registered" "register SU"

# ---- (160) bounded batches ------------------------------------------------------------------------
X900="$(long 900)"
bulk Supervisor 30 "$X900"
deliver; deliver
[ "$(nmsg SU)" = 2 ] || fail "30 events: $(nmsg SU) messages, expected 2"
[ "$(cur Supervisor)" = "$(lastseq)" ] || fail "cursor $(cur Supervisor) != last $(lastseq)"
jq -s -e 'map(select(.to == "Supervisor") | .seqs | length) == [25, 5]' "$TWD/deliveries.jsonl" \
  >/dev/null || fail "batch lengths: $(jq -sc 'map(.seqs | length)' "$TWD/deliveries.jsonl")"
while read -r n; do [ "$n" -le 60000 ] || fail "a message of $n bytes"; done < "$WORK/send.log"
bulk Supervisor 1 "$(long 70001)"; bulk Supervisor 1 small
export SEND_LIMIT=200000; deliver; unset SEND_LIMIT
[ "$(jq -s 'map(select(.to == "Supervisor")) | last | .seqs | length' "$TWD/deliveries.jsonl")" = 1 ] \
  || fail "an oversize event did not go alone"
deliver; [ "$(cur Supervisor)" = "$(lastseq)" ] || fail "the small event after the oversize one"
echo "team-smoke-18: (160) bounded batches OK"

# ---- (161) collapse -------------------------------------------------------------------------------
N0="$(nmsg SU)"
bulk Supervisor 1465 "$X900"
deliver
[ "$(nmsg SU)" = "$N0" ] || fail "the collapse sent a message"
[ "$(cur Supervisor)" = "$(lastseq)" ] || fail "collapse cursor"
[ -f "$TWD/collapsed.Supervisor" ] || fail "no collapsed.Supervisor"
jq -e '.registrations.Supervisor == "collapsed"' "$TWD/open.json" >/dev/null || fail "no replay mark"
bulk Supervisor 1 after; deliver
msgs SU | tail -n 1 | jq -e 'split("\n")[1] | startswith("(skipped 1465 backlog events from ")
  and endswith(" — current state below)")' \
  >/dev/null || { msgs SU | tail -n 1 > "$WORK/out"; fail "no skipped line"; }
[ ! -f "$TWD/collapsed.Supervisor" ] || fail "collapsed.Supervisor kept after the send"
echo "team-smoke-18: (161) collapse OK"

# ---- (162) pause pass-through; no cursor move; dedup -------------------------------------------
# Phase 1 — an incident-only pass: incident- mail passes, routine mail and a role prompt wait.
TEAM_MONITORING_JSON="$WORK/incident.json" as Supervisor SU $MON stop
expect 0 "Supervisor: paused since" "stop SU (incident-only pass)"
has "(Supervisor) (passes: {\"mail_threads\":[\"incident-\"]})" "$WORK/out" || fail "pause without its author or pass"
C0="$(cur Supervisor)"; N0="$(nmsg SU)"
sigupd "[$(sg mail:Supervisor:i Supervisor "MAIL Supervisor [agent-mail] i kind=turn thread=incident-1"),
  $(sg mail:Supervisor:o Supervisor "MAIL Supervisor [agent-mail] o kind=turn thread=ops-1"),
  $(sg ratt:Advisor:menu:f1 Supervisor "ATTENTION Advisor (menu) fp=f1: Pick one" role-attention)]"
TEAM_MONITORING_JSON="$WORK/incident.json" deliver
TEAM_MONITORING_JSON="$WORK/incident.json" deliver
[ "$(nmsg SU)" = $((N0 + 1)) ] && [ "$(nrecv SU "thread=incident-1")" = 1 ] || fail "SU did not get exactly the incident"
[ "$(nrecv SU "thread=ops-1")" = 0 ] && [ "$(nrecv SU "ATTENTION Advisor (menu)")" = 0 ] \
  || fail "routine passed the pause"
[ "$(cur Supervisor)" = "$C0" ] || fail "the pause moved the cursor"
TEAM_MONITORING_JSON="$WORK/incident.json" lib 'tw_alarm - "MONITOR probe #0"'
TEAM_MONITORING_JSON="$WORK/incident.json" deliver
[ "$(nrecv SU "MONITOR probe #0")" = 0 ] || fail "an alarm passed an incident-only pass"
# Phase 2 — the same pause under other policies: alarms pass the shipped pass and the fallback of a
# missing file, never an empty pass. A subjectless alarm (the daemon's) reaches its target.
lib 'tw_alarm - "MONITOR probe #1"'; wait_recv SU "MONITOR probe #1" 10
jq '.roles.Supervisor.pause.pass = {}' "$WORK/mon.json" > "$WORK/nopass.json"
TEAM_MONITORING_JSON="$WORK/nopass.json" lib 'tw_alarm - "MONITOR probe #2"'
TEAM_MONITORING_JSON="$WORK/nopass.json" deliver
[ "$(nrecv SU "MONITOR probe #2")" = 0 ] || fail "an alarm passed an empty pass"
TEAM_MONITORING_JSON="$WORK/missing.json" lib 'tw_alarm - "MONITOR probe #3"'
wait_recv SU "MONITOR probe #3" 10
[ "$(nrecv SU "thread=incident-1")" = 1 ] || fail "the delivery ledger did not dedup the incident"
[ "$(cur Supervisor)" = "$C0" ] || fail "a pass-through moved the cursor"
echo "team-smoke-18: (162) pause pass-through OK"

# ---- (162b) collapse keeps alarms, UNDELIVERED ----------------------------------------------------
run "$MAIN" env -u TEAM_SESSION_ROLE $MON start all; expect 0 "Supervisor: running · readiness:" "start all"
deliver
bulk Supervisor 120 routine
bulk Supervisor 30 "UNPICKED X #" alarm
deliver; deliver
msgs SU | tail -n 1 > "$WORK/last"
jq -e 'contains("older alarms") and contains("# 30") and contains("# 6\n")
  and (contains("# 5\n") | not) and (contains("routine") | not)' "$WORK/last" >/dev/null \
  || { cp "$WORK/last" "$WORK/out"; fail "collapse did not keep the 25 newest alarms"; }
jq -e 'contains(", 5 older alarms — current state below)")' "$WORK/last" >/dev/null \
  || { cp "$WORK/last" "$WORK/out"; fail "skipped line without 5 older alarms"; }
as Supervisor SU $MON stop; expect 0 "paused since" "stop SU again"
# The Supervisor is its own alarm target: its UNDELIVERED episode is only logged (terminal rule).
run "$MAIN" env TEAM_WATCH_UNDELIVERED_SECS=0 bash -c '. .claude/lib/team-watch-lib.sh \
  && tw_init "$PWD" && tw_undelivered Supervisor && tw_deliver'
has "UNDELIVERED Supervisor: no alarm target to tell (self or not live, or lock busy)" "$WORK/out" \
  || fail "the Supervisor's UNDELIVERED episode was not logged"
! has '"UNDELIVERED Supervisor' "$TWD/events.jsonl" || fail "an alarm about the Supervisor was queued"
lib 'tw_alarm - "MONITOR daemon dead (162b)"'; wait_recv SU "MONITOR daemon dead (162b)" 10
lib 'tw_delivered Supervisor'
echo "team-smoke-18: (162b) collapse keeps alarms, UNDELIVERED OK"

# ---- (162c) idle cursor, replay after start, classless alarms, bytes, incident mail --------------
run "$MAIN" env -u TEAM_SESSION_ROLE $MON start all; expect 0 "Supervisor: running" "start all (162c)"
deliver
C1="$(cur Supervisor)"; deliver; deliver; deliver
[ "$(cur Supervisor)" = "$C1" ] || fail "idle passes moved the cursor"
OPS="$(sg mail:Supervisor:x Supervisor "MAIL Supervisor [agent-mail] x kind=turn thread=ops-2")"
sigupd "[$OPS]"
deliver
as Supervisor SU $MON stop; expect 0 "paused since" "stop SU (162c)"
bulk Supervisor 10 ROUTINE-
run "$MAIN" env -u TEAM_SESSION_ROLE $MON start all; expect 0 "Supervisor: running · readiness:" "start all (SU)"
N1="$(nmsg SU)"
sigupd "[$OPS]"
deliver
[ "$(nmsg SU)" -gt "$N1" ] || fail "no replay after start"
msgs SU | tail -n 1 | jq -e 'contains("(current state)") and contains("thread=ops-2")
  and (contains("ROUTINE-") | not)' \
  >/dev/null || { msgs SU | tail -n 1 > "$WORK/out"; fail "start delivered the pre-start backlog"; }
as Supervisor SU $MON stop; expect 0 "paused since" "stop SU (classless alarm)"
lib 'tw_lock && tw_append_to Supervisor "" "MONITOR dog dead #9"; tw_unlock'
deliver; wait_recv SU "MONITOR dog dead #9" 10
# Resumed before the byte batching: a paused role would only get the incident class.
run "$MAIN" env -u TEAM_SESSION_ROLE $MON start all; expect 0 "Supervisor: running" "start all (bytes)"
deliver
: > "$WORK/send.log"
bulk Supervisor 25 "$(long 2400 ż)"
for _ in 1 2 3 4 5 6 7 8 9 10; do deliver; done
[ "$(cur Supervisor)" = "$(jq -s 'map(select(.to == "Supervisor")) | last | .seq' "$TWD/events.jsonl")" ] \
  || fail "non-ASCII backlog not drained"
while read -r n; do [ "$n" -le 60000 ] || fail "a non-ASCII message of $n bytes"; done < "$WORK/send.log"
as Supervisor SU $MON stop; expect 0 "paused since" "stop SU (incident mail)"
sigupd "[$(sg "mail:Supervisor:i7" Supervisor "MAIL Supervisor [agent-mail] a kind=turn thread=incident-7 x"),
  $(sg "mail:Supervisor:o1" Supervisor "MAIL Supervisor [agent-mail] b kind=turn thread=ops-1 y")]"
deliver
wait_recv SU "thread=incident-7" 10
[ "$(nrecv SU "thread=ops-1 y")" = 0 ] || fail "routine mail passed a paused Supervisor"
echo "team-smoke-18: (162c) replay, classless alarms, bytes, incident mail OK"

# ---- (163) a pause acks nothing: UNPICKED still fires ------------------------------------------
run "$MAIN" env -u TEAM_SESSION_ROLE $MON start all; expect 0 "" "start all (163)"
lib 'tw_lock && tw_append_to Supervisor "" "PING-163"; tw_unlock'; deliver
wait_recv SU "PING-163" 10
B="$(last_batch SU)"
as Supervisor SU $MON stop; expect 0 "paused since" "stop SU (163)"
jq -s -e --argjson b "$B" 'map(select(.to == "Supervisor" and .batch == $b)) == []' \
  "$TWD/acks.jsonl" >/dev/null || fail "the pause acked or superseded #$B"
C2="$(cur Supervisor)"
run "$MAIN" env TEAM_WATCH_PICKUP_SECS=0 bash -c '. .claude/lib/team-watch-lib.sh \
  && tw_init "$PWD" && sleep 1 && tw_check_receivers'
# The Supervisor is its own alarm target: the episode fires as the terminal-rule log line.
has "alarm not sent: UNPICKED Supervisor #" "$WORK/out" || fail "the pause silenced UNPICKED"
! has '"UNPICKED Supervisor' "$TWD/events.jsonl" || fail "an alarm about the Supervisor was queued"
[ "$(cur Supervisor)" = "$C2" ] || fail "the pickup check moved the cursor"
lib 'tw_alarm - "MONITOR daemon dead (163)"'; wait_recv SU "MONITOR daemon dead (163)" 10
echo "team-smoke-18: (163) pause acks nothing OK"

# ---- (164) start replays and confirms, all, send.d -------------------------------------------------
run "$MAIN" $MON paused Supervisor; expect 0 "(Supervisor)" "paused before start"
as Advisor AD $MON ensure; expect 2 "Usage:" "ensure is retired"
as Advisor AD $MON armed Advisor; expect 2 "Usage:" "armed is retired"
as Supervisor SU $MON stop; expect 0 "already paused" "stop SU (164)"
fresh_beats
as Supervisor SU $MON start; expect 0 "Supervisor: running · readiness: running" "start SU"
has "team-watch: works" "$WORK/out" && fail "start restarted current loops"
run "$MAIN" $MON paused Supervisor; expect 1 "" "paused after start"
jq -e '.registrations.Supervisor == "replay"' "$TWD/open.json" >/dev/null || fail "no replay"
E0="$(wc -l < "$TWD/events.jsonl")"
fresh_beats
as Supervisor SU $MON start; expect 0 "readiness: running" "second start"
[ "$(wc -l < "$TWD/events.jsonl")" = "$E0" ] || fail "a second start changed the queue"
as Advisor AD $MON stop; expect 0 "Advisor: paused since" "stop AD"
as Advisor AD $MON stop all; expect 1 "refused: Advisor cannot pause or start other roles" "stop all as Advisor"
( cd "$MAIN" && bash -c '. .claude/lib/team-watch-lib.sh && tw_init "$PWD" \
  && tw_claim "$TW_DIR/send.d" 5 && sleep 2 && tw_release "$TW_DIR/send.d"' ) & HOLD=$!
sleep 0.5
run "$MAIN" env -u TEAM_SESSION_ROLE $MON stop all; expect 0 "" "stop all without a role"
wait "$HOLD" || true
[ "$(grep -c 'paused since' "$WORK/out")" = 2 ] || fail "stop all: not two paused lines"
has "Advisor: paused since" "$WORK/out" && has "already paused" "$WORK/out" || fail "stop all: the kept pause"
run "$MAIN" env -u TEAM_SESSION_ROLE $MON status all; expect 0 "Supervisor: paused (" "status all"
has "Advisor: paused (" "$WORK/out" && has "  passes: " "$WORK/out" || fail "status all: Advisor / passes"
! has "wake:" "$WORK/out" || fail "status still prints a wake line"
run "$MAIN" $W status; grep -q '^paused: .*Supervisor since .* (operator)' "$WORK/out" || fail "team-watch status"
run "$MAIN" env -u TEAM_SESSION_ROLE $MON start all; expect 0 "" "start all (164)"
run "$MAIN" env -u TEAM_SESSION_ROLE $MON status all
has "Advisor: missing (no tmux smk-advisor)" "$WORK/out" || fail "Advisor not missing"
echo '{"paused": ' > "$TWD/state.json"
run "$MAIN" $MON paused Advisor; expect 0 "unreadable" "unreadable flag counts as a pause"
as Advisor AD $MON stop; expect 1 "unreadable" "stop over an unreadable state.json"
echo '{}' > "$TWD/state.json"
echo "team-smoke-18: (164) start, all OK"

# ---- (168b) version guards; a collapse never drops an alarm -------------------------------------
echo "$(date -u +%s) 1 v$((TWV - 1))" > "$TWD/beat"; echo "$(date -u +%s) 1 v$((TWV - 1))" > "$TWD/dog.beat"
as Advisor AD $MON stop; expect 1 "refused: team-watch runs an older version" "stop over old loops"
as Supervisor SU env TEAM_WATCH_SECS=1 $MON start; expect 0 "team-watch: works" "start restarts old loops"
grep -q " v$TWV\$" "$TWD/beat" || fail "beat not v$TWV after start"
kill_loops
bulk Supervisor 101 routine
lib 'tw_lock && tw_append_to Supervisor "" "MONITOR dog dead #77"; tw_unlock'
deliver; deliver
wait_recv SU "MONITOR dog dead #77" 10
echo "team-smoke-18: (168b) version guards OK"
echo "team-smoke-18: OK"
