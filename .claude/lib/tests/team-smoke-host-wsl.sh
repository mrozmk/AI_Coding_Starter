#!/usr/bin/env bash
# The session-host driver on Herdr for Windows driven from WSL (case H19): the .exe CLIs are found
# when only they are on PATH (and `auto` takes them for role sessions only); the launch line runs
# through wsl.exe in a login shell and carries the terminal's marker; liveness looks for the program
# inside WSL by that marker (0 alive · 3 gone · 1 cannot tell), since the core sees only wsl.exe; the
# hint names hc.exe; no Windows pid reaches the ownership probe; the space folder is the UNC path.
# Runs on Linux and macOS: `wsl.exe` is only an argv word to the fake hc, never executed.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

# The driver runs from a copy, so the messaging-socket sender can be a stub (as team-smoke-host.sh).
L="$WORK/drv"; mkdir -p "$L"
cp "$SRC/.claude/lib/session-host.sh" "$SRC/.claude/lib/session-host-lib.sh" \
  "$SRC/.claude/lib/session-host-layout.sh" \
  "$SRC/.claude/lib/team-send-lock.sh" "$SRC/.claude/lib/team-channel.sh" "$SRC/.claude/lib/roles-lib.sh" \
  "$SRC/.claude/lib/team-profile.sh" "$SRC/.claude/lib/team_prompt.py" "$SRC/.claude/lib/portable-lib.sh" \
  "$SRC/.claude/lib/team_transcript.py" "$L/"
cat > "$L/team-watch-send.py" <<'PY'
import os, sys
sys.stdin.read()
with open(os.environ["STUB_LOG"], "a") as f:
    f.write("socket " + sys.argv[1] + "\n")
