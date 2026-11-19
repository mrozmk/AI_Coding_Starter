#!/usr/bin/env bash
# Question ledger: team-answer menu actions, team-question ledger.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-799 chore/AB-799-tiers
RUN_ID=alfa-20261006-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
ANSWER="bash .claude/lib/team-answer.sh"
Q="bash .claude/lib/team-question.sh"
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
cp "$FIX/busy-esc.txt" "$WORK/busy"
downs() { grep -c 'send-keys -t %1 Down' "$STUB_LOG" || true; }
no_keys() { ! has "send-keys" "$STUB_LOG" || fail "$1: keys were sent"; }
qf() { echo "$RD/questions/$1.md"; }
qid() { head -n 1 "$WORK/out" | cut -d' ' -f1; }
last_line() { tail -n 1 "$WORK/out"; }
expect_nz() { [ "$RC" != 0 ] || fail "$1: exit 0"; }
assistant() {  # assistant <sid> <uuid> — the role's last transcript turn (the blocked/idle event)
  mkdir -p "$(dirname "$(transcript "$1")")"
  jq -cn --arg u "$2" '{type: "assistant", uuid: $u, message: {content: [{type: "text",
    text: "waiting"}]}}' >> "$(transcript "$1")"
}
ask() {  # ask <sid> <tool_use id> <question> — a pending AskUserQuestion
  pending_tool "$1" "$2" AskUserQuestion "$(jq -cn --arg q "$3" '{questions: [{question: $q}]}')"
}
# Shell text for STUB_ON_SENDKEYS: the role consumes the prompt as soon as the keys arrive.
consume() {
  printf "echo '%s' >> '%s'" "$(jq -cn --arg id "$2" \
    '{type: "user", message: {content: [{type: "tool_result", tool_use_id: $id}]}}')" \
    "$(transcript "$1")"
}

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
expect 5 "multi-question menu — answer in the window (tier 3)" "pick on a multi-question menu"
no_keys "pick on a multi-question menu"
: > "$STUB_LOG"; STUB_PANE="$WORK/multi" run "$MAIN" $ANSWER alfa planner pick 2
expect 3 "incomplete: prompt still rendering" "pick on a menu without its footer last"
no_keys "pick on a menu without its footer last"
run "$MAIN" $ANSWER alfa planner pick
expect 2 "" "pick without a number"

# ---- (30) team-question open + bound answer (blocked) -----------------------------------------
session coder 1 "$BASE"; export STUB_PANE="$WORK/idle"; assistant sid-coder-1 a-wait-1
[ "$(basename "$(record --verdict blocked --message "counter vs dead-letter?")")" = coder-1-1.json ] \
  || fail "fixture: first blocked record"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Which retry design?"
expect 0 "" "open blocked"
head -n 1 "$WORK/out" | grep -q '^q-1 ' || fail "open did not allocate q-1"
has "record: coder-1-1.json" "$(qf q-1)" || fail "q-1 lacks the record binding"
for l in "fingerprint: v2:none" "pane: %1@1700000000" "session: sid-coder-1" "event: a-wait-1"; do
  grep -qx "$l" "$(qf q-1)" || fail "q-1 lacks '$l'"
done
has "- last blocker: - [coder 1] counter vs dead-letter?" "$(qf q-1)" || fail "q-1 lacks the blocker"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Which retry design?"
expect 0 "(existing, state=open)" "open again while open"; has "q-1 " "$WORK/out" || fail "reopen id"
[ ! -e "$(qf q-2)" ] || fail "reopen allocated q-2"
cp "$RD/notes.md" "$WORK/notes0"
: > "$STUB_LOG"
STUB_PANE="$WORK/busy" run "$MAIN" $Q alfa answer q-1 --tier 1 --author supervisor --why "inside plan" \
  --text "Counter + backoff." --send say
