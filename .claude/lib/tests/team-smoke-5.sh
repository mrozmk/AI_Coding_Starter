#!/usr/bin/env bash
# prompt parser, instance binding, the sender's refusals, locks, policy and delivery.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-1142 chore/AB-1142-fp
RUN_ID=alfa-20261020-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
ANSWER="bash .claude/lib/team-answer.sh"
TR="bash .claude/lib/team-run.sh"
PY="$SRC/.claude/lib/team_prompt.py"
RULE="$(printf '─%.0s' $(seq 120))"; DASH="$(printf '╌%.0s' $(seq 120))"
export STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane"
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
pj "$FIX/multi-tabs.txt" '.fp == "v2:unreadable" and (.reason | contains("answer in the window"))'
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
# A named session's screens end with its name rule under the footer (Herdr stages, #105): a hook
# confirmation and the checkbox — complete (menu-phase0 carries one already); mid-render with the
# rule still is not.
NAMED="$(printf '─%.0s' $(seq 60)) alfa-wrapup ─"
{ echo "$RULE"; echo " Bash command"; echo " Run shell command"; echo "$DASH"; echo " │ gh issue list --limit 5"
  echo "$DASH"; echo " │ Hook PreToolUse:Bash requires confirmation for this command:"
  echo " │ team egress: gh in command position — Operator [settings]"; echo " settings.json to update hooks"
  echo " Do you want to proceed?"; echo " ❯ 1. Yes"; echo "   2. No"; echo " Esc to cancel · Tab to amend"
  echo "$NAMED"; } > "$WORK/hook-named"
pj "$WORK/hook-named" '.kind == "permission" and .complete and .cursor == 1 and .command == "gh issue list --limit 5"
  and (.reason_lines | index("settings.json to update hooks") != null)'
printf '%s\n' "$(cat "$FIX/checkbox.txt")" "$NAMED" > "$WORK/checkbox-named"
pj "$WORK/checkbox-named" '.kind == "checkbox" and .complete and .other == 4 and .cursor == 1'
sed '$d' "$WORK/hook-named" | sed '$d' > "$WORK/hook-midrender"; echo "$NAMED" >> "$WORK/hook-midrender"
pj "$WORK/hook-midrender" '.kind == "permission" and (.complete | not) and (.reason | startswith("incomplete:"))'
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

# ---- (83) decorative change above the prompt ------------------------------------------------
SID=sid-coder-1; session coder 1 "$BASE" "$SID"
mkdir -p "$(dirname "$(transcript "$SID")")"; cp "$FIX/t-bash-pending.jsonl" "$(transcript "$SID")"
LAST=toolu_018q18
setpane "$FIX/perm-az.txt"; : > "$STUB_LOG"
run "$MAIN" $ANSWER alfa coder yes --expect-fp "$(fpof "$FIX/perm-awk.txt")" --expect-event toolu_018q18
expect 0 "sent yes to alfa-coder" "decorative change above the prompt"
[ "$(grep -c '^tmux send-keys -t %1 Enter$' "$STUB_LOG")" = 1 ] && [ "$(keyc)" = 1 ] \
  || fail "decorative change: keys $(keyc)"
has "confirmed: no — prompt still open" "$WORK/out" || fail "decorative change: confirmation"

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
setpane "$FIX/perm-awk2.txt"; : > "$STUB_LOG"
run "$MAIN" $ANSWER alfa coder yes --expect-event toolu_018q18
expect 3 "transcript unreadable" "an expected event without a readable transcript"; no_keys "no event"
session coder 1 "$BASE" "$SID"
# A caller inside the clone without --clone (the per-run TeamLead): the transcript is found and
# the event binds — a wrong expectation is then a changed event (6), never "transcript unreadable".
setpane "$FIX/perm-awk.txt"; : > "$STUB_LOG"
run "$CLONE" env HARNESS_MAIN="$MAIN" $ANSWER alfa coder yes --expect-event toolu_other
expect 6 "new prompt event" "a caller inside the clone binds the event"; no_keys "clone caller"
run "$CLONE" env HARNESS_MAIN="$MAIN" $ANSWER beta coder yes
expect 2 "is not the clone of team beta" "a caller inside another team's clone"; no_keys "other clone"
echo "team-smoke-5: (83) binding OK"