sys.exit(int(os.environ.get("STUB_SOCK_RC", "1")))
PY
SH="bash $L/session-host.sh"
SL=". '$L/session-host-lib.sh'"
LL=". '$L/session-host-lib.sh'; . '$L/session-host-layout.sh'"
MP="$(cd "$MAIN" && pwd -P)"
REG="$MP/.agents/team/registry"
CL="$WORK/clone"; mkdir -p "$CL/.agents/team"
P="$MAIN/.claude/project-profile.json"; cp "$P" "$WORK/prof.bak"
prof() { jq "$1" "$WORK/prof.bak" > "$P"; }
clr() { : > "$STUB_LOG"; rm -f "$STUB_LOG.typed"; }
noline() { ! grep -qF -- "$1" "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "$2: unexpected '$1'"; }; }
out_is() { [ "$(cat "$WORK/out")" = "$1" ] || fail "$2: got '$(cat "$WORK/out")', expected '$1'"; }
prof '.teams.session_host = "herdr"'
export STUB_HC_RUN_ARGV="$WORK/hc-argv"
cp "$WORK/bin/hc" "$WORK/bin/hc.exe"
HXE="$WORK/bin/hc.exe"
# The fixture program: never `claude` — the account's real claude processes must not be candidates
# of the marker scan. ≤ 15 characters (Linux truncates comm there).
PG="smkc$$"
WP1=""; WP2=""; WP3=""
trap 'kill $WP1 $WP2 $WP3 2>/dev/null || true; [ -z "$SPID" ] || kill "$SPID" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# (1) sh_wsl_exe: the .exe only under WSL and only when no Linux binary of that name is on PATH
mkdir -p "$WORK/wslbin"; printf '#!/bin/sh\n' > "$WORK/wslbin/foo.exe"; chmod +x "$WORK/wslbin/foo.exe"
WE() { run "$MAIN" bash -c "$SL; PATH='$WORK/wslbin'; $1"; }
WE "WSL_DISTRO_NAME=Dx sh_wsl_exe foo"; out_is foo.exe "(H19) only foo.exe under WSL"
WE "unset WSL_DISTRO_NAME; sh_wsl_exe foo"; out_is foo "(H19) foo.exe outside WSL"
cp "$WORK/wslbin/foo.exe" "$WORK/wslbin/foo"
WE "WSL_DISTRO_NAME=Dx sh_wsl_exe foo"; out_is foo "(H19) a Linux foo comes first"

# (2) sh_hc_wsl: WSL and a Windows CLI, both
run "$MAIN" env WSL_DISTRO_NAME=Dx HC_BIN=/x/hc bash -c "$SL; sh_hc_wsl"; expect 1 "" "(H19) a Linux hc is not Windows Herdr"
run "$MAIN" env WSL_DISTRO_NAME=Dx "HC_BIN=$HXE" bash -c "$SL; sh_hc_wsl"; expect 0 "" "(H19) hc.exe under WSL"
run "$MAIN" env "HC_BIN=$HXE" bash -c "$SL; sh_hc_wsl"; expect 1 "" "(H19) hc.exe outside WSL"

# (3) ly_app_bin: the app of the core's family
run "$MAIN" env HERDR_APP_BIN=/x/app bash -c "$LL; ly_app_bin"; out_is /x/app "(H19) HERDR_APP_BIN wins"
run "$MAIN" env WSL_DISTRO_NAME=Dx "HC_BIN=$HXE" bash -c "unset HERDR_APP_BIN; $LL; ly_app_bin"
out_is herdr-app.exe "(H19) hc.exe pairs with herdr-app.exe"
run "$MAIN" env WSL_DISTRO_NAME=Dx "HC_BIN=$WORK/bin/hc" bash -c "unset HERDR_APP_BIN; $LL; ly_app_bin"
out_is herdr-app "(H19) a Linux hc pairs with herdr-app"

# (0) auto with only the Windows CLI on PATH (the ticket's failure): herdr, for role sessions only.
# The narrowed PATH keeps a machine's own hc out (the fixture rule would refuse it: auto would read tmux).
mv "$WORK/bin/hc" "$WORK/bin/hc.linux"; prof '.teams.session_host = "auto"'
# The driver's own tools come along by link (jq may live only under Homebrew); their directory never
# joins PATH, since it may hold a native hc too.
mkdir -p "$WORK/np"; ln -sf "$(command -v jq)" "$WORK/np/jq"; ln -sf "$(command -v perl)" "$WORK/np/perl"
NP="$WORK/bin:$WORK/np:/usr/bin:/bin"
run "$MAIN" env -u HC_BIN -u TEAM_SESSION_HOST TEAM_SMOKE_AUTO_HERDR=1 WSL_DISTRO_NAME=Dx PATH="$NP" $SH --check-host
expect 0 "" "(H19) auto picks herdr for windows"; out_is herdr "(H19) auto picks herdr for windows"
run "$MAIN" env -u HC_BIN -u TEAM_SESSION_HOST TEAM_SMOKE_AUTO_HERDR=1 WSL_DISTRO_NAME=Dx PATH="$NP" \
  bash -c "$SL; sh_pick_host '$MP' role; sh_pick_host '$MP' team; sh_pick_host '$MP' helper"
[ "$RC" = 0 ] && [ "$(tr '\n' ' ' < "$WORK/out")" = "herdr tmux tmux " ] || fail "(H19) auto: roles only"
mv "$WORK/bin/hc.linux" "$WORK/bin/hc"; prof '.teams.session_host = "herdr"'

# (4) start: the line runs through wsl.exe in a login shell and carries the terminal's marker
rm -f "$REG/HWsl.json"
clr; STUB_HC_GONE=1 STUB_HC_ADDR=t7w run "$MAIN" env -u TEAM_SESSION_HOST WSL_DISTRO_NAME=Dx "HC_BIN=$HXE" \
  $SH start HWsl --kind role --cwd "$CL" --cli claude --program "$PG" -- "$PG; read"
expect 0 "" "(H19) start"
sed -n '/^--$/,$p' "$STUB_HC_RUN_ARGV" | sed -n '2,14p' > "$WORK/argv.got"
printf '%s\n' wsl.exe -d Dx -u "$(id -un)" --cd "$CL" -e /bin/bash -lc 'exec "$@"' harness-wsl /usr/bin/env \
  > "$WORK/argv.want"
diff "$WORK/argv.want" "$WORK/argv.got" > "$WORK/out" 2>&1 || fail "(H19) start: wsl.exe wrapper"
grep -qxF "HC_WSL_TERMINAL=smk-hwsl" "$STUB_HC_RUN_ARGV" || { cp "$STUB_HC_RUN_ARGV" "$WORK/out"; fail "(H19) start: no marker"; }

# (5) the hint names the CLI the machine has
run "$MAIN" env WSL_DISTRO_NAME=Dx "HC_BIN=$HXE" STUB_HC_ADDR=t7w $SH hint HWsl
expect 0 "" "(H19) hint"; case "$(cat "$WORK/out")" in "hc.exe attach t7w"*) ;; *) fail "(H19) hint names hc.exe" ;; esac