expect 3 "q-1 state=not-sent-stale — not sent — stale (role is busy)" "answer a busy role"
no_keys "answer a busy role"
cmp -s "$RD/notes.md" "$WORK/notes0" || fail "a stale answer wrote notes"
run "$MAIN" $Q alfa answer q-1 --tier 1 --author supervisor --why x --text y --send say
expect 1 "use retry" "tier 1 answer on a stale question"
run "$MAIN" $Q alfa retry q-1 --run "$RUN_ID"
expect 0 "sent say" "retry after the role is idle"
has "send-keys -t %1 -l -- Counter + backoff." "$STUB_LOG" || fail "answer not typed"
grep -qx "attempt: 2" "$(qf q-1)" && grep -q '^retry-of: ' "$(qf q-1)" || fail "retry block"
has "delivery: sent" "$(qf q-1)" || fail "q-1 not marked sent"
grep -q '^confirmed: ' "$(qf q-1)" || fail "q-1 lacks the confirmed line"
has "- q-1 [tier 1, supervisor] Which retry design? → Counter + backoff. — inside plan" "$RD/notes.md" \
  || fail "notes lack the decision line"
[ "$(grep '^## ' "$RD/notes.md" | tail -n 1)" = "## Blockers" ] || fail "## Blockers is not last"
grep '^## ' "$RD/notes.md" | grep -A1 -x '## Supervised decisions' | grep -qx '## Blockers' \
  || fail "## Supervised decisions is not right before ## Blockers"
cp "$STUB_LOG" "$WORK/log0"
run "$MAIN" $Q alfa answer q-1 --tier 1 --author supervisor --why x --text y --send say
expect 1 "already answered" "answer twice"; cmp -s "$STUB_LOG" "$WORK/log0" || fail "second answer sent"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Which retry design?"
expect 0 "(existing, state=sent)" "open again after the answer"; [ ! -e "$(qf q-2)" ] || fail "re-arm q-2"
record --verdict blocked --message "second" >/dev/null
tail -n 1 "$RD/notes.md" | grep -qF -- '- [coder 1] second' || fail "a later blocker missed ## Blockers"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Second view"
expect 0 "q-2 " "open the second record"; has "record: coder-1-2.json" "$(qf q-2)" || fail "q-2 binding"
record --verdict blocked --message "third" >/dev/null
: > "$STUB_LOG"
run "$MAIN" $Q alfa answer q-2 --tier 1 --author supervisor --why x --text y --send say
expect 1 "stale: a newer record exists" "answer an outdated record"; no_keys "outdated record"
! grep -q -- '- q-2 ' "$RD/notes.md" || fail "a stale answer reached notes"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Third"
expect 0 "q-3 " "open the third record"
STUB_PANE="$WORK/menu" run "$MAIN" $Q alfa answer q-3 --tier 1 --author supervisor --why x --text y \
  --send say
expect 5 "not sent — changed (a menu or permission prompt is open)" "answer after the screen changed"
no_keys "screen changed"
run "$MAIN" $Q alfa answer q-3 --tier 1 --author supervisor --why x --text y --send none
expect 1 "tier 3 only" "send none at tier 1"
record --verdict blocked --message "fourth" >/dev/null
run "$MAIN" $Q alfa open coder --kind blocked --summary "Fourth"
expect 0 "q-4 " "open the fourth record"
cp "$RD/notes.md" "$WORK/notes0"
STUB_TMUX_ALIVE=1 run "$MAIN" $Q alfa answer q-4 --tier 1 --author supervisor --why "in plan" \
  --text "Table." --send say
expect 5 "q-4 state=not-sent" "delivery to a gone session"
grep -qx 'delivery: not sent — changed (session gone)' "$(qf q-4)" || fail "q-4 not marked not sent"
cmp -s "$RD/notes.md" "$WORK/notes0" || fail "an undelivered answer wrote notes"
run "$MAIN" $Q alfa answer q-4 --tier 1 --author supervisor --why x --text y --send say
expect 1 "tier 3 only" "tier 1 after a failed delivery"
true & DEAD=$!; wait $DEAD
mkdir "$(qf q-4).lock"; echo "$DEAD" > "$(qf q-4).lock/pid"; touch -t 202601010000 "$(qf q-4).lock"
TEAM_QUESTION_LOCK_SECS=1 run "$MAIN" $Q alfa answer q-4 --tier 3 --author operator --why "window" \
  --text "Table." --send none
