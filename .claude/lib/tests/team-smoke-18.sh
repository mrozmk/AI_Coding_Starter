#!/usr/bin/env bash
# team-watch delivery, pause and wake: bounded batches and backlog collapse; the per-role pause with
# its pass-through (no ack, no cursor move, dedup by the delivery ledger); replay at start; the wake
# loop (beat, socket push, pane-hash prompts); the re-arm Stop hook; version guards.
# Cases (160)-(166), (168b).
# It runs wake loops and waits on their grace windows, so the runner keeps it out of a parallel batch.
# team-smoke: serial
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-watch-lib.sh"
smoke_init
smoke_team AB-1245 chore/AB-1245-x
watch_init
mkrole TM; mkrole SU
MON="bash .claude/lib/monitoring.sh"
# Fixture policy: the TeamLead's pause passes incident- threads (the shipped example passes nothing).
jq '.roles.TeamLead.pause.pass = {mail_threads: ["incident-"]}' \
  "$MAIN/.claude/team/sessions/monitoring.json" > "$WORK/mon.json"
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
  jq -cn --arg k "$1" --arg to "$2" --arg h "$3" --arg kind "${4:-runner}" \
    '{key: $k, kind: $kind, team: null, role: null, head: $h, screen: [], to: $to}'
}
deliver() { lib 'tw_deliver'; }
cur() { cat "$TWD/cursor.$1" 2>/dev/null || echo 0; }
lastseq() { tail -n 1 "$TWD/events.jsonl" | jq .seq; }
nmsg() { msgs "$1" | wc -l | tr -d ' '; }
long() { printf "${2:-x}%.0s" $(seq 1 "$1"); }
fresh_beats() { echo "$(date -u +%s) 1 v$TWV" > "$TWD/beat"; echo "$(date -u +%s) 1 v$TWV" > "$TWD/dog.beat"; }

run "$MAIN" $W routing split; expect 0 "" "routing split"
as TeamLead TM $W register; expect 0 "TeamLead registered" "register TM"
as Supervisor SU $W register; expect 0 "Supervisor registered" "register SU"

# ---- (160) bounded batches ------------------------------------------------------------------------
X900="$(long 900)"
bulk TeamLead 30 "$X900"
deliver; deliver
[ "$(nmsg TM)" = 2 ] || fail "30 events: $(nmsg TM) messages, expected 2"
[ "$(cur TeamLead)" = "$(lastseq)" ] || fail "cursor $(cur TeamLead) != last $(lastseq)"
jq -s -e 'map(select(.to == "TeamLead") | .seqs | length) == [25, 5]' "$TWD/deliveries.jsonl" \
  >/dev/null || fail "batch lengths: $(jq -sc 'map(.seqs | length)' "$TWD/deliveries.jsonl")"
while read -r n; do [ "$n" -le 60000 ] || fail "a message of $n bytes"; done < "$WORK/send.log"
bulk TeamLead 1 "$(long 70001)"; bulk TeamLead 1 small
export SEND_LIMIT=200000; deliver; unset SEND_LIMIT
[ "$(jq -s 'map(select(.to == "TeamLead")) | last | .seqs | length' "$TWD/deliveries.jsonl")" = 1 ] \
  || fail "an oversize event did not go alone"
deliver; [ "$(cur TeamLead)" = "$(lastseq)" ] || fail "the small event after the oversize one"
echo "team-smoke-18: (160) bounded batches OK"

# ---- (161) collapse -------------------------------------------------------------------------------
N0="$(nmsg TM)"
bulk TeamLead 1465 "$X900"
deliver
[ "$(nmsg TM)" = "$N0" ] || fail "the collapse sent a message"
[ "$(cur TeamLead)" = "$(lastseq)" ] || fail "collapse cursor"
[ -f "$TWD/collapsed.TeamLead" ] || fail "no collapsed.TeamLead"
jq -e '.registrations.TeamLead == "collapsed"' "$TWD/open.json" >/dev/null || fail "no replay mark"
bulk TeamLead 1 after; deliver
msgs TM | tail -n 1 | jq -e 'split("\n")[1] | startswith("(skipped 1465 backlog events from ")
  and endswith(" — current state below)")' \
  >/dev/null || { msgs TM | tail -n 1 > "$WORK/out"; fail "no skipped line"; }
