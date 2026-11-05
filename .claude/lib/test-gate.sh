#!/usr/bin/env bash
#
# test-gate.sh — the project's test gate under the machine gate lock.
#
# WHY: several team clones on one machine run their gates at once; parallel builds and test runs
# starve each other and time out. This wrapper queues every full gate run behind one machine-wide
# lock (gate-lock.sh) and runs the project's own gate — `teams.test_gate` in
# .claude/project-profile.json — inside it. It fails closed: a gate that did not run is never green.
#
# Usage: bash .claude/lib/test-gate.sh
#
# Exit: the project gate's exit code (0 green) · 3 usage or no profile · 4 machine gate lock not
#       acquired (timeout or lock error). `teams.test_gate: none` → "test-gate: none", exit 0.
# Prints `load avg: <1m> <5m> <15m>` at start and end and `lock waited <n>s` (QA report `Load:`).
# A caller already holding the lock (team-merge-check.sh exports TEAM_GATE_LOCK_TOKEN) is not
# queued again. The harness self-test (.claude/lib/tests/cost-tests.sh) runs first when present.
# Lock root and knobs: TEAM_GATE_LOCK_DIR (default ~/.agent-ops/locks/test-gate), _WAIT (1800 s),
# _WORKLOAD (regex of the project's build/test tools) — team-pipeline.md → Machine gate lock.

set -uo pipefail
[ $# = 0 ] || { echo "test-gate: no arguments expected" >&2; exit 3; }
ROOT="$(git rev-parse --show-toplevel)" || exit 3
if [ -f "$ROOT/.claude/lib/tests/cost-tests.sh" ]; then
  bash "$ROOT/.claude/lib/tests/cost-tests.sh" || exit $?
fi
. "$ROOT/.claude/lib/team-profile.sh"
( team_profile_load "$ROOT" ) >/dev/null || { echo "test-gate: no teams profile" >&2; exit 3; }
team_profile_load "$ROOT"
if [ "$TEAM_TEST_GATE" = none ]; then echo "test-gate: none"; exit 0; fi
[ -f "$TEAM_TEST_GATE" ] || [ -f "$ROOT/$TEAM_TEST_GATE" ] \
  || { echo "test-gate: teams.test_gate $TEAM_TEST_GATE not found" >&2; exit 3; }
case "$TEAM_TEST_GATE" in */test-gate.sh|test-gate.sh)
  [ "$(cd "$ROOT" && cd "$(dirname "$TEAM_TEST_GATE")" && pwd -P)" != "$(cd "$(dirname "$0")" && pwd -P)" ] \
    || { echo "test-gate: teams.test_gate points at this wrapper — name the project's own gate" >&2; exit 3; } ;;
esac

. "$ROOT/.claude/lib/gate-lock.sh"
CHILD=""
on_signal() {
  gate_lock_cancel
  [ -z "$CHILD" ] || kill "$CHILD" 2>/dev/null || true
  exit 130
}
trap gate_lock_release EXIT
trap on_signal INT TERM HUP

echo "load avg: $(gate_load_avg)"
if gate_lock_held "${TEAM_GATE_LOCK_TOKEN:-}"; then
  echo "test-gate: lock held by the caller"
else
  gate_lock_acquire "test-gate" || exit 4
  echo "test-gate: lock waited ${GATE_LOCK_WAITED}s"
fi

# A tracked child, so a trapped signal interrupts `wait` at once and stops the gate too.
(cd "$ROOT" && exec bash "$TEAM_TEST_GATE") &
CHILD=$!
rc=0; wait "$CHILD" || rc=$?
CHILD=""
echo "load avg: $(gate_load_avg)"
echo "test-gate: exit $rc"
exit "$rc"
