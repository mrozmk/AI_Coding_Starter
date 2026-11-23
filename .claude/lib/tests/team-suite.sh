#!/usr/bin/env bash
# The whole team-layer suite in one fixed order, with counts: purity → every smoke part (serial
# parts last, alone) → the standalone suites → the agent-mail unittest → the shipped role profiles.
# Starter repo only: the tests are not distributed (manifest), so downstreams never run this.
#
# Usage: HOME=<scratch>/home TMPDIR=<scratch>/tmp/ bash .claude/lib/tests/team-suite.sh \
#          [--parallel] [--keep-going] [--out <dir>]
#   --parallel    smoke parts concurrently (TEAM_SMOKE_PARALLEL=1); serial parts still run alone
#   --keep-going  run every step even after a failure (the exit code still reports it)
#   --out <dir>   where suite-<utc>.log and the per-step outputs go (default $TMPDIR/team-suite);
#                 a relative dir is resolved against the caller's cwd
#
# TEAM_SUITE_JOBS=<n> (opt-in; unset or 1 = the serial run, unchanged): self-test first and alone,
# then up to n steps at once, each with its own HOME/TMPDIR under ${TMPDIR}team-suite-jobs.*, then
# the serial tail one at a time — smoke parts marked `# team-smoke: serial` and standalone suites
# marked `# team-suite: serial` (an exact line, with `# serial because: <reason>` on the next line).
# The log keeps the serial run's order whatever finishes first; without --keep-going a failure
# starts nothing more, the running steps drain and a step that never started has no line. INT/TERM
# ends every running step's process group, then the run reports FAIL. Serial stays the default until
# the pool has run green several times. Known limit: a process that moved itself into its own group
# (pr_timebox's timed command, team-lib.sh) outlives an interrupt until its own sleep ends; it never
# writes to --out. Exclusive with --parallel.
#
# Refuses to start (exit 2, before any test) unless HOME is not the account's real home and
# TMPDIR is set and not the system default: a test that reaches the real ~/.agent-mail or
# ~/.agent-ops is a bug, and this is the last wall. Each step prints `ok <step> <n> checks <s>s`
# or `FAIL <step> …`; <n> comes from the step's own output, and 0 checks with exit 0 is a FAIL.
# The log is redacted (real home → ~, scratch HOME/TMPDIR → <scratch-home>/<scratch-tmp>) and must
# pass the purity deny-list, so it can be pasted into evidence. Exit: 0 all ok · 1 a step failed ·
# 2 usage / refused.
# Step selection: TEAM_SUITE_ONLY (space-separated step names: run only these) and TEAM_SUITE_SKIP
# (space-separated step names: never run these, one `skip <step> (TEAM_SUITE_SKIP)` line each);
# ONLY picks, SKIP subtracts. Names are the ones the log prints: self-test, purity, smoke-<part>
# (smoke-parallel with --parallel), each standalone suite, agent-mail-unittest, session-profiles.
# An unknown SKIP name is a usage error (exit 2) — a typo must not silently skip nothing.
# Test hooks: TEAM_SUITE_TESTS (tests dir), TEAM_SUITE_SELFTEST=0 (skip the self-test step).
# TEAM_SUITE_CASE_TIMES=1: each step writes <out>/<step>.cases (suite-case-time.sh records) and the log
# gets one `  slowest: <case> <s>s · …` line per step (off with --parallel: one aggregate step).
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
# Absolute now, created later: a refused run must leave no --out directory behind.
case "$OUT" in ''|/*) ;; *) OUT="$PWD/$OUT" ;; esac
. "$HERE/suite-case-time.sh"

STANDALONE=(team-setup-smoke team-profile-smoke team-tracker-smoke team-tracker-sync-smoke team-pr-smoke worker-smoke
  cost-tests guard-team-egress-test guard-team-trunk-test guard-destructive-sql-test guard-leak-smoke team-audit-test
  gate-lock-smoke rm-in-project-smoke rm-in-scratchpad-smoke
  finder-model-test check-impl-contract-test coding-standards-contract-test coding-standards-gen-test qa-verify-contract-test refresh-brief-contract-test check-backlog-upkeep-contract-test start-claim-contract-test team-inbox-test team-ask-test herdr-dock-test herdr-kit-test herdr-kit-sync-test herdr-rate-limits-test notify-resolve-test touches-test
  prime-probes-test arch-assess-test upkeep-test
  starter-fork-commit-test team-starter-land-test branch-model-test guard-push-protected-test
  guard-jira-transition-test tracker-snapshot-test tracker-pointers-test pr-create-open-test pr-merge-github-test
  guarded-writes-az-test guarded-writes-ops-sql-test local-env-test trunk-trust-test remote-build-test)
ALL=()
[ ! -f "$TESTS/team-smoke.sh" ] \
  || read -r -a ALL <<<"$(sed -n 's/^ *all) parts=(\(.*\)) ;;$/\1/p' "$TESTS/team-smoke.sh")"
KNOWN=" self-test purity agent-mail-unittest session-profiles ${STANDALONE[*]} "
if [ -n "$PARALLEL" ]; then KNOWN="$KNOWN smoke-parallel "
else for p in ${ALL[@]+"${ALL[@]}"}; do [ "$p" = purity ] || KNOWN="$KNOWN smoke-$p "; done; fi
for n in ${TEAM_SUITE_SKIP:-}; do
  [[ "$KNOWN" == *" $n "* ]] || { echo "team-suite: TEAM_SUITE_SKIP names an unknown step: $n" >&2; exit 2; }
done
JOBS="${TEAM_SUITE_JOBS:-1}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "team-suite: TEAM_SUITE_JOBS must be a positive integer" >&2; exit 2; }
[ -z "$PARALLEL" ] || [ "$JOBS" = 1 ] || { echo "team-suite: --parallel and TEAM_SUITE_JOBS are exclusive" >&2; exit 2; }

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

# No step may reach the calling Claude session: a fixture that inherits its messaging socket writes it
# into a fixture registration, and a fixture doorbell then rings that real session. A case that needs
# a socket sets its own; `step` checks the variables are empty before every step.
unset CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN
# Nor the calling session's identity — team-smoke-lib.sh smoke_init says why; this covers the
# standalone steps and the mail part.
unset ${!HARNESS_@} TEAM_SESSION_ROLE TEAM_RUN_TEAM TEAM_RUN_ROLE TEAM_RUN_ID TEAM_RUN_ATTEMPT \
  HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE TMUX TMUX_PANE
# A guard refused in a fixture whose teamlead.json main_root is this checkout would log the block
# into the real touch log: touches.sh block stands down (touches-test unsets it to test block).
export TOUCHES_BLOCK_OFF=1

OUT="${OUT:-${TMPDIR%/}/team-suite}"
mkdir -p "$OUT" || { echo "team-suite: cannot create $OUT" >&2; exit 2; }
LOG="$OUT/suite-$(date -u +%Y%m%dT%H%M%SZ).log"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
RC=0
CASES_ON=""
if [ "${TEAM_SUITE_CASE_TIMES:-}" = 1 ]; then
  if [ -n "$PARALLEL" ]; then say "case times: off with --parallel (one aggregate step)"; else CASES_ON=1; fi
fi

want() { [ -z "${TEAM_SUITE_ONLY:-}" ] || [[ " $TEAM_SUITE_ONLY " == *" $1 "* ]]; }
skipped() { [[ " ${TEAM_SUITE_SKIP:-} " == *" $1 "* ]]; }

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

# case_report <cases file> — the three slowest intervals of a step; each interval carries the label
# of the record that opens it (`start` → setup). Without a closing `end` record: incomplete.
case_report() {
  [ -s "$1" ] || return 0
  say "  slowest: $(awk -F'\t' '
    { t[NR] = $1; l[NR] = ($2 == "start" ? "setup" : $2) }
    END {
      if (NR < 2 || l[NR] != "end") { print "incomplete"; exit }
      for (i = 1; i < NR; i++) d[i] = t[i + 1] - t[i]
      s = ""
      for (k = 1; k <= 3 && k < NR; k++) {
        b = 0
        for (i = 1; i < NR; i++) if (!(i in used) && (b == 0 || d[i] > d[b])) b = i
        used[b] = 1
        s = s (s == "" ? "" : " · ") l[b] " " sprintf("%.1f", d[b]) "s"
      }
      print s
    }' "$1")"
}

# step_ready <name> → 0 it runs · 1 not selected, or skipped · 2 refused (RC=1). The skip or refusal
# line goes to READY_LINE, never printed here: the serial run says it at once, jobs mode queues it.
step_ready() {
  READY_LINE=""
  want "$1" || return 1
  if skipped "$1"; then READY_LINE="skip $1 (TEAM_SUITE_SKIP)"; return 1; fi
  if [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}${CLAUDE_CODE_MESSAGING_TOKEN:-}" ]; then
    READY_LINE="FAIL $1 — a Claude messaging socket is set in the step environment"; RC=1; return 2
  fi
}

# step_report <name> <rc|noresult> <secs> — count, the ok/FAIL line, case times; 1 = failed (RC=1).
step_report() {
  local name="$1" rc="$2" out="$OUT/$1.out" cases="" n
  [ -z "$CASES_ON" ] || cases="$OUT/$name.cases"
  if [ "$rc" = noresult ]; then
    say "FAIL $name rc 255 (no result) — see $out"
  else
    n="$(count "$out")"
    if [ "$rc" = 0 ] && [ "$n" -gt 0 ]; then
      say "ok $name $n checks ${3}s"; [ -z "$cases" ] || case_report "$cases"; return 0
    fi
    if [ "$rc" = 0 ]; then say "FAIL $name 0 checks (exit 0) — see $out"
    else say "FAIL $name rc $rc, $n checks — see $out"; fi
  fi
  [ -z "$cases" ] || case_report "$cases"
  RC=1; return 1
}

# step <name> <cmd…> — run in the foreground, count, log one line; returns non-zero on a failed step.
step() {
  local name="$1" t0 rc cases=""; shift
  step_ready "$name"; case $? in
    1) [ -z "$READY_LINE" ] || say "$READY_LINE"; return 0 ;;
    2) say "$READY_LINE"; [ -n "$KEEP" ] || finish; return 1 ;;
  esac
  t0=$(date +%s)
  if [ -n "$CASES_ON" ]; then cases="$OUT/$name.cases"; printf '%s\tstart\n' "$(case_now)" > "$cases"; fi
  # Exported inside the subshell, never through `env`: a step command may be a shell function.
  ( cd "$ROOT" && export TEAM_CASE_TIMES="$cases" && "$@" ) > "$OUT/$name.out" 2>&1; rc=$?
  [ -z "$cases" ] || printf '%s\tend\n' "$(case_now)" >> "$cases"
  step_report "$name" "$rc" "$(( $(date +%s) - t0 ))" && return 0
  [ -n "$KEEP" ] || finish
  return 1
}

# ---- jobs mode (TEAM_SUITE_JOBS > 1): a queue in report order, run by run_jobs -------------------
QN=() QC=() QS=() QR=()   # name, quoted command, 1 = serial tail, a ready line (skip / not present)
add() {  # add <0|1 serial> <name> <cmd…> — the serial run runs the step now; jobs mode queues it
  local ser="$1" name="$2" i; shift 2
  if [ "$JOBS" = 1 ]; then step "$name" "$@"; return; fi
  step_ready "$name" || [ -n "$READY_LINE" ] || return 0
  i=${#QN[@]}; QN[i]="$name"; QS[i]="$ser"; QR[i]="$READY_LINE"; QC[i]="$(printf '%q ' "$@")"
}
add_note() {  # add_note <name> <line> — a selected step that cannot run: only its line, in order
  local i
  if [ "$JOBS" = 1 ]; then say "$2"; return; fi
  i=${#QN[@]}; QN[i]="$1"; QS[i]=0; QC[i]=""; QR[i]="$2"
}

# jobs_launch <i> — a background job with its own HOME/TMPDIR; its status goes to $JR/<name>.rc
# only after the timing record, so the record never becomes the status.
jobs_launch() {
  local i="$1" name="${QN[$1]}" cases=""
  mkdir -p "$JR/$name/home" "$JR/$name/tmp"
  if [ -n "$CASES_ON" ]; then cases="$OUT/$name.cases"; printf '%s\tstart\n' "$(case_now)" > "$cases"; fi
  JT0[i]=$(date +%s)
  { ( cd "$ROOT" && export HOME="$JR/$name/home" TMPDIR="$JR/$name/tmp/" TEAM_CASE_TIMES="$cases" || exit 1
      eval "${QC[$i]}"; rc=$?
      [ -z "$cases" ] || printf '%s\tend\n' "$(case_now)" >> "$cases"
      exit "$rc" ) > "$OUT/$name.out" 2>&1
    echo $? > "$JR/$name.rc"; } &
  JPID[i]=$!; JST[i]=run; RUNNING=$((RUNNING + 1))
}

# jobs_reap — classify every finished job; finished = its pid is gone (never a file that a killed
# wrapper will not write: no .rc → `noresult`). The suite's own rule: rc ≠ 0 or 0 checks fails, and
# without --keep-going a failure stops scheduling.
jobs_reap() {
  local i rc
  for ((i = 0; i < ${#QN[@]}; i++)); do
    [ "${JST[i]:-}" = run ] && ! kill -0 "${JPID[i]}" 2>/dev/null || continue
    wait "${JPID[i]}" 2>/dev/null
    rc="$(cat "$JR/${QN[i]}.rc" 2>/dev/null)"; [ -n "$rc" ] || rc=noresult
    JRCV[i]="$rc"; JSECS[i]=$(( $(date +%s) - JT0[i] )); JST[i]=done; RUNNING=$((RUNNING - 1))
    if [ "$rc" != 0 ] || [ "$(count "$OUT/${QN[i]}.out")" = 0 ]; then [ -n "$KEEP" ] || STOP=1; fi
  done
}

# jobs_flush [all] — report in the serial run's order: the head of the unreported queue, while
# finished. `all` (after a stop) passes over what never started instead of waiting for it.
jobs_flush() {
  while [ "$HEAD" -lt "${#QN[@]}" ]; do
    case "${JST[HEAD]}" in
      done) step_report "${QN[HEAD]}" "${JRCV[HEAD]}" "${JSECS[HEAD]}" || true ;;
      skip) say "${QR[HEAD]}" ;;
      *) [ -n "${1:-}" ] || return 0 ;;
    esac
    HEAD=$((HEAD + 1))
  done
}

jobs_interrupt() {  # INT/TERM: stop scheduling, end every running job's process group, report FAIL
  local i
  trap - INT TERM
  for ((i = 0; i < ${#QN[@]}; i++)); do [ "${JST[i]:-}" != run ] || kill -TERM -- "-${JPID[i]}" 2>/dev/null; done
  for ((i = 0; i < ${#QN[@]}; i++)); do [ "${JST[i]:-}" != run ] || wait "${JPID[i]}" 2>/dev/null; done
  set +m
  say "interrupted"; RC=1; finish
}

run_jobs() {
  local i
  [ "${#QN[@]}" -gt 0 ] || return 0
  JR="$(mktemp -d "${TMPDIR%/}/team-suite-jobs.XXXXXX")" || { say "FAIL jobs — no job root"; RC=1; finish; }
  JST=() JPID=() JRCV=() JSECS=() JT0=(); RUNNING=0; STOP=""; HEAD=0
  for ((i = 0; i < ${#QN[@]}; i++)); do
    if [ -n "${QR[i]}" ]; then JST[i]=skip; elif [ "${QS[i]}" = 1 ]; then JST[i]=tail; else JST[i]=queued; fi
  done
  trap jobs_interrupt INT TERM
  set -m   # every job leads its own process group, so an interrupt can end all of it
  for ((i = 0; i < ${#QN[@]}; i++)); do
    [ "${JST[i]}" = queued ] || continue
    # Classify before every launch: a failure the parent could already see starts nothing more.
    jobs_reap
    while [ -z "$STOP" ] && [ "$RUNNING" -ge "$JOBS" ]; do sleep 0.2; jobs_reap; jobs_flush; done
    [ -z "$STOP" ] || break
    jobs_launch "$i"; jobs_flush
  done
  while [ "$RUNNING" -gt 0 ]; do sleep 0.2; jobs_reap; jobs_flush; done
  for ((i = 0; i < ${#QN[@]}; i++)); do   # the serial tail: alone, one at a time
    [ -z "$STOP" ] || break
    [ "${JST[i]}" = tail ] || continue
    jobs_launch "$i"
    while [ "$RUNNING" -gt 0 ]; do sleep 0.2; jobs_reap; done
    jobs_flush
  done
  set +m
  trap - INT TERM
  jobs_flush all   # after a stop: what ran, in order; never a step that did not start
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

# ---- 0. self-test: a failing step, a 0-check step and a real-HOME run must all fail; SKIP skips a
# selected step and refuses an unknown name (inner runs never inherit the caller's SKIP) ----------
self_test() {
  local t rc; t=$(mktemp -d)
  printf 'echo "team-purity: FAIL"; exit 1\n' > "$t/team-purity.sh"
  TEAM_SUITE_TESTS="$t" TEAM_SUITE_ONLY=purity TEAM_SUITE_SKIP= TEAM_SUITE_SELFTEST=0 TEAM_SUITE_CASE_TIMES= TEAM_SUITE_JOBS= \
    bash "$HERE/team-suite.sh" --out "$t/o1" > "$t/r1" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q '^FAIL purity rc 1' "$t/r1" || { echo "FAIL: a failing step passed"; rm -rf "$t"; return 1; }
  printf 'exit 0\n' > "$t/team-purity.sh"
  TEAM_SUITE_TESTS="$t" TEAM_SUITE_ONLY=purity TEAM_SUITE_SKIP= TEAM_SUITE_SELFTEST=0 TEAM_SUITE_CASE_TIMES= TEAM_SUITE_JOBS= \
    bash "$HERE/team-suite.sh" --out "$t/o2" > "$t/r2" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q '^FAIL purity 0 checks' "$t/r2" || { echo "FAIL: a 0-check step passed"; rm -rf "$t"; return 1; }
  HOME="$REAL" TEAM_SUITE_TESTS="$t" TEAM_SUITE_SKIP= TEAM_SUITE_SELFTEST=0 TEAM_SUITE_CASE_TIMES= TEAM_SUITE_JOBS= \
    bash "$HERE/team-suite.sh" --out "$t/o3" > "$t/r3" 2>&1; rc=$?
  [ "$rc" = 2 ] && grep -q 'refused: run with a scratch HOME' "$t/r3" && [ ! -e "$t/o3" ] \
    || { echo "FAIL: the real HOME was not refused before any test"; rm -rf "$t"; return 1; }
  TEAM_SUITE_TESTS="$t" TEAM_SUITE_ONLY=purity TEAM_SUITE_SKIP=purity TEAM_SUITE_SELFTEST=0 TEAM_SUITE_CASE_TIMES= TEAM_SUITE_JOBS= \
    bash "$HERE/team-suite.sh" --out "$t/o4" > "$t/r4" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -qx 'skip purity (TEAM_SUITE_SKIP)' "$t/r4" && [ ! -e "$t/o4/purity.out" ] \
    || { echo "FAIL: TEAM_SUITE_SKIP did not skip a selected step"; rm -rf "$t"; return 1; }
  TEAM_SUITE_TESTS="$t" TEAM_SUITE_SKIP="purity smoke-nosuch" TEAM_SUITE_SELFTEST=0 TEAM_SUITE_CASE_TIMES= TEAM_SUITE_JOBS= \
    bash "$HERE/team-suite.sh" --out "$t/o5" > "$t/r5" 2>&1; rc=$?
  [ "$rc" = 2 ] && grep -q 'unknown step: smoke-nosuch' "$t/r5" && [ ! -e "$t/o5" ] \
    || { echo "FAIL: an unknown TEAM_SUITE_SKIP name was not a usage error"; rm -rf "$t"; return 1; }
  printf '%s\n' "env | grep -qE '^(HARNESS_|TEAM_RUN_TEAM=|HC_TERMINAL_ID=)' && { echo \"team-purity: FAIL\"; exit 1; }; echo \"PASS no session env\"" > "$t/team-purity.sh"
  HARNESS_ADDRESS=x HARNESS_MAIN=/nonexistent TEAM_RUN_TEAM=x HC_TERMINAL_ID=x \
    TEAM_SUITE_TESTS="$t" TEAM_SUITE_ONLY=purity TEAM_SUITE_SKIP= TEAM_SUITE_SELFTEST=0 TEAM_SUITE_CASE_TIMES= TEAM_SUITE_JOBS= \
    bash "$HERE/team-suite.sh" --out "$t/o6" > "$t/r6" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q '^ok purity 1 checks' "$t/r6" \
    || { echo "FAIL: the session env reached a step"; rm -rf "$t"; return 1; }
  printf '%s\n' ". '$HERE/suite-case-time.sh'" 'case_mark "(a) one"' 'case_mark "(b) two"' 'echo "PASS x"' \
    > "$t/team-purity.sh"
  TEAM_SUITE_TESTS="$t" TEAM_SUITE_ONLY=purity TEAM_SUITE_SKIP= TEAM_SUITE_SELFTEST=0 TEAM_SUITE_CASE_TIMES=1 TEAM_SUITE_JOBS= \
    bash "$HERE/team-suite.sh" --out "$t/o7" > "$t/r7" 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q '^  slowest: .*(b) two' "$t/r7" && grep -q '^  slowest: .*(b) two' "$t"/o7/suite-*.log \
    && ! grep -q slowest "$t/o7/purity.out" \
    || { echo "FAIL: case times did not report the last case"; rm -rf "$t"; return 1; }
  self_test_jobs "$t" || { rm -rf "$t"; return 1; }
  rm -rf "$t"
  echo "self-test: failing step OK"; echo "self-test: 0-check step OK"; echo "self-test: real HOME OK"
  echo "self-test: skip OK"; echo "self-test: unknown skip OK"; echo "self-test: session env OK"
  echo "self-test: case times OK"
  echo "self-test: jobs overlap OK"; echo "self-test: jobs fail-fast OK"; echo "self-test: jobs tail order OK"
  echo "self-test: jobs status with timing OK"; echo "self-test: jobs interrupt OK"
  echo "self-test: jobs skip order OK"; echo "self-test: jobs zero checks OK"
  echo "self-test: jobs isolation OK"; echo "self-test: jobs refusals OK"
}

# self_test_jobs <dir> — TEAM_SUITE_JOBS against four handshaking fake standalone steps (the first
# four STANDALONE names). Every wait is a bounded poll (10 s); a timeout writes <n>.timeout.
self_test_jobs() {
  local t="$1" H="$1/hs" J4="team-setup-smoke team-profile-smoke team-tracker-smoke team-tracker-sync-smoke"
  local rc v n f order bp
  jf() {  # jf <n> <body lines…> — fake n: records started + its HOME/TMPDIR, then the body
    local n="$1"; shift
    { printf '%s\n' "H='$H'" "touch \"\$H/$n.started\"" "printf '%s\n%s\n' \"\$HOME\" \"\$TMPDIR\" > \"\$H/$n.env\"" \
        "w() { local i=0; while ! eval \"\$1\"; do i=\$((i + 1)); [ \"\$i\" -lt 100 ] || { touch \"\$H/$n.timeout\"; exit 1; }; sleep 0.1; done; }"
      printf '%s\n' "$@"; } > "$t/$(echo "$J4" | cut -d' ' -f"$n").sh"
  }
  jser() { printf '%s\n' '# team-suite: serial' '# serial because: self-test fake' >> "$t/$(echo "$J4" | cut -d' ' -f"$1").sh"; }
  jrun() {  # jrun <tag> [VAR=value…] — the inner suite over the four fakes, JOBS=2 → $t/r-<tag>, rc
    local tag="$1"; shift; rm -rf "$H"; mkdir -p "$H"
    env TEAM_SUITE_TESTS="$t" TEAM_SUITE_ONLY="$J4" TEAM_SUITE_SKIP= TEAM_SUITE_SELFTEST=0 TEAM_SUITE_CASE_TIMES= \
      TEAM_SUITE_JOBS=2 "$@" bash "$HERE/team-suite.sh" --out "$t/o-$tag" > "$t/r-$tag" 2>&1
  }
  lines() { grep -E '^(ok|FAIL|skip) ' "$1" | awk '{ printf "%s%s %s", (NR > 1 ? "," : ""), $1, $2 } END { print "" }'; }
  # (a) overlap and the cap: 1 and 2 run together, the third enters only after one of them ended,
  # 2 finishes first, the serial 4th runs after all three; the log keeps declaration order.
  jf 1 'w "[ -e \"\$H/2.started\" ]"' 'w "[ -e \"\$H/2.done\" ]"' 'echo "PASS 1"' 'touch "$H/1.done"'
  jf 2 'w "[ -e \"\$H/1.started\" ]"' 'sleep 0.3' '[ ! -e "$H/3.started" ] || { touch "$H/2.cap-broken"; exit 1; }' \
    'echo "PASS 2"' 'touch "$H/2.done"'
  jf 3 '[ -e "$H/1.done" ] || [ -e "$H/2.done" ] || { touch "$H/3.cap-broken"; exit 1; }' 'echo "PASS 3"' 'touch "$H/3.done"'
  jf 4 '[ -e "$H/1.done" ] && [ -e "$H/2.done" ] && [ -e "$H/3.done" ] || { touch "$H/4.alone-broken"; exit 1; }' \
    'echo "PASS 4"' 'touch "$H/4.done"'; jser 4
  jrun a; rc=$?
  order="$(lines "$t/r-a")"
  [ "$rc" = 0 ] && [ "$order" = "ok team-setup-smoke,ok team-profile-smoke,ok team-tracker-smoke,ok team-tracker-sync-smoke" ] \
    || { echo "FAIL: jobs overlap/cap (rc $rc, $order, $(ls "$H" | tr '\n' ' '))"; return 1; }
  # (b) fail-fast: 1 fails while 2 runs; 2 drains and is reported, 3 and 4 never start.
  jf 1 'w "[ -e \"\$H/2.started\" ]"' 'touch "$H/1.exiting"' 'exit 1'
  jf 2 'w "[ -e \"\$H/1.exiting\" ]"' 'sleep 0.5' 'echo "PASS 2"'
  jf 3 'echo "PASS 3"'; jf 4 'echo "PASS 4"'
  jrun b; rc=$?
  [ "$rc" = 1 ] && grep -q '^FAIL team-setup-smoke rc 1' "$t/r-b" && grep -q '^ok team-profile-smoke' "$t/r-b" \
    && [ ! -e "$H/3.started" ] && [ ! -e "$H/4.started" ] \
    || { echo "FAIL: jobs fail-fast (rc $rc, $(lines "$t/r-b"), $(ls "$H" | tr '\n' ' '))"; return 1; }
  # (a2) order across the tail: only 2 is serial; it runs after the pool, its line stays second.
  for n in 1 3 4; do jf "$n" "echo \"PASS $n\"" "touch \"\$H/$n.done\""; done
  jf 2 '[ -e "$H/1.done" ] && [ -e "$H/3.done" ] && [ -e "$H/4.done" ] || { touch "$H/2.alone-broken"; exit 1; }' 'echo "PASS 2"'
  jser 2
  jrun a2; rc=$?
  order="$(lines "$t/r-a2")"
  [ "$rc" = 0 ] && [ "$order" = "ok team-setup-smoke,ok team-profile-smoke,ok team-tracker-smoke,ok team-tracker-sync-smoke" ] \
    || { echo "FAIL: jobs tail order (rc $rc, $order)"; return 1; }
  # (b3) the status survives the timing record.
  jf 1 'echo "PASS partial"' 'exit 7'; for n in 2 3 4; do jf "$n" "echo \"PASS $n\""; done
  jrun b3 TEAM_SUITE_CASE_TIMES=1; rc=$?
  [ "$rc" = 1 ] && grep -q '^FAIL team-setup-smoke rc 7' "$t/r-b3" && grep -q "$(printf '\tend$')" "$t/o-b3/team-setup-smoke.cases" \
    || { echo "FAIL: jobs status with timing (rc $rc, $(lines "$t/r-b3"))"; return 1; }
  # (b4) an interrupt ends the running steps' process groups and never reports OK.
  jf 1 'sleep 30 & echo $! > "$H/child.pid"' 'wait'; for n in 2 3 4; do jf "$n" 'w "[ -e \"\$H/never\" ]"'; done
  rm -rf "$H"; mkdir -p "$H"
  TEAM_SUITE_TESTS="$t" TEAM_SUITE_ONLY="$J4" TEAM_SUITE_SKIP= TEAM_SUITE_SELFTEST=0 TEAM_SUITE_CASE_TIMES= \
    TEAM_SUITE_JOBS=2 bash "$HERE/team-suite.sh" --out "$t/o-b4" > "$t/r-b4" 2>&1 & bp=$!
  for n in $(seq 1 100); do [ -s "$H/child.pid" ] && break; sleep 0.1; done
  kill -TERM "$bp" 2>/dev/null; wait "$bp"; rc=$?
  v=""; for n in $(seq 1 20); do kill -0 "$(cat "$H/child.pid" 2>/dev/null)" 2>/dev/null || { v=gone; break; }; sleep 0.1; done
  [ "$rc" != 0 ] && [ -s "$H/child.pid" ] && [ "$v" = gone ] && ! grep -q '^team-suite: OK' "$t"/o-b4/suite-*.log \
    && grep -q '^interrupted' "$t/r-b4" \
    || { echo "FAIL: jobs interrupt (rc $rc, child ${v:-alive}, $(tail -n 3 "$t/r-b4" | tr '\n' ' '))"; return 1; }
  # (b5) a skipped step keeps its place in the log.
  jf 1 'sleep 0.5' 'echo "PASS 1"'; for n in 2 3 4; do jf "$n" "echo \"PASS $n\""; done
  jrun b5 TEAM_SUITE_SKIP=team-profile-smoke; rc=$?
  order="$(lines "$t/r-b5")"
  [ "$rc" = 0 ] && [ "$order" = "ok team-setup-smoke,skip team-profile-smoke,ok team-tracker-smoke,ok team-tracker-sync-smoke" ] \
    || { echo "FAIL: jobs skip order (rc $rc, $order)"; return 1; }
  # (b2) 0 checks fails out of order behind a still-running head; nothing more starts.
  jf 1 'w "[ -e \"\$H/2.done\" ]"' 'sleep 0.5' 'echo "PASS 1"'; jf 2 'touch "$H/2.done"' 'exit 0'
  jf 3 'echo "PASS 3"'; jf 4 'echo "PASS 4"'
  jrun b2; rc=$?
  [ "$rc" = 1 ] && grep -q '^FAIL team-profile-smoke 0 checks' "$t/r-b2" && grep -q '^ok team-setup-smoke' "$t/r-b2" \
    && [ ! -e "$H/3.started" ] \
    || { echo "FAIL: jobs zero checks (rc $rc, $(lines "$t/r-b2"))"; return 1; }
  # (c) isolation: four different HOME and TMPDIR, the serial one too, all under this run's job root;
  # a relative --out lands under the caller's cwd.
  for n in 1 2 3 4; do jf "$n" "echo \"PASS $n\""; done; jser 4
  rm -rf "$H"; mkdir -p "$H"
  (cd "$t" && TEAM_SUITE_TESTS="$t" TEAM_SUITE_ONLY="$J4" TEAM_SUITE_SKIP= TEAM_SUITE_SELFTEST=0 TEAM_SUITE_CASE_TIMES= \
    TEAM_SUITE_JOBS=2 bash "$HERE/team-suite.sh" --out rel-out > "$t/r-c" 2>&1); rc=$?
  v=0
  for n in 1 2 3 4; do
    while IFS= read -r f; do case "$f" in "${TMPDIR%/}"/team-suite-jobs.*) ;; *) v=1 ;; esac; done < "$H/$n.env"
  done
  [ "$rc" = 0 ] && [ "$v" = 0 ] && [ "$(awk 'FNR == 1' "$H"/[1-4].env | sort -u | wc -l | tr -d ' ')" = 4 ] \
    && [ "$(awk 'FNR == 2' "$H"/[1-4].env | sort -u | wc -l | tr -d ' ')" = 4 ] && [ -f "$t/rel-out/team-setup-smoke.out" ] \
    || { echo "FAIL: jobs isolation (rc $rc, $(cat "$H"/[1-4].env 2>/dev/null | tr '\n' ' '))"; return 1; }
  # (d) refusals before any step.
  TEAM_SUITE_TESTS="$t" TEAM_SUITE_ONLY="$J4" TEAM_SUITE_SKIP= TEAM_SUITE_SELFTEST=0 TEAM_SUITE_JOBS=2 \
    bash "$HERE/team-suite.sh" --parallel --out "$t/o-d1" > "$t/r-d1" 2>&1; rc=$?
  [ "$rc" = 2 ] && grep -q 'exclusive' "$t/r-d1" || { echo "FAIL: --parallel with TEAM_SUITE_JOBS was not refused"; return 1; }
  TEAM_SUITE_TESTS="$t" TEAM_SUITE_ONLY="$J4" TEAM_SUITE_SKIP= TEAM_SUITE_SELFTEST=0 TEAM_SUITE_JOBS=x \
    bash "$HERE/team-suite.sh" --out "$t/o-d2" > "$t/r-d2" 2>&1; rc=$?
  [ "$rc" = 2 ] && grep -q 'positive integer' "$t/r-d2" || { echo "FAIL: TEAM_SUITE_JOBS=x was not refused"; return 1; }
}
if [ "${TEAM_SUITE_SELFTEST:-1}" != 0 ]; then step self-test self_test; fi

# ---- 1. purity ---------------------------------------------------------------------------------
add 0 purity bash "$TESTS/team-purity.sh"

# ---- 2. smoke parts, by name, serial parts last -------------------------------------------------
if [ -f "$TESTS/team-smoke.sh" ]; then
  [ "${#ALL[@]}" -gt 0 ] || { say "FAIL smoke — no parts list in team-smoke.sh"; RC=1; [ -n "$KEEP" ] || finish; }
  serial() { grep -qx '# team-smoke: serial' "$TESTS/team-smoke-$1.sh" 2>/dev/null; }
  if [ -n "$PARALLEL" ]; then
    step smoke-parallel env TEAM_SMOKE_PARALLEL=1 bash "$TESTS/team-smoke.sh"
  else
    for p in "${ALL[@]}"; do
      [ "$p" != purity ] && ! serial "$p" || continue
      add 0 "smoke-$p" env TEAM_SMOKE_PART="$p" bash "$TESTS/team-smoke.sh"
    done
    for p in "${ALL[@]}"; do
      serial "$p" || continue
      add 1 "smoke-$p" env TEAM_SMOKE_PART="$p" bash "$TESTS/team-smoke.sh"
    done
  fi
fi

# ---- 3. standalone suites (cost-tests carries the costs unittest) -------------------------------
sserial() { grep -qx '# team-suite: serial' "$TESTS/$1.sh" 2>/dev/null; }
for s in "${STANDALONE[@]}"; do
  if sserial "$s"; then add 1 "$s" bash "$TESTS/$s.sh"; else add 0 "$s" bash "$TESTS/$s.sh"; fi
done

# ---- 4. agent-mail unittest --------------------------------------------------------------------
add 0 agent-mail-unittest python3 -I -B -m unittest discover -s tools/agent_mail/tests -t .

# ---- 5. the shipped role profiles (P5; absent before it lands) ----------------------------------
if [ -f "$ROOT/.claude/lib/session_profile_check.py" ]; then
  add 0 session-profiles python3 -I "$ROOT/.claude/lib/session_profile_check.py" "$ROOT"
elif want session-profiles && ! skipped session-profiles; then
  add_note session-profiles "skip session-profiles — .claude/lib/session_profile_check.py not present at this sha"
fi

[ "$JOBS" = 1 ] || run_jobs
finish
