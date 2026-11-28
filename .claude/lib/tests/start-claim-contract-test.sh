#!/usr/bin/env bash
# Offline contract test of the claim at the start: /start-team and /start-task run Check → Claim →
# Confirm before the clone / the branch, the old late status move is gone, a resume never claims, a
# failed start releases the claim, and an own Jira claim is reused (held). A renamed or missing step
# heading fails closed. /start-team refuses a memory-only ticket (step 3a, team-scope.sh) between the
# ticket read and the claim, and a pending pre-mode close stops a new start. Text checks only — nothing is spawned, no tracker is called.
#
# Usage: bash .claude/lib/tests/start-claim-contract-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

TEAM=.claude/commands/start-team.md
TASK=.claude/commands/start-task.md
FAILS=()
N=0
check() {  # check <rc> <what>
  N=$((N + 1))
  [ "$1" -eq 0 ] || FAILS+=("$2")
}
has() { grep -qF -- "$2" "$ROOT/$1"; }
lacks() { ! grep -qF -- "$2" "$ROOT/$1"; }
# line_after <file> <ERE> <after> → the first matching line number greater than <after>, or empty.
line_after() {
  grep -nE -- "$2" "$ROOT/$1" 2>/dev/null | cut -d: -f1 | awk -v a="$3" '$1 > a { print; exit }'
}
# ordered <file> <ERE>… → 0 when each pattern first matches after the previous one (fail closed).
ordered() {
  local f="$1" at=0 n
  shift
  for re in "$@"; do
    n="$(line_after "$f" "$re" "$at")"
    [ -n "$n" ] || return 1
    at="$n"
  done
}
# section <file> <start ERE> <end ERE> → the lines from the start match to the line before the end.
section() {
  local a b
  a="$(line_after "$1" "$2" 0)"; [ -n "$a" ] || return 1
  b="$(line_after "$1" "$3" "$a")"; [ -n "$b" ] || return 1
  sed -n "${a},$((b - 1))p" "$ROOT/$1"
}

for f in "$TEAM" "$TASK" .claude/lib/team-claim.sh .claude/lib/team-scope.sh; do
  [ -f "$ROOT/$f" ]; check $? "missing file $f"
done

ordered "$TEAM" '^3b\. \*\*Claim the ticket\*\*' '\*\*Check\.\*\*' '\*\*Claim\.\*\*' '\*\*Confirm\.\*\*' \
  '^4\. \*\*Clone\.\*\*'
check $? "start-team: Check, Claim, Confirm precede the clone step"
ordered "$TEAM" '^3\. \*\*Ticket \+ branch name\.\*\*' '^3a\. \*\*Memory-only ticket\*\*' 'team-scope\.sh memory-only' '^3b\. \*\*Claim the ticket\*\*'
check $? "start-team: the memory-only refusal (3a) runs after the ticket read and before the claim"
has "$TEAM" 'Bash(bash .claude/lib/team-scope.sh:*)'
check $? "start-team allows team-scope.sh"
s="$(section "$TEAM" '^2\. \*\*RESUME\*\*' '^3\. ')" && ! printf '%s\n' "$s" | grep -qF 'team-scope.sh'
check $? "start-team: a resume runs no memory-only check"
s="$(section "$TEAM" '^3b\. ' '\*\*Check\.\*\*')" && printf '%s\n' "$s" | grep -qF 'closed: abandon-before-mode' \
  && printf '%s\n' "$s" | grep -qF 'team-inbox.sh list Supervisor'
check $? "start-team: a pending pre-mode close stops a new start before the claim"
ordered "$TASK" '^### 6b\. Claim the ticket' '\*\*Check\.\*\*' '\*\*Claim\.\*\*' '\*\*Confirm\.\*\*' \
  '^### 7\. Create or resume the working branch'
check $? "start-task: Check, Claim, Confirm precede the branch step"

lacks "$TEAM" 'set-status <KEY> started' && ! grep -qE '^4b\.' "$ROOT/$TEAM"
check $? "start-team: the old step 4b status move is gone"
lacks "$TASK" 'set-status KEY started' && ! grep -qE '^### 7b\.' "$ROOT/$TASK"
check $? "start-task: the old step 7b status move is gone"

s="$(section "$TEAM" '^2\. \*\*RESUME\*\*' '^3\. ')" && ! printf '%s\n' "$s" | grep -qF 'team-claim.sh'
check $? "start-team: the RESUME step never claims"
s="$(section "$TASK" '^### 6b\. ' '^### 7\. ')" && printf '%s\n' "$s" | grep -qF 'refs/heads/<BRANCH>'
check $? "start-task: a local branch skips the claim"

has "$TEAM" 'team-claim.sh release' && has "$TASK" 'team-claim.sh release'
check $? "both commands release a claim on a failed start"
has "$TEAM" 'team-claim.sh claim' && has "$TASK" 'team-claim.sh claim' \
  && has "$TEAM" 'Bash(bash .claude/lib/team-claim.sh:*)' && has "$TASK" 'Bash(bash .claude/lib/team-claim.sh:*)'
check $? "both commands claim through team-claim.sh"

held=0
s="$(section "$TEAM" '^3b\. \*\*Claim the ticket\*\*' '^4\. \*\*Clone\.\*\*')" \
  && printf '%s\n' "$s" | grep -qF '**Held**' && printf '%s\n' "$s" | grep -qF 'never a second claim' || held=1
s="$(section "$TASK" '^### 6b\. Claim the ticket' '^### 7\. ')" \
  && printf '%s\n' "$s" | grep -qF '**Held**' && printf '%s\n' "$s" | grep -qF 'never a second claim' || held=1
check "$held" "both commands reuse an own Jira claim (held)"

for f in "${FAILS[@]+"${FAILS[@]}"}"; do echo "FAIL [$f]"; done
[ "${#FAILS[@]}" -eq 0 ] || exit 1
echo "start-claim-contract-test: OK ($N checks)"
