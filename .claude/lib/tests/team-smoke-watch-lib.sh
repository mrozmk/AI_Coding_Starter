#!/usr/bin/env bash
# Fixtures for the team-watch parts (15-19): stub receiver sockets per role, a tmux stub that really
# spawns the team-watch loops (never a real tmux server), a stub operator-kit notifier, role-bound
# invocations. Sourced after team-smoke-lib.sh, after smoke_init + smoke_team.

watch_init() {
  unset CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN TEAM_SESSION_ROLE \
    TEAM_MONITORING_JSON TEAM_NOTIFY_SOUND TEAM_NOTIFY_SOUND_ALARM CLAUDECODE CLAUDE_CODE_ENTRYPOINT
  PIDS=""; DPID=""
  SD="$(mktemp -d /tmp/tw.XXXXXX)"   # macOS caps a unix socket path at 104 bytes
  TMUXD="$WORK/tmux"; mkdir -p "$TMUXD"; export STUB_TMUX_DIR="$TMUXD"
  trap 'kill_loops; for p in $PIDS; do kill "$p" 2>/dev/null || true; done
    rm -rf "$WORK" "$SD"' EXIT
  W="bash .claude/lib/team-watch.sh"
  TWV="$(cd "$SRC" && bash -c '. .claude/lib/team-watch-route.sh; echo "$TW_VERSION"')"
  TWD="$MAIN/.agents/team/watch"
  RUN_ID=alfa-20261019-000000; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"; echo "$RUN_ID" > "$TD/run"
  printf 'Bash command\n  npm run deploy -- --name app-x\nDo you want to proceed?\n❯ 1. Yes\n' \
    > "$WORK/pane"
  export STUB_PANE="$WORK/pane" STUB_TMUX_ALIVE=0
  pr_json false "$BASE"
  # Main checkout only: in the seed its deny rules would refuse the clones' stubbed prompts.
  cp "$SRC/.claude/settings.json" "$MAIN/.claude/"
  # The team-watch layer beyond the team-*.sh the seed carries.
  cp "$SRC/.claude/lib/team-watch-send.py" "$SRC/.claude/lib/team-watch-signals.jq" \
    "$SRC/.claude/lib/session-wake.sh" "$SRC/.claude/lib/monitoring.sh" "$MAIN/.claude/lib/"
  cp "$SRC/.claude/lib/team-watch"*.sh "$SRC/.claude/lib/team-channel.sh" "$MAIN/.claude/lib/"
  mkdir -p "$MAIN/.claude/team/sessions/operator-kit" "$MAIN/.claude/hooks"
  cp "$SRC/.claude/team/sessions/monitoring.json" "$MAIN/.claude/team/sessions/"
  cp "$SRC/.claude/hooks/team-watch-session.sh" "$SRC/.claude/hooks/monitoring-rearm.sh" \
    "$MAIN/.claude/hooks/"
  # The operator kit's notifier, stubbed: one log line per call (P7's notify.sh contract).
  printf '#!/usr/bin/env bash\necho "notify $*" >> "$STUB_LOG"\n[ "$1" != --check ] || echo "notifier: $3 ok (stub)"\nexit 0\n' \
    > "$MAIN/.claude/team/sessions/operator-kit/notify.sh"
  jq '.teams.channel = {project_code: "SM", tmux_prefix: "smk", notifier: "osascript"}' \
    "$MAIN/.claude/project-profile.json" > "$WORK/prof" && mv "$WORK/prof" "$MAIN/.claude/project-profile.json"
  watch_tmux_stub
  [ "$(command -v tmux)" = "$WORK/bin/tmux" ] || fail "fixture: tmux is not the stub"
  watch_srv
}

