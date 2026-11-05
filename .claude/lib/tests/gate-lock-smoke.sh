#!/usr/bin/env bash
# Smoke for the machine gate lock: queue, FIFO, timeout, reclaim, races, signals.
# Runs inside every gate (costs/tests/test_gate_lock.py), so order is driven by handshake files
# and no assertion bounds a duration — the load that caused the lock must not make it flaky.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../gate-lock.sh"
PY="$HERE/../gate_lock.py"
WORK="$(mktemp -d)"
export LIB WORK
export TEAM_GATE_LOCK_DIR="$WORK/root" TEAM_GATE_LOCK_LOG="$WORK/lock.log" TEAM_GATE_LOCK_POLL=0.1
export TEAM_GATE_LOCK_NOTICE=1
# The project knob for its own build tools; the reclaim case below runs a renamed `dotnet test`.
export TEAM_GATE_LOCK_WORKLOAD='dotnet (build|test)'
unset TEAM_GATE_LOCK_TOKEN TEAM_GATE_LOCK_WAIT TEAM_GATE_LOCK_TEST_PAUSE
ROOT="$TEAM_GATE_LOCK_DIR"
PIDS=()
CHECKS=0

( exec </dev/null >/dev/null 2>&1; sleep 180; touch "$WORK/watchdog"; kill -TERM $$ ) &
WD=$!

