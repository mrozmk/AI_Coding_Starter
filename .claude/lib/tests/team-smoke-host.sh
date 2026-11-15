#!/usr/bin/env bash
# team-smoke: serial
# The session-host driver: every tmux verb's argv equals the call it replaces, exit codes, locks, the
# registry record, backend resolution, the main-root rule and the readiness wait; the Herdr backend
# behind the fake hc (cases H1–H13).
# Serial: the readiness and graceful-kill cases sleep.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

# The driver runs from a copy, so the messaging-socket sender can be a stub.
L="$WORK/drv"; mkdir -p "$L"
cp "$SRC/.claude/lib/session-host.sh" "$SRC/.claude/lib/session-host-lib.sh" \
  "$SRC/.claude/lib/team-send-lock.sh" "$SRC/.claude/lib/team-channel.sh" "$SRC/.claude/lib/roles-lib.sh" \
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
line "tmux has-session -t =smk-alfa-coder" "(1) alive argv"
run "$MAIN" $SH alive alfa-coder; expect 3 "" "(1) gone"
STUB_TMUX_ERR="protocol version mismatch" run "$MAIN" $SH alive alfa-coder
expect 1 "protocol version mismatch" "(1) probe failed"

echo "team-smoke-host: (1) alive: 0 / 3 / 1 OK"

# ---- (2) read / history / read by target -----------------------------------------------------------
clr; STUB_PANE="$PANES/idle.txt" run "$MAIN" $SH read alfa-coder; expect 0 "" "(2) read"
line "tmux capture-pane -p -t =smk-alfa-coder:" "(2) read argv"
grep -q '^[[:space:]]*$' "$WORK/out" && fail "(2) read kept a blank line"
clr; run "$MAIN" $SH read alfa-coder --history 200; expect 0 "" "(2) history"
line "tmux capture-pane -p -J -S -200 -t =smk-alfa-coder:" "(2) history argv"
clr; run "$MAIN" bash -c ". '$L/session-host-lib.sh'; sh_read_target %1 --escapes"
expect 0 "" "(2) read target"; line "tmux capture-pane -p -e -J -S -200 -t %1" "(2) target argv"
clr; run "$MAIN" bash -c ". '$L/session-host-lib.sh'; sh_read_target %1 --history 50 --squeeze"
line "tmux capture-pane -p -J -S -50 -t %1" "(2) squeeze argv"

echo "team-smoke-host: (2) read / history / read by target OK"

# ---- (3) keys ----------------------------------------------------------------------------------------
clr; run "$MAIN" $SH keys alfa-coder --team-dir "$TDX" enter esc up down tab ctrl-c ctrl-e ctrl-u
expect 0 "" "(3) keys"; line "tmux send-keys -t =smk-alfa-coder: Enter Escape Up Down Tab C-c C-e C-u" "(3) keys argv"
[ ! -d "$TDX/send-coder.lock" ] || fail "(3) keys left the lock behind"
clr; run "$MAIN" $SH keys alfa-coder --team-dir "$TDX" enter bogus; expect 2 "unknown key" "(3) unknown key"
noline "send-keys" "(3) unknown key typed something"
clr; run "$MAIN" $SH keys alfa-coder --target %1 --team-dir "$TDX" Enter
expect 0 "" "(3) keys target"; line "tmux send-keys -t %1 Enter" "(3) keys target argv"
clr; run "$MAIN" $SH keys alfa-coder enter; expect 10 "" "(3) team address without a team dir"

echo "team-smoke-host: (3) keys OK"

# ---- (4) type ----------------------------------------------------------------------------------------
clr; run "$MAIN" $SH type alfa-coder --team-dir "$TDX" "hello world"; expect 0 "" "(4) type"
line "tmux send-keys -t =smk-alfa-coder: -l -- hello world" "(4) type argv"; noline "Enter" "(4) type pressed Enter"
clr; run "$MAIN" $SH type alfa-coder --team-dir "$TDX" "hi" --enter; expect 0 "" "(4) type --enter"
line "tmux send-keys -t =smk-alfa-coder: -l -- hi" "(4) type text"; line "tmux send-keys -t =smk-alfa-coder: Enter" "(4) enter"
clr; run "$MAIN" $SH type alfa-coder --target %1 --team-dir "$TDX" "x"; line "tmux send-keys -t %1 -l -- x" "(4) type target"

echo "team-smoke-host: (4) type OK"

# ---- (5) send: socket → idle input → skip ---------------------------------------------------------------
echo '{}' > "$WORK/reg.json"
clr; STUB_SOCK_RC=0 STUB_TMUX_ALIVE=0 run "$MAIN" $SH send alfa-coder "ping" --team-dir "$TDX" --reg "$WORK/reg.json"
expect 0 "" "(5) socket"; line "socket $WORK/reg.json" "(5) socket used"; noline "send-keys" "(5) socket typed too"
clr; STUB_TMUX_ALIVE=0 STUB_PANE="$PANES/idle.txt" run "$MAIN" $SH send alfa-coder $'two\nlines' --team-dir "$TDX"
expect 0 "" "(5) idle fallback"; line "tmux send-keys -t =smk-alfa-coder: -l -- two lines" "(5) idle text"
line "tmux send-keys -t =smk-alfa-coder: Enter" "(5) idle enter"
clr; STUB_TMUX_ALIVE=0 STUB_PANE="$PANES/perm-az.txt" run "$MAIN" $SH send alfa-coder "ping" --team-dir "$TDX"
expect 10 "" "(5) not idle"; noline "send-keys" "(5) typed into a prompt"
grep -q '^doorbell-skipped .* input not idle — ping$' "$TDX/send-coder.log" || fail "(5) not-idle log line"
mkdir "$TDX/send-coder.lock"; echo $$ > "$TDX/send-coder.lock/pid"; echo "q=1 pid=7" > "$TDX/send-coder.lock/owner"
clr; STUB_TMUX_ALIVE=0 STUB_PANE="$PANES/idle.txt" run "$MAIN" $SH send alfa-coder "ping2" --team-dir "$TDX"
expect 10 "" "(5) lock held"; noline "send-keys" "(5) typed under a held lock"
grep -q '^doorbell-skipped .* send lock held by q=1 pid=7 — ping2$' "$TDX/send-coder.log" || fail "(5) lock log line"
clr; run "$MAIN" $SH send alfa-coder "ping3" --team-dir "$TDX"; expect 3 "" "(5) gone"
grep -q 'session smk-alfa-coder not alive — ping3$' "$TDX/send-coder.log" || fail "(5) gone log line"
rm -rf "$TDX/send-coder.lock"
mkdir -p "$REG"; echo '{"address":"alfa-runner","cli":"script","backend":"tmux"}' > "$REG/alfa-runner.json"
run "$MAIN" $SH send alfa-runner "x"; expect 2 "script session" "(5) script refused"

echo "team-smoke-host: (5) send: socket → idle input → skip OK"

# ---- (6) kill ----------------------------------------------------------------------------------------
clr; STUB_TMUX_ALIVE=0 STUB_PANE="$PANES/idle.txt" run "$MAIN" $SH kill alfa-coder --graceful 1 --team-dir "$TDX"
expect 1 "" "(6) graceful (the stub never dies)"
line "tmux send-keys -t =smk-alfa-coder: /exit Enter" "(6) /exit"; line "tmux kill-session -t =smk-alfa-coder" "(6) kill"
mkdir "$TDX/send-coder.lock"; echo $$ > "$TDX/send-coder.lock/pid"; echo "q=2 pid=8" > "$TDX/send-coder.lock/owner"
clr; STUB_TMUX_ALIVE=0 run "$MAIN" $SH kill alfa-coder --graceful 1 --team-dir "$TDX"
has "session killed without /exit" "$WORK/out" || fail "(6) stop-during-send warning"
noline "/exit" "(6) /exit under a held lock"; line "tmux kill-session -t =smk-alfa-coder" "(6) kill under lock"
grep -q '^stop-during-send .* q=2 pid=8$' "$TDX/send-coder.log" || fail "(6) stop-during-send line"
rm -rf "$TDX/send-coder.lock"
clr; run "$MAIN" $SH kill alfa-coder; expect 0 "" "(6) gone = ended"; noline "kill-session" "(6) killed a gone session"

echo "team-smoke-host: (6) kill OK"

# ---- (7) start: env order, argv, CLAUDE_CONFIG_DIR -----------------------------------------------------
clr; run "$MAIN" $SH start alfa-coder --kind team --cwd "$CL" --cli claude --session-id s1 \
  --env "AGENT_COSTS_HOME=" --env "TEAM_RUN_TEAM=alfa" -- 'claude --session-id s1 -- "$(cat p)"'
expect 0 "alfa-coder" "(7) start"
line "tmux new-session -d -s smk-alfa-coder -c $CL -e AGENT_COSTS_HOME= -e TEAM_RUN_TEAM=alfa -e HARNESS_ADDRESS=alfa-coder -e HARNESS_MAIN=$MP -e HARNESS_REGISTRY=$REG -e HARNESS_BACKEND=tmux env -u CLAUDE_CONFIG_DIR claude --session-id s1 -- \"\$(cat p)\"" "(7) start argv"
clr; run "$MAIN" $SH start helper:quote --kind helper --cwd "$CL" --cli script -- printf "it's"
expect 0 "" "(7) two-element start"
line "tmux new-session -d -s smk-quote -c $CL -e HARNESS_ADDRESS=helper:quote -e HARNESS_MAIN=$MP -e HARNESS_REGISTRY=$REG -e HARNESS_BACKEND=tmux 'printf' 'it'\\''s'" "(7) quoted join"
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
  and .handle == "smk-alfa-coder" and .name == "smk-alfa-coder" and .cwd == $cl and .cli == "claude"
  and .session_id == "s1" and .team_dir == ($cl + "/.agents/team") and (.started_at | length > 0)' \
  "$REG/alfa-coder.json" >/dev/null || { cp "$REG/alfa-coder.json" "$WORK/out"; fail "(8) record fields"; }
prof '.teams.session_host = "herdr"'
STUB_TMUX_ALIVE=0 run "$MAIN" env -u TEAM_SESSION_HOST $SH alive alfa-coder; expect 0 "" "(8) tmux record under a herdr profile"
echo '{"address":"beta-coder","backend":"herdr","handle":"t9z"}' > "$REG/beta-coder.json"
clr; run "$MAIN" $SH alive beta-coder; expect 0 "" "(8) herdr record"; line "hc get t9z --json" "(8) herdr record by handle"
# A gone tmux record does not pin a fresh start: the configured backend decides.
cp "$REG/alfa-coder.json" "$WORK/alfa-coder.rec"
clr; STUB_HC_GONE=1 run "$MAIN" env -u TEAM_SESSION_HOST $SH start alfa-coder --kind team --cwd "$CL" --cli claude -- claude
expect 0 "" "(8) fresh start uses the configured backend"
[ "$(jq -r .backend "$REG/alfa-coder.json")" = herdr ] || fail "(8) fresh start not on herdr"
noline "new-session" "(8) fresh herdr start used tmux"
cp "$WORK/alfa-coder.rec" "$REG/alfa-coder.json"

echo "team-smoke-host: (8) the record, backend per record OK"