# ---- (84) identity refusals, zero keys each ---------------------------------------------------
C2="awk 'length > 100' x.sh"
fresh toolu_p1 "$C2" "Show long lines"
: > "$STUB_LOG"; STUB_PANE_CREATED=1700000099 run "$MAIN" $ANSWER alfa coder yes --expect-pane %1@1700000000
expect 6 "pane generation changed" "new pane generation"; no_keys "pane gen"
fresh toolu_p2 "$C2" "Show long lines"
session coder 1 "$BASE" sid-other; : > "$STUB_LOG"
run "$MAIN" $ANSWER alfa coder yes --expect-session "$SID"
expect 6 "session changed" "new session id"; no_keys "session"
session coder 2 "$BASE" "$SID"; run "$MAIN" $ANSWER alfa coder yes --expect-attempt 1
expect 6 "role or attempt changed" "new attempt"; no_keys "attempt"
session coder 1 "$BASE" "$SID"
run "$MAIN" $ANSWER alfa coder yes --expect-run alfa-19990101-000000
expect 6 "run changed" "new run"; no_keys "run"
tool_done "$SID" toolu_p2; pending_tool "$SID" toolu_p3 Bash "$(bash_input "$C2" "Show long lines")"
LAST=toolu_p3; : > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes --expect-event toolu_p2
expect 6 "new prompt event" "ABA: identical prompt, new event"; no_keys "ABA"
fresh toolu_p4 "$C2" "Show long lines"
pending_tool "$SID" toolu_p5 Bash "$(bash_input "$C2" "Show long lines")"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes --expect-event toolu_p4
expect 5 "ambiguous event" "two identical pending calls"; no_keys "batch"
tool_done "$SID" toolu_p5
setpane "$FIX/perm-clipped.txt"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes
expect 5 "prompt header not on screen" "clipped command"; no_keys "clipped"
fresh toolu_p6 "$C2" "Show long lines"
sed 's/^ ❯ 1\. Yes/   1. Yes/; s/^   2\. No/ ❯ 2. No/' "$WORK/pane" > "$WORK/pane.c2"; cp "$WORK/pane.c2" "$WORK/pane"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes
expect 6 "permission cursor is not on Yes" "cursor moved"; no_keys "cursor"
echo "team-smoke-5: (84) identity OK"

# ---- (85) failure paths ------------------------------------------------------------------------
fresh toolu_f1 "$C2" "Show long lines"
: > "$STUB_LOG"; STUB_SENDKEYS_FAIL_AT=1 run "$MAIN" $ANSWER alfa coder yes
expect 6 "pane gone" "send-keys fails on key 1"
SID=sid-planner-1; session planner 1 "$BASE" "$SID"
pending_tool "$SID" toolu_c1 AskUserQuestion '{"questions":[{"question":"Pick fruits"}]}'
setpane "$FIX/checkbox.txt"; : > "$STUB_LOG"
STUB_SENDKEYS_FAIL_AT=3 run "$MAIN" $ANSWER alfa planner picks 1,3
expect 4 "send-keys failed at key 3 — 2 keys sent" "partial checkbox"
tool_done "$SID" toolu_c1
pending_tool "$SID" toolu_c2 AskUserQuestion '{"questions":[{"question":"Pick fruits"}]}'
sed 's/Apple, Cherry/Banana/' "$FIX/review.txt" > "$WORK/review-wrong"
setpane "$FIX/checkbox.txt"; : > "$STUB_LOG"
STUB_ON_CAPTURE="[ \"\$(grep -c '^tmux send-keys ' \"\$STUB_LOG\")\" -lt 7 ] || cp '$WORK/review-wrong' '$WORK/pane'" \
  run "$MAIN" $ANSWER alfa planner picks 1,3
expect 4 "unexpected review or answer; final Enter not sent — answer in the window — 7 keys sent" \
  "review mismatch after keys"
[ "$(keyc)" = 7 ] || fail "review mismatch sent the final Enter"
SID=sid-coder-1; session coder 1 "$BASE" "$SID"
echo "team-smoke-5: (85) failure paths OK"

# ---- (86) dispatch log and duplicates ---------------------------------------------------------
fresh toolu_d1 "$C2" "Show long lines"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes --authority class --why w
expect 0 "sent yes to alfa-coder" "first dispatch of an instance"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes --authority class --why w
expect 6 "instance already dispatched by q=authority:class" "second dispatch, same instance"
no_keys "second dispatch"
fresh toolu_d2 "$C2" "Show long lines"
holdlock q-77; : > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes
expect 3 "target busy (pid $HP (q=q-77 attempt=1" "busy target"
no_keys "busy target"; droplock