expect 1 "stale: team-question.sh alfa unlock q-4" "answer under a stale lock"
has "busy" "$WORK/out" || fail "stale lock not reported as busy"
run "$MAIN" $Q alfa unlock q-4
expect 0 "removed stale lock" "unlock"; [ ! -d "$(qf q-4).lock" ] || fail "unlock left the lock"
run "$MAIN" $Q alfa answer q-4 --tier 3 --author operator --why "window" --text "Table." --send none
expect 0 "recorded" "tier 3 record after unlock"; has "delivery: recorded only" "$(qf q-4)" || fail "q-4"
run "$MAIN" $Q alfa answer q-2 --run alfa-19990101-000000 --tier 3 --author operator --why x \
  --text y --send none
expect 1 "stale: run changed" "answer from another run"; ! has "## Answer" "$(qf q-2)" || fail "q-2"

# ---- (31) menu binding + none + revoke + list + policy -----------------------------------------
session planner 1 "$BASE"; export STUB_PANE="$WORK/menu"
ask sid-planner-1 toolu_m1 "Which retry design for the worker?"
run "$MAIN" $Q alfa open planner --kind menu --anchor "Not on screen" --summary x
expect 1 "anchor not on screen" "open with a missing anchor"
run "$MAIN" $Q alfa open planner --kind menu --anchor "Which retry design for the worker?" \
  --summary "Retry design"
expect 0 "q-5 " "open a menu"; QM="$(qid)"
grep -qx "event: toolu_m1" "$(qf "$QM")" || fail "$QM lacks its event"
grep -q '^fingerprint: v2:[0-9a-f]\{64\}$' "$(qf "$QM")" || fail "$QM lacks a v2 fingerprint"
run "$MAIN" $Q alfa open planner --kind menu --anchor "2. Counter only" --summary "Same menu"
expect 0 "$QM " "the same menu under another anchor"
has "(existing, state=open)" "$WORK/out" || fail "anchor-independent dedup"
: > "$STUB_LOG"
STUB_ON_SENDKEYS="$(consume sid-planner-1 toolu_m1)" run "$MAIN" $Q alfa answer "$QM" --tier 1 \
  --author supervisor --why "planner recommended" --send pick:1
expect 0 "$QM state=consumed — sent" "answer a menu"
has "send-keys -t %1 Enter" "$STUB_LOG" || fail "pick:1 no Enter"
[ "$(downs)" = 0 ] || fail "pick:1 pressed Down"
grep -qx "confirmed: yes (tool_result)" "$(qf "$QM")" || fail "$QM consumption not recorded"
ask sid-planner-1 toolu_m2 "Which retry design for the worker?"
run "$MAIN" $Q alfa open planner --kind menu --anchor "Which retry design for the worker?" \
  --summary "Retry v2"
expect 0 "q-6 " "the identical menu asked again is a new instance"; QN="$(qid)"
: > "$STUB_LOG"
run "$MAIN" $Q alfa answer "$QN" --tier 1 --author supervisor --why x --text y --send say
expect 1 "--send say does not fit a menu question" "say to a menu"; no_keys "say to a menu"
STUB_PANE="$WORK/perm" run "$MAIN" $Q alfa answer "$QN" --tier 1 --author supervisor --why x \
  --send pick:2
expect 5 "not sent — changed (no single-question menu on screen)" "answer a menu that is gone"
no_keys "menu gone"
run "$MAIN" $Q alfa answer "$QN" --tier 3 --author operator --why "answered in window" \
  --text "Counter only" --send none