# (6) sh_pane_pid: never the Windows pid of a Herdr for Windows terminal
run "$MAIN" env STUB_HC_PID=4243 STUB_HC_ADDR=t7w WSL_DISTRO_NAME=Dx "HC_BIN=$HXE" bash -c "$SL; sh_pane_pid '$MP' HWsl"
expect 1 "" "(H19) pane pid under hc.exe"; out_is "" "(H19) pane pid under hc.exe"
run "$MAIN" env STUB_HC_PID=4243 STUB_HC_ADDR=t7w 'STUB_HC_FG=C:\WINDOWS\system32\wsl.exe' bash -c "$SL; sh_pane_pid '$MP' HWsl"
expect 1 "" "(H19) pane pid of a wsl.exe foreground"; out_is "" "(H19) pane pid of a wsl.exe foreground"
run "$MAIN" env STUB_HC_PID=4243 STUB_HC_ADDR=t7w bash -c "$SL; sh_pane_pid '$MP' HWsl"
expect 0 "" "(H19) native pane pid"; out_is 4243 "(H19) native pane pid"

# (7) liveness: the core sees wsl.exe; no marked program inside WSL is gone
W="STUB_HC_ADDR=t7w STUB_HC_NAME=smk-hwsl STUB_HC_FG=C:\\WINDOWS\\system32\\wsl.exe STUB_HC_FG_NAME=wsl.exe"
run "$MAIN" env $W $SH alive HWsl; expect 3 "" "(H19) no program inside WSL is gone"
# (7b) a process scan that fails is not "gone"
mkdir -p "$WORK/pgfail"; printf '#!/bin/sh\nexit 2\n' > "$WORK/pgfail/pgrep"; chmod +x "$WORK/pgfail/pgrep"
run "$MAIN" env PATH="$WORK/pgfail:$PATH" $W $SH alive HWsl; expect 1 "" "(H19) a failed process scan is not gone"

# (8) no terminal name: cannot tell — and a start then neither kills nor replaces
run "$MAIN" env ${W/STUB_HC_NAME=smk-hwsl/} $SH alive HWsl; expect 1 "" "(H19) no terminal name"
clr; run "$MAIN" env -u TEAM_SESSION_HOST ${W/STUB_HC_NAME=smk-hwsl/} \
  'STUB_HC_LABELS={"harness":"smk","kind":"role","address":"HWsl"}' WSL_DISTRO_NAME=Dx "HC_BIN=$HXE" \
  $SH start HWsl --kind role --cwd "$CL" --cli claude --program "$PG" -- "$PG; read"
[ "$RC" != 0 ] || fail "(H19) no terminal name: start succeeded"
noline "hc kill" "(H19) no terminal name"; noline "hc rm" "(H19) no terminal name"; noline "hc run" "(H19) no terminal name"

