#!/usr/bin/env bash
# a dim prompt suggestion is no draft, Enter only once the text is on screen, finish once.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-1246 chore/AB-1246-x
RUN_ID=alfa-20261025-180000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
Q="bash .claude/lib/team-question.sh"
PY="$SRC/.claude/lib/team_prompt.py"
export STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane" TEAM_CONFIRM_SECS=1
qf() { echo "$RD/questions/$1.md"; }
qid() { head -n 1 "$WORK/out" | cut -d' ' -f1; }
keyc() { grep -c '^tmux send-keys ' "$STUB_LOG" || true; }
keys() { grep '^tmux send-keys ' "$STUB_LOG" | sed 's/^tmux send-keys -t %1 //' | paste -sd '|' -; }
setpane() { cp "$1" "$WORK/pane"; }
pj() {  # pj <file> <jq condition> — parser output check
  python3 -I "$PY" parse < "$1" > "$WORK/p.json"
  jq -e "$2" "$WORK/p.json" >/dev/null || { cp "$WORK/p.json" "$WORK/out"; fail "parse $1: $2"; }
}
state() { (. "$SRC/.claude/lib/team-lib.sh"; team_q_state "$(qf "$1")" | cut -f1); }

SID=sid-coder-1; session coder 1 "$BASE" "$SID"; T="$(transcript "$SID")"
mkdir -p "$(dirname "$T")"
jq -cn '{type: "assistant", uuid: "a-w", message: {content: [{type: "text", text: "wait"}]}}' > "$T"
said() { jq -cn --arg t "$1" '{type: "user", uuid: "u-said", message: {content: $t}}'; }

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
[ "$(python3 -I "$PY" typed "Try" < "$FIX/idle-ghost.txt")" = no ] || fail "ghost read as typed"
# Text elsewhere on screen (an option label, the footer) is not the active field.
for c in "menu-phase0.txt:brainstorm" "menu-phase0.txt:Tak, quick-change" "idle.txt:Opus"; do
  [ "$(python3 -I "$PY" typed "${c#*:}" < "$FIX/${c%%:*}")" = no ] || fail "typed outside field: $c"
done
sed 's/^❯ $/❯ 1. Use the counter./' "$FIX/idle.txt" > "$WORK/numbered"
[ "$(python3 -I "$PY" typed "1. Use the counter." < "$WORK/numbered")" = yes ] \
  || fail "a numbered say answer does not read as typed"
echo "team-smoke-9: (160) ghost parse OK"

# ---- (161) AC1: say to an idle role with a suggestion is delivered --------------------------
record --verdict blocked --message "ghost case" >/dev/null
setpane "$FIX/idle-ghost.txt"
run "$MAIN" $Q alfa open coder --kind blocked --summary "ghost case"; expect 0 "" "open ghost"
QG="$(qid)"; : > "$STUB_LOG"; said "Counter." > "$WORK/said"
STUB_ON_SENDKEYS="case \"\$*\" in *' Enter') cat '$WORK/said' >> '$T' ;; esac" \
  run "$MAIN" $Q alfa answer "$QG" --tier 1 --author s --why w --text "Counter." --send say
expect 0 "$QG state=consumed" "say on a ghost"
[ "$(keys)" = "-l -- Counter.|Enter" ] || fail "say on a ghost: keys $(keys)"
echo "team-smoke-9: (161) say over a prompt suggestion OK"

# ---- (162) AC2: a long Other text gets its Enter only after it shows -----------------------
QTEXT="$(python3 -I "$PY" parse < "$FIX/menu-phase0.txt" | jq -r '.question | join(" ")')"
TEXT="Use the counter with exponential backoff, capped at five attempts; keep the dead-letter"
TEXT="$TEXT table out of this ticket and log each retry with the job id so the operator can follow"
TEXT="$TEXT it in Application Insights without opening the database, then record the decision in"
TEXT="$TEXT the plan notes for QA."
LAST=""
menu_q() {  # menu_q <tool_use id> → QM, a menu q of a new AskUserQuestion instance
  [ -z "$LAST" ] || tool_done "$SID" "$LAST"
  pending_tool "$SID" "$1" AskUserQuestion \
    "$(jq -cn --arg q "$QTEXT" '{questions: [{question: $q}]}')"
  LAST="$1"; setpane "$FIX/menu-phase0.txt"
  run "$MAIN" $Q alfa open coder --kind menu --anchor "Phase 0" --summary "menu $1"
  expect 0 "" "open menu $1"; QM="$(qid)"; : > "$STUB_LOG"; rm -f "$WORK/caps"
}
other() { run "$MAIN" $Q alfa answer "$QM" --tier 1 --author s --why w --text "$TEXT" \
  --send other; }
# menu-other-typed.txt is constructed from menu-phase0.txt: no live capture of a typed Other row.
[ "$(python3 -I "$PY" typed "$TEXT" < "$FIX/menu-other-typed.txt")" = yes ] \
  || fail "the typed Other fixture does not hold the text"
[ "${#TEXT}" -gt 120 ] || fail "the text is not wider than the pane"
menu_q toolu_m1
jq -cn '{type: "user", uuid: "u-m1", message: {content: [{type: "tool_result",
  tool_use_id: "toolu_m1"}]}}' > "$WORK/done-m1"