# ---- (9) host selection -----------------------------------------------------------------------------------
STUB_HC_SERVER=1 run "$MAIN" env -u TEAM_SESSION_HOST $SH start helper:h1 --kind helper --cwd "$CL" --cli script -- true
expect 6 "no session host: herdr core not answering" "(9) herdr without a core"
prof '.teams.session_host = "tmux"'
run "$MAIN" env -u TEAM_SESSION_HOST TMUX_BIN=no-such-tmux $SH start helper:h1 --kind helper --cwd "$CL" --cli script -- true
expect 6 "no session host" "(9) no tmux"
prof '.teams.session_host = "herdr"'
clr; run "$MAIN" env TEAM_SESSION_HOST=tmux $SH start helper:h2 --kind helper --cwd "$CL" --cli script -- true
expect 0 "" "(9b) TEAM_SESSION_HOST overrides the profile"
run "$MAIN" env TEAM_SESSION_HOST=tmux $SH --check-host; expect 0 "tmux" "(9b) check-host"
run "$MAIN" env -u TEAM_SESSION_HOST $SH --check-host; expect 0 "herdr" "(9b) check-host herdr"
STUB_HC_SERVER=1 run "$MAIN" env -u TEAM_SESSION_HOST $SH --check-host; expect 6 "herdr core not answering" "(9b) check-host herdr down"
run "$MAIN" env TMUX_BIN=no-such-tmux $SH --check-host; expect 6 "no session host" "(9b) check-host none"
prof '.'

echo "team-smoke-host: (9) host selection OK"

# ---- (10) --lock-held -------------------------------------------------------------------------------------
mkdir "$TDX/send-coder.lock"; echo $$ > "$TDX/send-coder.lock/pid"; echo "q=3 attempt=1 pid=9" > "$TDX/send-coder.lock/owner"
clr; run "$MAIN" $SH keys alfa-coder --team-dir "$TDX" --lock-held "q=3 attempt=1 pid=9" enter
expect 0 "" "(10) right owner"; line "tmux send-keys -t =smk-alfa-coder: Enter" "(10) keys sent"
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
[ "$(count "tmux send-keys -t =smk-c1: Escape")" = 1 ] || { cp "$STUB_LOG" "$WORK/out"; fail "(12) one esc"; }
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
run "$MAIN" $SH hint alfa-coder; expect 0 "tmux attach -t smk-alfa-coder" "(14) hint"
run "$MAIN" $SH hint Supervisor; expect 0 "tmux attach -t smk-supervisor" "(14) role hint"
run "$MAIN" env -u TMUX_TMPDIR $SH hint Supervisor
expect 0 "tmux attach -t smk-supervisor" "(14) no TMUX_TMPDIR"; ! has "TMUX_TMPDIR" "$WORK/out" || fail "(14) a hint without TMUX_TMPDIR names it"
run "$MAIN" env TMUX_TMPDIR="$WORK/tsock" $SH hint Supervisor
expect 0 "TMUX_TMPDIR=$WORK/tsock tmux attach -t smk-supervisor" "(14) the hint names the project's tmux server"
run "$MAIN" env TMUX_TMPDIR="$WORK/t sock" $SH hint Supervisor
expect 0 "TMUX_TMPDIR='$WORK/t sock' tmux attach -t smk-supervisor" "(14) a TMUX_TMPDIR with a space is quoted"
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
# ---- (19) status hook without HARNESS_ADDRESS: no file, no output, no tmux call (no OSC, #29) -----
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
  [ ! -s "$STUB_LOG" ] || { cp "$STUB_LOG" "$WORK/out"; fail "(19) $ev: tmux called"; }
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
# Inside tmux the state file is still written, and no tmux client is written to (#29).
clr; st '"hook_event_name":"Stop"' s1 'TMUX=/tmp/x,1,0 TMUX_PANE=%3'; want '.state == "done"' "inside tmux"
[ "$RC" = 0 ] && [ ! -s "$STUB_LOG" ] || { cp "$STUB_LOG" "$WORK/out"; fail "(20) inside tmux: rc $RC or a tmux call"; }; rm -f "$SF"
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

# ---- (24) session-registry: a driver-started session ------------------------------------------------
SR="$SRC/.claude/hooks/session-registry.sh"; IC="$SRC/.claude/hooks/inbox-count.sh"
grep -q transcript "$SR" "$IC" && grep -n transcript "$SR" "$IC" | grep -v '^[^:]*:[0-9]*:#' | grep -q . \
  && fail "(24) a registry hook touches the transcript"
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
B2="$WORK/bin2"; mkdir -p "$B2"   # the hooks call tmux/hc directly: per-case fakes
cat > "$B2/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "$STUB_LOG"
case "$*" in *display-message*) echo "${FAKE_TMUX_NAME:-dev.1}" ;; *has-session*"=${FAKE_TMUX_LIVE:-none}") exit 0 ;; *has-session*) exit 1 ;; esac
STUB
cat > "$B2/hc" <<'STUB'
#!/usr/bin/env bash
echo "hc $*" >> "$STUB_LOG"
[ "$1 $2" = "get ${FAKE_HC_LIVE:-t1k3}" ] || exit 3
echo '{"name":"fix-login","tab":{"name":"Main"},"state":"live"}'
STUB
chmod +x "$B2/tmux" "$B2/hc"
hr() {  # hr <hook> <dir> <session id> [env…] → RC, $WORK/out
  local h="$1" d="$2" sid="$3"; shift 3
  set +e; printf '{"session_id":"%s","transcript_path":"/nonexistent","hook_event_name":"SessionStart","source":"startup"}' "$sid" \
    | env "$@" PATH="$B2:$PATH" HC_BIN="$B2/hc" CLAUDE_PROJECT_DIR="$d" bash "$h" > "$WORK/out" 2>&1; RC=$?; set -e
}
NOV="-u HARNESS_ADDRESS -u HARNESS_REGISTRY -u HARNESS_MAIN -u TEAM_SESSION_ROLE -u HC_TERMINAL_ID -u TMUX -u TMUX_PANE -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN"
hr "$SR" "$MAIN" sess-0001-aaaa $NOV HARNESS_ADDRESS=Supervisor HARNESS_REGISTRY="$REG" \
  CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/1.sock CLAUDE_CODE_MESSAGING_TOKEN=tok-secret
[ "$RC" = 0 ] && [ ! -s "$WORK/out" ] || fail "(24) role: rc $RC or output"
jq -e '.session_id == "sess-0001-aaaa" and (.last_seen | length > 0) and .reg == "Supervisor.reg.json"' "$REG/Supervisor.json" >/dev/null \
  || { cp "$REG/Supervisor.json" "$WORK/out"; fail "(24) role record"; }
grep -q 'tok-secret\|cc-socks' "$REG/Supervisor.json" && fail "(24) a secret in the record"
jq -e '.token == "tok-secret" and .socket == "/tmp/cc-socks/1.sock" and .session_id == "sess-0001-aaaa"' "$REG/Supervisor.reg.json" >/dev/null || fail "(24) registration"
[ "$(mode "$REG/Supervisor.reg.json")" = 600 ] && [ "$(mode "$REG/Supervisor.json")" = 600 ] || fail "(24) modes $(mode "$REG/Supervisor.reg.json") / $(mode "$REG/Supervisor.json")"
hr "$SR" "$MAIN" sess-0002-bbbb $NOV HARNESS_ADDRESS=Supervisor HARNESS_REGISTRY="$REG"
jq -e '.session_id == "sess-0002-bbbb"' "$REG/Supervisor.json" >/dev/null || fail "(24) /clear moves the id"
hr "$SR" "$MAIN" 'bad id!' $NOV HARNESS_ADDRESS=Supervisor HARNESS_REGISTRY="$REG"
jq -e '.session_id == "sess-0002-bbbb"' "$REG/Supervisor.json" >/dev/null || fail "(24) a malformed id was taken"
hr "$SR" "$MAIN" sess-0003-cccc $NOV HARNESS_ADDRESS=Fable HARNESS_REGISTRY="$REG"
[ ! -e "$REG/Fable.json" ] || fail "(24) a record created for an address the driver never started"
echo "team-smoke-host: (24) session-registry, driver-started OK"

# ---- (25) session-registry: a team stage in its clone ------------------------------------------------
echo '{"address":"alfa-coder","backend":"tmux","session_id":"s1"}' > "$REG/alfa-coder.json"
echo '{"team":"alfa","role":"coder","run":"r1","attempt":1,"session_id":"s1"}' > "$TDX/session.json"
hr "$SR" "$CL" sess-0004-dddd $NOV HARNESS_ADDRESS=alfa-qa HARNESS_REGISTRY="$REG"
jq -e '.session_id == "s1"' "$REG/alfa-coder.json" >/dev/null || fail "(25) another stage moved the record"
hr "$SR" "$CL" sess-0004-dddd $NOV HARNESS_ADDRESS=alfa-coder HARNESS_REGISTRY="$REG" TEAM_SESSION_ROLE=TeamLead
jq -e '.session_id == "s1"' "$REG/alfa-coder.json" >/dev/null || fail "(25) the TeamLead branch is not this step's"
hr "$SR" "$CL" sess-0004-dddd $NOV HARNESS_ADDRESS=alfa-coder HARNESS_MAIN="$MP"
jq -e '.session_id == "sess-0004-dddd"' "$REG/alfa-coder.json" >/dev/null || fail "(25) the clone's own stage"
[ ! -e "$TDX/registry" ] || fail "(25) wrote a registry into the clone"
echo "team-smoke-host: (25) session-registry, team stage OK"

# ---- (26) session-registry: ad-hoc sessions ------------------------------------------------------------
clr; hr "$SR" "$MAIN" sess-0005-eeee $NOV HC_TERMINAL_ID=t1k3
[ "$RC" = 0 ] && [ ! -s "$WORK/out" ] || fail "(26) herdr: rc $RC or output"
jq -e --arg m "$MAIN" '.address == "adhoc-t1k3" and .kind == "adhoc" and .backend == "herdr" and .handle == "t1k3"
  and .name == "fix-login" and .tab == "Main" and .cwd == $m and .session_id == "sess-0005-eeee"
  and (keys - ["address","kind","backend","handle","name","tab","cwd","session_id","claude_pid","started_at","last_seen"] == [])' \
  "$REG/adhoc-t1k3.json" >/dev/null || { cp "$REG/adhoc-t1k3.json" "$WORK/out"; fail "(26) herdr record fields"; }
[ "$(mode "$REG/adhoc-t1k3.json")" = 600 ] || fail "(26) ad-hoc record mode"
line "hc get t1k3 --json" "(26) hc probe"
hr "$SR" "$MAIN" sess-0006-ffff $NOV HC_TERMINAL_ID=t1k3
jq -e '.session_id == "sess-0006-ffff"' "$REG/adhoc-t1k3.json" >/dev/null || fail "(26) a new session in the same terminal"
hr "$SR" "$MAIN" sess-0007-gggg $NOV TMUX="/tmp/s,1,0" TMUX_PANE=%4 FAKE_TMUX_NAME=dev.1
jq -e '.address == "adhoc-dev-1" and .backend == "tmux" and .handle == "dev.1"' "$REG/adhoc-dev-1.json" >/dev/null || fail "(26) tmux record"
hr "$SR" "$MAIN" sess-0008-hhhh $NOV
expect 0 "ad-hoc session not registered (plain terminal)" "(26) plain terminal"
n0="$(ls "$REG" | wc -l)"
hr "$SR" "$MAIN" sess-0009-iiii $NOV HC_TERMINAL_ID=t9 TEAM_SESSION_ROLE=Supervisor
hr "$SR" "$CL" sess-0009-iiii $NOV HC_TERMINAL_ID=t9
[ "$(ls "$REG" | wc -l)" = "$n0" ] && [ ! -e "$TDX/registry" ] || fail "(26) a role or a clone got an ad-hoc record"
echo "team-smoke-host: (26) ad-hoc records OK"

