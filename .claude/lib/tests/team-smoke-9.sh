#!/usr/bin/env bash
# a dim prompt suggestion parses as an empty input (the doorbell's idle check relies on it).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
PY="$SRC/.claude/lib/team_prompt.py"
pj() {  # pj <file> <jq condition> — parser output check
  python3 -I "$PY" parse < "$1" > "$WORK/p.json"
  jq -e "$2" "$WORK/p.json" >/dev/null || { cp "$WORK/p.json" "$WORK/out"; fail "parse $1: $2"; }
}

# ---- (160) parser: a dim suggestion reads as an empty input ---------------------------------
# -cursor-tmux.txt is how tmux 3.7c captures the cursor cell: no 27, the next SGR closes it.
for f in idle-ghost.txt idle-ghost-cursor.txt idle-ghost-cursor-tmux.txt; do
  pj "$FIX/$f" '.kind == "none" and .complete and .input_empty and .input == ""'
  cmp -s <(python3 -I "$PY" parse < "$FIX/$f") <(python3 -I "$PY" parse < "$FIX/idle.txt") \
    || fail "$f does not parse like idle.txt"
  ! python3 -I "$PY" strip < "$FIX/$f" | grep -q $'\x1b' || fail "strip left escapes in $f"
done
sed $'s/^❯ $/❯ \x1b[31mhello\x1b[39m/' "$FIX/idle.txt" > "$WORK/coloured"
pj "$WORK/coloured" '.kind == "none" and .input == "hello"'
sed $'s/^❯ $/❯ \x1b[38;5;2mhello\x1b[39m/' "$FIX/idle.txt" > "$WORK/colour2"
pj "$WORK/colour2" '.input == "hello"'
echo "team-smoke-9: (160) ghost parse OK"

echo "team-smoke-9: OK"
