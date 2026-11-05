#!/usr/bin/env bash
# prompt parser, instance binding, journaled sender, delivery states.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-1142 chore/AB-1142-fp
RUN_ID=alfa-20261020-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
ANSWER="bash .claude/lib/team-answer.sh"
Q="bash .claude/lib/team-question.sh"
ESC="bash .claude/lib/team-escalate.sh"
TR="bash .claude/lib/team-run.sh"
PY="$SRC/.claude/lib/team_prompt.py"
RULE="$(printf '─%.0s' $(seq 120))"; DASH="$(printf '╌%.0s' $(seq 120))"
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
perm() {  # perm <file> <description> <command line>… — a Bash permission prompt in the real layout
  local f="$1" d="$2" l; shift 2
  { echo "⏺ Running 1 shell command…"; echo "$RULE"; echo " Bash command"; echo " $d"; echo "$DASH"
    for l in "$@"; do echo " │ $l"; done
    echo "$DASH"; echo " This command requires approval"; echo " Do you want to proceed?"
    echo " ❯ 1. Yes"; echo "   2. No"; echo " Esc to cancel · Tab to amend"; } > "$f"
}
bash_input() { jq -cn --arg c "$1" --arg d "$2" '{command: $c, description: $d}'; }
LAST=""
fresh() {  # fresh <tool_use id> <command> <description> [<screen line>…] → a new prompt instance
  local id="$1" c="$2" d="$3"; shift 3
  [ -z "$LAST" ] || tool_done "$SID" "$LAST"
  pending_tool "$SID" "$id" Bash "$(bash_input "$c" "$d")"; LAST="$id"
  if [ $# -gt 0 ]; then perm "$WORK/pane" "$d" "$@"; else perm "$WORK/pane" "$d" "$c"; fi
}
openp() {  # openp <anchor> → Q1, the q of the prompt on screen
  run "$MAIN" $Q alfa open coder --kind permission --anchor "$1" --summary "permission $1"
  expect 0 "" "open permission $1"; Q1="$(qid)"
}
yes1() { run "$MAIN" $Q alfa answer "$1" --tier 1 --author supervisor --why "in plan" --send yes; }
holdlock() {  # holdlock <q-id> — a live foreign sender holding the coder's send lock
  sleep 30 & HP=$!
  mkdir "$TD/send-coder.lock"; echo "$HP" > "$TD/send-coder.lock/pid"
  echo "q=$1 attempt=1 pid=$HP" > "$TD/send-coder.lock/owner"
}
droplock() { kill "$HP" 2>/dev/null || true; wait "$HP" 2>/dev/null || true; rm -rf "$TD/send-coder.lock"; }

# ---- (81) parser matrix --------------------------------------------------------------------
pj "$FIX/perm-awk.txt" '.kind == "permission" and .complete and .cursor == 1
  and (.fp | test("^v2:[0-9a-f]{64}$")) and .header == "Bash command"'
[ "$(fpof "$FIX/perm-awk.txt")" = "$(fpof "$FIX/perm-az.txt")" ] \
  || fail "a decorative change above the prompt changed the fingerprint"
[ "$(fpof "$FIX/perm-awk.txt")" != "$(fpof "$FIX/perm-awk2.txt")" ] || fail "different prompts, same fp"
sed 's/ │ az repos pr show --org/ │ az repos pr  show --org/' "$FIX/perm-awk.txt" > "$WORK/space"
[ "$(fpof "$FIX/perm-awk.txt")" != "$(fpof "$WORK/space")" ] || fail "inner whitespace not in the fp"
pj "$FIX/perm-awk2.txt" '.options | length == 4 and (.[1].desc | length == 1)'
pj "$FIX/perm-clipped.txt" '.fp == "v2:unreadable" and (.complete | not)
  and .reason == "unreadable: prompt header not on screen"'
pj "$FIX/unknown-header.txt" '.fp == "v2:unreadable"'
pj "$FIX/multi-tabs.txt" '.fp == "v2:unreadable" and (.reason | contains("tier 3"))'
pj "$FIX/menu-phase0.txt" '.kind == "menu" and .other == 3 and .cursor == 1 and .complete
  and (.options | length == 4) and .title == "Phase 0"'
pj "$FIX/menu-wrapup.txt" '.kind == "checkbox" and .other == 5 and .cursor == 1'
pj "$FIX/checkbox.txt" '.kind == "checkbox" and .other == 4 and ([.options[].checked] | all | not)
  and ([.options[].checked] | any | not)'
pj "$FIX/review.txt" '.kind == "review" and .review.ready and .review.submit_cursor
  and .review.answers == ["Apple, Cherry"]'
pj "$FIX/idle.txt" '.kind == "none" and .fp == "v2:none" and (.busy | not) and .input_empty'
pj "$FIX/busy.txt" '.kind == "none" and .busy'
pj "$FIX/busy-esc.txt" '.kind == "none" and .busy'
cat "$FIX/menu-phase0.txt" "$FIX/idle.txt" > "$WORK/quoted"
pj "$WORK/quoted" '.kind == "none" and .complete'
sed '$d' "$FIX/perm-awk.txt" > "$WORK/nofooter"
pj "$WORK/nofooter" '.kind == "permission" and (.complete | not) and (.reason | startswith("incomplete:"))'
sed 's/^❯ $/❯ half-typed/' "$FIX/idle.txt" > "$WORK/draft"
pj "$WORK/draft" '.kind == "none" and (.input_empty | not) and .input == "half-typed"'
{ cat "$FIX/idle.txt"; echo "$RULE"; echo " Bash command"; echo " Show long lines"; } > "$WORK/below"
pj "$WORK/below" '(.complete | not) and (.reason | startswith("incomplete:"))'
echo "team-smoke-5: (81) parser OK"

# ---- (82) transcript event ---------------------------------------------------------------------
[ "$(ev "$FIX/perm-awk.txt" "$FIX/t-bash-pending.jsonl" permission)" = toolu_018q18 ] || fail "event pending"
[ "$(ev "$FIX/perm-awk.txt" "$FIX/t-bash-done.jsonl" permission)" = ambiguous ] || fail "event done"
[ "$(ev "$FIX/perm-awk.txt" "$FIX/t-batch-identical.jsonl" permission)" = ambiguous ] \
  || fail "event of an identical batch"
[ "$(ev "$FIX/menu-phase0.txt" "$FIX/t-menu-pending.jsonl" menu)" = toolu_01menu ] || fail "menu event"
[ "$(python3 -I "$PY" event "$FIX/t-idle.jsonl" idle)" = a-last ] || fail "idle event"
[ "$(ev "$FIX/perm-awk.txt" "$WORK/missing.jsonl" permission)" = - ] || fail "missing transcript"
[ "$(python3 -I "$PY" result "$FIX/t-bash-done.jsonl" toolu_018q18)" = yes ] || fail "result yes"
[ "$(python3 -I "$PY" result "$FIX/t-bash-pending.jsonl" toolu_018q18)" = no ] || fail "result no"
[ "$(python3 -I "$PY" user-after "$FIX/t-idle.jsonl" a-last "Counter + backoff.")" = yes ] \
  || fail "user-after yes"
[ "$(python3 -I "$PY" user-after "$FIX/t-idle.jsonl" a-last "Something else")" = no ] \
  || fail "user-after no"
{ cat "$FIX/t-bash-pending.jsonl"; echo '{"type":"user","uuid":"x"'; } > "$WORK/broken.jsonl"
[ "$(ev "$FIX/perm-awk.txt" "$WORK/broken.jsonl" permission)" = - ] || fail "a malformed line counted"
{ grep toolu_018q18 "$FIX/t-bash-pending.jsonl"
  for i in $(seq 450); do echo '{"type":"attachment","uuid":"n'"$i"'"}'; done
  grep toolu_018q18 "$FIX/t-bash-pending.jsonl" | sed 's/toolu_018q18/toolu_018q19/'; } > "$WORK/far.jsonl"
[ "$(ev "$FIX/perm-awk.txt" "$WORK/far.jsonl" permission)" = ambiguous ] \
  || fail "an identical pending call far back was missed"
echo "team-smoke-5: (82) events OK"

# ---- (83) decorative change, first open of a run --------------------------------------------
SID=sid-coder-1; session coder 1 "$BASE" "$SID"
mkdir -p "$(dirname "$(transcript "$SID")")"; cp "$FIX/t-bash-pending.jsonl" "$(transcript "$SID")"
LAST=toolu_018q18
[ ! -e "$RD/questions" ] || fail "fixture: questions dir exists"
setpane "$FIX/perm-awk.txt"
openp "Do you want to proceed?"
[ "$Q1" = q-1 ] || fail "first open of a run: $Q1"
grep -qx 'event: toolu_018q18' "$(qf q-1)" || fail "q-1 event"
setpane "$FIX/perm-az.txt"; : > "$STUB_LOG"
yes1 q-1
expect 0 "q-1 state=sent — sent" "decorative change above the prompt"
[ "$(grep -c '^tmux send-keys -t %1 Enter$' "$STUB_LOG")" = 1 ] && [ "$(keyc)" = 1 ] \
  || fail "decorative change: keys $(keyc)"
grep -qx 'confirmed: no — prompt still open' "$(qf q-1)" || fail "q-1 confirmation"

# ---- (83b) cursor away from Yes, missing event ------------------------------------------------
sed 's/^ ❯ 1\. Yes/   1. Yes/; s/^   2\. Yes, and switch/ ❯ 2. Yes, and switch/' "$FIX/perm-awk.txt" \
  > "$WORK/cursor2"
sed 's/^ ❯ 1\. Yes/   1. Yes/; s/^   3\. Yes, and switch/ ❯ 3. Yes, and switch/' "$FIX/perm-awk2.txt" \
  > "$WORK/cursor3"
for f in cursor2 cursor3; do
  : > "$STUB_LOG"; STUB_PANE="$WORK/$f" run "$MAIN" $ANSWER alfa coder yes
  expect 6 "permission cursor is not on Yes" "yes with the cursor on another option ($f)"
  no_keys "cursor $f"
done
session coder 1 "$BASE" sid-no-transcript
setpane "$FIX/perm-awk2.txt"; openp "This command requires approval"
grep -qx 'event: -' "$(qf "$Q1")" || fail "$Q1 should have no event"
: > "$STUB_LOG"; yes1 "$Q1"
expect 5 "not sent — unreadable (no prompt event)" "a prompt without its event"; no_keys "no event"
session coder 1 "$BASE" "$SID"
echo "team-smoke-5: (83) binding OK"

# ---- (84) identity refusals, zero keys each ---------------------------------------------------
C2="awk 'length > 100' x.sh"
fresh toolu_p1 "$C2" "Show long lines"; openp "Show long lines"
: > "$STUB_LOG"; STUB_PANE_CREATED=1700000099 yes1 "$Q1"
expect 5 "not sent — changed (pane generation changed)" "new pane generation"; no_keys "pane gen"
fresh toolu_p2 "$C2" "Show long lines"; openp "Show long lines"
session coder 1 "$BASE" sid-other; : > "$STUB_LOG"; yes1 "$Q1"
expect 1 "stale: session changed" "new session id"; no_keys "session"
session coder 2 "$BASE" "$SID"; yes1 "$Q1"
expect 1 "stale: role or attempt changed" "new attempt"; no_keys "attempt"
session coder 1 "$BASE" "$SID"
run "$MAIN" $Q alfa answer "$Q1" --run alfa-19990101-000000 --tier 1 --author s --why w --send yes
expect 1 "stale: run changed" "new run"; no_keys "run"
tool_done "$SID" toolu_p2; pending_tool "$SID" toolu_p3 Bash "$(bash_input "$C2" "Show long lines")"
LAST=toolu_p3; : > "$STUB_LOG"; yes1 "$Q1"
expect 5 "not sent — changed (new prompt event)" "ABA: identical prompt, new event"; no_keys "ABA"
fresh toolu_p4 "$C2" "Show long lines"; openp "Show long lines"
pending_tool "$SID" toolu_p5 Bash "$(bash_input "$C2" "Show long lines")"
: > "$STUB_LOG"; yes1 "$Q1"
expect 5 "not sent — unreadable (ambiguous event)" "two identical pending calls"; no_keys "batch"
tool_done "$SID" toolu_p5
setpane "$FIX/perm-clipped.txt"; openp "Tilde in assignment value"
head -n 1 "$WORK/out" | grep -qF "(unreadable: prompt header not on screen)" || fail "unreadable open"
grep -qx 'fingerprint: v2:unreadable' "$(qf "$Q1")" || fail "clipped fp"
: > "$STUB_LOG"; yes1 "$Q1"
expect 5 "not sent — unreadable (prompt header not on screen)" "clipped command"; no_keys "clipped"
fresh toolu_p6 "$C2" "Show long lines"; openp "Show long lines"
sed 's/^ ❯ 1\. Yes/   1. Yes/; s/^   2\. No/ ❯ 2. No/' "$WORK/pane" > "$WORK/pane.c2"; cp "$WORK/pane.c2" "$WORK/pane"
: > "$STUB_LOG"; yes1 "$Q1"
expect 5 "not sent — changed (permission cursor is not on Yes)" "cursor moved"; no_keys "cursor"
echo "team-smoke-5: (84) identity OK"

# ---- (85) failure paths and the key journal ---------------------------------------------------
fresh toolu_f1 "$C2" "Show long lines"; openp "Show long lines"
: > "$STUB_LOG"; STUB_SENDKEYS_FAIL_AT=1 yes1 "$Q1"
expect 5 "not sent — changed (pane gone)" "send-keys fails on key 1"
grep -qx '1 try 1 Enter' "$(qf "$Q1").keys" && ! grep -q '^1 ok' "$(qf "$Q1").keys" \
  || fail "journal of a failed first key"
SID=sid-planner-1; session planner 1 "$BASE" "$SID"
pending_tool "$SID" toolu_c1 AskUserQuestion '{"questions":[{"question":"Pick fruits"}]}'
setpane "$FIX/checkbox.txt"
run "$MAIN" $Q alfa open planner --kind menu --anchor "Pick fruits" --summary "fruits"; QC="$(qid)"
: > "$STUB_LOG"
STUB_SENDKEYS_FAIL_AT=3 run "$MAIN" $Q alfa answer "$QC" --tier 1 --author s --why w --send picks:1,3
expect 4 "$QC state=unknown — unknown — 2 keys (send-keys failed at key 3)" "partial checkbox"
tool_done "$SID" toolu_c1
pending_tool "$SID" toolu_c2 AskUserQuestion '{"questions":[{"question":"Pick fruits"}]}'
sed 's/Apple, Cherry/Banana/' "$FIX/review.txt" > "$WORK/review-wrong"
run "$MAIN" $Q alfa open planner --kind menu --anchor "Pick fruits" --summary "fruits 2"; QC="$(qid)"
: > "$STUB_LOG"
STUB_ON_CAPTURE="[ \"\$(grep -c '^tmux send-keys ' \"\$STUB_LOG\")\" -lt 7 ] || cp '$WORK/review-wrong' '$WORK/pane'" \
  run "$MAIN" $Q alfa answer "$QC" --tier 1 --author s --why w --send picks:1,3
expect 4 "state=unknown — unknown — 7 keys (unexpected review or answer; final Enter not sent" \
  "review mismatch after keys"
[ "$(keyc)" = 7 ] || fail "review mismatch sent the final Enter"
( TD="$TD"; . "$SRC/.claude/lib/team-lib.sh"; . "$SRC/.claude/lib/team-question-lib.sh"
  qf="$WORK/hq.md"; printf '1 try 1 Enter\n' > "$qf.keys"
  qb_outcome 137 "" "$qf" q-90 1 coder; echo "$QB_DELIVERY"
  : > "$qf.keys"; qb_outcome 137 "" "$qf" q-90 1 coder; echo "$QB_DELIVERY"
  printf '1 try 1 Enter\n1 ok 1\n2 try 1 Enter\n2 ok 1\n' > "$qf.keys"
  qb_outcome 137 "" "$qf" q-90 2 coder; echo "$QB_DELIVERY" ) > "$WORK/out"
[ "$(cat "$WORK/out")" = $'unknown — 0 keys (rc 137)\nfailed (rc 137)\nunknown — 1 keys (rc 137)' ] \
  || fail "crash mapping: $(cat "$WORK/out")"
SID=sid-coder-1; session coder 1 "$BASE" "$SID"
echo "team-smoke-5: (85) failure paths OK"

# ---- (86) dispatch log and duplicates ---------------------------------------------------------
fresh toolu_d1 "$C2" "Show long lines"
n0="$(ls "$RD/questions" | grep -c '^q-[0-9]*\.md$')"
( cd "$MAIN" && $Q alfa open coder --kind permission --anchor "Show long lines" --summary a ) \
  > "$WORK/o1" 2>&1 & A=$!
( cd "$MAIN" && $Q alfa open coder --kind permission --anchor "Show long lines" --summary b ) \
  > "$WORK/o2" 2>&1 & B=$!
wait "$A" "$B"
[ "$(ls "$RD/questions" | grep -c '^q-[0-9]*\.md$')" = $((n0 + 1)) ] || fail "concurrent open made two q's"
QA="$(head -n 1 "$WORK/o1" | cut -d' ' -f1)"; [ "$QA" = "$(head -n 1 "$WORK/o2" | cut -d' ' -f1)" ] \
  || fail "concurrent open returned different q's"
: > "$STUB_LOG"; yes1 "$QA"; expect 0 "$QA state=sent" "q-A delivered unconfirmed"
QB="q-$(( ${QA#q-} + 100 ))"; awk '/^## Answer$/{exit} {print}' "$(qf "$QA")" > "$(qf "$QB")"
: > "$STUB_LOG"; yes1 "$QB"
expect 5 "not sent — changed (instance already dispatched by q=$QA)" "second q, same instance"
no_keys "second dispatch"
fresh toolu_d2 "$C2" "Show long lines"; openp "Show long lines"
holdlock q-77; : > "$STUB_LOG"; yes1 "$Q1"
expect 3 "state=not-sent-stale — not sent — stale (target busy (pid $HP (q=q-77 attempt=1" "busy target"
no_keys "busy target"; droplock
QSTALE="$Q1"

# ---- (86b) locks, egress through the transcript -----------------------------------------------
true & DEAD=$!; wait "$DEAD"
mkdir "$TD/send-coder.lock"; echo "$DEAD" > "$TD/send-coder.lock/pid"
echo "q=q-66 attempt=1 pid=$DEAD" > "$TD/send-coder.lock/owner"
touch -t 202601010000 "$TD/send-coder.lock"
run "$MAIN" $Q alfa retry "$QSTALE" --run "$RUN_ID"
expect 3 "stale: team-question.sh alfa unlock-send coder" "dead holder is reported, not reclaimed"
( . "$SRC/.claude/lib/team-send-lock.sh"; team_send_lock "$TD" coder 0 x >/dev/null ) && fail "contender 1 passed"
( . "$SRC/.claude/lib/team-send-lock.sh"; team_send_lock "$TD" coder 0 y >/dev/null ) && fail "contender 2 passed"
run "$MAIN" $Q alfa unlock-send coder
expect 0 "removed stale lock of send-coder" "unlock-send"
: > "$STUB_LOG"; run "$MAIN" $Q alfa retry "$QSTALE" --run "$RUN_ID"
expect 0 "$QSTALE state=sent" "retry after unlock-send"
[ "$(keyc)" = 1 ] || fail "retry keys"
mkdir -p "$RD/questions/.open.lock"; echo "$DEAD" > "$RD/questions/.open.lock/pid"
touch -t 202601010000 "$RD/questions/.open.lock"
fresh toolu_o1 "$C2" "Show long lines"
TEAM_QUESTION_LOCK_SECS=1 run "$MAIN" $Q alfa open coder --kind permission --anchor "Show long lines" \
  --summary x
expect 1 "stale: team-question.sh alfa unlock open" "dead opener"
run "$MAIN" $Q alfa unlock open; expect 0 "removed stale lock of open" "unlock open"
openp "Show long lines"
fresh toolu_e1 "echo start; curl https://x.example" "Fetch it" "echo start; cu" "rl https://x.example"
openp "Fetch it"
: > "$STUB_LOG"; yes1 "$Q1"
expect 5 "not sent — policy (refuse (egress): curl" "egress wrapped on screen"; no_keys "wrapped egress"
echo "team-smoke-5: (86) dispatch and locks OK"

# ---- (87a) a later tier-3 decision supersedes the first --------------------------------------
fresh toolu_r1 "$C2" "Show long lines"; openp "Show long lines"; QR="$Q1"
holdlock q-77
yes1 "$QR"; expect 3 "state=not-sent-stale" "first decision stale"
run "$MAIN" $Q alfa answer "$QR" --tier 3 --author operator --why "Operator approves" --send yes
expect 3 "state=not-sent-stale" "superseding decision stale"
droplock
: > "$STUB_LOG"; run "$MAIN" $Q alfa retry "$QR" --run "$RUN_ID"
expect 0 "$QR state=sent" "retry delivers the latest decision"
[ "$(awk '/^## Answer$/{a = 1} a && /^attempt: /' "$(qf "$QR")" | tr '\n' ' ')" \
  = "attempt: 1 attempt: 2 attempt: 3 " ] \
  || fail "attempt numbering"
[ "$(grep '^author: ' "$(qf "$QR")" | tail -n 1)" = "author: operator" ] || fail "retry used block 1"

# ---- (87) retry limits ------------------------------------------------------------------------
fresh toolu_r2 "$C2" "Show long lines"; openp "Show long lines"; QR="$Q1"
holdlock q-77
yes1 "$QR"; expect 3 "" "retry chain: attempt 1"
awk '/^## Answer$/{n++} n == 1 && NF' "$(qf "$QR")" > "$WORK/block1"
run "$MAIN" $Q alfa retry "$QR" --run "$RUN_ID"; expect 3 "" "retry chain: attempt 2"
run "$MAIN" $Q alfa retry "$QR" --run "$RUN_ID"; expect 3 "" "retry chain: attempt 3"
grep -qx 'attempt: 3' "$(qf "$QR")" && grep -q '^retry-of: ' "$(qf "$QR")" || fail "retry blocks"
run "$MAIN" $Q alfa retry "$QR" --run "$RUN_ID"; expect 1 "refused: retry limit (3)" "fourth attempt"
awk '/^## Answer$/{n++} n == 1 && NF' "$(qf "$QR")" | cmp -s - "$WORK/block1" \
  || fail "block 1 rewritten"
QLIM="$QR"
touch "$TD/cancel"; run "$MAIN" $Q alfa retry "$QLIM" --run "$RUN_ID"
expect 1 "" "retry while stopped"; rm -f "$TD/cancel"
fresh toolu_r3 "$C2" "Show long lines"; openp "Show long lines"; QR="$Q1"
yes1 "$QR"; expect 3 "" "stale for the mode check"
droplock
mkdir -p "$MAIN/.agents/team/watch"; echo '{"tiers":"off","answering":"on"}' > "$MAIN/.agents/team/watch/state.json"
run "$MAIN" $Q alfa retry "$QR" --run "$RUN_ID"; expect 1 "refused: tiers off" "retry with tiers off"
rm -f "$MAIN/.agents/team/watch/state.json"
touch "$TD/cancel"; run "$MAIN" $Q alfa retry "$QR" --run "$RUN_ID"
expect 1 "refused: team stopped" "retry after stop"; rm -f "$TD/cancel"
run "$MAIN" $Q alfa retry "$QR" --run alfa-19990101-000000; expect 1 "stale: run changed" "retry, new run"
run "$MAIN" $Q alfa retry "$QR" --run "$RUN_ID"; expect 0 "state=sent" "retry once the lock is free"
grep -qx 'attempt: 2' "$(qf "$QR")" || fail "retry attempt 2"
run "$MAIN" $Q alfa retry "$QR" --run "$RUN_ID"; expect 1 "refused: $QR is sent" "retry a sent q"
SID=sid-coder-1b; session coder 1 "$BASE" "$SID"
record --verdict blocked --message "no transcript" >/dev/null
setpane "$FIX/idle.txt"
run "$MAIN" $Q alfa open coder --kind blocked --summary "no transcript"; QE="$(qid)"
setpane "$FIX/busy.txt"
run "$MAIN" $Q alfa answer "$QE" --tier 1 --author s --why w --text "go" --send say
expect 3 "not sent — stale (role is busy)" "say on a busy role"
run "$MAIN" $Q alfa retry "$QE" --run "$RUN_ID"
expect 1 "refused: no proof of instance continuity" "retry without an event"
SID=sid-coder-1; session coder 1 "$BASE" "$SID"
echo "team-smoke-5: (87) retry OK"

# ---- (88) last gate inside the sender ---------------------------------------------------------
fresh toolu_g1 "$C2" "Show long lines"; openp "Show long lines"
: > "$STUB_LOG"; STUB_ON_CAPTURE="touch '$TD/cancel'" yes1 "$Q1"
expect 5 "not sent — changed (team stopped)" "stop during preflight"; no_keys "stop in preflight"
rm -f "$TD/cancel"
fresh toolu_g2 "$C2" "Show long lines"; openp "Show long lines"
: > "$STUB_LOG"
STUB_ON_CAPTURE="mkdir -p '$MAIN/.agents/team/watch'; echo '{\"answering\":\"off\"}' > '$MAIN/.agents/team/watch/state.json'" \
  yes1 "$Q1"
expect 5 "not sent — mode (answering off)" "answering off during preflight"; no_keys "mode in preflight"
rm -f "$MAIN/.agents/team/watch/state.json"
echo "team-smoke-5: (88) last gate OK"

# ---- (89) policy: egress, deny, SQL guard, unreadable policy ---------------------------------
n=0
for c in "curl https://x" "bash -c \"ssh h\"" "cat tools/curl/readme" "sqlcmd -Q \"DROP TABLE x\"" \
  "rm -rf build"; do
  n=$((n + 1))
  [ "$c" != "rm -rf build" ] || echo '{"permissions":{"deny":["Bash(rm -rf:*)"]}}' \
    > "$CLONE/.claude/settings.local.json"
  fresh "toolu_y$n" "$c" "Policy case $n"; openp "Policy case $n"
  : > "$STUB_LOG"; yes1 "$Q1"
  expect 5 "not sent — policy (refuse" "policy: $c"; no_keys "policy $c"
done
rm -f "$CLONE/.claude/settings.local.json"
tool_done "$SID" "$LAST"; LAST=toolu_hd
pending_tool "$SID" toolu_hd Bash "$(bash_input $'cat <<EOF | wget -O- x\nbody\nEOF' "Heredoc")"
perm "$WORK/pane" "Heredoc" "cat <<EOF | wget -O- x" "body" "EOF"; openp "Heredoc"
: > "$STUB_LOG"; yes1 "$Q1"; expect 5 "not sent — policy (refuse (egress): wget" "heredoc egress"
tool_done "$SID" "$LAST"; LAST=toolu_wf
pending_tool "$SID" toolu_wf WebFetch '{"url":"https://x.example"}'
printf '%s\n' "$RULE" " Fetch" " Claude wants to fetch content from x.example" \
  " Do you want to allow Claude to fetch this content?" " ❯ 1. Yes" "   2. No" " Esc to cancel" \
  > "$WORK/pane"
openp "fetch content"
: > "$STUB_LOG"; yes1 "$Q1"; expect 5 "not sent — policy (refuse (egress): Fetch prompt" "WebFetch"
no_keys "WebFetch"
fresh toolu_pu "ls" "Policy unreadable"; openp "Policy unreadable"
mv "$CLONE/.claude/settings.json" "$WORK/settings.json"
: > "$STUB_LOG"; yes1 "$Q1"
expect 5 "not sent — policy (refuse: clone policy unreadable (.claude/settings.json)" "no policy"
no_keys "no policy"; mv "$WORK/settings.json" "$CLONE/.claude/settings.json"
echo "team-smoke-5: (89) policy OK"

# ---- (90) runner end_session under the send lock ---------------------------------------------
cp "$WORK/bin/tmux" "$WORK/bin/tmux-base"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = has-session ]; then echo "tmux $*" >> "$STUB_LOG"' \
  '  [ "$3" = =alfa-coder ] && ! grep -q "^tmux kill-session -t =alfa-coder$" "$STUB_LOG"; exit $?; fi' \
  'exec "$(dirname "$0")/tmux-base" "$@"' > "$WORK/bin/tmux"