[ ! -f "$TWD/collapsed.TeamLead" ] || fail "collapsed.TeamLead kept after the send"
echo "team-smoke-18: (161) collapse OK"

# ---- (162) pause pass-through; no cursor move; dedup -------------------------------------------
as TeamLead TM $MON stop; expect 0 "TeamLead: paused since" "stop TM"
has "(TeamLead) (passes: {\"mail_threads\":[\"incident-\"]})" "$WORK/out" || fail "pause without its author or pass"
C0="$(cur TeamLead)"; N0="$(nmsg TM)"
sigupd "[$(sg mail:TeamLead:i TeamLead "MAIL TeamLead [agent-mail] i kind=turn thread=incident-1" mail),
  $(sg mail:TeamLead:o TeamLead "MAIL TeamLead [agent-mail] o kind=turn thread=ops-1" mail),
  $(sg run:alfa:y TeamLead "RUNNER alfa stopped (run y)")]"
deliver; deliver
[ "$(nmsg TM)" = $((N0 + 1)) ] && [ "$(nrecv TM "thread=incident-1")" = 1 ] || fail "TM did not get exactly the incident"
[ "$(nrecv TM "thread=ops-1")" = 0 ] && [ "$(nrecv TM "RUNNER alfa stopped (run y)")" = 0 ] \
  || fail "routine passed the pause"
[ "$(cur TeamLead)" = "$C0" ] || fail "the pause moved the cursor"
as Supervisor SU $MON stop; expect 0 "Supervisor: paused since" "stop SU"
lib 'tw_alarm TeamLead "UNPICKED TeamLead #1"'; wait_recv SU "UNPICKED TeamLead #1" 10
jq '.roles.Supervisor.pause.pass = {}' "$WORK/mon.json" > "$WORK/nopass.json"
TEAM_MONITORING_JSON="$WORK/nopass.json" lib 'tw_alarm TeamLead "UNPICKED TeamLead #2"'
TEAM_MONITORING_JSON="$WORK/nopass.json" deliver
[ "$(nrecv SU "UNPICKED TeamLead #2")" = 0 ] || fail "an alarm passed an empty pass"
TEAM_MONITORING_JSON="$WORK/missing.json" lib 'tw_alarm TeamLead "UNPICKED TeamLead #3"'
wait_recv SU "UNPICKED TeamLead #3" 10
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
run "$MAIN" env TEAM_WATCH_UNDELIVERED_SECS=0 bash -c '. .claude/lib/team-watch-lib.sh \
  && tw_init "$PWD" && tw_undelivered TeamLead && tw_deliver'
wait_recv SU "UNDELIVERED TeamLead" 10
lib 'tw_delivered TeamLead'
echo "team-smoke-18: (162b) collapse keeps alarms, UNDELIVERED OK"

# ---- (162c) idle cursor, replay after start, classless alarms, bytes, incident mail --------------
C1="$(cur TeamLead)"; deliver; deliver; deliver
[ "$(cur TeamLead)" = "$C1" ] || fail "idle passes moved the cursor"
sigupd "[$(sg run:alfa:x TeamLead "RUNNER alfa stopped (run x)")]"
deliver
as TeamLead TM $MON stop; expect 0 "paused since" "stop TM"
bulk TeamLead 10 ROUTINE-
run "$MAIN" env -u TEAM_SESSION_ROLE $MON start all; expect 0 "TeamLead: running · readiness:" "start all (TM)"
N1="$(nmsg TM)"
sigupd "[$(sg run:alfa:x TeamLead "RUNNER alfa stopped (run x)")]"
deliver
[ "$(nmsg TM)" -gt "$N1" ] || fail "no replay after start"
msgs TM | tail -n 1 | jq -e 'contains("(current state)") and (contains("ROUTINE-") | not)' \
  >/dev/null || { msgs TM | tail -n 1 > "$WORK/out"; fail "start delivered the pre-start backlog"; }
as Supervisor SU $MON stop; expect 0 "paused since" "stop SU (162c)"
lib 'tw_lock && tw_append_to Supervisor "" "UNPICKED TeamLead #9"; tw_unlock'
deliver; wait_recv SU "UNPICKED TeamLead #9" 10
: > "$WORK/send.log"
bulk TeamLead 25 "$(long 2400 ż)"
for _ in 1 2 3 4 5 6 7 8 9 10; do deliver; done
[ "$(cur TeamLead)" = "$(jq -s 'map(select(.to == "TeamLead")) | last | .seq' "$TWD/events.jsonl")" ] \
  || fail "non-ASCII backlog not drained"
while read -r n; do [ "$n" -le 60000 ] || fail "a non-ASCII message of $n bytes"; done < "$WORK/send.log"
sigupd "[$(sg "mail:Supervisor:i" Supervisor "MAIL Supervisor [agent-mail] a kind=turn thread=incident-7 x" mail),
  $(sg "mail:Supervisor:o" Supervisor "MAIL Supervisor [agent-mail] b kind=turn thread=ops-1 y" mail)]"
