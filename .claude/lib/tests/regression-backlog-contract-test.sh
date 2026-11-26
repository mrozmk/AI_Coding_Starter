#!/usr/bin/env bash
# Offline contract test of the regression backlog texts (#335): quality-tasks.md is the one rule
# home (## Regression: markers, order, tags, retag, templates); the rubric grades K12; the backlog
# writers (create-backlog, backlog-author, delivery-plan, the Epic author and fixer, check-backlog,
# update-backlog) take REGRESSION and route a retag; /architect writes app_surface and names
# /setup:regression; /setup:start keeps and reads it; the question bank asks about the test
# environment. Text checks only; a missing file fails.
#
# Usage: bash .claude/lib/tests/regression-backlog-contract-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

QT=.claude/skills/backlog/quality-tasks.md
RB=.claude/skills/backlog/backlog-rubric.md
EA=.claude/agents/backlog-epic-author.md
EF=.claude/agents/backlog-epic-fixer.md
BA=.claude/agents/backlog-author.md
CR=.claude/commands/setup/create-backlog.md
DP=.claude/commands/setup/delivery-plan.md
AR=.claude/commands/architect.md
ST=.claude/commands/setup/start.md
QB=.claude/skills/discover/question-bank.md
CB=.claude/commands/check-backlog.md
UB=.claude/commands/update-backlog.md
PE=.claude/project-profile.json.example

FAILS=()
N=0
check() {  # check <rc> <what>
  N=$((N + 1))
  [ "$1" -eq 0 ] || FAILS+=("$2")
}
has() {  # has <file> <literal> — fails closed on a missing file
  [ -f "$ROOT/$1" ] && grep -qF -- "$2" "$ROOT/$1"
}

for f in "$QT" "$RB" "$EA" "$EF" "$BA" "$CR" "$DP" "$AR" "$ST" "$QB" "$CB" "$UB" "$PE"; do
  [ -f "$ROOT/$f" ]; check $? "missing file $f"
done

# One literal per line: <file variable>|<literal>. The first `|` splits; the literal may hold more.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  var=${line%%|*}; lit=${line#*|}
  file=${!var}
  has "$file" "$lit"; check $? "$file lacks: $lit"
done <<'EOF'
QT|## Regression
QT|| `[regression:foundation]` |
QT|| `[regression:baseline]` |
QT|| `[regression:smoke]` |
QT|outside the criterion fingerprint
QT|never lists a regression Task
QT|regression not adopted (no .claude/regression.json)
RB|**K12 Regression tags**
RB|not a bracket label
EA|| `REGRESSION` |
EA|only when `REGRESSION` is `on`
EF|protected — tags only
BA|| `REGRESSION` |
CR|| `REGRESSION` |
CR|web — not adopted
DP|REGRESSION: on | off
DP|regression tag:
DP|missing: ["tags"]
DP|protected — tags only
DP|K12
DP|.claude/regression.json and .claude/skills/backlog/quality-tasks.md when .claude/regression.json exists
AR|Phase 9b — App surface
AR|/setup:regression
AR|app_surface
ST|skipped(app_surface <value> — no browser QA)
ST|still `unknown`
ST|the answer given in this rerun
QB|Test environment and accounts
CB|RULES: K1,K2,K5,K7,K11,K12
CB|K1–K12
CB|`retag`
UB|`retag`
UB|the one edit a protected Task takes in place
PE|Written by /architect
EOF

grep -qx '## Regression' "$ROOT/$QT" 2>/dev/null; check $? "quality-tasks: ## Regression is not a whole-line heading"

for f in "${FAILS[@]+"${FAILS[@]}"}"; do echo "FAIL [$f]"; done
if [ "${#FAILS[@]}" -ne 0 ]; then echo "regression-backlog-contract-test: FAIL (${#FAILS[@]} of $N checks)"; exit 1; fi
echo "regression-backlog-contract-test: OK ($N checks)"