chmod +x "$WORK/bin/tmux"
stop() { : > "$STUB_LOG"; run "$MAIN" $TR alfa stop; rm -f "$TD/cancel"; }
setpane "$FIX/idle.txt"; stop
expect 0 "stopped" "stop on idle input"
[ "$(grep -c 'send-keys -t =alfa-coder: /exit Enter' "$STUB_LOG")" = 1 ] || fail "idle stop: no /exit"
for f in "$FIX/perm-awk.txt" "$FIX/menu-phase0.txt" "$WORK/draft"; do
  setpane "$f"; stop; expect 0 "stopped" "stop on $f"
  ! has "send-keys" "$STUB_LOG" || fail "stop typed into $f"
  has "kill-session -t =alfa-coder" "$STUB_LOG" || fail "stop did not kill on $f"
done
setpane "$FIX/idle.txt"; holdlock q-55
stop; expect 0 "stop while sender lock held by q=q-55" "stop during a send"
! has "send-keys" "$STUB_LOG" || fail "stop typed while a sender held the lock"
has "kill-session -t =alfa-coder" "$STUB_LOG" || fail "stop did not kill during a send"
grep -q "^stop-during-send .* q=q-55 attempt=1 pid=$HP$" "$TD/send-coder.log" || fail "no stop marker"
( TD="$TD"; . "$SRC/.claude/lib/team-lib.sh"; . "$SRC/.claude/lib/team-question-lib.sh"
  qb_outcome 0 "confirmed: yes (x)" "$WORK/hq.md" q-55 1 coder; echo "$QB_DELIVERY" ) > "$WORK/out"