# ---- (27) prune: old and gone only ------------------------------------------------------------------------
for x in old-gone old-live new-gone; do
  echo "{\"address\":\"adhoc-$x\",\"backend\":\"tmux\",\"handle\":\"$x\"}" > "$REG/adhoc-$x.json"
done
touch -t 202001010000 "$REG/adhoc-old-gone.json" "$REG/adhoc-old-live.json"
hr "$SR" "$MAIN" sess-0010-jjjj $NOV HC_TERMINAL_ID=t1k3 FAKE_TMUX_LIVE=old-live
[ ! -e "$REG/adhoc-old-gone.json" ] || fail "(27) an old, gone record survived"
[ -e "$REG/adhoc-old-live.json" ] || fail "(27) an old record of a live terminal was pruned"
[ -e "$REG/adhoc-new-gone.json" ] || fail "(27) a recent record was pruned"
echo "team-smoke-host: (27) prune OK"

# ---- (28) inbox-count ----------------------------------------------------------------------------------------
ib() { hr "$IC" "$@"; }
clr
mkdir -p "$MP/.agents/team/inbox/alfa/new" "$MP/.agents/team/inbox/Supervisor/new"
touch "$MP/.agents/team/inbox/alfa/new/1-a.md" "$MP/.agents/team/inbox/alfa/new/2-b.md" "$MP/.agents/team/inbox/alfa/new/x.tmp"
ib "$CL" s $NOV HARNESS_ADDRESS=alfa-lead HARNESS_REGISTRY="$REG"
[ "$RC" = 0 ] && [ "$(cat "$WORK/out")" = "inbox: 2 waiting — .agents/team/inbox/alfa/new" ] || fail "(28) TeamLead reads the team inbox"
ib "$MAIN" s $NOV HARNESS_ADDRESS=Supervisor HARNESS_REGISTRY="$REG"
[ "$RC" = 0 ] && [ ! -s "$WORK/out" ] || fail "(28) an empty inbox printed something"
touch "$MP/.agents/team/inbox/Supervisor/new/3-c.md"
ib "$MAIN" s $NOV HARNESS_ADDRESS=Supervisor HARNESS_MAIN="$MP"; expect 0 "inbox: 1 waiting — .agents/team/inbox/Supervisor/new" "(28) role inbox"
jq '.last_seen = "2020-01-01T00:00:00Z"' "$REG/adhoc-t1k3.json" > "$WORK/r.json" && cat "$WORK/r.json" > "$REG/adhoc-t1k3.json"
touch -t 202001010000 "$REG/adhoc-t1k3.json"; before="2020-01-01T00:00:00Z"
ib "$MAIN" s $NOV HC_TERMINAL_ID=t1k3
[ "$(jq -r .last_seen "$REG/adhoc-t1k3.json")" != "$before" ] || fail "(28) ad-hoc last_seen not refreshed"
[ "$(mode "$REG/adhoc-t1k3.json")" = 600 ] || fail "(28) last_seen write changed the mode"
cp "$REG/adhoc-t1k3.json" "$WORK/rec.bak"; ib "$MAIN" s $NOV HC_TERMINAL_ID=t1k3
cmp -s "$REG/adhoc-t1k3.json" "$WORK/rec.bak" || fail "(28) last_seen rewritten within a minute"
noline "hc " "(28) inbox-count called hc"
echo "team-smoke-host: (28) inbox-count OK"

# ---- (29) roles-lib: the teams.sessions reader and validator ------------------------------------------
RL="$SRC/.claude/lib/roles-lib.sh"
RR="$WORK/roles"; mkdir -p "$RR/.claude/team/sessions" "$RR/.agents/reference/roles"
cp "$SRC/.agents/reference/roles/supervisor.md" "$SRC/.agents/reference/roles/advisor.md" "$RR/.agents/reference/roles/"
cp "$SRC/.claude/team/sessions/Supervisor.settings.json" "$SRC/.claude/team/sessions/Advisor.settings.json" "$RR/.claude/team/sessions/"
rp() { if [ -n "$1" ]; then printf '%s' "$1" > "$RR/.claude/project-profile.json"; else rm -f "$RR/.claude/project-profile.json"; fi; }
rl() { run "$RR" env ROLES_ROOT="$RR" bash -c ". '$RL'; $1"; }
rp ""
rl 'roles_validate && echo "$(roles_list | tr "\n" " ")/ $(roles_list --standing | tr "\n" " ")"'
expect 0 "Supervisor Fable Astra TeamLead / Supervisor Fable Astra " "(29) the shipped default list"
[ "$(cat "$WORK/out")" = "Supervisor Fable Astra TeamLead / Supervisor Fable Astra " ] || fail "(29) the shipped default printed more than the list"
rp '{"teams":{"sessions":{"Supervisor":{"model":"opus","effort":"medium"},"TeamLead":{"model":"opus","effort":"high"},"Advisor":{"model":"opus","effort":"high"}}}}'
rl 'roles_validate && roles_list --standing | tr "\n" " " && roles_cfg Fable settings && roles_cfg Advisor contract && roles_cfg Supervisor place.slot && roles_cfg TeamLead standing'
expect 0 "warning: teams.sessions.Advisor is deprecated — read as Fable" "(29) legacy shape"
[ "$(sed -n 2,6p "$WORK/out" | tr '\n' '|')" = "Supervisor Fable Advisor|.agents/reference/roles/advisor.md|main|false|" ] \
  || fail "(29) legacy shape read with code defaults"
rp '{"teams":{"sessions":{"Fable":{},"Advisor":{"model":"sonnet"}}}}'
rl 'roles_validate && roles_list && roles_cfg Advisor model'
expect 0 "deprecated — read as Fable (ignored: Fable is declared)" "(29) Advisor beside Fable"
[ "$(sed -n 2,3p "$WORK/out" | tr '\n' ' ')" = "Fable opus " ] || fail "(29) Advisor beside Fable is not ignored"
rp '{"teams":{"sessions":{"supervisor":{},"Ab":{"cli":"x","model":"a b","effort":"huge","standing":"y"},"Mon":{"contract":"../x","settings":"a/b","place":{"tab":"Lead","slot":"main"}},"Supervisor":{},"Cx":{"cli":"codex","settings":"Advisor","contract":"none.md","place":{"tab":"","slot":"top"}},"Dx":{"settings":"Gone","contract":"/abs.md"},"Z":3,"Éa":{},"TeamLead":{"effort":"none"}}}}'
rl 'roles_validate'; expect 2 "" "(29) a bad list"
for e in \
  'error: teams.sessions.supervisor: the role name must match ^[A-Z][A-Za-z0-9]{1,23}$' \
  'error: teams.sessions.Éa: the role name must match ^[A-Z][A-Za-z0-9]{1,23}$' \
  'error: teams.sessions.Z: the role name must match ^[A-Z][A-Za-z0-9]{1,23}$' \
  'error: teams.sessions.Ab.standing must be true or false' \
  'error: teams.sessions.Ab.cli=x must be claude|codex' \
  'error: teams.sessions.Ab.model=a b is not a model name' \
  'error: teams.sessions.Ab.effort=huge must be low|medium|high|xhigh|max' \
  'error: teams.sessions.Mon.contract=../x must be a path inside the repo' \
  'error: teams.sessions.Mon.settings=a/b is not a profile name' \
  'error: teams.sessions.Cx.settings is for claude roles only' \
  'error: teams.sessions.Cx.contract=none.md: no such file' \
  'error: teams.sessions.Cx.place.tab is required' \
  'error: teams.sessions.Cx.place.slot=top must be main|side' \
  'error: teams.sessions.Dx.contract=/abs.md must be a path inside the repo' \
  'error: teams.sessions.Dx.settings=Gone: no .claude/team/sessions/Gone.settings.json' \
  'error: teams.sessions.TeamLead.effort=none must be low|medium|high|xhigh|max' \
  'error: teams.sessions: tab Lead has more than one main slot (Mon, Supervisor)'; do
  grep -qxF -- "$e" "$WORK/out" || fail "(29) missing: $e"
done
[ "$(grep -c '^error: ' "$WORK/out")" = 17 ] || fail "(29) not every error collected, or an extra one"
# The locale trap: under a UTF-8 collation, bash's [A-Z] matches lowercase b–z.
rp '{"teams":{"sessions":{"abc":{"standing":false}}}}'
run "$RR" env LC_ALL=en_US.UTF-8 ROLES_ROOT="$RR" bash -c ". '$RL'; roles_validate"
expect 2 "error: teams.sessions.abc: the role name must match" "(29) a lowercase name under en_US.UTF-8"
# standing:false and disabled roles: cli/model/effort only; neither is listed for /roles to start.
rp '{"teams":{"sessions":{"TeamLead":{"standing":false,"model":"fable"},"Old":{"enabled":false,"contract":"gone.md","settings":"Gone"}}}}'
rl 'roles_validate && roles_list | tr "\n" " " && roles_list --standing | wc -l | tr -d " " && roles_is_declared Old && ! roles_is_declared Nobody && echo declared'
expect 0 "" "(29) standing:false and disabled roles"
[ "$(tr '\n' '|' < "$WORK/out")" = "TeamLead 0|declared|" ] || fail "(29) standing:false / disabled listing"
rp '{"teams":{"sessions":[]}}'
rl 'roles_validate'; expect 2 "error: .claude/project-profile.json: teams.sessions is not an object" "(29) no object"
rp '{"teams":'
rl 'roles_validate'; expect 2 "error: .claude/project-profile.json: not valid JSON" "(29) broken profile"
echo "team-smoke-host: (29) roles-lib validator OK"

# ---- (30) a project role from the profile alone; the shipped settings and contracts ------------------------
# A monitoring role with its own contract, settings profile and tab: valid and listed, no code change.
mkdir -p "$RR/docs/roles"; echo "# Monitor" > "$RR/docs/roles/monitor.md"
jq '.env.TEAM_SESSION_ROLE = "Monitor"' "$RR/.claude/team/sessions/Supervisor.settings.json" > "$RR/.claude/team/sessions/Monitor.settings.json"
rp '{"teams":{"sessions":{"Supervisor":{},"Monitor":{"model":"sonnet","effort":"low","settings":"Monitor","contract":"docs/roles/monitor.md","place":{"tab":"Ops","slot":"main"}},"Fable":{},"Astra":{}}}}'
rl 'roles_validate && roles_list --standing | tr "\n" " " && for f in cli model effort settings contract place.tab place.slot standing; do roles_cfg Monitor $f; done | tr "\n" " " && roles_is_declared Monitor && echo declared'
expect 0 "" "(30) a project role"
[ "$(tr '\n' '|' < "$WORK/out")" = "Supervisor Monitor Fable Astra claude sonnet low Monitor docs/roles/monitor.md Ops main true declared|" ] \
  || fail "(30) the project role's values or its place in the list"
