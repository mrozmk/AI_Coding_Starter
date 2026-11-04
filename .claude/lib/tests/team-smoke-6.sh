#!/usr/bin/env bash
# wrapped Bash description, transient review frames, footered review, prompt still
# rendering at open, parser-first snapshot detection, revoke on a spinner-only busy role.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-1157 chore/AB-1157-parser
RUN_ID=alfa-20261020-110000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
Q="bash .claude/lib/team-question.sh"
PY="$SRC/.claude/lib/team_prompt.py"
RULE="$(printf '─%.0s' $(seq 120))"
export STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane"
qf() { echo "$RD/questions/$1.md"; }
qid() { head -n 1 "$WORK/out" | cut -d' ' -f1; }
keyc() { grep -c '^tmux send-keys ' "$STUB_LOG" || true; }
no_keys() { [ "$(keyc)" = 0 ] || fail "$1: keys were sent"; }
setpane() { cp "$1" "$WORK/pane"; }
pj() {  # pj <fixture> <jq condition> — parser output check
  python3 -I "$PY" parse < "$1" > "$WORK/p.json"
  jq -e "$2" "$WORK/p.json" >/dev/null || { cp "$WORK/p.json" "$WORK/out"; fail "parse $1: $2"; }
}
fpof() { python3 -I "$PY" parse < "$1" | jq -r .fp; }
ev() { python3 -I "$PY" parse < "$1" | python3 -I "$PY" event "$2" "$3"; }

# ---- (110) C2: a wrapped Bash description binds to its tool_use ------------------------------
# perm-desc-wrap.txt is constructed from the real layout of perm-awk.txt (no wrapped capture).
WRAP="Fetch the current description of PR 8583 into the scratchpad so the gate can"
WRAP="$WRAP compare it with the draft"
pj "$FIX/perm-desc-wrap.txt" '.kind == "permission" and .complete and .desc == "'"$WRAP"'"'
pj "$FIX/perm-awk.txt" '.desc == "Fetch current PR 8583 description"'
twrap() {  # twrap <description> → $WORK/t-wrap.jsonl, the perm-awk call with that description
  grep toolu_018q18 "$FIX/t-bash-pending.jsonl" \
    | jq -c --arg d "$1" '.message.content[0].input.description = $d' > "$WORK/t-wrap.jsonl"
}
twrap "$WRAP"
[ "$(ev "$FIX/perm-desc-wrap.txt" "$WORK/t-wrap.jsonl" permission)" = toolu_018q18 ] \
  || fail "wrapped description not bound to its tool_use"
twrap "Something else entirely"
[ "$(ev "$FIX/perm-desc-wrap.txt" "$WORK/t-wrap.jsonl" permission)" = ambiguous ] \
  || fail "a different description was bound"
DASH="$(printf '╌%.0s' $(seq 120))"
{ echo "$RULE"; echo " Bash command"; echo "$DASH"; echo " │ ls"; echo "$DASH"
  echo " Do you want to proceed?"; echo " ❯ 1. Yes"; echo "   2. No"; echo " Esc to cancel"; } \
  > "$WORK/nodesc"
pj "$WORK/nodesc" '.kind == "permission" and .complete and .desc == "" and .command == "ls"'
echo "team-smoke-6: (110) wrapped description OK"

# ---- (111) C3: transient frames before the review, closed event ------------------------------
SID=sid-planner-1; session planner 1 "$BASE" "$SID"; T="$(transcript "$SID")"
sed 's/^❯ 1\. \[ \] Apple/  1. [ ] Apple/; s/^     Submit$/❯    Submit/' "$FIX/checkbox.txt" \
  > "$WORK/submit-frame"
