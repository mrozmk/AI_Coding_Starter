#!/usr/bin/env bash
# Sender: team-answer menu, checkbox and say actions.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-799 chore/AB-799-tiers
RUN_ID=alfa-20261006-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
ANSWER="bash .claude/lib/team-answer.sh"
RULE="$(printf '─%.0s' $(seq 120))"; DASH="$(printf '╌%.0s' $(seq 120))"
printf '%s\n' "⏺ One question before the plan." "$RULE" " ☐ Retry" \
  "│ Which retry design for the worker?" "❯ 1. Counter + backoff (Recommended)" \
  "  2. Counter only" "  3. Dead-letter table" "  4. Type something." "$RULE" \
  "  5. Chat about this" "Enter to select · ↑/↓ to navigate · Esc to cancel" > "$WORK/menu"
{ cat "$WORK/menu"; echo "Review your answers"; } > "$WORK/multi"
printf '%s\n' "$RULE" " Bash command" " Deploy the web app" "$DASH" \
  " │ az webapp deploy --name shell-sk" "$DASH" " Do you want to proceed?" " ❯ 1. Yes" "   2. No" \
  " Esc to cancel · Tab to amend" > "$WORK/perm"
{ echo "⏺ > waiting for the supervisor's answer"; cat "$FIX/idle.txt"; } > "$WORK/idle"
downs() { grep -c 'send-keys -t %1 Down' "$STUB_LOG" || true; }
no_keys() { ! has "send-keys" "$STUB_LOG" || fail "$1: keys were sent"; }
expect_nz() { [ "$RC" != 0 ] || fail "$1: exit 0"; }

# ---- (29) team-answer menu actions ------------------------------------------------------------
session planner 1 "$BASE"
export STUB_PANE="$WORK/menu" STUB_TMUX_ALIVE=0
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa planner pick 2
expect 0 "sent pick to alfa-planner" "answer pick 2"
[ "$(downs)" = 1 ] || fail "pick 2 did not press Down once"
has "send-keys -t %1 Enter" "$STUB_LOG" || fail "pick 2 did not press Enter"
has "confirmed: no — prompt still open" "$WORK/out" || fail "pick 2 claimed consumption"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa planner pick 9
expect 6 "option 9 not on screen" "answer pick 9"; no_keys "pick 9"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa planner other "counter only, no table"
expect 0 "sent other" "answer other"
[ "$(downs)" = 3 ] || fail "other did not move to Type something."
has "send-keys -t %1 -l -- counter only, no table" "$STUB_LOG" || fail "other did not type"
has "send-keys -t %1 Enter" "$STUB_LOG" || fail "other did not press Enter"
# Under herdr (a herdr record for the address) `other` is deny + message (owner, 2026-11-15): esc on
# the open menu, then one hc send on the idle input, confirmed from the transcript; never typed into it.
mkdir -p "$MAIN/.agents/team/registry"
jq -n --arg td "$TD" '{address: "alfa-planner", kind: "team", backend: "herdr", handle: "t4p",
  name: "smk-alfa-planner", cli: "claude", team_dir: $td}' > "$MAIN/.agents/team/registry/alfa-planner.json"
echo blocked > "$WORK/hc-status"; mkdir -p "$(dirname "$(transcript sid-planner-1)")"
printf '%s\n' "jq -cn --arg t \"<hc from=\\\"t1\\\">\$1</hc>\" '{type: \"user\", message: {content: \$t}}' >> '$(transcript sid-planner-1)'" \
  > "$WORK/onsend"
: > "$STUB_LOG"; STUB_HC_ADDR=t4p STUB_HC_SCREEN="$WORK/menu" STUB_HC_STATUS_FILE="$WORK/hc-status" \
  STUB_HC_ON_SEND="bash '$WORK/onsend' \"\$3\"" run "$MAIN" $ANSWER alfa planner other "counter only, no table"
expect 0 "other→deny+message (herdr)" "answer other under herdr"
has "typed+submitted (transcript)" "$WORK/out" || fail "other under herdr: no transcript confirmation"
has "hc keys t4p esc" "$STUB_LOG" || fail "other under herdr: no esc"
[ "$(grep -c '^hc send ' "$STUB_LOG")" = 1 ] && has "hc send t4p counter only, no table" "$STUB_LOG" \
  || { cp "$STUB_LOG" "$WORK/out"; fail "other under herdr: not exactly one hc send"; }