# ---- (86b) locks, egress through the transcript -----------------------------------------------
true & DEAD=$!; wait "$DEAD"
mkdir "$TD/send-coder.lock"; echo "$DEAD" > "$TD/send-coder.lock/pid"
echo "q=q-66 attempt=1 pid=$DEAD" > "$TD/send-coder.lock/owner"
touch -t 202601010000 "$TD/send-coder.lock"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes
expect 3 "target busy" "dead holder is reported, not reclaimed"; no_keys "dead holder"
has "stale: remove" "$WORK/out" || fail "dead holder not reported as stale"
( . "$SRC/.claude/lib/team-send-lock.sh"; team_send_lock "$TD" coder 0 x >/dev/null ) && fail "contender 1 passed"
( . "$SRC/.claude/lib/team-send-lock.sh"; team_send_lock "$TD" coder 0 y >/dev/null ) && fail "contender 2 passed"
rm -rf "$TD/send-coder.lock"
fresh toolu_e1 "echo start; curl https://x.example" "Fetch it" "echo start; cu" "rl https://x.example"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes --authority class --why w
expect 9 "human-only: egress" "egress wrapped on screen"; no_keys "wrapped egress"
echo "team-smoke-5: (86) dispatch and locks OK"

# ---- (88) last gate inside the sender ---------------------------------------------------------
fresh toolu_g1 "$C2" "Show long lines"
: > "$STUB_LOG"; STUB_ON_CAPTURE="touch '$TD/cancel'" run "$MAIN" $ANSWER alfa coder yes
expect 6 "team stopped" "stop during preflight"; no_keys "stop in preflight"
rm -f "$TD/cancel"
echo "team-smoke-5: (88) last gate OK"

# ---- (89) policy: egress, deny, SQL guard, unreadable policy ---------------------------------
n=0
for c in "curl https://x" "bash -c \"ssh h\"" "cat tools/curl/readme" "sqlcmd -Q \"DROP TABLE x\"" \
  "rm -rf build"; do
  n=$((n + 1))
  [ "$c" != "rm -rf build" ] || echo '{"permissions":{"deny":["Bash(rm -rf:*)"]}}' \
    > "$CLONE/.claude/settings.local.json"
  fresh "toolu_y$n" "$c" "Policy case $n"
  : > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes
  expect 7 "refuse" "policy: $c"; no_keys "policy $c"
done
rm -f "$CLONE/.claude/settings.local.json"
perm "$WORK/pane" "Heredoc" "cat <<EOF | wget -O- x" "body" "EOF"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes
expect 7 "refuse (egress): wget" "heredoc egress"; no_keys "heredoc egress"
printf '%s\n' "$RULE" " Fetch" " Claude wants to fetch content from x.example" \
  " Do you want to allow Claude to fetch this content?" " ❯ 1. Yes" "   2. No" " Esc to cancel" \
  > "$WORK/pane"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes
expect 7 "refuse (egress): Fetch prompt" "WebFetch"; no_keys "WebFetch"
fresh toolu_pu "ls" "Policy unreadable"
mv "$CLONE/.claude/settings.json" "$WORK/settings.json"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes
expect 7 "refuse: clone policy unreadable (.claude/settings.json)" "no policy"
no_keys "no policy"; mv "$WORK/settings.json" "$CLONE/.claude/settings.json"
echo "team-smoke-5: (89) policy OK"

# ---- (90) runner end_session under the send lock ---------------------------------------------
cp "$WORK/bin/tmux" "$WORK/bin/tmux-base"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = has-session ]; then echo "tmux $*" >> "$STUB_LOG"' \
  '  [ "$3" = =smk-alfa-coder ] && ! grep -q "^tmux kill-session -t =smk-alfa-coder$" "$STUB_LOG"; exit $?; fi' \
  'exec "$(dirname "$0")/tmux-base" "$@"' > "$WORK/bin/tmux"
chmod +x "$WORK/bin/tmux"
stop() { : > "$STUB_LOG"; run "$MAIN" $TR alfa stop; rm -f "$TD/cancel"; }
setpane "$FIX/idle.txt"; stop
expect 0 "stopped" "stop on idle input"
[ "$(grep -c 'send-keys -t =smk-alfa-coder: /exit Enter' "$STUB_LOG")" = 1 ] || fail "idle stop: no /exit"
for f in "$FIX/perm-awk.txt" "$FIX/menu-phase0.txt" "$WORK/draft"; do
  setpane "$f"; stop; expect 0 "stopped" "stop on $f"
  ! has "send-keys" "$STUB_LOG" || fail "stop typed into $f"
  has "kill-session -t =smk-alfa-coder" "$STUB_LOG" || fail "stop did not kill on $f"
