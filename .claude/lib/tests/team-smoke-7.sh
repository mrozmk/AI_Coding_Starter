#!/usr/bin/env bash
# merge-check under the machine gate lock.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-1154 chore/AB-1154-lock
RUN_ID=alfa-20261020-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
LOCK="$HOME/.agent-ops/locks/test-gate/lock"
MC="bash .claude/lib/team-merge-check.sh"

# ---- (150) refusal before the lock ---------------------------------------------------------------
python3 -I -c 'import os,sys; os.setpgid(0,0); os.execvp(sys.argv[1], sys.argv[1:])' \
  bash -c 'until [ -f "$0" ]; do sleep 0.1; done' "$WORK/holder.stop" </dev/null >/dev/null 2>&1 &
HPID=$!
SPID=$HPID
mkdir -p "$LOCK"
printf 'pid=%s\npid_start=%s\npgid=%s\nclone=fake\nwhat=fake\nsince=2026-10-20T00:00:00Z\n' \
  "$HPID" "$(ps -o lstart= -p "$HPID" | sed 's/^ *//;s/ *$//')" "$HPID" > "$LOCK/holder"
echo token=t150 >> "$LOCK/holder"
session coder 1 "$BASE"
run "$MAIN" $MC alfa
expect 3 "a role is still live" "merge-check refuses a live role before the lock"
! has "waiting for the machine gate lock" "$WORK/out" || fail "merge-check refusal waited"
echo "team-smoke-7: (150) refusal before the lock OK"

# ---- (151) timeout names the holder --------------------------------------------------------------
rm -f "$TD/session.json"
mkrec qa "$BASE"; mkrec wrapup "$BASE"
TEAM_GATE_LOCK_WAIT=1 run "$MAIN" $MC alfa
expect 3 "machine gate lock not acquired" "merge-check lock timeout"
has "held by fake pid $HPID" "$WORK/out" || fail "merge-check timeout does not name the holder"
grep -qx token=t150 "$LOCK/holder" || fail "merge-check timeout touched the holder"
echo "team-smoke-7: (151) timeout names the holder OK"

# ---- (152) lock released after a run -------------------------------------------------------------
touch "$WORK/holder.stop"; wait "$HPID" 2>/dev/null || true; SPID=""
run "$MAIN" $MC alfa
expect 3 "absent on origin" "merge-check past the lock"
has "reclaimed from dead fake pid $HPID" "$WORK/out" || fail "merge-check did not reclaim"
[ ! -d "$LOCK" ] || fail "merge-check left the machine gate lock behind"
echo "team-smoke-7: (152) lock released after a run OK"

echo "team-smoke-7: (150)-(152) OK"