[ "$(cat "$WORK/out")" = "unknown — stop while sender lock held by pid $HP" ] \
  || fail "stop marker mapping: $(cat "$WORK/out")"
droplock

# ---- (90b) runner on a clone that lacks the lock helper ----------------------------------------
rm "$CLONE/.claude/lib/team-send-lock.sh"
setpane "$FIX/idle.txt"; holdlock q-56
stop; expect 0 "stop while sender lock held" "stop with an older clone"
! has "send-keys" "$STUB_LOG" || fail "older clone: stop typed under a held lock"
droplock; git -C "$CLONE" checkout -- .claude/lib/team-send-lock.sh
cp "$WORK/bin/tmux-base" "$WORK/bin/tmux"
echo "team-smoke-5: (90) runner OK"

# ---- (91) delivery states ---------------------------------------------------------------------
hq() { printf '# x\nrole: coder\n\n## Answer\ntier: 1\nauthor: s\ndelivery: %s\n%s' "$1" "${2:-}" \
  > "$WORK/hq.md"; ( . "$SRC/.claude/lib/team-lib.sh"; team_q_state "$WORK/hq.md" | cut -f1 ); }
got=""
for d in "sent" "failed (rc 1)" "pending" "recorded only" "not sent — mode off" "garbage" \
  "not sent — stale (x)" "unknown — 2 keys (x)"; do got="$got $(hq "$d")"; done