STUB_ECHO=0 STUB_ON_CAPTURE="if grep -q -- ' -l -- ' \"\$STUB_LOG\"; then
    c=\$((\$(cat '$WORK/caps' 2>/dev/null || echo 0) + 1)); echo \$c > '$WORK/caps'
    if [ \$c -le 2 ]; then echo frame:menu >> \"\$STUB_LOG\"
    else cp '$FIX/menu-other-typed.txt' '$WORK/pane'; echo frame:typed >> \"\$STUB_LOG\"; fi; fi" \
  STUB_ON_SENDKEYS="case \"\$*\" in *' Enter') cat '$WORK/done-m1' >> '$T' ;; esac" other
expect 0 "$QM state=consumed" "long Other text"
grep -qx 'confirmed: yes (tool_result)' "$(qf "$QM")" || fail "long Other: no tool_result confirm"
awk '/ -l -- /{t=1; next} t && /^frame:typed$/{n++} t && /^frame:menu$/{m++}
  t && / Enter$/{exit !(n >= 2 && m >= 1)}' "$STUB_LOG" \
  || { cp "$STUB_LOG" "$WORK/out"; fail "Enter before two typed frames"; }
[ "$(keys | sed "s/-l -- .*|/-l|/")" = "Down|Down|-l|Enter" ] || fail "long Other: keys $(keys)"
echo "team-smoke-9: (162) long Other text OK"

# ---- (163) the typed frame never shows: no Enter, unknown -----------------------------------
menu_q toolu_m2
STUB_ECHO=0 TEAM_TYPED_SECS=1 other
expect 4 "typed text not on screen — Enter not sent" "typed frame never shows"
[ "$(state "$QM")" = unknown ] || fail "timeout: state $(state "$QM")"
! keys | grep -q 'Enter' || fail "timeout: an Enter was sent"
echo "team-smoke-9: (163) no Enter without the text OK"

# ---- (164) AC3: finish sends the missing Enter once ---------------------------------------
QU="$QM"; setpane "$FIX/menu-other-typed.txt"; : > "$STUB_LOG"
run "$MAIN" $Q alfa finish "$QU" --run other-run
expect 1 "stale: run changed" "finish with a stale run"
[ "$(keyc)" = 0 ] || fail "stale finish sent keys"
run "$MAIN" $Q alfa finish "$QU" --run "$RUN_ID"
expect 0 "finish enter" "finish on the typed frame"
[ "$(keys)" = "Enter" ] || fail "finish: keys $(keys)"
grep -q '^finished: ' "$(qf "$QU")" || fail "finish: no finished mark"
grep -qx 'finish: enter — the text is in the Other field' "$(qf "$QU")" || fail "finish: no outcome"
[ "$(state "$QU")" = sent ] || fail "finish: state $(state "$QU")"
: > "$STUB_LOG"
run "$MAIN" $Q alfa finish "$QU" --run "$RUN_ID"
expect 1 "already finished once" "second finish"
[ "$(keyc)" = 0 ] || fail "second finish sent keys"
echo "team-smoke-9: (164) finish once OK"

# ---- (165) finish on a question already gone sends nothing --------------------------------
menu_q toolu_m3
STUB_ECHO=0 TEAM_TYPED_SECS=1 other; expect 4 "" "unknown before a gone question"
tool_done "$SID" toolu_m3; LAST=""; : > "$STUB_LOG"
run "$MAIN" $Q alfa finish "$QM" --run "$RUN_ID"
expect 0 "finish none — delivered (tool_result)" "finish on a gone question"
[ "$(keyc)" = 0 ] || fail "finish on a gone question sent keys"
[ "$(state "$QM")" = consumed ] || fail "gone question: state $(state "$QM")"
run "$MAIN" $Q alfa finish "$QM" --run "$RUN_ID"
expect 1 "is consumed — nothing to finish" "finish after delivered"
echo "team-smoke-9: (165) finish on a gone question OK"

# ---- (166) finish of an untyped say on a suggestion types the text, then Enter ------------
record --verdict blocked --message "say timeout" >/dev/null
setpane "$FIX/idle-ghost-cursor.txt"
run "$MAIN" $Q alfa open coder --kind blocked --summary "say timeout"; QS="$(qid)"; : > "$STUB_LOG"
STUB_ECHO=0 TEAM_TYPED_SECS=1 \
  run "$MAIN" $Q alfa answer "$QS" --tier 1 --author s --why w --text "Table." --send say
expect 4 "" "say whose text never shows"
# The role never took in the text: the stub pane forgets it, as the real field would be empty.
rm -f "$STUB_LOG.typed"; : > "$STUB_LOG"; said "Table." > "$WORK/said"
STUB_ON_SENDKEYS="case \"\$*\" in *' Enter') cat '$WORK/said' >> '$T' ;; esac" \
  run "$MAIN" $Q alfa finish "$QS" --run "$RUN_ID"
expect 0 "$QS state=consumed — finish text" "finish of an untyped say"
[ "$(keys)" = "-l -- Table.|Enter" ] || fail "finish say: keys $(keys)"
echo "team-smoke-9: (166) finish types a missing say OK"

echo "team-smoke-9: OK"