! grep -qE '^hc keys t4p .*(enter|down)|send-keys' "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "other under herdr: typed into the menu"; }
rm -f "$MAIN/.agents/team/registry/alfa-planner.json"
: > "$STUB_LOG"; STUB_PANE="$WORK/perm" run "$MAIN" $ANSWER alfa planner pick 2
expect 6 "no single-question menu on screen" "pick on a permission prompt"
no_keys "pick on a permission prompt"
: > "$STUB_LOG"; STUB_PANE="$FIX/multi-tabs.txt" run "$MAIN" $ANSWER alfa planner pick 2
expect 5 "multi-question menu — answer in the window" "pick on a multi-question menu"
no_keys "pick on a multi-question menu"
: > "$STUB_LOG"; STUB_PANE="$WORK/multi" run "$MAIN" $ANSWER alfa planner pick 2
expect 3 "incomplete: prompt still rendering" "pick on a menu without its footer last"
no_keys "pick on a menu without its footer last"
run "$MAIN" $ANSWER alfa planner pick
expect 2 "" "pick without a number"

# ---- (30) say to a gone session ---------------------------------------------------------------
session coder 1 "$BASE"; export STUB_PANE="$WORK/idle"
: > "$STUB_LOG"; STUB_TMUX_ALIVE=1 run "$MAIN" $ANSWER alfa coder say "Table."
expect 6 "session gone" "say to a gone session"; no_keys "say to a gone session"

# ---- (33) say text with a leading dash --------------------------------------------------------
session coder 3 "$BASE"; export STUB_PANE="$WORK/idle"
: > "$STUB_LOG"
run "$MAIN" $ANSWER alfa coder say "-x starts with a dash"
expect 0 "sent say" "say text with a leading dash"
has "send-keys -t %1 -l -- -x starts with a dash" "$STUB_LOG" || fail "dash not typed"

# ---- (34) single-question multiSelect: live-probe renderer and exact delivery -----------------
cp "$FIX/checkbox.txt" "$WORK/checkbox"; cp "$FIX/review.txt" "$WORK/review"
sed 's/Apple, Cherry/none - skip all/' "$WORK/review" > "$WORK/review-none"
sed 's/Apple, Cherry/Banana/' "$WORK/review" > "$WORK/review-wrong"
sed 's/☐ Probe/☒ Probe/; s/2\. \[ \]/2. [✔]/' "$WORK/checkbox" > "$WORK/preselected"
sed 's/❯ 1\./  1./; s/  2\./❯ 2./' "$WORK/checkbox" > "$WORK/cursor2"
sed 's/☐ Probe/☒ Probe ☒ Another/' "$WORK/checkbox" > "$WORK/completed-multi"
sed 's/☐ Retry/←  ☐ Nadzorca  ☐ \/mail-role  ☐ Koniec etapu  ✔ Submit  →/' \
  "$WORK/menu" > "$WORK/multi-question"
sed 's/4\. \[ \]/4. [✔]/' "$WORK/checkbox" > "$WORK/selected-other"
sed 's/  2\. \[ \]/  8. [ ]/' "$WORK/checkbox" > "$WORK/gap"
tail -n +3 "$WORK/checkbox" > "$WORK/truncated"
# The terminal returns the review only after the expected Submit key. All keys remain logged.
cp "$WORK/bin/tmux" "$WORK/bin/tmux-base"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = capture-pane ] && [ "${STUB_MULTI:-0}" = 1 ]; then' \
  '  n=$(awk '"'"'/^tmux send-keys /{n++} END{print n+0}'"'"' "$STUB_LOG")' \
  '  [ "$n" -lt "$STUB_REVIEW_AFTER" ] || export STUB_PANE="$STUB_REVIEW"' \
  'fi' \
  'exec "$(dirname "$0")/tmux-base" "$@"' > "$WORK/bin/tmux"
chmod +x "$WORK/bin/tmux"
keys() { sed -n 's/^tmux send-keys -t %1 //p' "$STUB_LOG"; }
ms() {  # fixture, review, expected pre-confirmation key count
  export STUB_MULTI=1 STUB_PANE="$WORK/$1" STUB_REVIEW="$WORK/$2" STUB_REVIEW_AFTER="$3"
  : > "$STUB_LOG"
}
exact_keys() { [ "$(keys)" = "$1" ] || fail "checkbox keys: $(keys)"; }
ms checkbox review 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 0 "sent picks" "choose 1 and 3 then confirm review"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter\nEnter'
ms preselected review 8
run "$MAIN" $ANSWER alfa planner picks 3,1
expect 0 "sent picks" "normalize preselected Banana and unsorted requested set"
exact_keys $'Enter\nDown\nEnter\nDown\nEnter\nDown\nDown\nEnter\nEnter'
ms preselected review-none 8
run "$MAIN" $ANSWER alfa planner picks none
expect 0 "sent picks" "explicit skip clears earlier selection and types Other"
exact_keys $'Down\nEnter\nDown\nDown\nEnter\n-l -- none - skip all\nDown\nEnter\nEnter'
ms checkbox review 7
run "$MAIN" $ANSWER alfa planner picks
expect 2 "Usage:" "picks missing argument"; no_keys "missing picks argument"
for selection in '' '1,' '0' '1;3'; do
  : > "$STUB_LOG"; run "$MAIN" $ANSWER alfa planner picks "$selection"
  expect 2 "picks needs" "invalid picks syntax $selection"; no_keys "bad picks syntax"