[ "$got" = " sent failed pending recorded not-sent unknown not-sent-stale unknown" ] \
  || fail "historical states:$got"
[ "$(hq sent "confirmed: yes (tool_result)"$'\n')" = consumed ] || fail "consumed"
[ "$(hq sent "confirmed: no — x"$'\n')" = sent ] || fail "unconfirmed sent"
run "$MAIN" $ESC alfa coder 2 "$(qf "$QLIM")" --blocks x
expect 2 "already answered" "escalate a not-sent-stale q"
run "$MAIN" $Q alfa list; expect 0 "state=not-sent-stale" "list shows precise states"
last="$(tail -n 1 "$WORK/out")"
sum=0; for k in tier1 tier2 tier3 revoked failed pending open escalating escalated waiting; do
  sum=$((sum + $(sed -n "s/.* $k=\([0-9]*\).*/\1/p" <<<" $last")))
done
[ "$sum" = "$(sed -n 's/^total=\([0-9]*\).*/\1/p' <<<"$last")" ] || fail "list counters: $last"
echo "team-smoke-5: (91) states OK"

# ---- (92) say on the idle input -----------------------------------------------------------------
SID=sid-coder-2; session coder 1 "$BASE" "$SID"
mkdir -p "$(dirname "$(transcript "$SID")")"
echo '{"type":"assistant","uuid":"a-w","message":{"content":[{"type":"text","text":"wait"}]}}' \
  > "$(transcript "$SID")"
