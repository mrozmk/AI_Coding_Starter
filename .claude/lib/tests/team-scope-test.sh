#!/usr/bin/env bash
# Offline unit test of team-scope.sh memory-only — the /start-team step 3a refusal of a ticket whose
# wanted change writes only under .agents/memory/: the path rule (guard-team-memory.sh's), the one
# refusal line and the exit codes. Nothing is spawned, no tracker is called.
#
# Usage: bash .claude/lib/tests/team-scope-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAILS=()
N=0
check() {  # check <rc> <what>
  N=$((N + 1))
  [ "$1" -eq 0 ] || FAILS+=("$2")
}
sc() { bash "$ROOT/.claude/lib/team-scope.sh" "$@" > "$T/out" 2>&1; echo $?; }

LINE='refused: #342 — memory-only change (.agents/memory/index.md): no team stage may write .agents/memory/ (guard-team-memory.sh) — do it in a solo session or ask the Supervisor'
[ "$(sc memory-only 342 .agents/memory/index.md)" = 3 ] && [ "$(cat "$T/out")" = "$LINE" ]
check $? "all-memory paths refuse with the one line"

[ "$(sc memory-only 342 ../AI_Coding_Starter/.agents/memory/index.md .agents/memory/decisions.md)" = 3 ]
check $? "a starter-relative memory path is memory"

[ "$(sc memory-only 7 .agents/memory)" = 3 ] && [ "$(sc memory-only 7 .agents/memory/)" = 3 ]
check $? "the bare directory is memory"

[ "$(sc memory-only 7 .agents/memory/index.md .claude/lib/prime-ba.mjs)" = 0 ] && [ ! -s "$T/out" ]
check $? "one non-memory path passes"

[ "$(sc memory-only 7 .agents/memory-old/x)" = 0 ] && [ "$(sc memory-only 7 docs/.agents-memory)" = 0 ] \
  && [ "$(sc memory-only 7 x.agents/memory/y)" = 0 ]
check $? "look-alike paths are not memory"

[ "$(sc memory-only 7)" = 2 ] && [ "$(sc memory-only)" = 2 ] && [ "$(sc nosuch 7 a)" = 2 ]
check $? "usage errors exit 2"

[ "$(sc memory-only '#9' .agents/memory/x)" = 3 ] && grep -q '^refused: #9 —' "$T/out"
check $? "a leading # in the key is not doubled"

for f in "${FAILS[@]+"${FAILS[@]}"}"; do echo "FAIL [$f]"; done
[ "${#FAILS[@]}" -eq 0 ] || exit 1
echo "team-scope-test: OK ($N checks)"