expect 0 "" "record a window answer"; no_keys "send none"
has "delivery: recorded only" "$(qf "$QN")" || fail "$QN not recorded only"
! grep -q -- "- $QN " "$RD/notes.md" || fail "a tier 3 answer reached notes"
cp "$RD/notes.md" "$WORK/notes.before"
: > "$STUB_LOG"
STUB_PANE="$WORK/idle" run "$MAIN" $Q alfa revoke "$QM" --why "Operator prefers table"
expect 0 "" "revoke a consumed answer"
has "## Revoked" "$(qf "$QM")" \
  && [ "$(grep '^delivery:' "$(qf "$QM")" | tail -n 1)" = "delivery: sent" ] \
  || fail "$QM revoke not recorded as sent"
has "-l -- The supervisor's answer to $QM is revoked by the Operator" "$STUB_LOG" \
  || fail "revoke not typed"
cmp -s "$RD/notes.md" "$WORK/notes.before" || fail "revoke wrote notes"
session coder 2 "$BASE"; : > "$STUB_LOG"
STUB_PANE="$WORK/idle" run "$MAIN" $Q alfa revoke q-1 --why "wrong call"
expect 1 "revoke recorded, not delivered" "revoke after a new attempt"; no_keys "revoke q-1"
has "## Revoked" "$(qf q-1)" && grep -q '^delivery: not sent' "$(qf q-1)" || fail "q-1 revoke"
run "$MAIN" $Q alfa answer "$QM" --tier 1 --author supervisor --why x --text y --send say
expect 1 "tier 3 only" "tier 1 after a revoke"
run "$MAIN" $Q alfa list
expect 0 "" "list"
[ "$(last_line)" = "total=6 tier1=0 tier2=0 tier3=2 revoked=2 failed=1 pending=0 open=1" ] \
  || fail "list counts: $(last_line)"
session planner 1 "$BASE"; export STUB_PANE="$WORK/menu"
tool_done sid-planner-1 toolu_m2; ask sid-planner-1 toolu_m3 "Which retry design for the worker?"
run "$MAIN" $Q alfa open planner --kind menu --anchor "2. Counter only" --summary "Interrupted"
expect 0 "q-7 " "open a third instance"; QP="$(qid)"
printf '\n## Answer\ntier: 1\nauthor: supervisor\nanswer: x\nwhy: y\nanswered: 2026-10-06T00:00:00Z\ndelivery: pending\n' \
  >> "$(qf "$QP")"
run "$MAIN" $Q alfa list
has "$QP planner menu tier=1 author=supervisor state=pending" "$WORK/out" || fail "$QP not pending"
run "$MAIN" $Q alfa answer "$QP" --tier 1 --author supervisor --why x --text y --send say
expect 1 "delivery unknown" "re-send a pending answer"
run "$MAIN" $Q alfa answer "$QP" --tier 3 --author operator --why "checked window" --text x --send none
expect 0 "" "record a pending answer at tier 3"
run "$MAIN" $Q alfa list
[ "$(last_line)" = "total=7 tier1=0 tier2=0 tier3=3 revoked=2 failed=1 pending=0 open=1" ] \
  || fail "list counts after $QP: $(last_line)"
echo '{"permissions":{"ask":["Bash(sqlcmd:*)"],"deny":["Read(**/.env)"]}}' > "$CLONE/.claude/settings.local.json"
mv "$CLONE/.claude/settings.json" "$WORK/settings.json"
run "$MAIN" $Q alfa policy
expect 0 "ask  .claude/settings.local.json: Bash(sqlcmd:*)" "policy ask"
has "deny  .claude/settings.local.json: Read(**/.env)" "$WORK/out" || fail "policy deny"
has "missing: .claude/settings.json" "$WORK/out" || fail "policy missing file"
mv "$WORK/settings.json" "$CLONE/.claude/settings.json"