done
setpane "$FIX/idle.txt"; holdlock q-55
stop; expect 0 "stop while sender lock held by q=q-55" "stop during a send"
! has "send-keys" "$STUB_LOG" || fail "stop typed while a sender held the lock"
has "kill-session -t =smk-alfa-coder" "$STUB_LOG" || fail "stop did not kill during a send"
grep -q "^stop-during-send .* q=q-55 attempt=1 pid=$HP$" "$TD/send-coder.log" || fail "no stop marker"
droplock

# ---- (90b) runner on a clone that lacks the lock helper ----------------------------------------
rm "$CLONE/.claude/lib/team-send-lock.sh"
setpane "$FIX/idle.txt"; holdlock q-56
stop; expect 0 "stop while sender lock held" "stop with an older clone"
! has "send-keys" "$STUB_LOG" || fail "older clone: stop typed under a held lock"
droplock; git -C "$CLONE" checkout -- .claude/lib/team-send-lock.sh
cp "$WORK/bin/tmux-base" "$WORK/bin/tmux"
echo "team-smoke-5: (90) runner OK"

# ---- (92) say on the idle input -----------------------------------------------------------------
SID=sid-coder-2; session coder 1 "$BASE" "$SID"
mkdir -p "$(dirname "$(transcript "$SID")")"
echo '{"type":"assistant","uuid":"a-w","message":{"content":[{"type":"text","text":"wait"}]}}' \
  > "$(transcript "$SID")"
setpane "$FIX/idle.txt"; : > "$STUB_LOG"
STUB_ON_SENDKEYS="echo '{\"type\":\"user\",\"uuid\":\"u-1\",\"message\":{\"content\":\"Counter.\"}}' >> '$(transcript "$SID")'" \
  run "$MAIN" $ANSWER alfa coder say "Counter."
expect 0 "sent say to alfa-coder" "say confirmed by the transcript"
has "confirmed: yes (transcript)" "$WORK/out" || fail "say confirmation"
setpane "$FIX/menu-phase0.txt"; : > "$STUB_LOG"
run "$MAIN" $ANSWER alfa coder say x
expect 6 "a menu or permission prompt is open" "say over a menu"; no_keys "menu"
sed '$d' "$FIX/unknown-header.txt" > "$WORK/pane"; : > "$STUB_LOG"
run "$MAIN" $ANSWER alfa coder say x
expect 5 "no idle input surface" "say on an unknown renderer"
no_keys "unknown renderer"
setpane "$FIX/busy.txt"; : > "$STUB_LOG"
run "$MAIN" $ANSWER alfa coder say x
expect 3 "role is busy" "say on a spinner without esc"; no_keys "busy"
SID=sid-coder-1; session coder 1 "$BASE" "$SID"
cp "$(transcript "$SID")" "$WORK/t.bak"
fresh toolu_m1 "$C2" "Show long lines"; echo '{"type":"user"' >> "$(transcript "$SID")"
: > "$STUB_LOG"; run "$MAIN" $ANSWER alfa coder yes --expect-event toolu_m1
expect 3 "transcript unreadable" "malformed transcript"; no_keys "malformed"
cp "$WORK/t.bak" "$(transcript "$SID")"; LAST=toolu_pu
echo "team-smoke-5: (92) say OK"

# ---- (93) no: the explanation is typed only on the idle input --------------------------------
fresh toolu_n1 "$C2" "Show long lines"
: > "$STUB_LOG"
STUB_ON_SENDKEYS="cp '$FIX/perm-awk2.txt' '$WORK/pane'" run "$MAIN" $ANSWER alfa coder no "not now"
expect 4 "screen after Escape is not idle input — 1 keys sent" "no, then another prompt"
[ "$(keyc)" = 1 ] && has "send-keys -t %1 Escape" "$STUB_LOG" || fail "no: keys $(keyc)"
fresh toolu_n2 "$C2" "Show long lines"
: > "$STUB_LOG"
STUB_ON_SENDKEYS="cp '$FIX/idle.txt' '$WORK/pane'" run "$MAIN" $ANSWER alfa coder no "not now"
expect 0 "sent no to alfa-coder" "no, then the idle input"
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