deliver
wait_recv SU "thread=incident-7" 10
[ "$(nrecv SU "thread=ops-1")" = 0 ] || fail "routine mail passed a paused Supervisor"
echo "team-smoke-18: (162c) replay, classless alarms, bytes, incident mail OK"

# ---- (163) a pause acks nothing: UNPICKED still fires ------------------------------------------
run "$MAIN" env -u TEAM_SESSION_ROLE $MON start all; expect 0 "" "start all (163)"
lib 'tw_lock && tw_append_to TeamLead "" "PING-163"; tw_unlock'; deliver
wait_recv TM "PING-163" 10
B="$(last_batch TM)"
as TeamLead TM $MON stop; expect 0 "paused since" "stop TM (163)"
jq -s -e --argjson b "$B" 'map(select(.to == "TeamLead" and .batch == $b)) == []' \
  "$TWD/acks.jsonl" >/dev/null || fail "the pause acked or superseded #$B"
run "$MAIN" env TEAM_WATCH_PICKUP_SECS=0 bash -c '. .claude/lib/team-watch-lib.sh \
  && tw_init "$PWD" && sleep 1 && tw_check_receivers'
has "UNPICKED TeamLead #" "$TWD/events.jsonl" || fail "the pause silenced UNPICKED"
echo "team-smoke-18: (163) pause acks nothing OK"

# ---- (164) start replays and confirms, ensure keeps the pause, all, send.d -------------------------
as TeamLead TM $MON ensure
expect 0 "wake: not armed — start in the background (Bash, run_in_background: true): bash .claude/lib/session-wake.sh" "ensure TM"
run "$MAIN" $MON paused TeamLead; expect 0 "(TeamLead)" "ensure kept the pause"
as Supervisor SU $MON ensure; expect 0 "wake: none declared" "ensure SU"
as Supervisor SU $MON stop; expect 0 "paused since" "stop SU (164)"
fresh_beats
as Supervisor SU $MON start; expect 0 "Supervisor: running · readiness: running" "start SU"
has "team-watch: works" "$WORK/out" && fail "start restarted current loops"
run "$MAIN" $MON paused Supervisor; expect 1 "" "paused after start"
jq -e '.registrations.Supervisor == "replay"' "$TWD/open.json" >/dev/null || fail "no replay"
E0="$(wc -l < "$TWD/events.jsonl")"
fresh_beats
as Supervisor SU $MON start; expect 0 "readiness: running" "second start"
[ "$(wc -l < "$TWD/events.jsonl")" = "$E0" ] || fail "a second start changed the queue"
as TeamLead TM $MON stop all; expect 1 "refused: TeamLead cannot pause or start other roles" "stop all as TeamLead"
( cd "$MAIN" && bash -c '. .claude/lib/team-watch-lib.sh && tw_init "$PWD" \
  && tw_claim "$TW_DIR/send.d" 5 && sleep 2 && tw_release "$TW_DIR/send.d"' ) & HOLD=$!
