#!/usr/bin/env bash
# The whole team-layer suite in one fixed order, with counts: purity → every smoke part (serial
# parts last, alone) → the standalone suites → the agent-mail unittest → the shipped role profiles.
# Starter repo only: the tests are not distributed (manifest), so downstreams never run this.
#
# Usage: HOME=<scratch>/home TMPDIR=<scratch>/tmp/ bash .claude/lib/tests/team-suite.sh \
#          [--parallel] [--keep-going] [--out <dir>]
#   --parallel    smoke parts concurrently (TEAM_SMOKE_PARALLEL=1); serial parts still run alone
#   --keep-going  run every step even after a failure (the exit code still reports it)
#   --out <dir>   where suite-<utc>.log and the per-step outputs go (default $TMPDIR/team-suite)
#
# Refuses to start (exit 2, before any test) unless HOME is not the account's real home and
# TMPDIR is set and not the system default: a test that reaches the real ~/.agent-mail or
# ~/.agent-ops is a bug, and this is the last wall. Each step prints `ok <step> <n> checks <s>s`
# or `FAIL <step> …`; <n> comes from the step's own output, and 0 checks with exit 0 is a FAIL.
# The log is redacted (real home → ~, scratch HOME/TMPDIR → <scratch-home>/<scratch-tmp>) and must
# pass the purity deny-list, so it can be pasted into evidence. Exit: 0 all ok · 1 a step failed ·
# 2 usage / refused.
# Test hooks: TEAM_SUITE_TESTS (tests dir), TEAM_SUITE_ONLY (space-separated step names),
# TEAM_SUITE_SELFTEST=0 (skip the self-test step).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
TESTS="${TEAM_SUITE_TESTS:-$HERE}"
PARALLEL="" KEEP="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --parallel) PARALLEL=1 ;;
    --keep-going) KEEP=1 ;;
    --out) OUT="${2:-}"; [ -n "$OUT" ] || { echo "team-suite: --out needs a dir" >&2; exit 2; }; shift ;;
    *) echo "usage: team-suite.sh [--parallel] [--keep-going] [--out <dir>]" >&2; exit 2 ;;
  esac
  shift
done

real_home() {
  local me; me="$(id -un)"
  if [ "$(uname)" = Darwin ]; then
    dscl . -read "/Users/$me" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
  else
    getent passwd "$me" | cut -d: -f6
  fi
}
canon() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }
REAL="$(real_home)"
[ -n "$REAL" ] || { echo "team-suite: refused: cannot read the account's real home" >&2; exit 2; }
if [ -z "${HOME:-}" ] || [ "$(canon "$HOME")" = "$(canon "$REAL")" ]; then
  echo "team-suite: refused: run with a scratch HOME (HOME is the account's real home)" >&2; exit 2
fi
SYS_TMP=""; [ "$(uname)" != Darwin ] || SYS_TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
if [ -z "${TMPDIR:-}" ] || { [ -n "$SYS_TMP" ] && [ "$(canon "$TMPDIR")" = "$(canon "$SYS_TMP")" ]; }; then
  echo "team-suite: refused: run with a scratch TMPDIR (unset or the system default)" >&2; exit 2
fi

OUT="${OUT:-${TMPDIR%/}/team-suite}"
mkdir -p "$OUT" || { echo "team-suite: cannot create $OUT" >&2; exit 2; }
LOG="$OUT/suite-$(date -u +%Y%m%dT%H%M%SZ).log"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
RC=0

want() { [ -z "${TEAM_SUITE_ONLY:-}" ] || [[ " $TEAM_SUITE_ONLY " == *" $1 "* ]]; }

# count <file> — the checks a step reported: the largest explicit "(N checks|tests)", "Ran N tests"
# or "passed: N" wins (a summary may repeat the runner's count, so never a sum); otherwise the
# number of per-check OK/PASS lines (the "team-smoke: OK" summary line is not a check).
count() {
  awk '
    function x(v) { if (v + 0 > n) n = v + 0; e = 1 }
    match($0, /\(([0-9]+) (checks|tests)\)/) { x(substr($0, RSTART + 1)); next }
    /^Ran [0-9]+ tests?/ { x($2); next }
    /^passed: [0-9]+/ { x($2); next }
    /^team-smoke: OK$/ { next }
    /(^|[: ])OK( |$)|^PASS / { k++ }
    END { print (e ? n : k + 0) }' "$1"
}

# step <name> <cmd…> — run, count, log one line; returns non-zero on a failed step.
step() {
  local name="$1" t0 rc n out; shift
  want "$name" || return 0
  out="$OUT/$name.out"; t0=$(date +%s)
  ( cd "$ROOT" && "$@" ) > "$out" 2>&1; rc=$?
  n="$(count "$out")"
  if [ "$rc" = 0 ] && [ "$n" -gt 0 ]; then
    say "ok $name $n checks $(( $(date +%s) - t0 ))s"; return 0
  fi
  if [ "$rc" = 0 ]; then say "FAIL $name 0 checks (exit 0) — see $out"
  else say "FAIL $name rc $rc, $n checks — see $out"; fi
  RC=1; [ -n "$KEEP" ] || finish
  return 1
}