# Sessions with a pid file (spawned here) or named smk-* answer by that pid; every other name (team
# roles) follows STUB_TMUX_ALIVE as in team-smoke-lib.sh. new-session runs its command for real,
# with the -e variables, in its own process group.
watch_tmux_stub() {
  cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "$STUB_LOG"
D="$STUB_TMUX_DIR"
case "$1" in
  has-session) n="${3#=}"
    if [ -f "$D/$n.pid" ]; then kill -0 "$(cat "$D/$n.pid")" 2>/dev/null; exit $?; fi
    case "$n" in smk-*|smx-*) exit 1 ;; esac
    gone="can't find session: $n"
    [ "${STUB_TMUX_ALIVE:-1}" = 0 ] || echo "${STUB_TMUX_ERR:-$gone}" >&2
    exit "${STUB_TMUX_ALIVE:-1}" ;;
  kill-session) n="${3#=}"; p="$(cat "$D/$n.pid" 2>/dev/null)"
    [ -z "$p" ] || kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null
    echo dead > "$D/$n.pid"; exit 0 ;;
  new-session) shift; name=""; dir="$PWD"; envs=()
    while [ $# -gt 1 ]; do
      case "$1" in -d) shift ;; -s) name="$2"; shift 2 ;; -c) dir="$2"; shift 2 ;;
        -e) envs+=("$2"); shift 2 ;; *) shift ;; esac
    done
    ( cd "$dir" && exec env ${envs[@]+"${envs[@]}"} perl -e 'setpgrp(0, 0); exec @ARGV' \
        bash -c "$1" ) < /dev/null >> "$D/$name.log" 2>&1 &
    echo $! > "$D/$name.pid"; exit 0 ;;
  capture-pane) n=""
    for a in "$@"; do case "$a" in =*:) n="${a#=}"; n="${n%:}" ;; esac; done
    # A per-session file is the whole history; -S/-J are ignored, team_pane tails it.
    if [ -n "$n" ] && [ -f "${STUB_PANE_DIR:-/nonexistent}/$n" ]; then cat "$STUB_PANE_DIR/$n"
    elif [ -n "${STUB_PANE:-}" ]; then cat "$STUB_PANE"; fi ;;
esac
exit 0
STUB
  chmod +x "$WORK/bin/tmux"
}

kill_loops() {
  local n p
  for n in smk-team-watch smk-team-watch-dog smx-team-watch smx-team-watch-dog; do
    p="$(cat "$TMUXD/$n.pid" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true
    echo dead > "$TMUXD/$n.pid"
  done
}

# A stub receiver: the socket file at 0600 (the sender refuses any other mode), every connection's
# bytes appended to <out>.
watch_srv() {
  cat > "$WORK/srv.py" <<'EOF'
import os, socket, sys
path, mode, out = sys.argv[1:4]
if os.path.exists(path):
    os.unlink(path)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
os.chmod(path, 0o600)
s.listen(16)
while True:
    c, _ = s.accept()
    c.settimeout(5)
    data = b""
    try:
        while True:
            b = c.recv(65536)
            if not b:
                break
            data += b
    except OSError:
        pass
    c.close()
    with open(out, "ab") as f:
        f.write(data)
EOF
}

# mkrole <TAG> — a live holder pid P (the "claude" process) and its socket $SD/P.sock, served into
# $WORK/<TAG>.recv; sets <TAG>_PID and <TAG>_SOCK. The socket name gives tw_sock_pid the pid.
mkrole() {
  local p
  sleep 3000 & p=$!; PIDS="$PIDS $p"
  eval "${1}_PID=$p; ${1}_SOCK=$SD/$p.sock"
  python3 -I "$WORK/srv.py" "$SD/$p.sock" read "$WORK/$1.recv" & PIDS="$PIDS $!"
  for _ in $(seq 1 50); do [ -S "$SD/$p.sock" ] && [ -n "$(find "$SD/$p.sock" -perm 600)" ] && return 0
    sleep 0.1; done
  fail "stub server did not bind $SD/$p.sock"
}

as() {  # as <role|-> <TAG> <cmd...> — run in MAIN as that role's session
  local r="$1" s
  eval "s=\$${2}_SOCK"; shift 2
  if [ "$r" = - ]; then
    run "$MAIN" env -u TEAM_SESSION_ROLE CLAUDE_CODE_MESSAGING_SOCKET="$s" \
      CLAUDE_CODE_MESSAGING_TOKEN=tok "$@"
  else
    run "$MAIN" env TEAM_SESSION_ROLE="$r" CLAUDE_CODE_MESSAGING_SOCKET="$s" \
      CLAUDE_CODE_MESSAGING_TOKEN=tok "$@"
  fi
}