sleep 0.5
run "$MAIN" env -u TEAM_SESSION_ROLE $MON stop all; expect 0 "" "stop all without a role"
wait "$HOLD" || true
[ "$(grep -c 'paused since' "$WORK/out")" = 3 ] || fail "stop all: not three paused lines"
has "TeamLead: paused since" "$WORK/out" && has "already paused" "$WORK/out" || fail "stop all: the kept pause"
run "$MAIN" env -u TEAM_SESSION_ROLE $MON status all; expect 0 "TeamLead: paused (" "status all"
has "Advisor: paused (" "$WORK/out" && has "  passes: " "$WORK/out" || fail "status all: Advisor / passes"
run "$MAIN" $W status; grep -q '^paused: .*Supervisor since .* (operator)' "$WORK/out" || fail "team-watch status"
run "$MAIN" env -u TEAM_SESSION_ROLE $MON start all; expect 0 "" "start all (164)"
run "$MAIN" env -u TEAM_SESSION_ROLE $MON status all
has "Advisor: missing (no tmux smk-advisor, no wake loop)" "$WORK/out" || fail "Advisor not missing"
echo '{"paused": ' > "$TWD/state.json"
run "$MAIN" $MON paused TeamLead; expect 0 "unreadable" "unreadable flag counts as a pause"
as TeamLead TM $MON stop; expect 1 "unreadable" "stop over an unreadable state.json"
echo '{}' > "$TWD/state.json"
echo "team-smoke-18: (164) start, ensure, all OK"

# ---- (165) wake loop ------------------------------------------------------------------------------
jq '.remind_secs = 3600 | .roles.TeamLead.wake = {"team-prompts": 2}' "$WORK/mon.json" > "$WORK/wake.json"
sleep 300 & FC=$!; PIDS="$PIDS $FC"
ATT1="$(sg att:alfa:r:coder:1:1:a TeamLead "ATTENTION alfa coder (permission): a" attention)"
sigupd "[$ATT1]"
wake() {  # wake [extra env…] — the loop in the background as TeamLead; WPID, $WORK/wake.out
  ( cd "$MAIN" && exec env TEAM_SESSION_ROLE=TeamLead TEAM_WAKE_CLAUDE_PID="$FC" TEAM_WAKE_SECS=1 \
      TEAM_WAKE_SLOW_SECS=1 TEAM_MONITORING_JSON="$WORK/wake.json" \
      CLAUDE_CODE_MESSAGING_SOCKET="$TM_SOCK" CLAUDE_CODE_MESSAGING_TOKEN=tok "$@" \
      bash .claude/lib/session-wake.sh ) > "$WORK/wake.out" 2>&1 &
  WPID=$!; PIDS="$PIDS $WPID"
  for _ in $(seq 1 30); do [ -f "$TWD/wake/TeamLead.json" ] && return 0; sleep 0.2; done
  fail "the wake loop did not arm"
}
gone() {  # gone <pid> <secs>
  local end=$((SECONDS + $2))
  while kill -0 "$1" 2>/dev/null; do [ "$SECONDS" -lt "$end" ] || return 1; sleep 0.3; done
}
wake
sleep 5; kill -0 "$WPID" 2>/dev/null || { cp "$WORK/wake.out" "$WORK/out"; fail "baseline woke"; }
run "$MAIN" env TEAM_SESSION_ROLE=TeamLead TEAM_WAKE_CLAUDE_PID="$FC" TEAM_MONITORING_JSON="$WORK/wake.json" \
  bash .claude/lib/session-wake.sh; expect 0 "ALREADY-ARMED" "second arm"