record --verdict blocked --message "say case" >/dev/null
setpane "$FIX/idle.txt"
run "$MAIN" $Q alfa open coder --kind blocked --summary "say case"; QS="$(qid)"
grep -qx 'event: a-w' "$(qf "$QS")" || fail "blocked event"
: > "$STUB_LOG"
STUB_ON_SENDKEYS="echo '{\"type\":\"user\",\"uuid\":\"u-1\",\"message\":{\"content\":\"Counter.\"}}' >> '$(transcript "$SID")'" \
  run "$MAIN" $Q alfa answer "$QS" --tier 1 --author s --why w --text "Counter." --send say
expect 0 "$QS state=consumed" "say confirmed by the transcript"
grep -qx 'confirmed: yes (transcript)' "$(qf "$QS")" || fail "say confirmation"
record --verdict blocked --message "say on a menu" >/dev/null
run "$MAIN" $Q alfa open coder --kind blocked --summary "say on a menu"; QS="$(qid)"
setpane "$FIX/menu-phase0.txt"; : > "$STUB_LOG"
run "$MAIN" $Q alfa answer "$QS" --tier 1 --author s --why w --text x --send say
expect 5 "not sent — changed (a menu or permission prompt is open)" "say over a menu"; no_keys "menu"
record --verdict blocked --message "say on unknown" >/dev/null
setpane "$FIX/idle.txt"
run "$MAIN" $Q alfa open coder --kind blocked --summary "say on unknown"; QS="$(qid)"
sed '$d' "$FIX/unknown-header.txt" > "$WORK/pane"; : > "$STUB_LOG"
run "$MAIN" $Q alfa answer "$QS" --tier 1 --author s --why w --text x --send say
expect 5 "not sent — unreadable (no idle input surface)" "say on an unknown renderer"
no_keys "unknown renderer"
record --verdict blocked --message "say on busy" >/dev/null
setpane "$FIX/idle.txt"
run "$MAIN" $Q alfa open coder --kind blocked --summary "say on busy"; QS="$(qid)"
setpane "$FIX/busy.txt"; : > "$STUB_LOG"
run "$MAIN" $Q alfa answer "$QS" --tier 1 --author s --why w --text x --send say
expect 3 "not sent — stale (role is busy)" "say on a spinner without esc"; no_keys "busy"
SID=sid-coder-1; session coder 1 "$BASE" "$SID"
cp "$(transcript "$SID")" "$WORK/t.bak"
fresh toolu_m1 "$C2" "Show long lines"; echo '{"type":"user"' >> "$(transcript "$SID")"
openp "Show long lines"
grep -qx 'event: -' "$(qf "$Q1")" || fail "a malformed transcript gave an event"
: > "$STUB_LOG"; yes1 "$Q1"
expect 5 "not sent — unreadable (no prompt event)" "malformed transcript"; no_keys "malformed"
cp "$WORK/t.bak" "$(transcript "$SID")"; LAST=toolu_pu
echo "team-smoke-5: (92) say OK"