# ---- (33) busy role: deferred fingerprint, author, dash text ----------------------------------
session coder 3 "$BASE"; export STUB_PANE="$WORK/idle"
record --verdict blocked --message "busy case" >/dev/null
STUB_PANE="$WORK/busy" run "$MAIN" $Q alfa open coder --kind blocked --summary "Busy"
expect 0 "fingerprint deferred: role is busy" "open blocked on a busy role"
head -n 1 "$WORK/out" | grep -q '^q-8 ' || fail "busy open did not allocate q-8"
grep -q '^fingerprint: -$' "$(qf q-8)" || fail "q-8 fingerprint not deferred"
STUB_PANE="$WORK/busy" run "$MAIN" $Q alfa open coder --kind idle --anchor "esc to interrupt" \
  --summary x
expect 1 "is busy" "open idle on a busy role"
: > "$STUB_LOG"
run "$MAIN" $Q alfa answer q-8 --tier 1 --author supervisor --why x --text y --send say
expect 1 "stale: fingerprint not recorded" "answer a deferred question"; no_keys "deferred"
run "$MAIN" $Q alfa answer q-8 --tier 1 --author $'super\nvisor' --why x --text y --send say
expect 1 "--author must be one line" "two-line author"; no_keys "two-line author"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Busy"
expect 0 "(existing, state=open)" "re-open a deferred question"
grep -qx 'fingerprint: v2:none' "$(qf q-8)" || fail "q-8 fingerprint not refreshed"
[ ! -e "$(qf q-9)" ] || fail "re-open allocated q-9"
run "$MAIN" $Q alfa answer q-8 --tier 1 --author supervisor --why "in plan" --text "Counter." \
  --send say
expect 0 "sent say" "answer after re-open"
: > "$STUB_LOG"
run "$MAIN" $ANSWER alfa coder say "-x starts with a dash"
expect 0 "sent say" "say text with a leading dash"
has "send-keys -t %1 -l -- -x starts with a dash" "$STUB_LOG" || fail "dash not typed"
record --verdict blocked --message "busy, tier 2" >/dev/null
STUB_PANE="$WORK/busy" run "$MAIN" $Q alfa open coder --kind blocked --summary "Busy, tier 2"
head -n 1 "$WORK/out" | grep -q '^q-9 .*fingerprint deferred' || fail "busy open did not defer q-9"
run "$MAIN" $Q alfa open coder --kind blocked --summary "Busy, tier 2"
expect 0 "(existing, state=open)" "re-open a deferred question"
grep -qx 'fingerprint: v2:none' "$(qf q-9)" || fail "q-9 fingerprint not refreshed"
run "$MAIN" $Q alfa answer q-9 --tier 2 --author Advisor+Reviewer --why x --text "Counter." \
  --send say
expect 0 "sent say" "tier-2 answer after a deferred re-open"
record --verdict blocked --message "a second blocked question" >/dev/null
run "$MAIN" $Q alfa open coder --kind blocked --summary "Idle, tier 2"
head -n 1 "$WORK/out" | grep -q '^q-10 ' || fail "idle open did not allocate q-10"

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
  expect 5 "tier 3" "invalid option set $selection"; no_keys "bad option set"
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

# Ledger must bind picks to a menu and distinguish picks:none from recorded-only send none.
session planner 1 "$BASE"; ms checkbox review 7
ask sid-planner-1 toolu_c1 "Pick fruits"
run "$MAIN" $Q alfa open planner --kind menu --anchor "Pick fruits" --summary "Pick fruits"
expect 0 "q-11 " "open checkbox question"; QC="$(qid)"
: > "$STUB_LOG"
run "$MAIN" $Q alfa answer "$QC" --tier 1 --author supervisor --why "in plan" \
  --text "approved subset" --send picks:1,3