TEAM_MONITORING_JSON="$WORK/wake.json" run "$MAIN" $MON armed TeamLead; expect 0 "pid $WPID" "armed with a beat"
N2="$(nmsg TM)"
sigupd "[$ATT1, $(sg att:alfa:r:coder:1:2:b TeamLead "ATTENTION alfa coder (permission): b" attention)]"
gone "$WPID" 8 || fail "a new prompt did not wake within 8s"
has "WAKE TeamLead team-prompts:" "$WORK/wake.out" || { cp "$WORK/wake.out" "$WORK/out"; fail "wake text"; }
has "Handle it, then re-arm in the background: bash .claude/lib/session-wake.sh (the Stop hook enforces it)" \
  "$WORK/wake.out" || { cp "$WORK/wake.out" "$WORK/out"; fail "wake tail"; }
wait_recv TM "WAKE TeamLead team-prompts:" 5
[ "$(nmsg TM)" -gt "$N2" ] || fail "the wake was not pushed into the session"
[ ! -f "$TWD/wake/TeamLead.json" ] || fail "pidfile kept after the wake"
# A second question of the same role is a new screen: the pane hash wakes.
mkdir -p "$WORK/panes"; export STUB_PANE_DIR="$WORK/panes"
printf 'First question?\n❯ 1. Yes\nEnter to select\n' > "$WORK/panes/alfa-coder"
wake
sleep 4; kill -0 "$WPID" 2>/dev/null || { cp "$WORK/wake.out" "$WORK/out"; fail "pane baseline woke"; }
printf 'Second question?\n❯ 1. Yes\nEnter to select\n' > "$WORK/panes/alfa-coder"
gone "$WPID" 8 || fail "a second question of the same role did not wake"
has "alfa-coder" "$WORK/wake.out" || { cp "$WORK/wake.out" "$WORK/out"; fail "pane wake text"; }
wake
as TeamLead TM $MON stop; expect 0 "paused since" "pause the woken role"
printf 'Third question?\n❯ 1. Yes\nEnter to select\n' > "$WORK/panes/alfa-coder"
sleep 5; kill -0 "$WPID" 2>/dev/null || { cp "$WORK/wake.out" "$WORK/out"; fail "a paused loop woke"; }
as TeamLead TM env TEAM_MONITORING_JSON="$WORK/wake.json" $MON status; expect 0 "dormant (paused)" "dormant"
kill "$FC"; gone "$WPID" 6 || fail "the loop outlived its claude"
[ ! -f "$TWD/wake/TeamLead.json" ] || fail "pidfile kept after claude died"
unset STUB_PANE_DIR
run "$MAIN" env -u TEAM_SESSION_ROLE $MON start all; expect 0 "" "start all (165)"
# Teams come from clones with team.json (epsilon); a team session without one (zeta) is never scanned.
sleep 300 & FC=$!; PIDS="$PIDS $FC"
export STUB_PANE_DIR="$WORK/panes"
mkdir -p "$WORK/main-epsilon/.agents/team"
echo '{"team":"epsilon"}' > "$WORK/main-epsilon/.agents/team/team.json"
mkdir -p "$WORK/main-zeta/.agents/team"
wake
sleep 4; kill -0 "$WPID" 2>/dev/null || { cp "$WORK/wake.out" "$WORK/out"; fail "epsilon baseline woke"; }
N3="$(nmsg TM)"; L3="$(wc -l < "$STUB_LOG")"
printf 'Question zeta?\n❯ 1. Yes\nEnter to select\n' > "$WORK/panes/zeta-coder"
sleep 5
kill -0 "$WPID" 2>/dev/null || { cp "$WORK/wake.out" "$WORK/out"; fail "a zeta prompt woke the loop"; }
[ "$(nmsg TM)" = "$N3" ] || fail "a zeta prompt pushed into the session"
tail -n +"$((L3 + 1))" "$STUB_LOG" > "$WORK/slice3"
! grep -q 'capture-pane.*=zeta-' "$WORK/slice3" || fail "zeta was scanned"
grep -q 'capture-pane.*=epsilon-coder:' "$WORK/slice3" || fail "the loop did not scan epsilon"
printf 'Question epsilon?\n❯ 1. Yes\nEnter to select\n' > "$WORK/panes/epsilon-coder"
gone "$WPID" 8 || fail "an epsilon prompt did not wake within 8s"
has "epsilon-coder" "$WORK/wake.out" || { cp "$WORK/wake.out" "$WORK/out"; fail "epsilon wake text"; }
kill "$FC"
rm -rf "$WORK/main-epsilon" "$WORK/main-zeta" "$WORK/slice3"
rm -f "$WORK/panes/zeta-coder" "$WORK/panes/epsilon-coder"
unset STUB_PANE_DIR
echo "team-smoke-18: (165) wake loop OK"

