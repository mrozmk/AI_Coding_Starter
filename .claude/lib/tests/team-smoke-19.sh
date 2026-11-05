#!/usr/bin/env bash
# team-watch pause hardening: incident-channel errors pass a pause, a stop during the wake loop's
# slow read does not wake, an empty or unreadable state.json is a pause and never rewritten,
# rotation keeps a pause-delivered incident, version guard, idempotent stop (since/by kept), a
# broken pause flag refused. Cases (220), (222)-(224), (227)-(230).
# It runs a wake loop against a slow probe, so the runner keeps it out of a parallel batch.
# team-smoke: serial
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-watch-lib.sh"
smoke_init
smoke_team AB-1253 chore/AB-1253-x
watch_init
mkrole TM; mkrole SU
MON="bash .claude/lib/monitoring.sh"
jq '.roles.TeamLead.pause.pass = {}' "$MAIN/.claude/team/sessions/monitoring.json" > "$WORK/mon.json"
export TEAM_MONITORING_JSON="$WORK/mon.json"

cat > "$WORK/send" <<EOF
#!/usr/bin/env bash
in="\$(cat; echo x)"; in="\${in%x}"
echo sent >> "$WORK/send.log"
printf '%s' "\$in" | python3 -I "$SRC/.claude/lib/team-watch-send.py" "\$1"
EOF
chmod +x "$WORK/send"
export TEAM_WATCH_SENDER="$WORK/send"
: > "$WORK/send.log"; : > "$WORK/daemon.log"

sigupd() {  # sigupd <signals json> — tw_update, the producer of keyed events and open.json
  mkdir -p "$WORK/sigd"; echo "$1" > "$WORK/sigd/sig.json"
  lib 'tw_lock && tw_update "'"$WORK"'/sigd/sig.json"; tw_unlock'
  [ "$RC" = 0 ] || fail "tw_update"
}
sg() {  # sg <key> <to> <head> [kind]
  jq -cn --arg k "$1" --arg to "$2" --arg h "$3" --arg kind "${4:-error}" \
    '{key: $k, kind: $kind, team: null, role: null, head: $h, screen: [], to: $to}'
}
deliver() { lib 'tw_deliver'; }
cur() { cat "$TWD/cursor.$1" 2>/dev/null || echo 0; }
nmsg() { msgs "$1" | wc -l | tr -d ' '; }
nsent() { wc -l < "$WORK/send.log" | tr -d ' '; }
startall() { run "$MAIN" env -u TEAM_SESSION_ROLE $MON start all; expect 0 "" "start all"; }
same_state() {  # same_state <label> — state.json byte-equal to $WORK/st.before
  cmp -s "$TWD/state.json" "$WORK/st.before" || fail "$1 rewrote state.json"
}

run "$MAIN" $W routing split; expect 0 "" "routing split"
as TeamLead TM $W register; expect 0 "TeamLead registered" "register TM"
as Supervisor SU $W register; expect 0 "Supervisor registered" "register SU"

# ---- (220) incident-channel errors pass a pause with an incident pass -----------------------------
as Supervisor SU $MON stop; expect 0 "paused since" "stop SU (220)"
as TeamLead TM $MON stop; expect 0 "paused since" "stop TM (220)"
CS="$(cur Supervisor)"; CT="$(cur TeamLead)"
sigupd "[$(sg err:mail:Supervisor Supervisor "ERROR mail Supervisor: E220"),
  $(sg err:mail:TeamLead TeamLead "ERROR mail TeamLead: T220")]"
deliver; deliver
wait_recv SU "ERROR mail Supervisor: E220" 10
sleep 1
[ "$(nrecv TM "T220")" = 0 ] || fail "an err:mail event passed an empty pass {}"
[ "$(cur Supervisor)" = "$CS" ] && [ "$(cur TeamLead)" = "$CT" ] \
  || fail "an incident-channel delivery moved a cursor"
echo "team-smoke-19: (220) incident-channel errors pass a pause OK"

# ---- (222) a stop during the slow source read does not wake ----------------------------------------
startall
cat > "$WORK/slowmail" <<EOF
#!/usr/bin/env bash
[ -f "$WORK/mail.go" ] || exit 0
touch "$WORK/mail.reading"; sleep 3
echo "[agent-mail] m222 kind=turn thread=ops-222"
EOF
chmod +x "$WORK/slowmail"
mailcfg true "bash $WORK/slowmail"
jq '.remind_secs = 3600 | .roles.TeamLead.wake = {"mail": 0}' "$WORK/mon.json" > "$WORK/wake.json"
sleep 300 & FC=$!; PIDS="$PIDS $FC"
( cd "$MAIN" && exec env TEAM_SESSION_ROLE=TeamLead TEAM_WAKE_CLAUDE_PID="$FC" TEAM_WAKE_SECS=1 \
    TEAM_WAKE_SLOW_SECS=1 TEAM_MONITORING_JSON="$WORK/wake.json" \
    CLAUDE_CODE_MESSAGING_SOCKET="$TM_SOCK" CLAUDE_CODE_MESSAGING_TOKEN=tok \
    bash .claude/lib/session-wake.sh ) > "$WORK/wake.out" 2>&1 &