pj "$WORK/submit-frame" '(.complete | not) and .reason == "unreadable: missing unique Submit row"'
LASTC=""
fresh_menu() {  # fresh_menu <tool_use id> → QC, a new checkbox instance opened on the ledger
  [ -z "$LASTC" ] || tool_done "$SID" "$LASTC"
  pending_tool "$SID" "$1" AskUserQuestion '{"questions":[{"question":"Pick fruits"}]}'; LASTC="$1"
  setpane "$FIX/checkbox.txt"; rm -f "$WORK/mark"
  run "$MAIN" $Q alfa open planner --kind menu --anchor "Pick fruits" --summary "fruits $1"
  expect 0 "" "open checkbox $1"; QC="$(qid)"; : > "$STUB_LOG"
}
on_cap() {  # on_cap <first frame cmd> <later pane> — STUB_ON_CAPTURE after the 7 checkbox keys
  echo "if [ \"\$(grep -c '^tmux send-keys ' \"\$STUB_LOG\")\" -ge 7 ]; then
    if [ ! -e '$WORK/mark' ]; then $1; touch '$WORK/mark'; else cp '$2' '$WORK/pane'; fi; fi"
}
picks() { run "$MAIN" $Q alfa answer "$QC" --tier 1 --author s --why w --send picks:1,3; }
fresh_menu toolu_r1
STUB_ON_CAPTURE="$(on_cap "cp '$WORK/submit-frame' '$WORK/pane'" "$FIX/review.txt")" picks
expect 0 "$QC state=" "review after a transient Submit frame"
[ "$(keyc)" = 8 ] || fail "transient frame: $(keyc) keys, the final Enter expected"
fresh_menu toolu_r2
STUB_ON_CAPTURE="$(on_cap "cp '$WORK/submit-frame' '$WORK/pane'" "$WORK/submit-frame")" picks
expect 4 "review screen did not appear (last: missing unique Submit row); final Enter not sent" \
  "persistent unreadable frame"
[ "$(keyc)" = 7 ] || fail "persistent unreadable: $(keyc) keys"
fresh_menu toolu_r3
jq -cn '{type: "user", uuid: "u-r3", message: {content: [{type: "tool_result",
  tool_use_id: "toolu_r3"}]}}' > "$WORK/closed"
STUB_ON_CAPTURE="$(on_cap "cat '$WORK/closed' >> '$T'; cp '$FIX/review.txt' '$WORK/pane'" \
  "$FIX/review.txt")" picks
expect 4 "prompt event closed before review; final Enter not sent" "review after the call closed"
[ "$(keyc)" = 7 ] || fail "closed event: $(keyc) keys"
[ "$(python3 -I "$PY" pending "$T" toolu_r3)" = no ] || fail "pending of a closed call"
fresh_menu toolu_r4
[ "$(python3 -I "$PY" pending "$T" toolu_r4)" = yes ] || fail "pending of an open call"
{ sed 's/toolu_r3/toolu_r4/; s/u-r3/u-r4/' "$WORK/closed"; echo '{"type":"user"'; } > "$WORK/closed"
STUB_ON_CAPTURE="$(on_cap "cat '$WORK/closed' >> '$T'; cp '$FIX/review.txt' '$WORK/pane'" \
  "$FIX/review.txt")" picks
expect 4 "prompt event closed before review; final Enter not sent" "review, transcript unreadable"
[ "$(keyc)" = 7 ] || fail "unreadable transcript: $(keyc) keys"
[ "$(python3 -I "$PY" pending "$T" toolu_r4)" = unknown ] || fail "pending, malformed transcript"
echo "team-smoke-6: (111) transient review frames OK"

# ---- (112) C4: a review that ends in the menu footer ----------------------------------------
# review-footer.txt is constructed from the real layouts of review.txt and checkbox.txt.
pj "$FIX/review-footer.txt" '.kind == "review" and .complete and .review.ready
  and .review.submit_cursor'
[ "$(fpof "$FIX/review-footer.txt")" = "$(fpof "$FIX/review.txt")" ] \
  || fail "the footer changed the review fingerprint"
sed 's/<description>/Review your answers/' "$FIX/checkbox.txt" > "$WORK/quote-review"
pj "$WORK/quote-review" '.kind == "checkbox" and .other == 4'
sed '$d' "$WORK/quote-review" > "$WORK/quote-review-nofooter"
pj "$WORK/quote-review-nofooter" '.kind != "review"'
echo "team-smoke-6: (112) footered review OK"

# ---- (113) C5: a prompt still rendering is not a question yet -------------------------------
# An old prompt left in the scrollback never makes a later, unknown bottom "still rendering".
{ sed '$d' "$FIX/perm-awk.txt"; echo "⏺ Gotowe."; echo " Some dialog"; } > "$WORK/old-out"
pj "$WORK/old-out" '.reason == "unreadable: no idle input surface"'
{ sed '$d' "$FIX/perm-awk.txt"; echo "$RULE alfa-coder ─"; echo "❯ first line of a draft"
  echo "  second line"; echo "$RULE"; } > "$WORK/old-draft"
