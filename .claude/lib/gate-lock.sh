#!/usr/bin/env bash
# Machine-wide lock for full gate runs: one test-gate / merge-check build+test at a time.
# Sourced by test-gate.sh and team-merge-check.sh. Bash 3.2; the caller sets its own shell options.
# Callers acquire in their main shell (the lock is owned by $$), set `trap gate_lock_release EXIT`
# before acquiring and call gate_lock_cancel from their INT/TERM/HUP trap.

GATE_LOCK_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate_lock.py"

# Usage: gate_lock_acquire <what> → rc 0 holding the lock (GATE_LOCK_TOKEN, GATE_LOCK_WAITED);
# non-zero = not acquired (4 timeout, 5 error); the reason is already on stderr.
# The helper runs as a tracked background child: a trapped signal interrupts `wait` at once,
# where a $(…) substitution would defer the trap for the whole queue wait.
gate_lock_acquire() {
  local clone rc=0
  clone="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
  GATE_LOCK_OUT="$(mktemp)"
  python3 -I "$GATE_LOCK_PY" acquire "$$" "$clone" "$1" >"$GATE_LOCK_OUT" &
  GATE_LOCK_HELPER=$!
  wait "$GATE_LOCK_HELPER" || rc=$?
  GATE_LOCK_HELPER=""
  [ "$rc" = 0 ] || return "$rc"
  read -r GATE_LOCK_TOKEN GATE_LOCK_WAITED <"$GATE_LOCK_OUT"
}

gate_lock_cancel() {  # for the caller's INT/TERM/HUP trap: stop a queued helper, let it clean up
  [ -n "${GATE_LOCK_HELPER:-}" ] || return 0
  kill "$GATE_LOCK_HELPER" 2>/dev/null || true
  wait "$GATE_LOCK_HELPER" 2>/dev/null || true
  GATE_LOCK_HELPER=""
}

gate_lock_release() {  # owner-only; a no-op when this shell holds nothing
  local token="${GATE_LOCK_TOKEN:-}"
  # A signal between the helper's publish and the `read` leaves the token only in the file.
  [ -n "$token" ] || [ ! -s "${GATE_LOCK_OUT:-/nonexistent}" ] || read -r token _ <"$GATE_LOCK_OUT"
  [ -z "$token" ] || python3 -I "$GATE_LOCK_PY" release "$$" "$token" || true
  GATE_LOCK_TOKEN=""
  rm -f "${GATE_LOCK_OUT:-}"
}

gate_lock_held() { [ -n "${1:-}" ] && python3 -I "$GATE_LOCK_PY" held "$1"; }

gate_load_avg() { python3 -I "$GATE_LOCK_PY" load 2>/dev/null || echo '?'; }
