#!/usr/bin/env bash
# team-smoke: serial
# The session-host driver (tmux backend): every verb's tmux argv equals the call it replaces, exit
# codes, locks, the registry record, backend resolution, the main-root rule and the readiness wait.
# Serial: the readiness and graceful-kill cases sleep.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

# The driver runs from a copy, so the messaging-socket sender can be a stub.
L="$WORK/drv"; mkdir -p "$L"
cp "$SRC/.claude/lib/session-host.sh" "$SRC/.claude/lib/session-host-lib.sh" \
  "$SRC/.claude/lib/team-send-lock.sh" "$SRC/.claude/lib/team-channel.sh" \
  "$SRC/.claude/lib/team-profile.sh" "$SRC/.claude/lib/team_prompt.py" \
  "$SRC/.claude/lib/team_transcript.py" "$L/"
cat > "$L/team-watch-send.py" <<'PY'
import os, sys
sys.stdin.read()
with open(os.environ["STUB_LOG"], "a") as f:
    f.write("socket " + sys.argv[1] + "\n")
sys.exit(int(os.environ.get("STUB_SOCK_RC", "1")))
PY
SH="bash $L/session-host.sh"
MP="$(cd "$MAIN" && pwd -P)"
REG="$MP/.agents/team/registry"
CL="$WORK/clone"; TDX="$CL/.agents/team"; mkdir -p "$TDX"
P="$MAIN/.claude/project-profile.json"; cp "$P" "$WORK/prof.bak"
prof() { jq "$1" "$WORK/prof.bak" > "$P"; }
PANES="$SRC/.claude/lib/tests/fixtures/prompts"
clr() { : > "$STUB_LOG"; rm -f "$STUB_LOG.typed"; }
line() { grep -qxF -- "$1" "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "$2: no log line '$1'"; }; }
noline() { ! grep -qF -- "$1" "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "$2: unexpected '$1'"; }; }
count() { grep -cxF -- "$1" "$STUB_LOG" || true; }

# ---- (1) alive: 0 / 3 / 1 -------------------------------------------------------------------------
clr; STUB_TMUX_ALIVE=0 run "$MAIN" $SH alive alfa-coder; expect 0 "" "(1) alive"
line "tmux has-session -t =alfa-coder" "(1) alive argv"
run "$MAIN" $SH alive alfa-coder; expect 3 "" "(1) gone"
STUB_TMUX_ERR="protocol version mismatch" run "$MAIN" $SH alive alfa-coder
expect 1 "protocol version mismatch" "(1) probe failed"

echo "team-smoke-host: (1) alive: 0 / 3 / 1 OK"

# ---- (2) read / history / read by target -----------------------------------------------------------
clr; STUB_PANE="$PANES/idle.txt" run "$MAIN" $SH read alfa-coder; expect 0 "" "(2) read"
line "tmux capture-pane -p -t =alfa-coder:" "(2) read argv"
grep -q '^[[:space:]]*$' "$WORK/out" && fail "(2) read kept a blank line"
clr; run "$MAIN" $SH read alfa-coder --history 200; expect 0 "" "(2) history"
line "tmux capture-pane -p -J -S -200 -t =alfa-coder:" "(2) history argv"
clr; run "$MAIN" bash -c ". '$L/session-host-lib.sh'; sh_read_target %1 --escapes"
expect 0 "" "(2) read target"; line "tmux capture-pane -p -e -J -S -200 -t %1" "(2) target argv"
clr; run "$MAIN" bash -c ". '$L/session-host-lib.sh'; sh_read_target %1 --history 50 --squeeze"
line "tmux capture-pane -p -J -S -50 -t %1" "(2) squeeze argv"

echo "team-smoke-host: (2) read / history / read by target OK"

# ---- (3) keys ----------------------------------------------------------------------------------------
clr; run "$MAIN" $SH keys alfa-coder --team-dir "$TDX" enter esc up down tab ctrl-c ctrl-e ctrl-u
expect 0 "" "(3) keys"; line "tmux send-keys -t =alfa-coder: Enter Escape Up Down Tab C-c C-e C-u" "(3) keys argv"
[ ! -d "$TDX/send-coder.lock" ] || fail "(3) keys left the lock behind"
clr; run "$MAIN" $SH keys alfa-coder --team-dir "$TDX" enter bogus; expect 2 "unknown key" "(3) unknown key"
noline "send-keys" "(3) unknown key typed something"
clr; run "$MAIN" $SH keys alfa-coder --target %1 --team-dir "$TDX" Enter
expect 0 "" "(3) keys target"; line "tmux send-keys -t %1 Enter" "(3) keys target argv"
clr; run "$MAIN" $SH keys alfa-coder enter; expect 10 "" "(3) team address without a team dir"

echo "team-smoke-host: (3) keys OK"

# ---- (4) type ----------------------------------------------------------------------------------------
clr; run "$MAIN" $SH type alfa-coder --team-dir "$TDX" "hello world"; expect 0 "" "(4) type"
line "tmux send-keys -t =alfa-coder: -l -- hello world" "(4) type argv"; noline "Enter" "(4) type pressed Enter"
clr; run "$MAIN" $SH type alfa-coder --team-dir "$TDX" "hi" --enter; expect 0 "" "(4) type --enter"
line "tmux send-keys -t =alfa-coder: -l -- hi" "(4) type text"; line "tmux send-keys -t =alfa-coder: Enter" "(4) enter"
clr; run "$MAIN" $SH type alfa-coder --target %1 --team-dir "$TDX" "x"; line "tmux send-keys -t %1 -l -- x" "(4) type target"

echo "team-smoke-host: (4) type OK"

# ---- (5) send: socket → idle input → skip ---------------------------------------------------------------
echo '{}' > "$WORK/reg.json"
clr; STUB_SOCK_RC=0 STUB_TMUX_ALIVE=0 run "$MAIN" $SH send alfa-coder "ping" --team-dir "$TDX" --reg "$WORK/reg.json"
expect 0 "" "(5) socket"; line "socket $WORK/reg.json" "(5) socket used"; noline "send-keys" "(5) socket typed too"
clr; STUB_TMUX_ALIVE=0 STUB_PANE="$PANES/idle.txt" run "$MAIN" $SH send alfa-coder $'two\nlines' --team-dir "$TDX"
expect 0 "" "(5) idle fallback"; line "tmux send-keys -t =alfa-coder: -l -- two lines" "(5) idle text"
line "tmux send-keys -t =alfa-coder: Enter" "(5) idle enter"
clr; STUB_TMUX_ALIVE=0 STUB_PANE="$PANES/perm-az.txt" run "$MAIN" $SH send alfa-coder "ping" --team-dir "$TDX"
expect 10 "" "(5) not idle"; noline "send-keys" "(5) typed into a prompt"
grep -q '^doorbell-skipped .* input not idle — ping$' "$TDX/send-coder.log" || fail "(5) not-idle log line"
mkdir "$TDX/send-coder.lock"; echo $$ > "$TDX/send-coder.lock/pid"; echo "q=1 pid=7" > "$TDX/send-coder.lock/owner"
clr; STUB_TMUX_ALIVE=0 STUB_PANE="$PANES/idle.txt" run "$MAIN" $SH send alfa-coder "ping2" --team-dir "$TDX"
expect 10 "" "(5) lock held"; noline "send-keys" "(5) typed under a held lock"
grep -q '^doorbell-skipped .* send lock held by q=1 pid=7 — ping2$' "$TDX/send-coder.log" || fail "(5) lock log line"
clr; run "$MAIN" $SH send alfa-coder "ping3" --team-dir "$TDX"; expect 3 "" "(5) gone"
grep -q 'session alfa-coder not alive — ping3$' "$TDX/send-coder.log" || fail "(5) gone log line"
rm -rf "$TDX/send-coder.lock"
mkdir -p "$REG"; echo '{"address":"alfa-runner","cli":"script","backend":"tmux"}' > "$REG/alfa-runner.json"
run "$MAIN" $SH send alfa-runner "x"; expect 2 "script session" "(5) script refused"

echo "team-smoke-host: (5) send: socket → idle input → skip OK"

# ---- (6) kill ----------------------------------------------------------------------------------------
clr; STUB_TMUX_ALIVE=0 STUB_PANE="$PANES/idle.txt" run "$MAIN" $SH kill alfa-coder --graceful 1 --team-dir "$TDX"
expect 1 "" "(6) graceful (the stub never dies)"
line "tmux send-keys -t =alfa-coder: /exit Enter" "(6) /exit"; line "tmux kill-session -t =alfa-coder" "(6) kill"
mkdir "$TDX/send-coder.lock"; echo $$ > "$TDX/send-coder.lock/pid"; echo "q=2 pid=8" > "$TDX/send-coder.lock/owner"
clr; STUB_TMUX_ALIVE=0 run "$MAIN" $SH kill alfa-coder --graceful 1 --team-dir "$TDX"
has "session killed without /exit" "$WORK/out" || fail "(6) stop-during-send warning"
noline "/exit" "(6) /exit under a held lock"; line "tmux kill-session -t =alfa-coder" "(6) kill under lock"
grep -q '^stop-during-send .* q=2 pid=8$' "$TDX/send-coder.log" || fail "(6) stop-during-send line"
rm -rf "$TDX/send-coder.lock"
clr; run "$MAIN" $SH kill alfa-coder; expect 0 "" "(6) gone = ended"; noline "kill-session" "(6) killed a gone session"

echo "team-smoke-host: (6) kill OK"

# ---- (7) start: env order, argv, CLAUDE_CONFIG_DIR -----------------------------------------------------
clr; run "$MAIN" $SH start alfa-coder --kind team --cwd "$CL" --cli claude --session-id s1 \
  --env "AGENT_COSTS_HOME=" --env "TEAM_RUN_TEAM=alfa" -- 'claude --session-id s1 -- "$(cat p)"'
expect 0 "alfa-coder" "(7) start"
line "tmux new-session -d -s alfa-coder -c $CL -e AGENT_COSTS_HOME= -e TEAM_RUN_TEAM=alfa -e HARNESS_ADDRESS=alfa-coder -e HARNESS_MAIN=$MP -e HARNESS_REGISTRY=$REG -e HARNESS_BACKEND=tmux claude --session-id s1 -- \"\$(cat p)\"" "(7) start argv"
clr; run "$MAIN" $SH start helper:quote --kind helper --cwd "$CL" --cli script -- printf "it's"
expect 0 "" "(7) two-element start"
line "tmux new-session -d -s quote -c $CL -e HARNESS_ADDRESS=helper:quote -e HARNESS_MAIN=$MP -e HARNESS_REGISTRY=$REG -e HARNESS_BACKEND=tmux 'printf' 'it'\\''s'" "(7) quoted join"
mkdir -p "$WORK/cc"; CC="$(cd "$WORK/cc" && pwd -P)"
printf '# fixture\n%s\n' "$WORK/cc" > "$MAIN/.claude/claude-profile"
clr; run "$MAIN" $SH start helper:cc --kind helper --cwd "$CL" --cli claude --claude-home auto -- claude
expect 0 "" "(7) claude home"; grep -q " -e CLAUDE_CONFIG_DIR=$CC claude$" "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(7) CLAUDE_CONFIG_DIR"; }
printf '%s\n' "$WORK/missing" > "$MAIN/.claude/claude-profile"
clr; run "$MAIN" $SH start helper:cc2 --kind helper --cwd "$CL" --cli claude --claude-home auto -- claude
expect 1 "error: Claude profile" "(7) bad claude profile"; noline "new-session" "(7) launched with a bad profile"
rm -f "$MAIN/.claude/claude-profile"
clr; STUB_TMUX_ALIVE=0 run "$MAIN" $SH start alfa-coder --kind team --cwd "$CL" --cli claude -- claude
expect 1 "already running" "(7) live address refused"; noline "new-session" "(7) started twice"

echo "team-smoke-host: (7) start: env order, argv, CLAUDE_CONFIG_DIR OK"

# ---- (8) the record, backend per record ------------------------------------------------------------------
jq -e --arg cl "$CL" '.address == "alfa-coder" and .kind == "team" and .backend == "tmux"
  and .handle == "alfa-coder" and .name == "alfa-coder" and .cwd == $cl and .cli == "claude"
  and .session_id == "s1" and .team_dir == ($cl + "/.agents/team") and (.started_at | length > 0)' \
  "$REG/alfa-coder.json" >/dev/null || { cp "$REG/alfa-coder.json" "$WORK/out"; fail "(8) record fields"; }
prof '.teams.session_host = "herdr"'
STUB_TMUX_ALIVE=0 run "$MAIN" env -u TEAM_SESSION_HOST $SH alive alfa-coder; expect 0 "" "(8) tmux record under a herdr profile"
echo '{"address":"beta-coder","backend":"herdr"}' > "$REG/beta-coder.json"
run "$MAIN" $SH alive beta-coder; expect 6 "not yet supported" "(8) herdr record"
# A gone tmux record does not pin a fresh start: the configured backend decides.
run "$MAIN" env -u TEAM_SESSION_HOST $SH start alfa-coder --kind team --cwd "$CL" --cli claude -- claude
expect 6 "not yet supported" "(8) fresh start uses the configured backend"

echo "team-smoke-host: (8) the record, backend per record OK"

# ---- (9) host selection -----------------------------------------------------------------------------------
run "$MAIN" env -u TEAM_SESSION_HOST $SH start helper:h1 --kind helper --cwd "$CL" --cli script -- true
expect 6 "teams.session_host=herdr: not yet supported" "(9) herdr"
prof '.teams.session_host = "tmux"'
run "$MAIN" env -u TEAM_SESSION_HOST TMUX_BIN=no-such-tmux $SH start helper:h1 --kind helper --cwd "$CL" --cli script -- true
expect 6 "no session host" "(9) no tmux"
prof '.teams.session_host = "herdr"'
clr; run "$MAIN" env TEAM_SESSION_HOST=tmux $SH start helper:h2 --kind helper --cwd "$CL" --cli script -- true
expect 0 "" "(9b) TEAM_SESSION_HOST overrides the profile"
run "$MAIN" env TEAM_SESSION_HOST=tmux $SH --check-host; expect 0 "tmux" "(9b) check-host"
run "$MAIN" env -u TEAM_SESSION_HOST $SH --check-host; expect 6 "not yet supported" "(9b) check-host herdr"
run "$MAIN" env TMUX_BIN=no-such-tmux $SH --check-host; expect 6 "no session host" "(9b) check-host none"
prof '.'

echo "team-smoke-host: (9) host selection OK"

# ---- (10) --lock-held -------------------------------------------------------------------------------------
mkdir "$TDX/send-coder.lock"; echo $$ > "$TDX/send-coder.lock/pid"; echo "q=3 attempt=1 pid=9" > "$TDX/send-coder.lock/owner"
clr; run "$MAIN" $SH keys alfa-coder --team-dir "$TDX" --lock-held "q=3 attempt=1 pid=9" enter
expect 0 "" "(10) right owner"; line "tmux send-keys -t =alfa-coder: Enter" "(10) keys sent"
[ -d "$TDX/send-coder.lock" ] || fail "(10) a held lock was released by the driver"
clr; run "$MAIN" $SH type alfa-coder --team-dir "$TDX" --lock-held "someone else" "x"
expect 10 "" "(10) wrong owner"; noline "send-keys" "(10) typed with a wrong owner"
rm -rf "$TDX/send-coder.lock"
run "$MAIN" bash -c "mkdir -p '$REG' && . '$L/session-host-lib.sh' && sh_lock '$MP' Supervisor '' 'me' 1 && [ -d '$REG/Supervisor.lock' ] && sh_unlock '$MP' Supervisor '' && [ ! -d '$REG/Supervisor.lock' ]"
expect 0 "" "(10) role lock in the registry"

echo "team-smoke-host: (10) --lock-held OK"

# ---- (11) TEAM_SMOKE guard ----------------------------------------------------------------------------------
run "$MAIN" env TMUX_BIN=/usr/bin/true $SH alive alfa-coder; expect 1 "refusing" "(11) real binary refused"

echo "team-smoke-host: (11) TEAM_SMOKE guard OK"

# ---- (12) readiness wait --------------------------------------------------------------------------------------
printf 'Accessing workspace:\n\n Do you trust the files in this folder?\n\n ❯ 1. Yes, proceed\n   2. No, exit\n' > "$WORK/trust.txt"
clr; STUB_PANE="$WORK/trust.txt" TEAM_HOST_READY_POLL=0 TEAM_HOST_READY_SECS=3 \
  run "$MAIN" $SH start helper:t1 --kind helper --cwd "$CL" --cli claude --wait-ready -- claude
expect 0 "waiting at the folder trust dialog" "(12) trust reported"; noline "send-keys" "(12) trust answered"
printf '  ✨ Update available! 0.1.0 -> 0.2.0\n\n› 1. Update now\n  2. Skip\n' > "$WORK/update.txt"
clr; STUB_PANE="$WORK/update.txt" TEAM_HOST_READY_POLL=0 TEAM_HOST_READY_SECS=3 \
  run "$MAIN" $SH start helper:c1 --kind helper --cwd "$CL" --cli codex --wait-ready -- codex
expect 0 "no sign of life" "(12) codex update"
[ "$(count "tmux send-keys -t =c1: Escape")" = 1 ] || { cp "$STUB_LOG" "$WORK/out"; fail "(12) one esc"; }
clr; STUB_PANE="$PANES/idle.txt" TEAM_HOST_READY_POLL=0 run "$MAIN" $SH start helper:r1 --kind helper --cwd "$CL" --cli claude --wait-ready -- claude
expect 0 "" "(12) ready"; has "warn:" "$WORK/out" && fail "(12) a ready session warned"
clr; run "$MAIN" $SH start helper:n1 --kind helper --cwd "$CL" --cli claude -- claude
noline "capture-pane" "(12) a start without --wait-ready read the pane"

echo "team-smoke-host: (12) readiness wait OK"

# ---- (13) sh_gen / sh_pid -------------------------------------------------------------------------------------
clr; STUB_TMUX_ALIVE=0 run "$MAIN" bash -c ". '$L/session-host-lib.sh'; sh_gen alfa-coder; sh_pid alfa-coder"
expect 0 "%1@1700000000" "(13) gen"; has 4242 "$WORK/out" || fail "(13) pid"
line "tmux display-message -p -t =alfa-coder: #{pane_id}@#{session_created}" "(13) gen argv"
line "tmux display-message -p -t =alfa-coder: #{pane_pid}" "(13) pid argv"

echo "team-smoke-host: (13) sh_gen / sh_pid OK"

# ---- (14) hint, (15) main root, (16) program check, (17) status, (18) refusals -------------------------------
run "$MAIN" $SH hint alfa-coder; expect 0 "tmux attach -t alfa-coder" "(14) hint"
run "$MAIN" $SH hint Supervisor; expect 0 "-supervisor" "(14) role hint"
git -C "$CL" init --quiet; echo '{"team":"alfa"}' > "$TDX/team.json"
run "$CL" $SH alive alfa-coder; expect 2 "team clone" "(15) git root of a clone refused"
run "$CL" env HARNESS_MAIN="$MAIN" $SH alive alfa-coder; expect 3 "" "(15) HARNESS_MAIN from a clone"
run "$CL" env HARNESS_REGISTRY="$REG" $SH alive alfa-coder; expect 3 "" "(15) HARNESS_REGISTRY from a clone"
run "$CL" $SH alive alfa-coder --main "$MAIN"; expect 3 "" "(15) --main from a clone"
echo '{"address":"Supervisor","backend":"tmux","program":"claude"}' > "$REG/Supervisor.json"
STUB_TMUX_ALIVE=0 STUB_PANE_CMD=bash run "$MAIN" $SH alive Supervisor; expect 3 "" "(16) a shell is not the program"
STUB_TMUX_ALIVE=0 run "$MAIN" $SH alive Supervisor; expect 0 "" "(16) the program runs"
STUB_TMUX_ALIVE=0 run "$MAIN" $SH status alfa-coder; expect 0 '"state":"starting"' "(17) status alive, no state yet"
run "$MAIN" $SH status alfa-coder; expect 0 '"state":"gone"' "(17) status gone"
run "$MAIN" $SH start adhoc-t1 --kind role --cwd "$CL" --cli claude -- claude; expect 2 "registry only" "(18) adhoc"
run "$MAIN" $SH alive 'bad name'; expect 2 "must match" "(18) malformed address"
run "$MAIN" $SH; expect 2 "Usage" "(18) usage"
run "$MAIN" $SH frob x; expect 2 "unknown verb" "(18) unknown verb"

echo "team-smoke-host: (14) hint, (15) main root, (16) program check, (17) status, (18) refusals OK"
# ---- (19) status hook without HARNESS_ADDRESS: no file, today's output and tmux calls -------------
HK="$SRC/.claude/hooks/team-status.sh"
hk() {  # hk <payload> [env…] → RC, $WORK/out
  local p="$1"; shift
  set +e; printf '%s' "$p" | env "$@" bash "$HK" > "$WORK/out" 2>&1; RC=$?; set -e
}
SD="$WORK/hreg"
for ev in '"hook_event_name":"UserPromptSubmit"' '"hook_event_name":"PostToolUse"' '"hook_event_name":"Stop"' \
  '"hook_event_name":"SessionEnd"' '"hook_event_name":"Notification","notification_type":"permission_prompt"' \
  '"hook_event_name":"Notification","notification_type":"idle_prompt"' '"hook_event_name":"Notification","notification_type":"other"' \
  '"hook_event_name":"PreCompact"'; do
  clr; hk "{\"session_id\":\"s1\",\"transcript_path\":\"/t\",$ev}" -u HARNESS_ADDRESS HARNESS_REGISTRY="$SD" TMUX="/tmp/x,1,0" TMUX_PANE=%3
  [ "$RC" = 0 ] && [ ! -s "$WORK/out" ] || fail "(19) $ev: rc $RC or output"
  [ ! -e "$SD" ] || fail "(19) $ev: a state file without HARNESS_ADDRESS"
  case "$ev" in
    *other*|*PreCompact*) [ ! -s "$STUB_LOG" ] || { cp "$STUB_LOG" "$WORK/out"; fail "(19) $ev: tmux called"; } ;;
    *) [ "$(cat "$STUB_LOG")" = "tmux -S /tmp/x display-message -p -t %3 #S" ] \
         || { cp "$STUB_LOG" "$WORK/out"; fail "(19) $ev: tmux calls changed"; } ;;
  esac
