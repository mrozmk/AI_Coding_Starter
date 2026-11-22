#!/usr/bin/env bash
# prompt parser, the send lock, and the runner's stop under it.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-1142 chore/AB-1142-fp
RUN_ID=alfa-20261020-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
TR="bash .claude/lib/team-run.sh"
PY="$SRC/.claude/lib/team_prompt.py"
RULE="$(printf '─%.0s' $(seq 120))"; DASH="$(printf '╌%.0s' $(seq 120))"
export STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane"
setpane() { cp "$1" "$WORK/pane"; }
pj() {  # pj <fixture> <jq condition> — parser output check
  python3 -I "$PY" parse < "$1" > "$WORK/p.json"
  jq -e "$2" "$WORK/p.json" >/dev/null || { cp "$WORK/p.json" "$WORK/out"; fail "parse $1: $2"; }
}
fpof() { python3 -I "$PY" parse < "$1" | jq -r .fp; }
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

# ---- (86b) the send lock: a dead holder is never reclaimed by a contender ---------------------
true & DEAD=$!; wait "$DEAD"
mkdir "$TD/send-coder.lock"; echo "$DEAD" > "$TD/send-coder.lock/pid"
echo "q=q-66 attempt=1 pid=$DEAD" > "$TD/send-coder.lock/owner"
touch -t 202601010000 "$TD/send-coder.lock"
( . "$SRC/.claude/lib/team-send-lock.sh"; team_send_lock "$TD" coder 0 x >/dev/null ) && fail "contender 1 passed"
( . "$SRC/.claude/lib/team-send-lock.sh"; team_send_lock "$TD" coder 0 y >/dev/null ) && fail "contender 2 passed"
rm -rf "$TD/send-coder.lock"
echo "team-smoke-5: (86b) send lock OK"

# ---- (90) runner end_session under the send lock ---------------------------------------------
SID=sid-coder-1; session coder 1 "$BASE" "$SID"
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

echo "team-smoke-5: OK"
