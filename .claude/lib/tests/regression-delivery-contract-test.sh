#!/usr/bin/env bash
# Offline contract test of the regression delivery texts (#336): regression.md §16 is the one rule
# home (brainstorm, plan + quick-change, execute, gate, backlog, team); every command and team
# prompt points at its subsection; and the guarded-line rule — every line of an edited command or
# prompt that carries a new regression output literal also names .claude/regression.json, the
# textual half of "regression off → none of this text" (the behavioural half: the not-adopted
# case of regression-crosscheck.test.mjs). Text checks only; a missing file fails.
#
# Usage: bash .claude/lib/tests/regression-delivery-contract-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

RG=.agents/reference/regression.md
BR=.claude/commands/brainstorm.md
PF=.claude/commands/plan-feature.md
QC=.claude/commands/quick-change.md
EX=.claude/commands/execute.md
VI=.claude/commands/gates/verify-implementation.md
CB=.claude/commands/check-backlog.md
UB=.claude/commands/update-backlog.md
PL=.claude/team/prompts/planner.md
CO=.claude/team/prompts/coder.md
TP=.claude/team/prompts/teamlead.md
TL=.agents/reference/team-lead.md
TM=.agents/reference/team-mode.md

FAILS=()
N=0
check() {  # check <rc> <what>
  N=$((N + 1))
  [ "$1" -eq 0 ] || FAILS+=("$2")
}
has() {  # has <file> <literal> — fails closed on a missing file
  [ -f "$ROOT/$1" ] && grep -qF -- "$2" "$ROOT/$1"
}

for f in "$RG" "$BR" "$PF" "$QC" "$EX" "$VI" "$CB" "$UB" "$PL" "$CO" "$TP" "$TL" "$TM"; do
  [ -f "$ROOT/$f" ]; check $? "missing file $f"
done

# One literal per line: <file variable>|<literal>. The first `|` splits; the literal may hold more.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  var=${line%%|*}; lit=${line#*|}
  file=${!var}
  has "$file" "$lit"; check $? "$file lacks: $lit"
done <<'EOF'
RG|## 13. Delivery — scenarios with every Task
RG|### 16.1
RG|### 16.6
RG|**Scenarios:**
RG|Proof: scenario — <ID>
RG|--planning
RG|(Expected <d>)
RG|--candidate <dir>
RG|delta: not evaluated — no base
BR|regression.md §16.1
PF|regression.md §16.2
PF|Proof: scenario — <ID>
QC|regression.md §16.2
EX|regression.md §16.3
VI|regression.md §16.4
VI|Bash(node .claude/lib/regression/catalog.mjs:*)
VI|Regression catalog
CB|regression.md §16.5
UB|regression.md §16.5
UB|catalog.mjs --backlog --candidate .agents/.pending-update
PL|regression.md §16.6
CO|regression.md §16.6
TP|a changed `Expected` of a regression scenario that exists on the base branch
TL|a changed `Expected` of a regression scenario that exists on the base branch
TM|manual check: regression scenario
BR|Bash(node .claude/lib/regression/catalog.mjs:*)
PF|Bash(node .claude/lib/regression/catalog.mjs:*)
CB|Bash(node .claude/lib/regression/catalog.mjs:*)
UB|Bash(node .claude/lib/regression/catalog.mjs:*)
EOF

grep -qx '## 16. Delivery — scenarios with every Task' "$ROOT/$RG" 2>/dev/null; check $? "regression.md: §16 is not a whole-line heading"

# Guarded-line rule: the rule homes (regression.md) and the team references are exempt.
GUARD='.claude/regression.json'
for var in BR PF QC EX VI CB UB PL CO; do
  file=${!var}
  [ -f "$ROOT/$file" ] || continue
  for lit in 'Proof: scenario' 'Regression scenarios' '**Scenarios:**' 'Scenario:' 'Regression catalog' 'regression.md §16'; do
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      n=${hit%%:*}; text=${hit#*:}
      case "$text" in *"$GUARD"*) check 0 ok ;; *) check 1 "$file:$n: unguarded regression text" ;; esac
    done <<EOF
$(grep -nF -- "$lit" "$ROOT/$file")
EOF
  done
done

for f in "${FAILS[@]+"${FAILS[@]}"}"; do echo "FAIL [$f]"; done
if [ "${#FAILS[@]}" -ne 0 ]; then echo "regression-delivery-contract-test: FAIL (${#FAILS[@]} of $N checks)"; exit 1; fi
echo "regression-delivery-contract-test: OK ($N checks)"