pj "$WORK/old-draft" '.reason == "unreadable: no idle input surface"'
SID=sid-coder-1; session coder 1 "$BASE" "$SID"
mkdir -p "$(dirname "$(transcript "$SID")")"
echo '{"type":"assistant","uuid":"a-c","message":{"content":[{"type":"text","text":"x"}]}}' \
  > "$(transcript "$SID")"
{ cat "$FIX/idle.txt"; echo "$RULE"; echo " Bash command"; echo " x"; } > "$WORK/pane"
n0="$(ls -1 "$RD/questions" | grep -c '^q-[0-9]*\.md$' || true)"
run "$MAIN" $Q alfa open coder --kind permission --anchor "Bash command" --summary "rendering"
expect 1 "prompt is still rendering" "open on a prompt still rendering"
[ "$(ls -1 "$RD/questions" | grep -c '^q-[0-9]*\.md$' || true)" = "$n0" ] \
  || fail "a q was created for a rendering prompt"
record --verdict blocked --message "rendering" >/dev/null
run "$MAIN" $Q alfa open coder --kind blocked --summary "rendering"
expect 0 "fingerprint deferred: prompt still rendering" "blocked open while rendering"
QB="$(qid)"
grep -qx 'fingerprint: -' "$(qf "$QB")" || fail "$QB fingerprint not deferred"
! grep -q '^unreadable:' "$(qf "$QB")" || fail "$QB stored unreadable"
setpane "$FIX/idle.txt"
run "$MAIN" $Q alfa open coder --kind blocked --summary "rendering"
expect 0 "(existing, state=open)" "blocked re-open after render"
grep -qx 'fingerprint: v2:none' "$(qf "$QB")" || fail "$QB not rebound after render"
echo "team-smoke-6: (113) prompt still rendering OK"

# ---- (114) snapshot detection follows the parse --------------------------------------------
STUB_PANE="$FIX/busy-stale-yes.txt" snap "busy with prompt-like text" \
  'coder | (.prompt_open | not) and (.menu_open | not)'
STUB_PANE="$FIX/perm-awk.txt" snap "permission prompt" \
  'coder | .prompt_open and .status == "attention" and (.actions[0] | endswith(" yes"))'
STUB_PANE="$FIX/menu-wrapup.txt" snap "menu" 'coder | .menu_open'
STUB_PANE="$FIX/idle.txt" snap "idle" 'coder | (.prompt_open | not) and (.menu_open | not)'
( . "$SRC/.claude/lib/team-lib.sh"; STUB_PANE="$FIX/busy-stale-yes.txt" \
  team_prompt_open alfa-coder ) \
  || fail "busy-stale-yes.txt no longer exercises the regex false positive"
echo "team-smoke-6: (114) parser-first detection OK"

# ---- (115) an unreadable screen falls back to the regexes ---------------------------------
printf 'Bash command\n  ls\nDo you want to proceed?\n❯ 1. Yes\n' > "$WORK/pane-min"
pj "$WORK/pane-min" '(.complete | not)'
STUB_PANE="$WORK/pane-min" snap "unreadable fallback" 'coder | .prompt_open'
echo "team-smoke-6: (115) regex fallback OK"

# ---- (116) revoke on a spinner-only busy role types nothing ---------------------------------
record --verdict blocked --message "revoke case" >/dev/null
setpane "$FIX/idle.txt"
run "$MAIN" $Q alfa open coder --kind blocked --summary "revoke case"; QR="$(qid)"
: > "$STUB_LOG"
echo '{"type":"user","uuid":"u-9","message":{"content":"Counter."}}' > "$WORK/said"
STUB_ON_SENDKEYS="cat '$WORK/said' >> '$(transcript "$SID")'" \
  run "$MAIN" $Q alfa answer "$QR" --tier 1 --author s --why w --text "Counter." --send say
expect 0 "$QR state=consumed" "say before the revoke"
setpane "$FIX/busy.txt"; : > "$STUB_LOG"
run "$MAIN" $Q alfa revoke "$QR" --why x
[ "$RC" != 0 ] || fail "revoke on a busy role succeeded"
sed -n '/^## Revoked/,$p' "$(qf "$QR")" | grep -qx 'delivery: not sent — stale (role is busy)' \
  || { cp "$(qf "$QR")" "$WORK/out"; fail "revoke delivery on a busy role"; }
no_keys "revoke on a busy role"
echo "team-smoke-6: (116) revoke on a busy role OK"

echo "team-smoke-6: OK"