# ---- (93) no: the explanation is typed only on the idle input --------------------------------
fresh toolu_n1 "$C2" "Show long lines"; openp "Show long lines"
: > "$STUB_LOG"
STUB_ON_SENDKEYS="cp '$FIX/perm-awk2.txt' '$WORK/pane'" run "$MAIN" $Q alfa answer "$Q1" --tier 1 \
  --author s --why w --text "not now" --send no
expect 4 "unknown — 1 keys (screen after Escape is not idle input)" "no, then another prompt"
[ "$(keyc)" = 1 ] && has "send-keys -t %1 Escape" "$STUB_LOG" || fail "no: keys $(keyc)"
fresh toolu_n2 "$C2" "Show long lines"; openp "Show long lines"
: > "$STUB_LOG"
STUB_ON_SENDKEYS="cp '$FIX/idle.txt' '$WORK/pane'" run "$MAIN" $Q alfa answer "$Q1" --tier 1 \
  --author s --why w --text "not now" --send no
expect 0 "state=sent" "no, then the idle input"
[ "$(grep -c 'send-keys -t %1 Enter' "$STUB_LOG")" = 1 ] && has "-l -- Rejected by the developer: not now" \
  "$STUB_LOG" || fail "no: explanation keys"
echo "team-smoke-5: (93) no OK"

# ---- (94) a target without a clone (a supervision role session): pick on its menu -------------
[ ! -e "$WORK/main-sup" ] || fail "fixture has a sup clone"
setpane "$FIX/menu-phase0.txt"; : > "$STUB_LOG"
run "$MAIN" $ANSWER sup lead pick 2
expect 0 "sent pick to sup-lead" "pick on a clone-less target"
[ "$(keyc)" = 2 ] && has "send-keys -t %1 Down" "$STUB_LOG" && has "send-keys -t %1 Enter" \
  "$STUB_LOG" || fail "clone-less pick: keys $(keyc)"
[ ! -e "$MAIN/.agents/team/send-lead.lock" ] || fail "clone-less send lock not released"
echo "team-smoke-5: (94) clone-less target OK"

echo "team-smoke-5: OK"