redact() {
  local f esc_real esc_home esc_tmp
  esc_real=$(printf '%s' "$REAL" | sed 's/[][\.*^$/|]/\\&/g')
  esc_home=$(printf '%s' "$HOME" | sed 's/[][\.*^$/|]/\\&/g')
  esc_tmp=$(printf '%s' "${TMPDIR%/}" | sed 's/[][\.*^$/|]/\\&/g')
  for f in "$OUT"/*.out "$LOG"; do
    [ -f "$f" ] || continue
    sed -i.bak -e "s|$esc_tmp|<scratch-tmp>|g" -e "s|$esc_home|<scratch-home>|g" \
      -e "s|$esc_real|~|g" "$f" && rm -f "$f.bak"
  done
}

# The redacted log must itself be pure: run the purity scanner over a root holding only the log.
log_pure() {
  local t; t=$(mktemp -d); mkdir -p "$t/docs/teams"
  cp "$LOG" "$t/docs/teams/suite.log"
  bash "$HERE/team-purity.sh" "$t" > "$t/out" 2>&1; local rc=$?
  [ "$rc" = 0 ] || { grep -v '^team-purity' "$t/out" | sed 's/^/  | /'; }
  rm -rf "$t"; return "$rc"
}

finish() {
  redact
  if ! log_pure; then printf 'FAIL log-purity — the redacted log carries project identity\n' >> "$LOG"; RC=1; fi
  if [ "$RC" = 0 ]; then printf 'team-suite: OK\n' >> "$LOG"; else printf 'team-suite: FAIL\n' >> "$LOG"; fi
  tail -n 1 "$LOG"; echo "log: $LOG"
  exit "$RC"
}

# ---- 0. self-test: a failing step, a 0-check step and a real-HOME run must all fail -------------
self_test() {
  local t rc; t=$(mktemp -d)
  printf 'echo "team-purity: FAIL"; exit 1\n' > "$t/team-purity.sh"
  TEAM_SUITE_TESTS="$t" TEAM_SUITE_ONLY=purity TEAM_SUITE_SELFTEST=0 \
    bash "$HERE/team-suite.sh" --out "$t/o1" > "$t/r1" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q '^FAIL purity rc 1' "$t/r1" || { echo "FAIL: a failing step passed"; rm -rf "$t"; return 1; }
  printf 'exit 0\n' > "$t/team-purity.sh"
  TEAM_SUITE_TESTS="$t" TEAM_SUITE_ONLY=purity TEAM_SUITE_SELFTEST=0 \
    bash "$HERE/team-suite.sh" --out "$t/o2" > "$t/r2" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q '^FAIL purity 0 checks' "$t/r2" || { echo "FAIL: a 0-check step passed"; rm -rf "$t"; return 1; }
  HOME="$REAL" TEAM_SUITE_TESTS="$t" TEAM_SUITE_SELFTEST=0 \
    bash "$HERE/team-suite.sh" --out "$t/o3" > "$t/r3" 2>&1; rc=$?
  [ "$rc" = 2 ] && grep -q 'refused: run with a scratch HOME' "$t/r3" && [ ! -e "$t/o3" ] \
    || { echo "FAIL: the real HOME was not refused before any test"; rm -rf "$t"; return 1; }
  rm -rf "$t"
  echo "self-test: failing step OK"; echo "self-test: 0-check step OK"; echo "self-test: real HOME OK"
}
if [ "${TEAM_SUITE_SELFTEST:-1}" != 0 ]; then step self-test self_test; fi

# ---- 1. purity ---------------------------------------------------------------------------------
step purity bash "$TESTS/team-purity.sh"

# ---- 2. smoke parts, by name, serial parts last -------------------------------------------------
if [ -f "$TESTS/team-smoke.sh" ]; then
  read -r -a ALL <<<"$(sed -n 's/^ *all) parts=(\(.*\)) ;;$/\1/p' "$TESTS/team-smoke.sh")"
  [ "${#ALL[@]}" -gt 0 ] || { say "FAIL smoke — no parts list in team-smoke.sh"; RC=1; [ -n "$KEEP" ] || finish; }
  serial() { grep -qx '# team-smoke: serial' "$TESTS/team-smoke-$1.sh" 2>/dev/null; }
  if [ -n "$PARALLEL" ]; then
    step smoke-parallel env TEAM_SMOKE_PARALLEL=1 bash "$TESTS/team-smoke.sh"
  else
    for p in "${ALL[@]}"; do
      [ "$p" != purity ] && ! serial "$p" || continue
      step "smoke-$p" env TEAM_SMOKE_PART="$p" bash "$TESTS/team-smoke.sh"
    done
    for p in "${ALL[@]}"; do
      serial "$p" || continue
      step "smoke-$p" env TEAM_SMOKE_PART="$p" bash "$TESTS/team-smoke.sh"
    done
  fi
fi

# ---- 3. standalone suites (cost-tests carries the costs unittest) -------------------------------
for s in team-setup-smoke team-profile-smoke team-tracker-smoke team-pr-smoke worker-smoke \
         cost-tests guard-team-egress-test guard-destructive-sql-test team-audit-test gate-lock-smoke; do
  step "$s" bash "$TESTS/$s.sh"
done

# ---- 4. agent-mail unittest --------------------------------------------------------------------
step agent-mail-unittest python3 -I -B -m unittest discover -s tools/agent_mail/tests -t .

# ---- 5. the shipped role profiles (P5; absent before it lands) ----------------------------------
if [ -f "$ROOT/.claude/lib/session_profile_check.py" ]; then
  step session-profiles python3 -I "$ROOT/.claude/lib/session_profile_check.py" "$ROOT"
elif want session-profiles; then
  say "skip session-profiles — .claude/lib/session_profile_check.py not present at this sha"
fi

finish