done
clr; hk '{"session_id":"s1","hook_event_name":"Stop"}' -u TMUX -u HARNESS_ADDRESS
[ "$RC" = 0 ] && [ ! -s "$WORK/out" ] && [ ! -s "$STUB_LOG" ] || fail "(19) outside tmux"
echo "team-smoke-host: (19) status hook without HARNESS_ADDRESS OK"

# ---- (20) status hook → state file: mapping, session fence, refusals -------------------------------
mkdir -p "$SD"; rm -f "$SD"/*.json
SF="$SD/state/alfa-coder.json"
st() { hk "{\"session_id\":\"${2:-s1}\",\"transcript_path\":\"/t/s.jsonl\",$1}" -u TMUX HARNESS_ADDRESS=alfa-coder HARNESS_REGISTRY="$SD" ${3:-}; }
want() { jq -e "$1" "$SF" >/dev/null 2>&1 || { cat "$SF" > "$WORK/out" 2>&1; fail "(20) $2"; }; }
st '"hook_event_name":"UserPromptSubmit"'; want '.state == "working" and .kind == null and .session_id == "s1" and .transcript_path == "/t/s.jsonl"' "working"
[ ! -s "$WORK/out" ] || fail "(20) the hook printed something"
st '"hook_event_name":"Notification","notification_type":"permission_prompt"'; want '.state == "blocked" and .kind == "permission"' "permission"
st '"hook_event_name":"Notification","notification_type":"elicitation_dialog"'; want '.kind == "question"' "question"
st '"hook_event_name":"Notification","notification_type":"agent_needs_input"'; want '.kind == "input"' "input"
st '"hook_event_name":"Notification","notification_type":"idle_prompt"'; want '.state == "idle"' "idle"
st '"hook_event_name":"Stop"'; want '.state == "done"' "Stop is done"
st '"hook_event_name":"PostToolUse","tool_input":{"session_id":"evil","hook_event_name":"Stop"}'
want '.state == "working" and .session_id == "s1"' "nested keys do not win"
echo '{"address": "alfa-coder", "session_id": "s1"}' > "$SD/alfa-coder.json"
st '"hook_event_name":"Stop"' s2; want '.state == "working"' "a foreign session id is fenced off"
st '"hook_event_name":"SessionEnd"' s2; [ -f "$SF" ] || fail "(20) an old SessionEnd removed the live state"
st '"hook_event_name":"SessionEnd"'; [ ! -f "$SF" ] || fail "(20) SessionEnd kept the state file"
st '"hook_event_name":"Stop"' s1 HARNESS_BACKEND=herdr; [ ! -f "$SF" ] || fail "(20) wrote under HARNESS_BACKEND=herdr"
hk '{"session_id":"s1","hook_event_name":"Stop"}' -u TMUX HARNESS_ADDRESS=../x HARNESS_REGISTRY="$SD"
[ "$RC" = 0 ] && [ ! -e "$SD/x.json" ] && [ ! -e "$WORK/x.json" ] || fail "(20) a path in HARNESS_ADDRESS"
echo "team-smoke-host: (20) state file OK"

# ---- (21) team_prompt.py pending-tool ------------------------------------------------------------------
TR="$WORK/t.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Read","input":{"file_path":"/x"}}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a"}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b","name":"Bash","input":{"command":"rm -rf build","description":"d"}}]}}' > "$TR"
[ "$(python3 -I "$L/team_prompt.py" pending-tool "$TR")" = '{"tool": "Bash", "detail": "rm -rf build"}' ] || fail "(21) open Bash call"
head -n 2 "$TR" > "$WORK/t2.jsonl"; [ "$(python3 -I "$L/team_prompt.py" pending-tool "$WORK/t2.jsonl")" = '{}' ] || fail "(21) nothing open"
[ "$(python3 -I "$L/team_prompt.py" pending-tool "$WORK/none.jsonl")" = unknown ] || fail "(21) unreadable"
echo "team-smoke-host: (21) pending-tool OK"

# ---- (22) status from the state file ----------------------------------------------------------------------
mkdir -p "$REG/state"
put_state() { printf '{"state":"%s","kind":%s,"session_id":"%s","transcript_path":"%s"}\n' "$1" "$2" "$3" "$TR" > "$REG/state/alfa-coder.json"; }
put_state working null s1
STUB_TMUX_ALIVE=0 run "$MAIN" $SH status alfa-coder; expect 0 '"state":"working","kind":null,"msg":null,"source":"hook"' "(22) working"
put_state blocked '"permission"' s1
STUB_TMUX_ALIVE=0 run "$MAIN" $SH status alfa-coder; expect 0 '"state":"blocked","kind":"permission","msg":"Bash: rm -rf build"' "(22) blocked + msg"
noline capture-pane "(22) status read the screen"
put_state done null s0
STUB_TMUX_ALIVE=0 run "$MAIN" $SH status alfa-coder; expect 0 '"state":"starting"' "(22) a leftover of another session"
echo '{"address":"alfa-qa","cli":"codex","backend":"tmux"}' > "$REG/alfa-qa.json"
STUB_TMUX_ALIVE=0 run "$MAIN" $SH status alfa-qa; expect 0 '"state":"unknown"' "(22) codex"
STUB_TMUX_ALIVE=0 run "$MAIN" $SH status alfa-planner; expect 0 '"state":"unknown"' "(22) no record"
echo "team-smoke-host: (22) status OK"

# ---- (23) send → 9 while blocked ------------------------------------------------------------------------------
put_state blocked '"permission"' s1
clr; STUB_SOCK_RC=0 STUB_TMUX_ALIVE=0 STUB_PANE="$PANES/idle.txt" run "$MAIN" $SH send alfa-coder "ring" --team-dir "$TDX" --reg "$WORK/reg.json"
expect 9 "" "(23) blocked"; noline "send-keys" "(23) typed into a dialog"; noline "socket" "(23) used the socket"
grep -q '^doorbell-blocked .* — ring$' "$TDX/send-coder.log" || fail "(23) doorbell-blocked line"
put_state idle null s1
clr; STUB_TMUX_ALIVE=0 STUB_PANE="$PANES/idle.txt" run "$MAIN" $SH send alfa-coder "ring2" --team-dir "$TDX"; expect 0 "" "(23) idle again"
echo "team-smoke-host: (23) send while blocked OK"

echo "team-smoke-host: OK"