# ---- (166) Stop hook ------------------------------------------------------------------------------
HOOK="$SRC/.claude/hooks/monitoring-rearm.sh"
export TEAM_SESSION_ROLE=TeamLead
hook "$MAIN" '{}'; [ "$RC" = 0 ] && jq -e '.decision == "block" and (.reason
  | startswith("Wake loop of role TeamLead is not armed. Start it in the background"))' "$WORK/out" >/dev/null \
  || fail "no block without a loop"
hook "$MAIN" '{"stop_hook_active": true}'; [ "$RC" = 0 ] && [ ! -s "$WORK/out" ] || fail "blocked twice"
sleep 300 & FC=$!; PIDS="$PIDS $FC"
TEAM_MONITORING_JSON="$MAIN/.claude/team/sessions/monitoring.json"
( cd "$MAIN" && exec env TEAM_WAKE_CLAUDE_PID="$FC" TEAM_WAKE_SECS=1 \
    CLAUDE_CODE_MESSAGING_SOCKET="$TM_SOCK" CLAUDE_CODE_MESSAGING_TOKEN=tok \
    bash .claude/lib/session-wake.sh ) > "$WORK/wake.out" 2>&1 & WPID=$!; PIDS="$PIDS $WPID"
for _ in $(seq 1 30); do [ -f "$TWD/wake/TeamLead.json" ] && break; sleep 0.2; done
hook "$MAIN" '{}'; [ "$RC" = 0 ] && [ ! -s "$WORK/out" ] || fail "blocked with a live loop"
kill "$WPID" "$FC" 2>/dev/null || true
export TEAM_SESSION_ROLE=Supervisor
hook "$MAIN" '{}'; [ "$RC" = 0 ] && [ ! -s "$WORK/out" ] || fail "Supervisor (no wake declared) blocked"
export TEAM_SESSION_ROLE=TeamLead
hook "$CLONE" '{}'; [ "$RC" = 0 ] && [ ! -s "$WORK/out" ] || fail "blocked in a team clone"
unset TEAM_SESSION_ROLE
T0=$SECONDS; hook "$MAIN" '{}'; [ "$RC" = 0 ] && [ ! -s "$WORK/out" ] && [ $((SECONDS - T0)) -lt 2 ] \
  || fail "a role-less session was held or slowed"
export TEAM_MONITORING_JSON="$WORK/mon.json"
echo "team-smoke-18: (166) Stop hook OK"

# ---- (168b) version guards; a collapse never drops an alarm -------------------------------------
echo "$(date -u +%s) 1 v$((TWV - 1))" > "$TWD/beat"; echo "$(date -u +%s) 1 v$((TWV - 1))" > "$TWD/dog.beat"
as TeamLead TM $MON stop; expect 1 "refused: team-watch runs an older version" "stop over old loops"
as Supervisor SU env TEAM_WATCH_SECS=1 $MON start; expect 0 "team-watch: works" "start restarts old loops"
grep -q " v$TWV\$" "$TWD/beat" || fail "beat not v$TWV after start"
kill_loops
bulk Supervisor 101 routine
lib 'tw_lock && tw_append_to Supervisor "" "UNPICKED TeamLead #77"; tw_unlock'
deliver; deliver
wait_recv SU "UNPICKED TeamLead #77" 10
echo "team-smoke-18: (168b) version guards OK"
echo "team-smoke-18: OK"