msgs() {  # msgs <TAG> → the message texts received, one JSON string per line
  [ -f "$WORK/$1.recv" ] || return 0
  jq -nR '[inputs | fromjson? | select(.type == "user") | .message.content][]' "$WORK/$1.recv"
}
nrecv() {  # nrecv <TAG> <text> → messages containing it
  msgs "$1" | jq -s --arg x "$2" 'map(select(contains($x))) | length'
}
wait_recv() {  # wait_recv <TAG> <text> <secs> [count]
  local end=$((SECONDS + $3))
  until [ "$(nrecv "$1" "$2")" -ge "${4:-1}" ]; do
    if [ "$SECONDS" -ge "$end" ]; then
      { cat "$WORK/daemon.log" 2>/dev/null || true; echo "--- $1"; msgs "$1"; } > "$WORK/out"
      fail "$1 did not receive within $3s: $2 (x${4:-1})"
    fi
    sleep 0.5
  done
}
last_batch() {  # last_batch <TAG> → #n of the newest message
  msgs "$1" | tail -n 1 | jq -r 'capture("^\\[team-watch #(?<n>[0-9]+)\\]").n'
}

daemon() {
  (cd "$MAIN" && TEAM_WATCH_SECS=1 exec bash .claude/lib/team-watch.sh run) >> "$WORK/daemon.log" 2>&1 &
  DPID=$!; PIDS="$PIDS $DPID"
}
stop_daemon() { [ -z "$DPID" ] || { kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null || true; DPID=""; }; }

mkclone() {  # mkclone <team> [run] → CT = the clone's .agents/team, written by team_write_json
  local d="$WORK/main-$1"
  git clone --quiet "$ADO_URL" "$d"
  ( cd "$MAIN" && . "$SRC/.claude/lib/team-profile.sh" && team_profile_load "$MAIN" \
    && . "$SRC/.claude/lib/team-lib.sh" \
    && team_write_json "$d" "$1" AB-1118 "chore/AB-1118-$1" origin/develop brainstorm "$MAIN" )
  CT="$d/.agents/team"
  [ -z "${2:-}" ] || { echo "$2" > "$CT/run"; mkdir -p "$CT/runs/$2"; }
}
wrec() {  # wrec <td> <team> <run> <role> <verdict> [message] — the team-record.sh shape
  jq -n --arg t "$2" --arg run "$3" --arg role "$4" --arg v "$5" --arg m "${6:-}" \
    '{team: $t, ticket: "AB-1118", run: $run, role: $role, attempt: 1, seq: 1, branch: "x",
      input_rev: "", output_rev: "", verdict: $v, pr_id: 8571, artifacts: [], evidence: [],
      notes: "", message: $m, written_at: "2026-10-19T09:00:00Z"}' > "$1/runs/$3/$4-1-1.json"
  [ "$5" != done ] || touch "$1/runs/$3/$4-1-1.json.accepted"
}
wsess() {  # wsess <td> <team> <run> <role>
  jq -n --arg t "$2" --arg run "$3" --arg role "$4" \
    '{team: $t, role: $role, run: $run, attempt: 1, ticket: "AB-1118", input_rev: "",
      launched_at: "2026-10-19T00:00:00Z"}' > "$1/session.json"
}
mailcfg() {  # mailcfg <Supervisor cmd> [TeamLead cmd] — the rendered watch.local.json shape
  mkdir -p "$MAIN/.agents/team"
  jq -n --arg s "$1" --arg t "${2:-true}" \
    '{mail: {Supervisor: $s, TeamLead: $t}, mail_unread: $s, timeout_secs: 10}' \
    > "$MAIN/.agents/team/watch.local.json"
}
dead_pid() { sh -c 'exit 0' & local p=$!; wait "$p" 2>/dev/null || true; echo "$p"; }
setpid() {  # setpid <role> <pid> — fixture surgery on a receiver file
  jq --argjson p "$2" '.pid = $p' "$TWD/receivers/$1.json" > "$WORK/r" \
    && mv "$WORK/r" "$TWD/receivers/$1.json"
}
lib() {  # lib <shell> — a team-watch library call in MAIN → RC, $WORK/out
  run "$MAIN" bash -c ". .claude/lib/team-watch-lib.sh && tw_init \"\$PWD\" && $1"
}
nnotify() {  # nnotify <text> → stub notify.sh calls carrying it
  grep -c "^notify .*$1" "$STUB_LOG" 2>/dev/null || true
}