done
for selection in 5 4 '1,99' '1,1'; do
  : > "$STUB_LOG"; run "$MAIN" $ANSWER alfa planner picks "$selection"
  expect 5 "answer in the window" "invalid option set $selection"; no_keys "bad option set"
done
for fixture in cursor2 completed-multi multi-question selected-other gap truncated multi menu perm
do
  ms "$fixture" review 7; run "$MAIN" $ANSWER alfa planner picks 1,3
  expect_nz "unsafe checkbox fixture $fixture"; no_keys "unsafe checkbox fixture"
done
ms cursor2 review 7; run "$MAIN" $ANSWER alfa planner picks 1,3
expect 6 "menu cursor is not on option 1" "checkbox cursor moved"
for action in pick other; do
  ms checkbox review 7; run "$MAIN" $ANSWER alfa planner "$action" 1
  expect 6 "no single-question menu on screen" "legacy $action refuses multiSelect"
  no_keys "legacy checkbox refusal"
done
ms checkbox review-wrong 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 4 "final Enter not sent" "refuse wrong answer in review"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter'
ms checkbox review-none 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 4 "final Enter not sent" "refuse unintended skip in review"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter'
sed 's/Ready to submit your answers?/⚠ You have not answered all questions/' \
  "$WORK/review" > "$WORK/review-unanswered"
ms checkbox review-unanswered 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 4 "final Enter not sent" "refuse unanswered review"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter'
sed 's/❯ 1\./  1./; s/  2\./❯ 2./' "$WORK/review" > "$WORK/review-cursor2"
ms checkbox review-cursor2 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 4 "final Enter not sent" "refuse wrong review cursor"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter'
# Under herdr (live, 2026-11-16): the stage's screens end with its session-name rule, and hc read
# --lines adds a note line of its own after a blocked screen (stub). picks still sends the same keys
# through hc and submits the review only once it is on screen.
unset STUB_MULTI
NAMED="$(printf '─%.0s' $(seq 40)) alfa-planner ─"
printf '%s\n' "$(cat "$WORK/checkbox")" "$NAMED" > "$WORK/h-checkbox"
printf '%s\n' "$(cat "$WORK/review")" "$NAMED" > "$WORK/h-review"
mkdir -p "$MAIN/.agents/team/registry"
jq -n --arg td "$TD" '{address: "alfa-planner", kind: "team", backend: "herdr", handle: "t4p",
  name: "smk-alfa-planner", cli: "claude", team_dir: $td}' > "$MAIN/.agents/team/registry/alfa-planner.json"
echo blocked > "$WORK/hc-status"
cp "$WORK/bin/hc" "$WORK/bin/hc-base"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = read ] && [ "$(grep -c "^hc keys " "$STUB_LOG")" -ge 7 ]; then export STUB_HC_SCREEN="$H_REVIEW"; fi' \
  'exec "$(dirname "$0")/hc-base" "$@"' > "$WORK/bin/hc"
chmod +x "$WORK/bin/hc"
: > "$STUB_LOG"; H_REVIEW="$WORK/h-review" STUB_HC_ADDR=t4p STUB_HC_SCREEN="$WORK/h-checkbox" \
  STUB_HC_STATUS_FILE="$WORK/hc-status" run "$MAIN" $ANSWER alfa planner picks 1,3
expect 0 "sent picks" "picks under herdr with the named rule and hc's note line"
[ "$(sed -n 's/^hc keys t4p //p' "$STUB_LOG")" = $'enter\ndown\ndown\nenter\ndown\ndown\nenter\nenter' ] \
  || { cp "$STUB_LOG" "$WORK/out"; fail "picks under herdr: wrong keys"; }
! grep -q '^tmux send-keys' "$STUB_LOG" || fail "picks under herdr: tmux keys sent"
mv "$WORK/bin/hc-base" "$WORK/bin/hc"; rm -f "$MAIN/.agents/team/registry/alfa-planner.json"

# C2: missing tab icons still produce diagnostics, including after the first Submit Enter.
sed 's/☐ Probe/Probe/' "$WORK/checkbox" > "$WORK/no-icon"
sed 's/☒ Probe/Probe/' "$WORK/review" > "$WORK/review-no-icon"
ms no-icon review 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 5 "not a single-question checkbox menu" "missing initial tab icon"
no_keys "missing initial tab icon"
ms checkbox review-no-icon 7
run "$MAIN" $ANSWER alfa planner picks 1,3
expect 4 "not a single-question checkbox menu" "missing review tab icon"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter'
unset STUB_MULTI STUB_REVIEW STUB_REVIEW_AFTER

echo "team-smoke-4: OK"