! grep -q 'Monitor' "$RL" || fail "(30) roles-lib.sh names the project role"
rm "$RR/.claude/team/sessions/Monitor.settings.json"
rl 'roles_validate'; expect 2 "error: teams.sessions.Monitor.settings=Monitor: no .claude/team/sessions/Monitor.settings.json" "(30) its settings file is required"
rp '{"teams":{"sessions":{"Monitor":{"model":"sonnet","contract":"docs/roles/monitor.md","place":{"tab":"Lead","slot":"main"}},"Supervisor":{}}}}'
rl 'roles_validate'; expect 2 "error: teams.sessions: tab Lead has more than one main slot (Monitor, Supervisor)" "(30) two mains in one tab"
# The Advisor template passes the profile check (its _samples), and the shipped default names
# contracts and settings that exist in the starter itself.
run "$SRC" python3 -I -c 'import sys; sys.path.insert(0, ".claude/lib"); import session_profile_check as s
out = []; rc = s.check_role(".", ".claude/team/sessions", "Advisor", out); print("\n".join(out)); sys.exit(rc)'
expect 0 "Advisor OK" "(30) Advisor.settings.json samples"
mkdir -p "$WORK/noprof"
run "$SRC" env ROLES_ROOT="$WORK/noprof" bash -c ". '$RL'
  for r in Supervisor Fable Astra; do c=\$(roles_cfg \$r contract); [ -f \"\$c\" ] || echo missing \$c; done
  for r in Supervisor Fable; do s=\$(roles_cfg \$r settings); [ -f .claude/team/sessions/\$s.settings.json ] || echo missing \$s; done"
expect 0 "" "(30) shipped contracts and settings"; [ ! -s "$WORK/out" ] || fail "(30) a shipped default names a missing file"
echo "team-smoke-host: (30) project role and shipped profiles OK"

# ---- (31) roles.lock: owner pid + start time, serialised stale reclaim ----------------------------------------
LR="$WORK/lockreg"; LD="$LR/roles.lock"
lk() { run "$WORK" bash -c ". '$RL'; $1"; }
lk "roles_lock '$LR' 1 && cat '$LD/pid' && roles_unlock '$LR'"; expect 0 "" "(31) take and release"
[ ! -e "$LD" ] && [ -s "$WORK/out" ] || fail "(31) the lock was not released"
[ "$(mode "$LR")" = 700 ] || fail "(31) registry dir mode $(mode "$LR")"
bash -c ". '$RL'; roles_lock '$LR' 1 && exec sleep 30" & HOLD=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$LD/pid" ] && break; sleep 0.1; done
[ "$(cat "$LD/pid" 2>/dev/null)" = "$HOLD" ] && [ -s "$LD/started" ] || fail "(31) the holder's pid/started"
lk "roles_lock '$LR' 1"; expect 1 "another /roles is running (pid $HOLD)" "(31) a live holder is waited on"
lk "roles_unlock '$LR'"; [ -e "$LD" ] || fail "(31) a non-holder released the lock"
kill -9 "$HOLD"; wait "$HOLD" 2>/dev/null || true
lk "roles_lock '$LR' 2 && echo got"; expect 0 "got" "(31) a SIGKILLed holder is reclaimed"
rm -rf "$LD"; mkdir "$LD"; echo $$ > "$LD/pid"; echo "Thu Jan  1 00:00:00 1970" > "$LD/started"
lk "roles_lock '$LR' 2 && echo got"; expect 0 "got" "(31) a reused pid (other start time) is reclaimed"
rm -rf "$LD"; mkdir "$LD"; touch -t 202001010000 "$LD"
lk "roles_lock '$LR' 2 && echo got"; expect 0 "got" "(31) a lock with no pid is reclaimed"
rm -rf "$LD"; sleep 0.1 & DEAD=$!; wait "$DEAD"; mkdir "$LD"; echo "$DEAD" > "$LD/pid"
: > "$WORK/lk.log"
for w in a b; do
  bash -c ". '$RL'; roles_lock '$LR' 5 || exit 1; echo in >> '$WORK/lk.log'; sleep 0.4; echo out >> '$WORK/lk.log'; roles_unlock '$LR'" &
done
wait
[ "$(tr '\n' ' ' < "$WORK/lk.log")" = "in out in out " ] || { cp "$WORK/lk.log" "$WORK/out"; fail "(31) two waiters overlapped after a reclaim"; }
[ ! -e "$LD" ] && [ ! -e "$LD.reclaim" ] || fail "(31) a lock or reclaim dir left behind"
echo "team-smoke-host: (31) roles.lock OK"

# ---- (32) records reach jq without a pipe: a large existing record under pipefail ---------------------------
# The CLI runs with pipefail: a `cat record | jq -n` writer killed by SIGPIPE used to drop the write.
big="$(head -c 300000 /dev/zero | tr '\0' x)"
jq -n --arg p "$big" '{address: "gamma-coder", pad: $p}' > "$REG/gamma-coder.json"
clr; run "$MAIN" $SH start gamma-coder --kind team --cwd "$CL" --cli claude --session-id s7 -- claude
expect 0 "gamma-coder" "(32) start over a large record"
! has "could not be written" "$WORK/out" || fail "(32) the record write failed"
jq -e '.address == "gamma-coder" and .session_id == "s7" and (has("pad") | not)' "$REG/gamma-coder.json" >/dev/null \
  || fail "(32) the fresh record did not replace the large one"
jq --arg p "$big" '.pad = $p' "$REG/Supervisor.json" > "$WORK/r.json" && cat "$WORK/r.json" > "$REG/Supervisor.json"
hr "$SR" "$MAIN" sess-0032-zzzz $NOV HARNESS_ADDRESS=Supervisor HARNESS_REGISTRY="$REG"
jq -e '.session_id == "sess-0032-zzzz" and (.pad | length) == 300000' "$REG/Supervisor.json" >/dev/null \
  || fail "(32) session-registry lost a large record"
jq --arg p "$big" '.teams.sessions = {"Supervisor": {"_pad": $p}}' "$WORK/prof.bak" > "$RR/.claude/project-profile.json"
run "$RR" env ROLES_ROOT="$RR" bash -c "set -o pipefail; . '$RL'; roles_list"
expect 0 "Supervisor" "(32) roles_list over a large profile under pipefail"
echo "team-smoke-host: (32) records without a pipe OK"

# ---- (33) follow-up chains: lineage, the count, the ledger --------------------------------------------------
LN="bash $SRC/.claude/lib/team-lineage.sh"
LM="$WORK/lin"; mkdir -p "$LM"; git -C "$LM" init -q; LD="$LM/.agents/team/lineage"
lin() { run "$LM" $LN "$@"; }
printf 'Body.\nFollow-up of #7 · origin #7\n[wrapup r1 create-a]\n' > "$WORK/f8.md"
lin parse "$WORK/f8.md"; expect 0 "parent=7 origin=7" "(33) parse a github follow-up line"
printf 'x\n' > "$WORK/plain.md"; lin parse "$WORK/plain.md"; [ "$RC" = 0 ] && [ ! -s "$WORK/out" ] || fail "(33) a plain ticket parsed as a follow-up"
printf 'Follow-up of 7 · origin 7\nFollow-up of 8 · origin 7\n' > "$WORK/two.md"
lin parse "$WORK/two.md"; expect 2 "names two origins" "(33) two different lines"
lin check ABC-2 --follow-up-of abc; expect 2 "is not a jira, github or none key" "(33) a bad key"
lin record 7 alfa; expect 0 "recorded 7" "(33) an origin is recorded"
lin check 8 --ticket-file "$WORK/f8.md"; [ "$RC" = 0 ] && [ ! -s "$WORK/out" ] || fail "(33) the first follow-up is free"
lin record 8 beta --ticket-file "$WORK/f8.md"; expect 0 "recorded 8 (origin 7)" "(33) follow-up 1"
lin record 9 gamma --follow-up-of 8; expect 0 "recorded 9 (origin 7)" "(33) follow-up 2, a generation deeper"
lin record 9 gamma --follow-up-of 8; expect 0 "9 already recorded" "(33) a re-start is no new link"
[ "$(grep -c '"ticket":"9"' "$LD/starts.jsonl")" = 1 ] || fail "(33) the ledger holds a ticket twice"
lin check 10 --follow-up-of 7
expect 9 "follow-up 3 of origin 7 (8, 9 started) — needs the Operator's consent" "(33) the third (a sibling) is refused"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$LD/refused/10" && [ "$(mode "$LD/refused/10")" = 600 ] \
  || fail "(33) the refusal stamp is missing or not 0600"
cp "$LD/refused/10" "$WORK/stamp10"
lin record 10 delta --follow-up-of 9; expect 9 "follow-up 3 of origin 7" "(33) record refuses the third too"
cmp -s "$LD/refused/10" "$WORK/stamp10" || fail "(33) a second refusal moved the first refusal's time"
lin lineage 11; expect 0 "parent= origin=11" "(33) lineage of a ticket with no lineage"
lin lineage 10 --follow-up-of 9; expect 0 "parent=9 origin=7" "(33) lineage takes the parent's origin from the ledger"
lin lineage 8 --ticket-file "$WORK/f8.md"; expect 0 "parent=7 origin=7" "(33) lineage from the body line"
lin lineage 7; expect 0 "parent= origin=7" "(33) a chain's first ticket is its own origin"
[ ! -e "$LD/refused/7" ] && [ ! -e "$LD/refused/8" ] || fail "(33) a free ticket got a refusal stamp"
! grep -q '"ticket":"10"' "$LD/starts.jsonl" || fail "(33) a refused start was recorded"
lin check 10 --follow-up-of 9 --ticket-file "$WORK/f8.md"; expect 2 "ask the Operator which" "(33) flag and body disagree"
printf 'Follow-up of 9 · origin 3\n' > "$WORK/f10.md"
lin check 10 --ticket-file "$WORK/f10.md"; expect 2 "the ledger has 9 under origin 7" "(33) the body's origin contradicts the ledger"
lin check 11; [ "$RC" = 0 ] || fail "(33) a ticket with no lineage was refused"
[ "$(mode "$LD")" = 700 ] && [ "$(mode "$LD/starts.jsonl")" = 600 ] && [ "$(mode "$LD/consents")" = 700 ] \
  || fail "(33) lineage modes $(mode "$LD") / $(mode "$LD/starts.jsonl")"
! grep -q 'Body\|wrapup r1' "$LD/starts.jsonl" || fail "(33) ticket text in the ledger"
lin list; expect 0 "7: 8 (beta, " "(33) list"
(cd "$LM" && mkdir -p .agents/team && echo '{}' > .agents/team/team.json)
lin check 12; expect 2 "team clone" "(33) refused in a clone"; rm "$LM/.agents/team/team.json"
echo "team-smoke-host: (33) follow-up chains OK"

# ---- (34) consent: terminal only, key typed back, consumed once --------------------------------------------
lin consent 10 --text "go ahead" </dev/null; expect 7 "stdin is not a TTY" "(34) no terminal, no consent"
tty_consent() {  # tty_consent <typed key> <ticket> — a real pty through script(1)
  set +e; (sleep 1; printf '%s\n' "$1"; sleep 1) | (cd "$LM" && script -q /dev/null $LN consent "$2" --text "go ahead, Operator") \
    | tr -d '\r' > "$WORK/out" 2>&1; set -e
}
tty_consent 11 10; has "is not 10 — no consent written" "$WORK/out" || fail "(34) a wrong key wrote a consent"
[ ! -e "$LD/consents/10.md" ] || fail "(34) consent file after a wrong key"
tty_consent 10 10; has "consent written" "$WORK/out" || fail "(34) the terminal consent"
grep -qx 'status: answered' "$LD/consents/10.md" && grep -qx 'answered_via: terminal' "$LD/consents/10.md" \
  && [ "$(mode "$LD/consents/10.md")" = 600 ] || { cp "$LD/consents/10.md" "$WORK/out"; fail "(34) consent fields or mode"; }
lin check 10 --follow-up-of 7; expect 0 "Operator consent .agents/team/lineage/consents/10.md" "(34) check accepts the consent"
lin check 13 --follow-up-of 7; expect 9 "" "(34) a consent for 10 does not open the chain for 13"
lin record 10 delta --follow-up-of 7; expect 0 "consent consumed" "(34) record consumes it"
grep -qx 'status: consumed' "$LD/consents/10.md" || fail "(34) the consent was not consumed"
grep -q '"ticket":"10".*"consent":"consents/10.md"' "$LD/starts.jsonl" || fail "(34) the ledger names no consent"
lin check 13 --follow-up-of 10; expect 9 "follow-up 4 of origin 7 (8, 9, 10 started)" "(34) the fourth needs its own consent"
tty_consent 10 10; has "already started on a consent" "$WORK/out" || fail "(34) a consumed consent was rewritten"
# The Supervisor-window path (no TTY): the Operator's typed message after the refusal holds --text.
[ -f "$LD/refused/13" ] || fail "(34) no refusal stamp for 13"
SUPT="$WORK/supproj"; mkdir -p "$SUPT" "$LM/.agents/team/registry"
sup() {  # sup <uuid> <timestamp> <text> [isMeta] — one user line in the Supervisor transcript
  jq -cn --arg u "$1" --arg t "$2" --arg m "$3" --argjson meta "${4:-false}" \
    '{type: "user", isMeta: $meta, uuid: $u, timestamp: $t, message: {role: "user", content: $m}}' >> "$SUPT/s-sup.jsonl"
}
wlin() { TEAM_DASH_PROJECT_DIR="$SUPT" lin "$@" </dev/null; }
wlin consent 13 --text "consent 13"; expect 7 "no message typed in the Supervisor window" "(34) no Supervisor record"
jq -n --arg c "$LM" '{session_id: "s-sup", cwd: $c}' > "$LM/.agents/team/registry/Supervisor.json"
sup u-old 2000-01-01T00:00:00.000Z "yes, consent 13"
sup u-bell 2099-01-01T00:00:00.000Z "inbox: consent 13"
sup u-run 2099-01-01T00:00:01.000Z "[team-run] consent 13"
sup u-meta 2099-01-01T00:00:02.000Z "consent 13" true
sup u-tw 2099-01-01T00:00:02.500Z "[team-watch #5] 1 signal(s) · mail: consent 13"
sup u-hc 2099-01-01T00:00:02.700Z '<hc from="x">consent 13</hc>'
wlin consent 13 --text "consent 13"
expect 7 "no message typed in the Supervisor window" "(34) an old message, a doorbell, a runner, team-watch, hc or meta line is no consent"
sup u-ask 2099-01-01T00:00:02.800Z "why is 13 refused?"
wlin consent 13 --text "13"; expect 7 "holding 'consent 13'" "(34) a mention of the ticket is no consent"
wlin consent 13 --text "why is 13 refused?"; expect 7 "holding 'consent 13'" "(34) a question naming the ticket is no consent"
sup u-other 2099-01-01T00:00:02.900Z "consent 14"
wlin consent 13 --text "consent 14"; expect 7 "holding 'consent 13'" "(34) the phrase with another key"
wlin consent 13 --text "consent 130"; expect 7 "holding 'consent 13'" "(34) the key is a whole word"
sup u-op 2099-01-01T00:00:03.000Z "OK — Consent 13, I accept the chain"
wlin consent 11 --text "consent 11"; expect 7 "no message typed" "(34) a ticket never refused has no window path"
wlin consent 13 --text "Consent 13, go ahead"; expect 7 "no message typed" "(34) --text must be the Operator's words verbatim"
wlin consent 13 --text "Consent 13, I accept the chain"; expect 0 "consent written" "(34) the Supervisor-window consent (any case)"
grep -qx 'answered_via: supervisor-window u-op' "$LD/consents/13.md" && grep -qx 'status: answered' "$LD/consents/13.md" \
  || { cp "$LD/consents/13.md" "$WORK/out"; fail "(34) window consent fields"; }
lin check 13 --follow-up-of 10; expect 0 "Operator consent .agents/team/lineage/consents/13.md" "(34) check accepts the window consent"
echo "team-smoke-host: (34) consent OK"

# ---- (35) no direct tmux call outside the driver (step 1b) -------------------------------------------------
# Every tmux call of the team layer goes through session-host-lib.sh. The exceptions are permanent,
# each with its reason: path, the subcommands allowed there, why. A new direct call anywhere else — or
# another subcommand in an excepted file — fails.
TMUX_RE='(^|[;&|(]|[[:space:]])tmux[[:space:]]+(-S[[:space:]]+[^[:space:]]+[[:space:]]+)?(new-session|has-session|kill-session|capture-pane|send-keys|display-message|list-clients|set-option|attach)'
cat > "$WORK/tmux-exceptions" <<'EXC'
.claude/lib/session-host-lib.sh	.*	— (the driver)
.claude/hooks/session-registry.sh	display-message|has-session	permanent: a SessionStart hook must not pay for sourcing the driver (this terminal's handle through $TMUX's socket)
.claude/hooks/inbox-count.sh	display-message	permanent: a prompt-time hook must not pay for sourcing the driver (this terminal's handle through $TMUX's socket)
EXC
: > "$WORK/tmux-hits"
for f in "$SRC"/.claude/lib/*.sh "$SRC"/.claude/lib/*.py "$SRC"/.claude/hooks/*.sh; do
  rel="${f#"$SRC"/}"; allow="$(awk -F'\t' -v p="$rel" '$1 == p {print $2}' "$WORK/tmux-exceptions")"
  grep -nE "$TMUX_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*(#|echo |printf |die |refuse |TEAM_PROBLEMS\+=|\|\|)' \
    | while IFS= read -r hit; do
        if [ -n "$allow" ] && printf '%s\n' "$hit" | grep -qE "tmux[[:space:]]+(-S[[:space:]]+[^[:space:]]+[[:space:]]+)?($allow)"; then continue; fi
        echo "$rel:$hit" >> "$WORK/tmux-hits"
      done || true
done
grep -rn 'Bash(tmux' "$SRC/.claude/commands" | sed "s|^$SRC/||" >> "$WORK/tmux-hits" || true
[ ! -s "$WORK/tmux-hits" ] || { cp "$WORK/tmux-hits" "$WORK/out"; fail "(35) direct tmux calls outside the driver"; }
# The guard itself catches a call: a fixture file with one.
mkdir -p "$WORK/g/.claude/lib"; printf 'x() {\n  tmux kill-session -t "=a"\n}\n' > "$WORK/g/.claude/lib/team-x.sh"
grep -nE "$TMUX_RE" "$WORK/g/.claude/lib/team-x.sh" | grep -vqE '^[0-9]+:[[:space:]]*(#|echo )' || fail "(35) the scan misses a call"
echo "team-smoke-host: (35) no direct tmux outside the driver OK"

# ---- (36) from a team clone: HARNESS_MAIN picks the main checkout's registry (team-run.sh exports it) ----
mkdir -p "$CL/.agents/team"; echo '{"team":"alfa"}' > "$CL/.agents/team/team.json"
clr; run "$CL" env HARNESS_MAIN="$MP" $SH start alfa-qa --kind team --cwd "$CL" --cli claude --no-probe -- claude
expect 0 "alfa-qa" "(36) start from the clone"
[ -f "$REG/alfa-qa.json" ] && [ ! -e "$CL/.agents/team/registry" ] || fail "(36) the record is not in the main registry"
noline "tmux has-session" "(36) --no-probe probed"
jq -e '.backend == "tmux"' "$REG/alfa-qa.json" >/dev/null || fail "(36) record backend"
run "$CL" $SH alive alfa-qa; expect 2 "team clone — pass --main or set HARNESS_MAIN" "(36) no HARNESS_MAIN in a clone"
clr; STUB_TMUX_ALIVE=0 run "$CL" env HARNESS_MAIN="$MP" $SH alive alfa-qa; expect 0 "" "(36) alive reads the main record"
rm -f "$CL/.agents/team/team.json"
echo "team-smoke-host: (36) clone + HARNESS_MAIN OK"

# ---- (37) session-name prefix: session_prefix, else tmux_prefix, else the repo slug (step 2) -----------------
pfx() {  # pfx <dir name> <profile json> → a fixture main checkout under $WORK/pfx
  local d="$WORK/pfx/$1"; mkdir -p "$d/.claude" "$d/.agents"; printf '%s' "$2" > "$d/.claude/project-profile.json"; echo "$d"
}
SL=". '$L/session-host-lib.sh'"
A="$(pfx alpha '{"teams":{"session_prefix":"pa","channel":{"tmux_prefix":"zz"}}}')"
run "$MAIN" bash -c "$SL; sh_prefix '$A'"; expect 0 "pa" "(37) session_prefix wins"
B="$(pfx beta '{"teams":{"session_prefix":"","channel":{"tmux_prefix":"Mixed_X"}}}')"
run "$MAIN" bash -c "$SL; sh_prefix '$B'"; expect 0 "mixed_x" "(37) empty session_prefix → tmux_prefix, lowercased"
C="$(pfx Gamma-Repo '{"teams":{}}')"
run "$MAIN" bash -c "$SL; sh_prefix '$C'"; expect 0 "gamma-repo" "(37) neither → the repo slug"
echo "team-smoke-host: (37) prefix chain OK"

# ---- (38) a derived prefix over 12 is cut, with one warning; an explicit one over 12 is refused -----------
D="$(pfx ai_coding_starter_x '{"teams":{}}')"
run "$MAIN" bash -c "$SL; sh_prefix '$D'; sh_name '$D' alfa-coder"
expect 0 "warn: session prefix ai_coding_starter_x cut to ai_coding_st — set teams.session_prefix" "(38) cut + warning"
[ "$(grep -c '^warn: session prefix' "$WORK/out")" = 1 ] && grep -qx 'ai_coding_st-alfa-coder' "$WORK/out" || fail "(38) one warning, the cut prefix used"
E="$(pfx toolong '{"teams":{"session_prefix":"abcdefghijklm"}}')"
run "$MAIN" bash -c "$SL; sh_prefix '$E'"; expect 2 "teams.session_prefix=abcdefghijklm must match" "(38) 13 characters refused"
F="$(pfx badcase '{"teams":{"session_prefix":"Pa"}}')"
run "$MAIN" bash -c "$SL; sh_prefix '$F'"; expect 2 "teams.session_prefix=Pa must match" "(38) uppercase refused"
echo "team-smoke-host: (38) cut and refusal OK"

# ---- (39) names: role, team, helper, a helper that already carries the prefix --------------------------------
run "$MAIN" bash -c "$SL; for a in Supervisor alfa-coder helper:retro-r1 helper:pa-team-watch; do sh_name '$A' \$a; done"
[ "$(tr '\n' ' ' < "$WORK/out")" = "pa-supervisor pa-alfa-coder pa-retro-r1 pa-team-watch " ] || fail "(39) names"
echo "team-smoke-host: (39) names OK"

# ---- (40) a name over 32 characters is refused with the computed name ----------------------------------------
run "$MAIN" bash -c "$SL; sh_name '$A' abcdefghijklmnopqrstuvwxyz-wrapup"
expect 2 "session name pa-abcdefghijklmnopqrstuvwxyz-wrapup is over 32 characters" "(40) 33+ characters"
echo "team-smoke-host: (40) length OK"

# ---- (41) no old-name fallback (the step-2 bridge is gone): an alive pre-prefix name is never reached ----
rm -f "$REG/alfa-qa.json"
OLD_HS='[ "$3" != =alfa-qa ] || exit 0'   # only the old name is alive; the stub answers "gone" for the rest
clr; STUB_ON_HAS_SESSION="$OLD_HS" run "$MAIN" $SH alive alfa-qa; expect 3 "" "(41) the new name only"
noline "=alfa-qa" "(41) probed the old name"; noline "old name" "(41) old-name note"
clr; STUB_ON_HAS_SESSION="$OLD_HS" run "$MAIN" $SH start alfa-qa --kind team --cwd "$CL" --cli script -- true
expect 0 "smk-alfa-qa" "(41) start uses the new name"; noline "-s alfa-qa " "(41) start used the old name"
echo "team-smoke-host: (41) no old-name fallback OK"

# ---- (42) two fixture projects on one stub server ---------------------------------------------------------------
for x in pa pb; do
  mkdir -p "$WORK/proj-$x/.claude" "$WORK/proj-$x/.agents"
  echo "{\"teams\":{\"session_prefix\":\"$x\"}}" > "$WORK/proj-$x/.claude/project-profile.json"
done
clr
for x in pa pb; do
  run "$WORK/proj-$x" env HARNESS_MAIN="$WORK/proj-$x" $SH start alfa-coder --kind team --cwd "$CL" --cli script -- true
  expect 0 "$x-alfa-coder" "(42) project $x starts"
done
line "tmux new-session -d -s pa-alfa-coder -c $CL -e HARNESS_ADDRESS=alfa-coder -e HARNESS_MAIN=$(cd "$WORK/proj-pa" && pwd) -e HARNESS_REGISTRY=$(cd "$WORK/proj-pa" && pwd)/.agents/team/registry -e HARNESS_BACKEND=tmux true" "(42) project A's name"
has "new-session -d -s pb-alfa-coder " "$STUB_LOG" || fail "(42) project B's name"
# The same prefix: B finds the name alive with no record of its own and refuses, naming both paths.
sed -i '' 's/"pb"/"pa"/' "$WORK/proj-pb/.claude/project-profile.json"
clr; STUB_TMUX_ALIVE=0 STUB_SESSION_PATH="$WORK/proj-pa" run "$WORK/proj-pb" env HARNESS_MAIN="$WORK/proj-pb" \
  $SH start alfa-qa --kind team --cwd "$CL" --cli script -- true
expect 1 "pa-alfa-qa belongs to another checkout ($WORK/proj-pa); this one is $CL — set a different teams.session_prefix" "(42) same prefix refused"
noline "new-session" "(42) a colliding start launched"
# Alive, no record, but its session_path is this start's cwd: our own session with a lost record.
clr; STUB_TMUX_ALIVE=0 STUB_SESSION_PATH="$CL" run "$WORK/proj-pb" env HARNESS_MAIN="$WORK/proj-pb" \
  $SH start alfa-qa --kind team --cwd "$CL" --cli script -- true
expect 1 "alfa-qa is already running" "(42) own session without a record"
has "belongs to another checkout" "$WORK/out" && fail "(42) own session reported as another checkout"
noline "new-session" "(42) an own-session start launched"
# A path that does not resolve (the stub's default /elsewhere) is another checkout.
clr; STUB_TMUX_ALIVE=0 run "$WORK/proj-pb" env HARNESS_MAIN="$WORK/proj-pb" \
  $SH start alfa-qa --kind team --cwd "$CL" --cli script -- true
expect 1 "pa-alfa-qa belongs to another checkout (/elsewhere); this one is $CL" "(42) unresolvable path refused"
echo "team-smoke-host: (42) two fixture projects OK"

# ---- (43) team-new.sh: a team named like a role, ad-hoc or too long is refused before any clone ---------------
for t in supervisor fable adhoc-x team-watch abcdefghijklmnopqrstuvwxy; do
  run "$MAIN" bash .claude/lib/team-new.sh "$t" AB-1 feature/AB-1-x origin/develop
  [ "$RC" != 0 ] || fail "(43) team $t accepted"
done
run "$MAIN" bash .claude/lib/team-new.sh supervisor AB-1 feature/AB-1-x origin/develop; has "team name supervisor is a declared role" "$WORK/out" || fail "(43) role message"
run "$MAIN" bash .claude/lib/team-new.sh adhoc-x AB-1 feature/AB-1-x origin/develop; has "is reserved (adhoc-*, team-watch, retro)" "$WORK/out" || fail "(43) reserved message"
run "$MAIN" bash .claude/lib/team-new.sh abcdefghijklmnopqrstuvwxy AB-1 feature/AB-1-x origin/develop
has "session name smk-abcdefghijklmnopqrstuvwxy-wrapup is over 32 characters" "$WORK/out" || fail "(43) length message"
[ ! -d "$WORK/main-supervisor" ] && [ ! -d "$WORK/main-adhoc-x" ] || fail "(43) a refused team got a clone"
# A team's Herdr tab is named after it: the roles tab's name (Lead, case-insensitive) is refused.
run "$MAIN" bash .claude/lib/team-new.sh lead AB-1 feature/AB-1-x origin/develop
[ "$RC" != 0 ] && has "team name lead is the roles' Herdr tab Lead" "$WORK/out" && [ ! -d "$WORK/main-lead" ] \
  || fail "(43) a team named lead was not refused"
# A clone from before the rule: the runner refuses to start it, status still answers.
mkdir -p "$WORK/main-lead/.agents/team"; echo '{"team":"lead","mode":"quick"}' > "$WORK/main-lead/.agents/team/team.json"
run "$MAIN" bash .claude/lib/team-run.sh lead; expect 1 "team name lead is the roles' Herdr tab Lead — pick another team name" "(43) runner refuses lead"
run "$MAIN" bash .claude/lib/team-run.sh lead status; ! has "roles' Herdr tab" "$WORK/out" || fail "(43) status refused for lead"
rm -r "$WORK/main-lead"
echo "team-smoke-host: (43) team names OK"

# ---- (44) the inbox's session per address; send reads <registry>/<address>.reg.json; ad-hoc never rung ----
cp "$WORK/prof.bak" "$P"
mkdir -p "$MP/.agents/team/anchors"; echo '{}' > "$MP/.agents/team/anchors/alfa.json"
run "$MAIN" bash -c "$SL; for a in Supervisor Fable alfa adhoc-dev-1; do sh_inbox_session '$MP' \$a; done"
[ "$RC" = 0 ] && [ "$(tr '\n' ' ' < "$WORK/out")" = "Supervisor Fable alfa-lead adhoc-dev-1 " ] || fail "(44) inbox sessions"
run "$MAIN" bash -c "$SL; sh_inbox_session '$MP' nobody"; expect 3 "" "(44) an unknown address"
rm -f "$REG/alfa-planner.json"; echo '{}' > "$REG/alfa-planner.reg.json"
clr; STUB_SOCK_RC=0 STUB_TMUX_ALIVE=0 run "$MAIN" $SH send alfa-planner "ping" --team-dir "$TDX"
expect 0 "" "(44) send without a record"; line "socket $REG/alfa-planner.reg.json" "(44) the registry registration"
rm -f "$REG/alfa-planner.reg.json"
clr; run "$MAIN" $SH send adhoc-dev-1 "ping"; expect 3 "ad-hoc session — never rung" "(44) ad-hoc"
noline "send-keys" "(44) an ad-hoc session was typed into"
echo "team-smoke-host: (44) inbox sessions and the registry registration OK"

# ---- (H) the Herdr backend, behind the fake hc (step 6) ------------------------------------------------
# Every hc line of these cases is kept in $WORK/hc-all for (H2). Herdr is chosen by the profile.
hclr() { grep '^hc ' "$STUB_LOG" >> "$WORK/hc-all" 2>/dev/null || true; clr; }
argv_is() {  # argv_is <label> <word…> — the last `hc run` argv, word for word
  printf '%s\n' "${@:2}" > "$WORK/argv.want"
  diff "$WORK/argv.want" "$STUB_HC_RUN_ARGV" > "$WORK/out" 2>&1 || fail "$1: hc run argv differs"
}
cp "$WORK/prof.bak" "$P"; prof '.teams.session_host = "herdr"'
HX="env -u TEAM_SESSION_HOST"
export STUB_HC_RUN_ARGV="$WORK/hc-argv"
rm -f "$REG/hb-coder.json" "$REG/Hrole.json"

# (H1) start: argv, env words, the handle in the record
hclr; STUB_HC_GONE=1 STUB_HC_ADDR=t7a run "$MAIN" $HX $SH start hb-coder --kind team --cwd "$CL" --cli claude \
  --env K1=v1 --session-id s9 -- 'claude --session-id s9 -- "$(cat p)"'
expect 0 "smk-hb-coder" "(H1) start"
argv_is "(H1) one command" run --bg --no-parent --json --name smk-hb-coder --cwd "$CL" --label harness=smk \
  --label kind=team --label address=hb-coder --label team=hb -- /usr/bin/env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CONFIG_DIR K1=v1 HARNESS_ADDRESS=hb-coder \
  "HARNESS_MAIN=$MP" "HARNESS_REGISTRY=$REG" HARNESS_BACKEND=herdr /bin/sh -c \
  "printf '\\033]2;%s\\007' 'hb-coder'; "'claude --session-id s9 -- "$(cat p)"'   # the pane title first (OSC 2)
jq -e --arg cl "$CL" '.backend == "herdr" and .handle == "t7a" and .name == "smk-hb-coder" and .session_id == "s9"
  and .team_dir == ($cl + "/.agents/team")' "$REG/hb-coder.json" >/dev/null \
  || { cp "$REG/hb-coder.json" "$WORK/out"; fail "(H1) record"; }
printf '# fixture\n%s\n' "$WORK/cc" > "$MAIN/.claude/claude-profile"
hclr; STUB_HC_GONE=1 STUB_HC_ADDR=t7b run "$MAIN" $HX $SH start helper:hcc --kind helper --cwd "$CL" --cli claude \
  --claude-home auto -- claude --model x
expect 0 "" "(H1) claude home"
argv_is "(H1) argv form" run --bg --no-parent --json --name smk-hcc --cwd "$CL" --label harness=smk \
  --label kind=helper --label address=helper:hcc -- /usr/bin/env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN HARNESS_ADDRESS=helper:hcc "HARNESS_MAIN=$MP" \
  "HARNESS_REGISTRY=$REG" HARNESS_BACKEND=herdr "CLAUDE_CONFIG_DIR=$CC" claude --model x
rm -f "$MAIN/.claude/claude-profile"
hclr; STUB_HC_GONE=1 STUB_HC_RUN_RC=1 run "$MAIN" $HX $SH start helper:hfail --kind helper --cwd "$CL" --cli script -- true
expect 1 "hc run failed" "(H1) hc run failure"
echo "team-smoke-host: (H1) herdr start OK"

# (H3) alive by handle: the program in the foreground, or in its process group; gone and finished
STUB_HC_GONE=1 STUB_HC_ADDR=t7r run "$MAIN" $HX $SH start Hrole --kind role --cwd "$CL" --cli claude --program claude -- 'claude; read'
expect 0 "" "(H3) role start"
hclr; STUB_HC_ADDR=t7r run "$MAIN" $SH alive Hrole; expect 0 "" "(H3) claude in front"; line "hc get t7r --json" "(H3) by handle"
STUB_HC_FG=zsh run "$MAIN" $SH alive Hrole; expect 3 "" "(H3) a kept shell is gone"
# A process named claude in this shell's process group (a symlink keeps the name; a copied system
# binary would be killed by code signing).
mkdir -p "$WORK/pg"; ln -s "$(command -v sleep)" "$WORK/pg/claude"; "$WORK/pg/claude" 30 & PGC=$!
PG="$(ps -o pgid= -p $$ | tr -d ' ')"
STUB_HC_FG=/bin/sh STUB_HC_FG_NAME=sh STUB_HC_FG_PID="$PG" run "$MAIN" $SH alive Hrole
expect 0 "" "(H3) claude in the foreground group (sh -c '…; read')"
kill "$PGC" 2>/dev/null || true; wait "$PGC" 2>/dev/null || true
STUB_HC_FG=/bin/sh STUB_HC_FG_NAME=sh STUB_HC_FG_PID="$PG" run "$MAIN" $SH alive Hrole
expect 3 "" "(H3) sh -c with claude gone"
STUB_HC_GONE=1 run "$MAIN" $SH alive Hrole; expect 3 "" "(H3) not found"
STUB_HC_STATE=finished run "$MAIN" $SH alive Hrole; expect 3 "" "(H3) finished"
echo "team-smoke-host: (H3) herdr alive OK"

# (H4) status from hc get, never the screen
STUB_HC_STATUS=null run "$MAIN" $SH status hb-coder
[ "$RC" = 0 ] && [ "$(cat "$WORK/out")" = '{"state":"starting","kind":null,"msg":null,"source":"herdr"}' ] || fail "(H4) null"
STUB_HC_STATUS=blocked STUB_HC_KIND=permission STUB_HC_MSG="approve Bash: touch x" run "$MAIN" $SH status hb-coder
[ "$(cat "$WORK/out")" = '{"state":"blocked","kind":"permission","msg":"approve Bash: touch x","source":"herdr"}' ] || fail "(H4) blocked"
STUB_HC_GONE=1 STUB_HC_ADDR=t7s run "$MAIN" $HX $SH start helper:hs --kind helper --cwd "$CL" --cli script -- 'bash x; read'
STUB_HC_ADDR=t7s run "$MAIN" $SH status helper:hs; has '"state":"unknown"' "$WORK/out" || fail "(H4) script"
STUB_HC_GONE=1 run "$MAIN" $SH status hb-coder; has '"state":"gone"' "$WORK/out" || fail "(H4) gone"
echo "team-smoke-host: (H4) herdr status OK"

# (H5) send: socket first; else hc send, never forced, draft risk logged once per session; blocked; script
rm -f "$TDX/send-coder.log" "$REG/hb-coder.draft-logged"; echo '{}' > "$REG/hb-coder.reg.json"
hclr; STUB_SOCK_RC=0 STUB_HC_ADDR=t7a run "$MAIN" $SH send hb-coder "ping"; expect 0 "" "(H5) socket"
noline "hc send" "(H5) socket path typed"
rm -f "$REG/hb-coder.reg.json"
hclr; STUB_HC_ADDR=t7a run "$MAIN" $SH send hb-coder "ping 1"; expect 0 "" "(H5) fallback 1"
line "hc send t7a ping 1" "(H5) hc send"
STUB_HC_ADDR=t7a run "$MAIN" $SH send hb-coder "ping 2"; expect 0 "" "(H5) fallback 2"
[ "$(grep -c '^doorbell-draft-unsafe ' "$TDX/send-coder.log")" = 1 ] || { cp "$TDX/send-coder.log" "$WORK/out"; fail "(H5) draft line once"; }
grep -q "^doorbell-draft-unsafe .* hb-coder$" "$TDX/send-coder.log" || fail "(H5) draft line text"
[ "$(cat "$REG/hb-coder.draft-logged")" = s9 ] || fail "(H5) marker holds the session id"
hclr; STUB_HC_STATUS=blocked run "$MAIN" $SH send hb-coder "ping 3"; expect 9 "" "(H5) blocked"
noline "hc send" "(H5) blocked typed"
STUB_HC_ADDR=t7s run "$MAIN" $SH send helper:hs "ping"; expect 2 "script session" "(H5) script"
STUB_HC_STATE=finished run "$MAIN" $SH send hb-coder "ping 4"; expect 3 "" "(H5) finished"
echo "team-smoke-host: (H5) herdr send OK"

# (H6) type: hc send on an idle input (typed+submitted), refused on an open prompt
hclr; STUB_HC_ADDR=t7a run "$MAIN" $SH type hb-coder "hello there" --enter; expect 0 "typed+submitted" "(H6) type"
line "hc send t7a hello there" "(H6) argv"
hclr; STUB_HC_STATUS=blocked run "$MAIN" $SH type hb-coder "x"; expect 9 "not supported under herdr" "(H6) blocked"
noline "hc send" "(H6) typed into a prompt"
echo "team-smoke-host: (H6) herdr type OK"

# (H7) keys: the name map; an unknown key is refused before any call
hclr; run "$MAIN" $SH keys hb-coder enter esc up down tab ctrl-c ctrl-e ctrl-u; expect 0 "" "(H7) keys"
line "hc keys t7a enter esc up down tab ctrl+c ctrl+e ctrl+u" "(H7) argv"
hclr; run "$MAIN" $SH keys hb-coder f13; expect 2 "unknown key" "(H7) unknown"; noline "hc keys" "(H7) unknown sent"
echo "team-smoke-host: (H7) herdr keys OK"

# (H7b) the snapshot's "how to look" for a team stage (#29): the hint line, also when it is gone
run "$MAIN" $SH hint hb-coder; expect 0 "hc attach t7a · herdr: smk-hb-coder" "(H7b) team hint"
STUB_HC_GONE=1 run "$MAIN" $SH hint hb-coder; expect 0 "hc attach t7a" "(H7b) team hint, gone"

# (H8) kill: graceful /exit on idle, then rm; a held lock kills without /exit and logs it
rm -f "$WORK/gone"
hclr; STUB_HC_GONE_FILE="$WORK/gone" run "$MAIN" $SH kill hb-coder --graceful 2; expect 0 "" "(H8) graceful"
line "hc send t7a /exit" "(H8) /exit"; line "hc rm t7a" "(H8) rm"
rm -f "$WORK/gone"
hclr; STUB_HC_GONE_FILE="$WORK/gone" STUB_HC_STATUS=working run "$MAIN" $SH kill hb-coder --graceful 2
expect 0 "" "(H8) working"; noline "hc send" "(H8) /exit while working"; line "hc kill t7a" "(H8) kill"
rm -f "$WORK/gone"; mkdir -p "$TDX/send-coder.lock"; echo 1 > "$TDX/send-coder.lock/pid"; echo "other" > "$TDX/send-coder.lock/owner"
hclr; STUB_HC_GONE_FILE="$WORK/gone" run "$MAIN" $SH kill hb-coder --graceful 2; expect 0 "killed without /exit" "(H8) lock held"
noline "hc send" "(H8) /exit under a held lock"; grep -q '^stop-during-send ' "$TDX/send-coder.log" || fail "(H8) stop-during-send"
rm -rf "$TDX/send-coder.lock" "$WORK/gone"
STUB_HC_GONE=1 run "$MAIN" $SH kill hb-coder; expect 0 "" "(H8) never ran"
# The program leaves, its `sh -c '…; read'` terminal stays live: the wait ends at once (the record's
# program is gone from the foreground group), and the terminal is still killed and removed.
t0="$(date +%s)"
hclr; STUB_HC_ADDR=t7r STUB_HC_FG=sh STUB_HC_FG_PID=999999 run "$MAIN" $SH kill Hrole --graceful 5; expect 0 "" "(H8) program gone"
[ $(( $(date +%s) - t0 )) -lt 4 ] || fail "(H8) the wait ran the whole grace time after the program left"
line "hc send t7r /exit" "(H8) program gone: /exit"; line "hc kill t7r" "(H8) program gone: kill"; line "hc rm t7r" "(H8) program gone: rm"
echo "team-smoke-host: (H8) herdr kill OK"

# (H9) startup: the trust dialog is reported, never answered; the Codex update prompt gets one esc
printf '%s\n' " Do you want to work in this folder?" " ❯ 1. Yes, I trust this folder" "   2. No, exit" > "$WORK/trust"
hclr; STUB_HC_GONE=1 STUB_HC_ADDR=t7t run "$MAIN" $HX $SH start Htrust --kind role --cwd "$CL" --cli claude --wait-ready -- claude
expect 0 "" "(H9) start"
hclr; STUB_HC_ADDR=t7t STUB_HC_STATUS=null STUB_HC_SCREEN="$WORK/trust" TEAM_HOST_READY_SECS=2 TEAM_HOST_READY_POLL=0 \
  run "$MAIN" bash -c ". '$L/session-host-lib.sh'; sh_wait_ready Htrust t7t claude herdr"
expect 0 "waiting at the folder trust dialog — accept it once in hc attach t7t" "(H9) trust"; noline "hc keys" "(H9) trust answered"
printf '%s\n' "  Update available" "  1. Update now" "  2. Skip" "  Press enter to continue · esc skip" > "$WORK/upd"
hclr; STUB_HC_ADDR=t7u STUB_HC_STATUS=null STUB_HC_SCREEN="$WORK/upd" TEAM_HOST_READY_SECS=2 TEAM_HOST_READY_POLL=0 \
  run "$MAIN" bash -c ". '$L/session-host-lib.sh'; sh_wait_ready Hcx t7u codex herdr"
expect 0 "no sign of life" "(H9) update"; [ "$(count "hc keys t7u esc")" = 1 ] || { cp "$STUB_LOG" "$WORK/out"; fail "(H9) one esc"; }
hclr; STUB_HC_ADDR=t7t STUB_HC_STATUS=idle run "$MAIN" bash -c ". '$L/session-host-lib.sh'; sh_wait_ready Htrust t7t claude herdr"
expect 0 "" "(H9) ready on a status"; [ ! -s "$WORK/out" ] || fail "(H9) ready warned"
echo "team-smoke-host: (H9) herdr startup OK"

# (H10) auto: tmux while the switch is off; with it on, herdr only when the core answers
prof '.teams.session_host = "auto"'
run "$MAIN" $HX $SH --check-host; expect 0 "tmux" "(H10) auto is tmux (switch off)"
TEAM_SMOKE_AUTO_HERDR=1 run "$MAIN" $HX $SH --check-host; expect 0 "herdr" "(H10) auto probe, core up"
TEAM_SMOKE_AUTO_HERDR=1 STUB_HC_SERVER=1 run "$MAIN" $HX $SH --check-host; expect 0 "tmux" "(H10) auto probe, core down"
TEAM_SMOKE_AUTO_HERDR=1 run "$MAIN" $HX HC_BIN=no-such-hc TMUX_BIN=no-such-tmux $SH --check-host
expect 6 "install tmux or Herdr" "(H10) neither"
grep -q '^SH_AUTO_HERDR=0$' "$L/session-host-lib.sh" || fail "(H10) the shipped switch is not off"
echo "team-smoke-host: (H10) auto OK"

# (H11) a record's backend survives a session_host change
hclr; STUB_TMUX_ALIVE=0 run "$MAIN" $HX $SH alive alfa-coder; expect 0 "" "(H11) tmux record under auto"
line "tmux has-session -t =smk-alfa-coder" "(H11) still tmux"; noline "hc get" "(H11) asked herdr"
hclr; run "$MAIN" $SH alive hb-coder; line "hc get t7a --json" "(H11) herdr record under auto"
echo "team-smoke-host: (H11) backend per record OK"

# (H12) under TEAM_SMOKE=1 only a fixture hc runs
HC_BIN=/usr/bin/true run "$MAIN" $SH status hb-coder; expect 1 "refusing /usr/bin/true under TEAM_SMOKE=1" "(H12) real hc"
echo "team-smoke-host: (H12) fixture hc OK"

# (H13) start probes: our stale terminal under the name is removed; a live foreign one refuses
prof '.teams.session_host = "herdr"'; rm -f "$REG/hb-qa.json"
hclr; STUB_HC_ADDR=t7o STUB_HC_STATE=finished STUB_HC_LABELS='{"harness":"smk","address":"hb-qa"}' \
  run "$MAIN" $HX $SH start hb-qa --kind team --cwd "$CL" --cli claude -- claude
expect 0 "" "(H13) our stale terminal"; line "hc rm t7o" "(H13) removed"
rm -f "$REG/hb-qa.json"
hclr; STUB_HC_ADDR=t7f STUB_HC_LABELS='{"harness":"other"}' STUB_HC_CWD=/elsewhere \
  run "$MAIN" $HX $SH start hb-qa --kind team --cwd "$CL" --cli claude -- claude
expect 1 "smk-hb-qa belongs to another checkout (/elsewhere)" "(H13) foreign"; noline "hc run" "(H13) started over a foreign one"
hclr; STUB_HC_ADDR=t7a run "$MAIN" $HX $SH start Hrole --kind role --cwd "$CL" --cli claude --program claude -- claude
expect 1 "already running" "(H13) live record"
echo "team-smoke-host: (H13) herdr start probes OK"

# (H14) identity guard: the record's created_ms against the terminal now under its handle
jq -e '.created_ms == "1700000000000"' "$REG/hb-coder.json" >/dev/null || fail "(H14) start did not record created_ms"
export STUB_HC_CREATED=1800000000000   # another terminal now holds t7a
hclr; STUB_HC_ADDR=t7a run "$MAIN" $SH alive hb-coder; expect 3 "hb-coder: terminal t7a is not the recorded one (replaced)" "(H14) alive"
STUB_HC_ADDR=t7a run "$MAIN" $SH kill hb-coder --graceful 1; expect 0 "" "(H14) kill"
STUB_HC_ADDR=t7a run "$MAIN" $SH send hb-coder "ping"; expect 3 "" "(H14) send"
STUB_HC_ADDR=t7a run "$MAIN" $SH keys hb-coder enter; expect 3 "" "(H14) keys"
STUB_HC_ADDR=t7a run "$MAIN" $SH type hb-coder "x"; expect 3 "" "(H14) type"
STUB_HC_ADDR=t7a run "$MAIN" $SH status hb-coder; has '"state":"gone"' "$WORK/out" || fail "(H14) status"
STUB_HC_ADDR=t7a run "$MAIN" $SH hint hb-coder; expect 0 "hb-coder: its herdr terminal was replaced — nothing to attach" "(H14) hint"
! grep -qE '^hc (kill|rm|send|keys) ' "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(H14) acted on the foreign terminal"; }
hclr; STUB_HC_NONAME=1 STUB_HC_ADDR=t7a run "$MAIN" $HX $SH start hb-coder --kind team --cwd "$CL" --cli claude -- claude
expect 0 "" "(H14) start over a replaced record"
! grep -qE '^hc (kill|rm|send|keys) ' "$STUB_LOG" && grep -q '^hc run ' "$STUB_LOG" \
  || { cp "$STUB_LOG" "$WORK/out"; fail "(H14) start touched the foreign terminal"; }
jq -e '.created_ms == "1800000000000"' "$REG/hb-coder.json" >/dev/null || fail "(H14) the new start's created_ms"
unset STUB_HC_CREATED
jq 'del(.created_ms)' "$REG/hb-coder.json" > "$WORK/r.json" && mv "$WORK/r.json" "$REG/hb-coder.json"
STUB_HC_CREATED=1900000000000 STUB_HC_ADDR=t7a run "$MAIN" $SH alive hb-coder; expect 0 "" "(H14) a record without created_ms is not checked"
echo "team-smoke-host: (H14) identity guard OK"

# (H15) start probe: our labelled terminal whose probe fails is neither killed nor removed
rm -f "$REG/hb-wrapup.json"
hclr; STUB_HC_ADDR=t7w STUB_HC_GET_RC_HANDLE=5 STUB_HC_LABELS='{"harness":"smk","address":"hb-wrapup"}' \
  run "$MAIN" $HX $SH start hb-wrapup --kind team --cwd "$CL" --cli claude -- claude
expect 1 "hb-wrapup: cannot probe smk-hb-wrapup — not started" "(H15) failed probe"
! grep -qE '^hc (kill|rm|run) ' "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(H15) acted on a failed probe"; }
echo "team-smoke-host: (H15) start probe on a failed probe OK"

# (H16) a slash command goes without HC_TERMINAL_ID (else it arrives wrapped in <hc from=…> and is
# read as text); the doorbell keeps it (step 6 live L1)
rm -f "$REG/hb-coder.reg.json" "$WORK/gone" "$WORK/hcid"; jq 'del(.created_ms)' "$REG/hb-coder.json" > "$WORK/r" && mv "$WORK/r" "$REG/hb-coder.json"
hclr; STUB_HC_IDLOG="$WORK/hcid" HC_TERMINAL_ID=t0me STUB_HC_ADDR=t7a run "$MAIN" $SH send hb-coder "ring"
expect 0 "" "(H16) doorbell"; grep -qxF "id-set hc send t7a ring" "$WORK/hcid" || { cp "$WORK/hcid" "$WORK/out"; fail "(H16) doorbell lost the sender id"; }
STUB_HC_IDLOG="$WORK/hcid" HC_TERMINAL_ID=t0me STUB_HC_ADDR=t7a run "$MAIN" $SH type hb-coder "/clear"
expect 0 "typed+submitted" "(H16) slash type"; grep -qxF "id-unset hc send t7a /clear" "$WORK/hcid" || { cp "$WORK/hcid" "$WORK/out"; fail "(H16) slash command wrapped"; }
STUB_HC_IDLOG="$WORK/hcid" HC_TERMINAL_ID=t0me STUB_HC_ADDR=t7a run "$MAIN" $SH type hb-coder "plain text"
grep -qxF "id-set hc send t7a plain text" "$WORK/hcid" || { cp "$WORK/hcid" "$WORK/out"; fail "(H16) plain type lost the sender id"; }
STUB_HC_IDLOG="$WORK/hcid" HC_TERMINAL_ID=t0me STUB_HC_GONE_FILE="$WORK/gone" STUB_HC_ADDR=t7a run "$MAIN" $SH kill hb-coder --graceful 2
expect 0 "" "(H16) graceful"; grep -qxF "id-unset hc send t7a /exit" "$WORK/hcid" || { cp "$WORK/hcid" "$WORK/out"; fail "(H16) /exit wrapped"; }
rm -f "$WORK/gone" "$WORK/hcid"
echo "team-smoke-host: (H16) unwrapped slash commands OK"

# (H17) an agent with no status yet (a startup dialog may be open) is never typed into or rung; a
# script session keeps today's rule; the MCP servers dialog is reported, never answered (live L2)
hclr; STUB_HC_STATUS=null STUB_HC_ADDR=t7a run "$MAIN" $SH type hb-coder "x"
expect 9 "hb-coder: still starting (a startup dialog may be open) — answer it in hc attach t7a" "(H17) type"
noline "hc send" "(H17) typed while starting"
rm -f "$TDX/send-coder.log"
hclr; STUB_HC_STATUS=null STUB_HC_ADDR=t7a run "$MAIN" $SH send hb-coder "ring 2"; expect 9 "" "(H17) doorbell"
noline "hc send" "(H17) rung while starting"
grep -q '^doorbell-skipped .* starting — ring 2$' "$TDX/send-coder.log" || { cp "$TDX/send-coder.log" "$WORK/out"; fail "(H17) doorbell log"; }
hclr; STUB_HC_STATUS=null STUB_HC_GONE_FILE="$WORK/gone" STUB_HC_ADDR=t7a run "$MAIN" $SH kill hb-coder --graceful 1
expect 0 "" "(H17) kill while starting"; noline "hc send" "(H17) /exit while starting"; line "hc kill t7a" "(H17) killed"
rm -f "$WORK/gone"
hclr; STUB_HC_STATUS=null STUB_HC_ADDR=t7a run "$MAIN" bash -c ". '$L/session-host-lib.sh'; sh_herdr_type t7a x script hb-s"
expect 0 "typed+submitted" "(H17) script session"
printf '%s\n' " 3 new MCP servers found in this project" " ❯ [ ] alpha" "   [ ] beta" > "$WORK/mcp"
hclr; STUB_HC_ADDR=t7t STUB_HC_STATUS=null STUB_HC_SCREEN="$WORK/mcp" TEAM_HOST_READY_SECS=2 TEAM_HOST_READY_POLL=0 \
  run "$MAIN" bash -c ". '$L/session-host-lib.sh'; sh_wait_ready Htrust t7t claude herdr"
expect 0 "waiting at the MCP servers dialog — answer it in hc attach t7t" "(H17) mcp"
noline "hc keys" "(H17) mcp answered"; noline "hc send" "(H17) mcp typed"
echo "team-smoke-host: (H17) startup dialogs under herdr OK"

# (H2) no hc call of the part ever carried the force, keep or parent flag
hclr; [ -s "$WORK/hc-all" ] || fail "(H2) no hc line recorded"
! grep -nE -- '--force|--keep|--parent |--outlive-parent' "$WORK/hc-all" || { cp "$WORK/hc-all" "$WORK/out"; fail "(H2) forbidden hc flag"; }
grep -q -- '--no-parent' "$WORK/hc-all" || fail "(H2) no --no-parent start"
cp "$WORK/prof.bak" "$P"
echo "team-smoke-host: (H2) hc flags OK"

echo "team-smoke-host: OK"