WPID=$!; PIDS="$PIDS $WPID"
for _ in $(seq 1 30); do [ -f "$TWD/wake/TeamLead.json" ] && break; sleep 0.2; done
[ -f "$TWD/wake/TeamLead.json" ] || fail "the wake loop did not arm"
sleep 3; kill -0 "$WPID" 2>/dev/null || { cp "$WORK/wake.out" "$WORK/out"; fail "baseline woke"; }
N0="$(nmsg TM)"
touch "$WORK/mail.go"
for _ in $(seq 1 50); do [ -f "$WORK/mail.reading" ] && break; sleep 0.2; done
[ -f "$WORK/mail.reading" ] || fail "the slow mail source was never read"
as TeamLead TM $MON stop; expect 0 "paused since" "stop during the read"
sleep 6
kill -0 "$WPID" 2>/dev/null || { cp "$WORK/wake.out" "$WORK/out"; fail "a stop during the read woke"; }
! has "WAKE TeamLead" "$WORK/wake.out" || { cp "$WORK/wake.out" "$WORK/out"; fail "WAKE text"; }
[ "$(nmsg TM)" = "$N0" ] || fail "a paused loop pushed into the session"
kill "$FC"
for _ in $(seq 1 20); do kill -0 "$WPID" 2>/dev/null || break; sleep 0.3; done
! kill -0 "$WPID" 2>/dev/null || fail "the loop outlived its claude"
rm -f "$WORK/mail.go" "$WORK/mail.reading"; mailcfg true
echo "team-smoke-19: (222) stop during the read does not wake OK"

# ---- (223) an empty or unreadable state.json is a pause, never overwritten -----------------------
startall
cp "$TWD/state.json" "$WORK/st.orig"
for bad in empty broken; do
  if [ "$bad" = empty ]; then : > "$TWD/state.json"; else printf '{"paused": ' > "$TWD/state.json"; fi
  cp "$TWD/state.json" "$WORK/st.before"
  run "$MAIN" $MON paused TeamLead; expect 0 "unreadable" "paused over $bad"
  as TeamLead TM $MON stop; expect 1 "unreadable" "stop over $bad"; same_state "stop ($bad)"
  run "$MAIN" $W mode tiers on; expect 1 "unreadable" "mode tiers over $bad"
  same_state "mode tiers ($bad)"
  run "$MAIN" $W mode class merge-line on; expect 1 "unreadable" "mode class over $bad"
  same_state "mode class ($bad)"
  run "$MAIN" $W status; has "paused: unreadable (state.json)" "$WORK/out" || fail "status over $bad"
done
cp "$WORK/st.orig" "$TWD/state.json"
run "$MAIN" $MON paused TeamLead; expect 1 "" "restored state.json is not a pause"
echo "team-smoke-19: (223) unreadable state.json OK"

# ---- (224) rotation keeps a pause-delivered incident's delivery line --------------------------------
as Supervisor SU $MON stop; expect 0 "paused since" "stop SU (224)"
lib 'tw_lock && tw_append_to Supervisor "" "UNPICKED TeamLead #224"; tw_unlock'
deliver; wait_recv SU "UNPICKED TeamLead #224" 10
B224="$(last_batch SU)"
as Supervisor SU $W ack "$B224"; expect 0 "" "ack #$B224"
as Supervisor SU $W done "$B224"; expect 0 "" "done #$B224"
deliver
S0="$(nsent)"
run "$MAIN" env TEAM_WATCH_ROTATE_BYTES=1 TEAM_WATCH_KEEP_SECS=0 bash -c \
  '. .claude/lib/team-watch-lib.sh && tw_init "$PWD" && tw_rotate'
expect 0 "" "tw_rotate"
jq -s -e --argjson b "$B224" 'any(.[]; .to == "Supervisor" and .batch == $b)' \
  "$TWD/deliveries.jsonl" >/dev/null || fail "rotation dropped the pause delivery #$B224"
