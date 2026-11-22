# Per-case timer for the team suite — sourced, never run.
# case_mark <label> appends one tab-separated `<epoch>\t<label>` record to $TEAM_CASE_TIMES when it is
# set (team-suite.sh sets it with TEAM_SUITE_CASE_TIMES=1); unset, it does nothing. The suite adds a
# `start` record before the step and an `end` record after it, so each record opens one interval.
# Always returns 0, so `set -e` callers are safe. Bash 3.2: no EPOCHREALTIME, perl gives fractions.

case_now() {
  perl -MTime::HiRes=time -e 'printf "%.2f\n", time' 2>/dev/null || date +%s
}

case_mark() {
  [ -n "${TEAM_CASE_TIMES:-}" ] || return 0
  printf '%s\t%s\n' "$(case_now)" "$1" >> "$TEAM_CASE_TIMES" 2>/dev/null || true
  return 0
}

# case_under <s0> <s1> <c0> <c1> <margin> — a same-load latency proof: the slow run (s0→s1, case_now
# stamps) cost less than <margin> s over its control (c0→c1). Both share the machine's load, so only
# the extra work counts. Returns the verdict (unlike case_mark): callers assert on it.
case_under() {
  awk -v a="$1" -v b="$2" -v c="$3" -v d="$4" -v m="$5" 'BEGIN { exit !((b - a) - (d - c) < m) }'
}