cleanup() {
  local p
  pkill -P "$WD" 2>/dev/null; kill "$WD" 2>/dev/null
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -9 -- "-$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap '[ ! -f "$WORK/watchdog" ] || echo "gate-lock-smoke: FAIL — watchdog (180s)" >&2; exit 1' TERM

fail() {
  local f
  echo "gate-lock-smoke: FAIL — $1" >&2
  for f in "$WORK"/*.err; do [ ! -s "$f" ] || { echo "--- $f"; cat "$f"; } >&2; done
  exit 1
}
check() { local label="$1"; shift; "$@" || fail "$label"; CHECKS=$((CHECKS + 1)); }
has() { grep -qF -- "$1" "$2" 2>/dev/null; }
wait_for() {  # wait_for <label> <cmd…> — poll every 0.1 s, give up after 300 polls (~30 s)
  local label="$1" i=0; shift
  until "$@"; do
    i=$((i + 1)); [ "$i" -lt 300 ] || fail "$label: not reached in 30s"
    sleep 0.1
  done
}
own_group() { [ "$(ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ')" = "$1" ]; }
cmd_is() { ps -o command= -p "$1" 2>/dev/null | grep -qF -- "$2"; }
ticket_of() { ls "$ROOT/queue" 2>/dev/null | grep -q -- "-$1\$"; }
queue_empty() { [ -z "$(ls "$ROOT/queue" 2>/dev/null)" ]; }
token() { sed -n 's/^token=//p' "$ROOT/lock/holder" 2>/dev/null; }
reclaims() { grep -c "reclaimed .*pid $1 " "$TEAM_GATE_LOCK_LOG" 2>/dev/null || true; }
mark() { sed -n "s/^$2 //p" "$WORK/$1"; }
no_overlap() { [ "$(mark "$2" start)" -ge "$(mark "$1" end)" ]; }

spawn() {  # spawn <name> <cmd…> → SPAWNED: own process group, no inherited stdio
  local name="$1"; shift
  python3 -I -c 'import os,sys; os.setpgid(0,0); os.execvp(sys.argv[1], sys.argv[1:])' "$@" \
    </dev/null >"$WORK/$name.out" 2>"$WORK/$name.err" &
  SPAWNED=$!
  PIDS+=("$SPAWNED")
  wait_for "spawn $name" own_group "$SPAWNED"
}
live() { spawn "$1" bash -c 'until [ -f "$0" ]; do sleep 0.1; done' "$WORK/$1.stop"; }
dead_pid() { sleep 0 & DEAD=$!; wait "$DEAD"; }
caller() { spawn "$1" env "${@:2}" bash "$WORK/caller.sh" "$1"; }  # caller <name> [env…]
holder() { caller "$1" HOLD=1 "${@:2}"; }
fg_caller() {  # fg_caller <name> [env…] → RC; a caller.sh run in the foreground
  local name="$1"; shift
  env "$@" bash "$WORK/caller.sh" "$name" </dev/null >"$WORK/$name.out" 2>"$WORK/$name.err"
  RC=$?
}
fake_holder() {  # fake_holder <pid> <token> [pgid] [pid_start] — written while lock/ is absent
  local start pgid
  start="$(ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//')"
  pgid="$(ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ')"
  start="${4:-${start:-Thu Jan  1 00:00:00 1970}}"; pgid="${3:-${pgid:-0}}"
  mkdir -p "$ROOT/tmp-x"
  printf 'pid=%s\npid_start=%s\npgid=%s\nclone=fake\nwhat=fake\nsince=2026-10-20T00:00:00Z\n' \
    "$1" "$start" "$pgid" > "$ROOT/tmp-x/holder"
  printf 'token=%s\n' "$2" >> "$ROOT/tmp-x/holder"
  mv "$ROOT/tmp-x" "$ROOT/lock"
}
reset() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -9 -- "-$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done
  for p in ${PIDS[@]+"${PIDS[@]}"}; do wait "$p" 2>/dev/null; done
  PIDS=()
  rm -rf "$ROOT" "$TEAM_GATE_LOCK_LOG" "$WORK/order"
}

cat > "$WORK/caller.sh" <<'EOF'
# caller.sh <name>: the gate's lock calls with its traps; HOLD=1 holds until <name>.go.
ns() { python3 -I -c 'import time; print(time.time_ns())'; }
name="$1"
[ -z "${WAIT_START:-}" ] || until [ -f "$WAIT_START" ]; do sleep 0.1; done
. "$LIB"
trap 'gate_lock_cancel; exit 130' TERM
trap gate_lock_release EXIT
gate_lock_acquire "smoke-$name" || exit $?
echo "start $(ns)" >> "$WORK/$name"
echo "$GATE_LOCK_WAITED" > "$WORK/$name.waited"
echo "$name" >> "$WORK/order"
touch "$WORK/$name.acquired"
[ -z "${HOLD:-}" ] || until [ -f "$WORK/$name.go" ]; do sleep 0.1; done
echo "end $(ns)" >> "$WORK/$name"
gate_lock_release
touch "$WORK/$name.released"
EOF

# ---- (1) acquire / release / ownership ----
holder h1
P=$SPAWNED
wait_for "h1 acquired" test -f "$WORK/h1.acquired"
for k in pid pid_start pgid clone what since token; do
  grep -q "^$k=." "$ROOT/lock/holder" || fail "holder lacks $k"
done
check "holder pid is the caller" grep -qx "pid=$P" "$ROOT/lock/holder"
python3 -I "$PY" release 1 "$(token)"
check "a foreign release keeps the lock" test -f "$ROOT/lock/holder"
touch "$WORK/h1.go"
wait_for "h1 released" test -f "$WORK/h1.released"
check "the owner's release removes the lock" test ! -e "$ROOT/lock"

# ---- (2) two parallel callers ----
reset
holder a2; P1=$SPAWNED
wait_for "a2 acquired" test -f "$WORK/a2.acquired"
holder b2; P2=$SPAWNED
wait_for "b2 ticket" ticket_of "$P2"
wait_for "b2 notice" has "waiting for the machine gate lock held by" "$WORK/b2.err"
check "the notice names the holder" has "pid $P1 (smoke-a2)" "$WORK/b2.err"
check "b2 waits" test ! -f "$WORK/b2.acquired"
touch "$WORK/a2.go"
wait_for "b2 acquired" test -f "$WORK/b2.acquired"
check "no overlap" no_overlap a2 b2
touch "$WORK/b2.go"
wait_for "b2 released" test -f "$WORK/b2.released"

# ---- (3) FIFO ----
reset
holder h3
wait_for "h3 acquired" test -f "$WORK/h3.acquired"
for w in w31 w32 w33; do caller "$w"; wait_for "$w ticket" ticket_of "$SPAWNED"; done
touch "$WORK/h3.go"
all_in() { [ "$(wc -l < "$WORK/order" 2>/dev/null || echo 0)" -ge 4 ]; }
wait_for "three waiters" all_in
check "FIFO order" test "$(tr '\n' ' ' < "$WORK/order")" = "h3 w31 w32 w33 "

# ---- (4) timeout ----
reset
live l4; L=$SPAWNED
fake_holder "$L" t4
fg_caller w4 TEAM_GATE_LOCK_WAIT=1
check "timeout exits 4" test "$RC" = 4
check "timeout message" has "timeout after" "$WORK/w4.err"
check "timeout names the holder" has "held by fake pid $L" "$WORK/w4.err"
check "nothing started" has "nothing started" "$WORK/w4.err"
check "timeout leaves no ticket" queue_empty
check "timeout keeps the holder" test "$(token)" = t4

# ---- (5) dead holder ----
reset
dead_pid; D=$DEAD
fake_holder "$D" t5
fg_caller w5
check "dead holder reclaimed" test "$RC" = 0
check "reclaim is reported" has "reclaimed from dead fake" "$WORK/w5.err"
check "reclaim is logged once" test "$(reclaims "$D")" = 1

# ---- (6) PID reuse ----
reset
live l6; L=$SPAWNED
fake_holder "$L" t6 "" "Thu Jan  1 00:00:00 1970"
fg_caller w6
check "reused pid reclaimed" test "$RC" = 0
check "reused pid reported" has "reclaimed from dead fake pid $L" "$WORK/w6.err"

# ---- (7) orphan workload ----
reset
LOOP='until [ -f "$0" ]; do sleep 0.1; done'
spawn wl bash -c 'exec -a "dotnet test smoke" bash -c "$0" "$1"' "$LOOP" "$WORK/wl.stop"
G=$SPAWNED
wait_for "workload renamed" cmd_is "$G" "dotnet test smoke"
dead_pid; fake_holder "$DEAD" t7 "$G"
fg_caller w7 TEAM_GATE_LOCK_WAIT=1
check "a live workload blocks the reclaim" test "$RC" = 4
check "the workload is named" has "its workload pid $G" "$WORK/w7.err"
touch "$WORK/wl.stop"; wait "$G" 2>/dev/null
fg_caller w7b
check "reclaim after the workload ended" test "$RC" = 0

# ---- (8) crash during acquisition ----
reset
dead_pid; mkdir -p "$ROOT/tmp-$DEAD-x"; echo "pid=$DEAD" > "$ROOT/tmp-$DEAD-x/holder"
fg_caller w8
check "acquired past a crashed publish" test "$RC" = 0
check "the crashed tmp dir is swept" test ! -e "$ROOT/tmp-$DEAD-x"

# ---- (9) dead waiter ticket ----
reset
dead_pid; mkdir -p "$ROOT/queue"
printf 'pid_start=Thu Jan  1 00:00:00 1970\n' > "$ROOT/queue/00000000000000000001-$DEAD"
fg_caller w9
check "acquired past a dead ticket" test "$RC" = 0
check "no wait behind a dead ticket" test "$(cat "$WORK/w9.waited")" = 0
check "the dead ticket is pruned" test ! -e "$ROOT/queue/00000000000000000001-$DEAD"

# ---- (10) reclaim race ----
reset
dead_pid; fake_holder "$DEAD" aaaa
touch "$WORK/pause"
caller w10 TEAM_GATE_LOCK_TEST_PAUSE="$WORK/pause"
wait_for "w10 paused" test -f "$WORK/pause.reached"
check "w10 is the paused head" test -f "$WORK/pause"
mv "$ROOT/lock" "$ROOT/gone"
live l10; fake_holder "$SPAWNED" bbbb
rm -f "$WORK/pause"
wait_for "reclaim aborted" has "reclaim aborted" "$WORK/w10.err"
check "the new holder survives" test "$(token)" = bbbb

# ---- (11) re-entrancy ----
reset
live l11; L=$SPAWNED
fake_holder "$L" t11
check "held: own token" bash -c '. "$LIB"; gate_lock_held t11'
check "held: wrong token" bash -c '. "$LIB"; ! gate_lock_held zz'
check "held: empty token" bash -c '. "$LIB"; ! gate_lock_held ""'
kill -9 -- "-$L"; wait "$L" 2>/dev/null
check "held: dead holder" bash -c '. "$LIB"; ! gate_lock_held t11'

# ---- (12) caller TERM while queued ----
reset
live l12; fake_holder "$SPAWNED" t12
caller w12; W=$SPAWNED
wait_for "w12 ticket" ticket_of "$W"
kill -TERM "$W"; wait "$W"; RC=$?
check "a queued caller exits 130" test "$RC" = 130
check "its ticket is gone" queue_empty
check "it never acquired" test ! -f "$WORK/w12.acquired"
check "the holder is untouched" test "$(token)" = t12

# ---- (13) concurrent reclaim ----
reset
dead_pid; D=$DEAD; fake_holder "$D" dddd
holder a13; holder b13
first_of() { [ -f "$WORK/a13.acquired" ] || [ -f "$WORK/b13.acquired" ]; }
wait_for "one of a13/b13 acquired" first_of
if [ -f "$WORK/a13.acquired" ]; then F=a13; S=b13; else F=b13; S=a13; fi
touch "$WORK/$F.go"
wait_for "$S acquired" test -f "$WORK/$S.acquired"
check "exactly one reclaim" test "$(reclaims "$D")" = 1
check "no overlap after a reclaim" no_overlap "$F" "$S"
touch "$WORK/$S.go"

# ---- (14) TERM inside a critical section ----
reset
dead_pid; fake_holder "$DEAD" t14
touch "$WORK/pause"
caller w14 TEAM_GATE_LOCK_TEST_PAUSE="$WORK/pause"; W=$SPAWNED
wait_for "w14 paused" test -f "$WORK/pause.reached"
kill -TERM "$W"
rm -f "$WORK/pause"
wait "$W"; RC=$?
check "TERM in a critical section exits 130" test "$RC" = 130
check "its ticket is gone" queue_empty
holder h14
wait_for "control.lock is free" test -f "$WORK/h14.acquired"
touch "$WORK/h14.go"

# ---- (15) waiter sharing the dead holder's group ----
reset
spawn w15 env WAIT_START="$WORK/w15.start" \
  bash -c 'exec -a "bash .claude/lib/test-gate.sh" bash "$WORK/caller.sh" w15'
W=$SPAWNED
wait_for "w15 renamed" cmd_is "$W" "test-gate.sh"
dead_pid; fake_holder "$DEAD" t15 "$W"
touch "$WORK/w15.start"
wait_for "a waiter in the dead holder's group acquires" test -f "$WORK/w15.acquired"

# ---- (16) surviving nested gate shell ----
reset
spawn ng bash -c 'exec -a "bash .claude/lib/test-gate.sh" bash -c "$0" "$1"' \
  "$LOOP" "$WORK/ng.stop"
N=$SPAWNED
wait_for "nested gate renamed" cmd_is "$N" "test-gate.sh"
dead_pid; fake_holder "$DEAD" t16 "$N"
fg_caller w16 TEAM_GATE_LOCK_WAIT=1
check "a surviving nested gate blocks the reclaim" test "$RC" = 4
check "the nested gate is named" has "its workload pid $N" "$WORK/w16.err"
touch "$WORK/ng.stop"; wait "$N" 2>/dev/null
fg_caller w16b
check "reclaim after the nested gate ended" test "$RC" = 0

reset
echo "gate-lock-smoke: OK ($CHECKS checks)"