deliver; deliver
[ "$(nsent)" = "$S0" ] || fail "the pause-delivered incident #$B224 was resent after rotation"
[ "$(nrecv SU "UNPICKED TeamLead #224")" = 1 ] || fail "#$B224 received twice"
echo "team-smoke-19: (224) rotation dedup OK"

# ---- (227) version: loops of another version make stop refuse -----------------------------------
echo "$(date -u +%s) 1 v$((TWV - 1))" > "$TWD/beat"; echo "$(date -u +%s) 1 v$((TWV - 1))" > "$TWD/dog.beat"
as TeamLead TM $MON stop; expect 1 "older version" "stop over old loops"
rm -f "$TWD/beat" "$TWD/dog.beat"
echo "team-smoke-19: (227) version guard OK"

# ---- (228) stop→incident→stop keeps since/by; the batch stays pending for the Stop hook ----------
startall
as Supervisor SU $MON stop; expect 0 "paused since" "stop SU (228)"
lib 'tw_lock && tw_append_to Supervisor "" "UNPICKED TeamLead #228"; tw_unlock'
deliver; wait_recv SU "UNPICKED TeamLead #228" 10
B228="$(last_batch SU)"
touch "$TWD/deliveries.jsonl" "$TWD/acks.jsonl"
P228="$(jq -c .paused.Supervisor "$TWD/state.json")"; C228="$(cur Supervisor)"
cp "$TWD/deliveries.jsonl" "$WORK/d228"; cp "$TWD/acks.jsonl" "$WORK/a228"
sleep 1
as Supervisor SU $MON stop; expect 0 "already paused" "second stop SU (228)"
[ "$(jq -c .paused.Supervisor "$TWD/state.json")" = "$P228" ] \
  || fail "a second stop re-dated the pause ($P228)"
[ "$(cur Supervisor)" = "$C228" ] || fail "a second stop moved the cursor"
cmp -s "$TWD/deliveries.jsonl" "$WORK/d228" && cmp -s "$TWD/acks.jsonl" "$WORK/a228" \
  || fail "a second stop changed deliveries or acks"
# The operator kit's Stop hook reads exactly these two answers (its own case is in part kit).
run "$MAIN" $MON paused Supervisor; expect 0 "" "paused Supervisor"
SINCE="$(cut -d' ' -f1 "$WORK/out")"
[[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] && has "(Supervisor)" "$WORK/out" \
  || fail "monitoring.sh paused is not '<since> (<by>)'"
run "$MAIN" $W pending Supervisor "$SINCE"; grep -qx "$B228" "$WORK/out" || fail "#$B228 not pending since the pause"
S228="$(nsent)"; deliver
[ "$(nsent)" = "$S228" ] || fail "#$B228 was resent after a second stop"
as Supervisor SU $W ack "$B228"; expect 0 "" "ack #$B228"
run "$MAIN" $W pending Supervisor "$SINCE"; ! grep -qx "$B228" "$WORK/out" || fail "#$B228 pending after ack"
startall
echo "team-smoke-19: (228) stop→incident→stop OK"

# ---- (229) stop of one role, then stop all over mixed states ----------------------------------
startall
as TeamLead TM $MON stop; expect 0 "paused since" "stop TM (229)"
S1="$(jq -r .paused.TeamLead.since "$TWD/state.json")"
lib 'echo "$TW_SESSION_ROLES"'; R229="$(cat "$WORK/out")"
[ "$R229" = "Supervisor TeamLead Advisor" ] || fail "TW_SESSION_ROLES: $R229"
sleep 1
run "$MAIN" env -u TEAM_SESSION_ROLE $MON stop all; expect 0 "" "stop all (229)"
jq -e --arg s "$S1" '.paused.TeamLead == {since: $s, by: "TeamLead"}' "$TWD/state.json" \
  >/dev/null || fail "stop all re-dated the TeamLead pause"
grep -F "TeamLead: paused since" "$WORK/out" | grep -qF "already paused" \
  || fail "stop all did not report the kept TeamLead pause"
for r in $R229; do
  [ "$r" = TeamLead ] && continue
  jq -e --arg r "$r" --arg s "$S1" '.paused[$r].since != $s and .paused[$r].by == "operator"' \
    "$TWD/state.json" >/dev/null || fail "stop all: $r not newly paused by operator"
done
startall
echo "team-smoke-19: (229) stop all over mixed states OK"

# ---- (230) a broken pause flag is refused, never re-dated -------------------------------------------
startall
for bad in '"x"' '{}' '{"since":"bogus"}' '{"since":"2026-11-04T99:99:99Z","by":"TeamLead"}'; do
  jq --argjson b "$bad" '.paused = ((.paused // {}) | .TeamLead = $b)' "$TWD/state.json" \
    > "$WORK/st.new"
  mv "$WORK/st.new" "$TWD/state.json"; cp "$TWD/state.json" "$WORK/st.before"
  as TeamLead TM $MON stop; expect 1 "pause flag unreadable" "stop over $bad"
  same_state "stop over $bad"
  run "$MAIN" env -u TEAM_SESSION_ROLE $MON stop all; expect 1 "pause flag unreadable" \
    "stop all over $bad"
  same_state "stop all over $bad"
done
jq 'del(.paused)' "$TWD/state.json" > "$WORK/st.new"; mv "$WORK/st.new" "$TWD/state.json"
startall
echo "team-smoke-19: (230) broken pause flag refused OK"
echo "team-smoke-19: OK"