# (9) the marker, on real processes (procfs only: WSL is Linux)
if [ -r /proc/self/environ ]; then
  # A bash under the program's name (a multicall coreutils sleep refuses another name); `; :` keeps
  # bash from exec'ing sleep in its place. No output fd held open: the suite reads this part's output.
  mkdir -p "$WORK/wsl"; ln -sf "$(command -v bash)" "$WORK/wsl/$PG"
  env HC_WSL_TERMINAL=smk-other "$WORK/wsl/$PG" -c 'sleep 30; :' </dev/null >/dev/null 2>&1 & WP1=$!
  run "$MAIN" env $W $SH alive HWsl; expect 3 "" "(H19) another terminal's program"
  env NOTE=$'x\nHC_WSL_TERMINAL=smk-hwsl' HC_WSL_TERMINAL=smk-other "$WORK/wsl/$PG" -c 'sleep 30; :' \
    </dev/null >/dev/null 2>&1 & WP2=$!
  run "$MAIN" env $W $SH alive HWsl; expect 3 "" "(H19) a multiline value is not the marker"
  # The marker followed by a large environment: an early match must not read as a miss (SIGPIPE).
  env HC_WSL_TERMINAL=smk-hwsl BIG="$(head -c 100000 /dev/zero | tr '\0' x)" "$WORK/wsl/$PG" -c 'sleep 30; :' \
    </dev/null >/dev/null 2>&1 & WP3=$!
  run "$MAIN" env $W $SH alive HWsl; expect 0 "" "(H19) claude with the marker is alive"
  clr; run "$MAIN" env -u TEAM_SESSION_HOST $W WSL_DISTRO_NAME=Dx "HC_BIN=$HXE" \
    $SH start HWsl --kind role --cwd "$CL" --cli claude --program "$PG" -- "$PG; read"
  expect 1 "already running" "(H19) second start: already running"; noline "hc run" "(H19) second start: already running"
  cp "$REG/HWsl.json" "$WORK/rec.before"
  clr; run "$MAIN" env -u TEAM_SESSION_HOST $W STUB_HC_GET_RC_HANDLE=5 STUB_HC_NONAME=1 WSL_DISTRO_NAME=Dx \
    "HC_BIN=$HXE" $SH start HWsl --kind role --cwd "$CL" --cli claude --program "$PG" -- "$PG; read"
  expect 1 "cannot probe" "(H19) a failed handle probe starts nothing"
  cmp -s "$WORK/rec.before" "$REG/HWsl.json" || fail "(H19) a failed handle probe starts nothing: record changed"
  noline "hc run" "(H19) a failed handle probe starts nothing"; noline "hc kill" "(H19) a failed handle probe starts nothing"
  noline "hc rm" "(H19) a failed handle probe starts nothing"
  kill "$WP1" "$WP2" "$WP3" 2>/dev/null || true; wait "$WP1" "$WP2" "$WP3" 2>/dev/null || true
  WP1=""; WP2=""; WP3=""
else
  echo "team-smoke-host-wsl: (H19) marker liveness skipped (no procfs)"
fi

# (10) placement: Herdr for Windows keeps the space folder as the UNC path
UNC="\\\\wsl.localhost\\Dx$(printf '%s' "$MP" | tr '/' '\\')"
jq -n --arg f "$UNC" '{spaces: [{id: "s1", name: "smk", folder: $f, tabs: []}]}' > "$WORK/ls.json"
printf '#!/bin/sh\n[ "$1" = -w ] && [ "$2" = %s ] && printf "%%s\\n" %s\n' "'$MP'" "'$UNC'" > "$WORK/bin/wslpath"
chmod +x "$WORK/bin/wslpath"
run "$MAIN" env STUB_HERDR_LS="$WORK/ls.json" WSL_DISTRO_NAME=Dx "HC_BIN=$HXE" \
  bash -c "$LL; ly_ls && ly_space '$MP' no && echo \"LY_SPACE=\$LY_SPACE\""
expect 0 "LY_SPACE=s1" "(H19) the space by its UNC folder"
run "$MAIN" env STUB_HERDR_LS="$WORK/ls.json" bash -c "$LL; ly_ls && ly_space '$MP' no"
expect 1 "" "(H19) outside WSL the UNC folder is not this checkout"
rm -f "$WORK/bin/wslpath"

# (11) a tmux session never carries a Herdr for Windows terminal's marker: started from a marked
# role terminal (auto: team and helper sessions stay on tmux), it resets the variable for its panes.
clr; run "$MAIN" env HC_WSL_TERMINAL=smk-supervisor WSL_DISTRO_NAME=Dx "HC_BIN=$HXE" \
  $SH start helper:wm --kind helper --cwd "$CL" --cli script -- true
expect 0 "" "(H19) tmux from a marked terminal"
grep -q '^tmux new-session .* -e HC_WSL_TERMINAL= ' "$STUB_LOG" \
  || { cp "$STUB_LOG" "$WORK/out"; fail "(H19) tmux from a marked terminal resets the marker"; }
clr; run "$MAIN" $SH start helper:wn --kind helper --cwd "$CL" --cli script -- true
expect 0 "" "(H19) native tmux start"; noline "HC_WSL_TERMINAL" "(H19) native tmux start"

rm -f "$WORK/bin/hc.exe" "$REG/HWsl.json"
echo "team-smoke-host-wsl: (H19) herdr for windows under wsl OK"
