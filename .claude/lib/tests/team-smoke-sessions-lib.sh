#!/usr/bin/env bash
# Fixtures for the role-session parts (sessions, 15, 17): a short socket dir, a tmux stub that
# really spawns a session's command (never a real tmux server), the run dir, the channel prefix.
# Sourced after team-smoke-lib.sh, after smoke_init + smoke_team.

sessions_init() {
  unset CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN TEAM_SESSION_ROLE \
    CLAUDECODE CLAUDE_CODE_ENTRYPOINT
  PIDS=""
  SD="$(mktemp -d /tmp/smk.XXXXXX)"   # macOS caps a unix socket path at 104 bytes
  TMUXD="$WORK/tmux"; mkdir -p "$TMUXD"; export STUB_TMUX_DIR="$TMUXD"
  trap 'for p in $PIDS; do kill "$p" 2>/dev/null || true; done; rm -rf "$WORK" "$SD"' EXIT
  WD="$MAIN/.agents/team/watch"; mkdir -p "$WD"
  RUN_ID=alfa-20261019-000000; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"; echo "$RUN_ID" > "$TD/run"
  printf 'Bash command\n  npm run deploy -- --name app-x\nDo you want to proceed?\n❯ 1. Yes\n' \
    > "$WORK/pane"
  export STUB_PANE="$WORK/pane" STUB_TMUX_ALIVE=0
  pr_json false "$BASE"
  # Main checkout only: in the seed its deny rules would refuse the clones' stubbed prompts.
  cp "$SRC/.claude/settings.json" "$MAIN/.claude/"
  # The doorbell's socket sender and the channel names, beyond the team-*.sh the seed carries.
  cp "$SRC/.claude/lib/team-watch-send.py" "$SRC/.claude/lib/team-channel.sh" "$MAIN/.claude/lib/"
  mkdir -p "$MAIN/.claude/team/sessions" "$MAIN/.claude/hooks"
  jq '.teams.channel = {project_code: "SM", tmux_prefix: "smk"}' \
    "$MAIN/.claude/project-profile.json" > "$WORK/prof" && mv "$WORK/prof" "$MAIN/.claude/project-profile.json"
  sessions_tmux_stub
  [ "$(command -v tmux)" = "$WORK/bin/tmux" ] || fail "fixture: tmux is not the stub"
}

# Sessions with a pid file (spawned here) or named smk-* answer by that pid; every other name (team
# roles) follows STUB_TMUX_ALIVE as in team-smoke-lib.sh. new-session runs its command for real,
# with the -e variables, in its own process group.
sessions_tmux_stub() {
  cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "$STUB_LOG"
D="$STUB_TMUX_DIR"
case "$1" in
  has-session) n="${3#=}"
    if [ -f "$D/$n.pid" ]; then kill -0 "$(cat "$D/$n.pid")" 2>/dev/null; exit $?; fi
    # Team stage sessions carry the fixture prefix too (smk-<team>-<role>): they follow STUB_TMUX_ALIVE.
    case "$n" in *-planner|*-coder|*-qa|*-wrapup|*-cli|*-runner|*-lead) ;; smk-*|smx-*) exit 1 ;; esac
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
    [ -z "$n" ] || [ -f "${STUB_PANE_DIR:-/nonexistent}/$n" ] || n="${n#smk-}"   # pane files name addresses
    if [ -n "$n" ] && [ -f "${STUB_PANE_DIR:-/nonexistent}/$n" ]; then cat "$STUB_PANE_DIR/$n"
    elif [ -n "${STUB_PANE:-}" ]; then cat "$STUB_PANE"; fi ;;
esac
exit 0
STUB
  chmod +x "$WORK/bin/tmux"
}