expect 0 "sent picks" "ledger delivers checkbox set"
has 'answer: (menu options 1,3) — approved subset' "$(qf "$QC")" || fail "ledger lost selected set"
has 'delivery: sent' "$(qf "$QC")" || fail "checkbox delivery not sent"
exact_keys $'Enter\nDown\nDown\nEnter\nDown\nDown\nEnter\nEnter'
grep -q "^1 try 8 Enter$" "$(qf "$QC").keys" && grep -q "^1 ok 8$" "$(qf "$QC").keys" \
  || fail "key journal lacks the final Enter"
ms checkbox review-none 7
run "$MAIN" $Q alfa open planner --kind menu --anchor "1. [ ] Apple" --summary "Skip fruits"
expect 0 "$QC " "the answered checkbox instance is not a new question"
tool_done sid-planner-1 toolu_c1; ask sid-planner-1 toolu_c2 "Pick fruits"
run "$MAIN" $Q alfa open planner --kind menu --anchor "1. [ ] Apple" --summary "Skip fruits"
expect 0 "q-12 " "open explicit skip question"; QS="$(qid)"
run "$MAIN" $Q alfa answer "$QS" --tier 1 --author supervisor --why "skip all" --send picks:none
expect 0 "sent picks" "ledger delivers explicit skip"
has 'answer: (skip all: none - skip all)' "$(qf "$QS")" || fail "skip not explicit in ledger"
exact_keys $'Down\nDown\nDown\nEnter\n-l -- none - skip all\nDown\nEnter\nEnter'
ms idle review 7
run "$MAIN" $Q alfa open planner --kind idle --anchor "> waiting" --summary "Not a menu"
expect 0 "q-13 " "open idle question"; QI="$(qid)"
run "$MAIN" $Q alfa answer "$QI" --tier 1 --author supervisor --why x --send picks:1,3
expect 1 "does not fit a idle question" "ledger refuses picks on idle"; no_keys "picks on idle"
run "$MAIN" $Q alfa answer "$QI" --tier 1 --author supervisor --why x --send picks:
expect 1 "picks needs" "ledger syntax preflight"; no_keys "ledger bad syntax"

# C1: picks:none must refuse every non-menu kind before any ledger/notes write, at every tier.
for tier in 1 2 3; do
  cp "$(qf "$QI")" "$WORK/question-before"; cp "$RD/notes.md" "$WORK/notes-before"
  run "$MAIN" $Q alfa answer "$QI" --tier "$tier" --author supervisor --why x --send picks:none
  expect 1 "does not fit a idle question" "explicit skip on idle at tier $tier"
  no_keys "explicit skip on idle"
  cmp -s "$(qf "$QI")" "$WORK/question-before" || fail "idle skip wrote ledger"
  cmp -s "$RD/notes.md" "$WORK/notes-before" || fail "idle skip wrote notes"
done
ms perm review 7
run "$MAIN" $Q alfa open planner --kind permission --anchor "az webapp deploy" \
  --summary "Permission"
expect 0 "q-14 " "open permission for skip refusal"; QPERM="$(qid)"
ms idle review 7; session coder 3 "$BASE"
record --verdict blocked --message "skip guard" >/dev/null
run "$MAIN" $Q alfa open coder --kind blocked --summary "Blocked for skip refusal"
expect 0 "q-15 " "open blocked for skip refusal"; QBL="$(qid)"
for kind in permission blocked; do
  case "$kind" in permission) id="$QPERM" ;; blocked) id="$QBL" ;; esac
  cp "$(qf "$id")" "$WORK/question-before"; cp "$RD/notes.md" "$WORK/notes-before"
  : > "$STUB_LOG"
  run "$MAIN" $Q alfa answer "$id" --tier 1 --author supervisor --why x --send picks:none
  expect 1 "does not fit a $kind question" "explicit skip on $kind"
  no_keys "explicit skip on $kind"
  cmp -s "$(qf "$id")" "$WORK/question-before" || fail "$kind skip wrote ledger"
  cmp -s "$RD/notes.md" "$WORK/notes-before" || fail "$kind skip wrote notes"
done

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
