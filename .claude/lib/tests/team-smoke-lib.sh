#!/usr/bin/env bash
# Shared offline fixtures; each suite part owns its workspace and EXIT cleanup.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/suite-case-time.sh"
SRC=$(cd "$HERE/../../.." && pwd)
FIX="$SRC/.claude/lib/tests/fixtures/prompts"

fail() { echo "team-smoke: FAIL — $*"; [ ! -f "$WORK/out" ] || sed 's/^/  | /' "$WORK/out"; exit 1; }
has() { grep -qF -- "$1" "$2"; }
run() {  # run <dir> <cmd...> → RC, $WORK/out
  local d="$1"; shift
  set +e; (cd "$d" && "$@") > "$WORK/out" 2>&1; RC=$?; set -e
}
expect() {  # expect <rc> <text> <label>
  [ "$RC" = "$1" ] || fail "$3: exit $RC, expected $1"
  [ -z "$2" ] || has "$2" "$WORK/out" || fail "$3: output lacks '$2'"
}

session() {  # session <role> <attempt> <input_rev> [session_id]
  jq -n --arg role "$1" --argjson attempt "$2" --arg input "$3" --arg run "$RUN_ID" \
    --arg sid "${4:-sid-$1-$2}" \
    '{team: "alfa", role: $role, run: $run, attempt: $attempt, ticket: "AB-790",
      input_rev: $input, launched_at: "2026-10-02T00:00:00Z", session_id: $sid}' > "$TD/session.json"
}
# The role's Claude transcript in the hermetic HOME.
# The scripts resolve the clone through git (/private/var/…), so the slug uses the physical path.
transcript() {
  echo "$HOME/.claude/projects/$(cd "$CLONE" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')/$1.jsonl"
}
pending_tool() {  # pending_tool <sid> <tool_use id> <tool> <json input> [cwd]
  mkdir -p "$(dirname "$(transcript "$1")")"
  jq -cn --arg id "$2" --arg n "$3" --argjson in "$4" --arg cwd "${5:-}" '{type: "assistant",
    uuid: ("a-" + $id), message: {content: [{type: "tool_use", id: $id, name: $n, input: $in}]}}
    | if $cwd != "" then .cwd = $cwd else . end' >> "$(transcript "$1")"
}
# mkask <a-n> <kind> <tier> <payload json> [waiter pid] — an ask of the current stage, as the stage
# hook files it (team-ask.sh file contract); role, attempt and session id come from session.json.
# A permission ask needs a live waiter pid, or the channel withdraws it as timed out.
mkask() {
  local run; run="$(cat "$TD/run")"; mkdir -p "$TD/runs/$run/asks"
  jq -n --arg id "$1" --arg k "$2" --arg t "$3" --argjson p "$4" --arg w "${5:-}" \
    --slurpfile s "$TD/session.json" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{id: $id, kind: $k, role: $s[0].role, attempt: $s[0].attempt, round: ($s[0].round // 1),
      session_id: $s[0].session_id, agent_id: "", agent_type: "", payload: $p, tier: $t,
      tier_cause: "", fp: ("fixture-" + $id), state: "waiting", filed_at: $at}
     + (if $w != "" then {waiter_pid: ($w | tonumber)} else {} end)' > "$TD/runs/$run/asks/$1.json"
}
tool_done() {  # tool_done <sid> <tool_use id>
  jq -cn --arg id "$2" '{type: "user", uuid: ("u-" + $id),
    message: {content: [{type: "tool_result", tool_use_id: $id}]}}' >> "$(transcript "$1")"
}
hook() { set +e; printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" bash "$HOOK" > "$WORK/out" 2>&1; RC=$?; set -e; }
commit_file() {  # commit_file <path> <content>
  mkdir -p "$CLONE/$(dirname "$1")"; printf '%s\n' "$2" > "$CLONE/$1"
  git -C "$CLONE" add "$1" && git -C "$CLONE" commit --quiet -m "add $1"
}
pr_json() {  # pr_json <isDraft> <source sha> [mergeStatus] [target ref] [target sha]
  jq -n --argjson d "$1" --arg s "$2" --arg ms "${3:-succeeded}" --arg t "${4:-refs/heads/develop}" \
    --arg ts "${5:-$BASE}" \
    '{pullRequestId: 8371, status: "active", isDraft: $d, mergeStatus: $ms,
      repository: {name: "fixture"}, sourceRefName: "refs/heads/feature/AB-790-x", targetRefName: $t,
      lastMergeSourceCommit: {commitId: $s}, lastMergeTargetCommit: {commitId: $ts},
      lastMergeCommit: {commitId: (env.MERGE_SHA // "")}}' > "$STUB_PR"
}
pr_set() {  # pr_set <jq args...> — edit the stub PR in place
  jq "$@" "$STUB_PR" > "$WORK/pr-set.json" && mv "$WORK/pr-set.json" "$STUB_PR"
}
record() { (cd "$CLONE" && $REC "$@") | tail -n 1; }

# Run fixtures for parts 2 and 3; they use the part's BR, TGT0, RUN_ID and RD.
pr_w() {  # pr_w <source sha> [target sha] — the PR of the clone's current branch
  pr_json false "$1" succeeded refs/heads/develop "${2:-$TGT0}"
  pr_set --arg b "refs/heads/$BR" '.sourceRefName = $b'
}
mkrec() {  # mkrec <role> <output sha> [verdict] — an accepted record in this run
  jq -n --arg role "$1" --arg rev "$2" --arg run "$RUN_ID" --arg v "${3:-done}" \
    --arg t "$(jq -r .ticket "$TD/team.json")" \
    '{team: "alfa", ticket: $t, run: $run, role: $role, attempt: 1, seq: 1, branch: "x",
      input_rev: "", output_rev: $rev, verdict: $v, pr_id: 8371, artifacts: [], evidence: [],
      notes: "", message: "", written_at: "2026-10-04T00:00:00Z"}' > "$RD/$1-1-1.json"
  [ "${3:-done}" != done ] || touch "$RD/$1-1-1.json.accepted"
}
point() {  # point <sha> — clone branch and its origin tip at <sha> (fixture-only ref surgery)
  git -C "$CLONE" switch --quiet -C "$BR" "$1"
  git -C "$CLONE" push --quiet --force origin "$1:refs/heads/$BR"
}
merge_at() {  # merge_at <source sha> [target sha] — ADO's merge ref and PR state for <sha>
  git -C "$CLONE" push --quiet --force origin "$1:refs/pull/8371/merge"
  export MERGE_SHA="$1"; pr_w "$1" "${2:-$TGT0}"
}

snap() {  # snap <label> <jq condition>; `coder` = the alfa coder role object
  run "$MAIN" $SNAP --out "$WORK/snap.json"
  expect 0 "" "snapshot $1"
  jq -e "def coder: .teams[] | select(.team == \"alfa\") | .roles[] | select(.role == \"coder\"); $2" \
    "$WORK/snap.json" >/dev/null || { jq . "$WORK/snap.json" > "$WORK/out" 2>&1; fail "snapshot $1: $2"; }
}

smoke_init() {
  WORK=$(mktemp -d)
  SPID=""
  trap '[ -z "$SPID" ] || kill "$SPID" 2>/dev/null || true; rm -rf "$WORK"' EXIT
  REAL_GIT=$(command -v git)
  ADO_URL=https://dev.azure.com/fixture/_git/fixture
  GH_URL=https://github.com/acme/widgets
  GH_BARE="$WORK/origin.git"
  export STUB_LOG="$WORK/log" STUB_PR="$WORK/pr.json" REAL_GIT ADO_URL GH_URL GH_BARE
  export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
  # The runner resolves .claude/codex-profile against HOME; keep it hermetic.
  export HOME="$WORK/home"
  # A fixture hook must never register the calling Claude session's own messaging socket: a
  # doorbell would then reach that real session. A case that needs a socket sets its own.
  unset CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN
  # Nor may it see the calling session's identity: run from a team role session, the driver's
  # HARNESS_* (HARNESS_MAIN/HARNESS_REGISTRY win over the fixture root in sh_main_root), the run's
  # TEAM_RUN_* and the host's terminal ids would point the fixtures at the real registry and
  # terminal. A case that needs one sets it per call.
  unset ${!HARNESS_@} TEAM_SESSION_ROLE TEAM_RUN_TEAM TEAM_RUN_ROLE TEAM_RUN_ID TEAM_RUN_ATTEMPT \
    HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE TMUX TMUX_PANE
  mkdir -p "$HOME/.codex-acmeshop"
  export TEAM_POLL_SECS=0 TEAM_ADO_WAIT_SECS=0 TEAM_ADO_POLL_SECS=1
  export TEAM_EXIT_WAIT_SECS=0 TEAM_STOP_WAIT_SECS=1
  export TEAM_SEND_LOCK_WAIT=1 TEAM_SEND_LOCK_WAIT_SENDER=0
  export TEAM_GATE_LOCK_POLL=0.1
  # No per-run TeamLead in a fixture unless the part unsets TEAM_SMOKE_NO_LEAD (the lead parts).
  export TEAM_SMOKE=1 TEAM_SMOKE_NO_LEAD=1
  # The session-host driver runs only fixture binaries under TEAM_SMOKE=1, and never picks a host
  # by itself: a fake `hc` on PATH must not move an old part off tmux.
  export TEAM_SMOKE_BIN_DIR="$WORK/bin" TEAM_SESSION_HOST=tmux
  # Session names carry the fixture prefix (teams.session_prefix = smk).
  unset TEAM_GATE_LOCK_DIR TEAM_GATE_LOCK_LOG TEAM_GATE_LOCK_TOKEN TEAM_GATE_LOCK_WAIT
  unset CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR
  smoke_gitconfig
  smoke_stubs
  smoke_git_stub
  chmod +x "$WORK/bin/"*
  export PATH="$WORK/bin:$PATH"
  smoke_repos
  REC="bash .claude/lib/team-record.sh"
  TR="bash .claude/lib/team-run.sh"
  HOOK="$SRC/.claude/hooks/guard-team-memory.sh"
  SNAP="bash .claude/lib/team-snapshot.sh"
}

smoke_gitconfig() {
  cat > "$GIT_CONFIG_GLOBAL" <<EOF
[user]
  name = smoke
  email = smoke@example.invalid
[init]
  defaultBranch = develop
[advice]
  detachedHead = false
[url "$WORK/origin.git"]
  insteadOf = $ADO_URL
  insteadOf = $GH_URL
EOF

}

smoke_stubs() {
  mkdir -p "$WORK/bin"
  for t in claude codex dotnet; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\n' "$t" > "$WORK/bin/$t"
  done
  # The build check's view of the main checkout (team-merge-check exports HARNESS_MAIN).
  echo 'echo "HARNESS_MAIN=${HARNESS_MAIN-unset}"' >> "$WORK/bin/dotnet"
  # The runner's auto-mode preflight reads the version; not logged, it launches nothing.
  printf '#!/usr/bin/env bash\n[ "$*" != --version ] || { echo "${STUB_CLAUDE_VERSION:-2.1.301} (Claude Code)"; exit 0; }\necho "claude $*" >> "$STUB_LOG"\n' \
    > "$WORK/bin/claude"
  # Logged only: a test asserts nothing calls osascript directly.
  printf '#!/usr/bin/env bash\necho "osascript $*" >> "$STUB_LOG"\n' > "$WORK/bin/osascript"
  cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "$STUB_LOG"
if [ "$1" = has-session ]; then
  [ -z "${STUB_ON_HAS_SESSION:-}" ] || eval "$STUB_ON_HAS_SESSION"
  gone="can't find session: ${3#=}"
  [ "${STUB_TMUX_ALIVE:-1}" = 0 ] || echo "${STUB_TMUX_ERR:-$gone}" >&2
  exit "${STUB_TMUX_ALIVE:-1}"
fi
# Real tmux finds no pane for `-t =NAME` (session-only form); pane commands need `=NAME:`.
case "$1 $*" in capture-pane*" -t ="*|send-keys*" -t ="*) case "$*" in *" -t ="*:*) ;;
  *) echo "can't find pane" >&2; exit 1 ;; esac ;; esac
if [ "$1" = list-panes ]; then
  [ "${STUB_TMUX_ALIVE:-1}" = 0 ] || exit 1
  [ "${STUB_LIST_PANES_RC:-0}" = 0 ] || { echo "no such session" >&2; exit "$STUB_LIST_PANES_RC"; }
  # Rows `<pane pid> <command>`; the default group 99999999 is above every pid_max, so it holds no claude.
  [ -z "${STUB_PANES:-}" ] || { printf '%b\n' "$STUB_PANES"; exit 0; }
  echo "${STUB_PANES_PID:-99999999} ${STUB_PANE_CMD:-claude}"; exit 0
fi
if [ "$1" = display-message ]; then
  [ "${STUB_TMUX_ALIVE:-1}" = 0 ] || exit 1
  # The driver's pane-pid and foreground probes; every other format keeps its old answer.
  case "$*" in
    *'#{pane_pid}'*) echo "${STUB_PANE_PID:-4242}"; exit 0 ;;
    *'#{pane_current_command}'*) echo "${STUB_PANE_CMD:-claude}"; exit 0 ;;
    *'#{session_path}'*) echo "${STUB_SESSION_PATH:-/elsewhere}"; exit 0 ;;
  esac
  echo "${STUB_PANE_ID:-%1}@${STUB_PANE_CREATED:-1700000000}"; exit 0
fi
if [ "$1" = send-keys ]; then
  [ -z "${STUB_ON_SENDKEYS:-}" ] || eval "$STUB_ON_SENDKEYS"
  n=$(grep -c '^tmux send-keys ' "$STUB_LOG" || true)
  [ "$n" != "${STUB_SENDKEYS_FAIL_AT:-0}" ] || { echo "can't find pane" >&2; exit 1; }
  # The pane echoes typed text until Enter/Escape/C-u, as the sender waits for it.
  case " $* " in
    *" -l -- "*) a="$*"; printf '%s' "${a#* -l -- }" > "$STUB_LOG.typed" ;;
    *" Enter "|*" Escape "|*" C-u ") rm -f "$STUB_LOG.typed" ;;
  esac
fi
[ "$1" != capture-pane ] || [ -z "${STUB_ON_CAPTURE:-}" ] || eval "$STUB_ON_CAPTURE"
if [ "$1" = capture-pane ] && [ -n "${STUB_PANE:-}" ]; then
  if [ "${STUB_ECHO:-1}" = 1 ] && [ -f "$STUB_LOG.typed" ]; then
    # Menu at the bottom → the Other row, cursor on it; otherwise the input line under the top rule.
    T="$(cat "$STUB_LOG.typed")" awk '
      { l[NR] = $0; s = $0; gsub(/\033\[[0-9;:?]*[a-zA-Z]/, "", s)
        if (p ~ /────────────────────/ && s ~ /^ *❯( |$)/ && s !~ /^ *❯ *[0-9]+\./) inp = NR
        if (index(s, "Type something")) oth = NR
        p = s }
      END { m = index(p, "Enter to select") && oth; at = m ? oth : inp
        for (i = 1; i <= NR; i++) {
          if (i != at) { s = l[i]; if (m) sub(/^❯ /, "  ", s); print s; continue }
          s = l[i]; gsub(/\033\[[0-9;:?]*[a-zA-Z]/, "", s)
          if (m) { s = substr(s, 1, index(s, "Type something") - 1); sub(/^  /, "❯ ", s)
            print s ENVIRON["T"] }
          else print "❯ " ENVIRON["T"] } }' "$STUB_PANE"
  else
    cat "$STUB_PANE"
  fi
fi
STUB
  cat > "$WORK/bin/az" <<'STUB'
#!/usr/bin/env bash
echo "az $*" >> "$STUB_LOG"
case "$*" in
  "account show"*) echo '{}' ;;
  "repos pr show"*) [ -z "${STUB_AZ_PIDFILE:-}" ] || echo $$ > "$STUB_AZ_PIDFILE"
    [ -z "${STUB_AZ_SLEEP:-}" ] || sleep "$STUB_AZ_SLEEP"
    [ -z "${STUB_TOUCH:-}" ] || touch "$STUB_TOUCH"; cat "$STUB_PR" ;;
  *) exit 1 ;;
esac
STUB
  # Fake herdr-core CLI (session-host driver, Herdr backend). Logs `hc $*`; `run` also writes its argv,
  # one word per line, to $STUB_HC_RUN_ARGV. Behaviour from STUB_HC_*: SERVER (server status rc),
  # ADDR (the handle), STATE (live|finished), FG / FG_NAME / FG_PID (foreground), STATUS (null|idle|
  # working|blocked|done; STATUS_FILE wins and `keys … esc` writes idle into it), KIND, MSG, LABELS
  # (JSON), CREATED, PID, SCREEN (a file `read` prints), ON_SEND (shell text `send` evals). Gone:
  # STUB_HC_GONE=1 or $STUB_HC_GONE_FILE exists (kill and a `send … /exit` create it) — get, keys,
  # send and read exit 3, or 11 when finished. STUB_HC_IDLOG: each call also logged there as
  # `id-set|id-unset hc $*` — whether HC_TERMINAL_ID reached it (a send with it set arrives wrapped).
  cat > "$WORK/bin/hc" <<'STUB'
#!/usr/bin/env bash
echo "hc $*" >> "$STUB_LOG"
if [ -n "${STUB_HC_IDLOG:-}" ]; then
  if [ -n "${HC_TERMINAL_ID+x}" ]; then echo "id-set hc $*"; else echo "id-unset hc $*"; fi >> "$STUB_HC_IDLOG"
fi
gone() { [ "${STUB_HC_GONE:-}" = 1 ] || { [ -n "${STUB_HC_GONE_FILE:-}" ] && [ -f "$STUB_HC_GONE_FILE" ]; }; }
st() { if [ -n "${STUB_HC_STATUS_FILE:-}" ] && [ -f "$STUB_HC_STATUS_FILE" ]; then cat "$STUB_HC_STATUS_FILE"
  else echo "${STUB_HC_STATUS:-idle}"; fi; }
nf() { echo '{"error":{"kind":"not_found","message":"no such terminal"}}' >&2; exit 3; }
fin() { [ "${STUB_HC_STATE:-live}" != finished ] || { echo '{"error":{"kind":"finished"}}' >&2; exit 11; }; }
case "$1" in
  server) [ "${2:-}" = status ] || exit 2
          [ "${STUB_HC_SERVER:-0}" = 0 ] || exit "${STUB_HC_SERVER}"
          echo '{"version":"0.1.20","live":1,"pid":4242}' ;;
  run) [ -z "${STUB_HC_RUN_ARGV:-}" ] || printf '%s\n' "$@" > "$STUB_HC_RUN_ARGV"
       [ "${STUB_HC_RUN_RC:-0}" = 0 ] || { echo '{"error":{"kind":"spawn_failed"}}' >&2; exit "$STUB_HC_RUN_RC"; }
       rm -f "${STUB_HC_GONE_FILE:-/nonexistent}"
       echo "{\"address\":\"${STUB_HC_ADDR:-t1a}\",\"state\":\"live\",\"created_ms\":${STUB_HC_CREATED:-1700000000000}}" ;;
  get) gone && nf
       # NONAME=1: no terminal under a name (only handles t… resolve); GET_RC_HANDLE: a handle probe fails.
       case "${2:-}" in t[0-9]*) [ -z "${STUB_HC_GET_RC_HANDLE:-}" ] || exit "$STUB_HC_GET_RC_HANDLE" ;;
         *) [ "${STUB_HC_NONAME:-}" != 1 ] || nf ;; esac
       s="$(st)"; l="${STUB_HC_LABELS:-}"; [ -n "$l" ] || l='{}'
       jq -cn --arg a "${STUB_HC_ADDR:-t1a}" --arg state "${STUB_HC_STATE:-live}" --arg fg "${STUB_HC_FG:-claude}" \
         --arg fn "${STUB_HC_FG_NAME:-${STUB_HC_FG:-claude}}" --argjson fp "${STUB_HC_FG_PID:-999999}" \
         --arg s "$s" --arg k "${STUB_HC_KIND:-}" --arg m "${STUB_HC_MSG:-}" \
         --argjson l "$l" --argjson c "${STUB_HC_CREATED:-1700000000000}" \
         --argjson p "${STUB_HC_PID:-4243}" --arg cwd "${STUB_HC_CWD:-/fixture}" \
         '{address: $a, state: $state, labels: $l, created_ms: $c, pid: $p, cwd: $cwd, argv: ["sh"],
           foreground: (if $state == "live" then {argv: [$fg], name: $fn, pid: $fp, cwd: $cwd} else null end),
           status: (if $s == "null" or $state != "live" then null
             else {state: $s} + (if $k != "" then {kind: $k} else {} end) + (if $m != "" then {msg: $m} else {} end) end)}' ;;
  send) gone && nf; fin
        [ "$(st)" != blocked ] || { echo '{"error":{"kind":"blocked","message":"blocked (permission)"}}' >&2; exit 9; }
        [ "${3:-}" != /exit ] || [ -z "${STUB_HC_GONE_FILE:-}" ] || touch "$STUB_HC_GONE_FILE"
        [ -z "${STUB_HC_ON_SEND:-}" ] || eval "$STUB_HC_ON_SEND"
        echo '{"turn":1,"status":"idle","started":true}' ;;
  keys) gone && nf; fin
        case " $* " in *" esc "*) [ -z "${STUB_HC_STATUS_FILE:-}" ] || echo idle > "$STUB_HC_STATUS_FILE" ;; esac
        echo '{"turn":1}' ;;
  read) gone && nf; [ -z "${STUB_HC_SCREEN:-}" ] || cat "$STUB_HC_SCREEN"
        # As the live hc (2026-11-16): with --lines, a working or blocked terminal gets a note line
        # of hc's own on stdout after its screen.
        case " $* :$(st)" in
          *" --lines "*:blocked) echo "[hc] only its screen: it is blocked; history is not scrolled in this state" ;;
          *" --lines "*:working) echo "[hc] only its screen: it is working; read again once it stops for its history" ;;
        esac ;;
  kill) [ -z "${STUB_HC_GONE_FILE:-}" ] || touch "$STUB_HC_GONE_FILE"; echo '{}' ;;
  label) # With a window model (fake herdr-app): herdr.space=<s> [herdr.tab=<t>] adopts the terminal there;
         # an unknown tab id, or none, makes a new tab "tb<terminal>". STUB_HERDR_NOADOPT=1: no effect.
         t="$2"; shift 2; sp=""; tb=""
         for kv in "$@"; do case "$kv" in herdr.space=*) sp="${kv#*=}" ;; herdr.tab=*) tb="${kv#*=}" ;; esac; done
         L="${STUB_HERDR_LS:-}"
         if [ -n "$sp" ] && [ -n "$L" ] && [ -f "$L" ] && [ "${STUB_HERDR_NOADOPT:-}" != 1 ]; then
           jq --arg t "$t" --arg s "$sp" --arg b "$tb" '(.spaces[].tabs[].terminals) |= map(select(.terminal != $t))
             | .parked = ((.parked // []) - [$t])
             | (.spaces[] | select(.id == $s) | .tabs) |= (if $b != "" and any(.[]; .id == $b)
                 then map(if .id == $b then .terminals += [{terminal: $t, pane: ("p" + $t)}] else . end)
                 else . + [{id: ("tb" + $t), name: "", terminals: [{terminal: $t, pane: ("p" + $t)}]}] end)' "$L" > "$L.$$" && mv "$L.$$" "$L"
         fi
         echo '{}' ;;
  rm) echo '{}' ;;
  *) exit 2 ;;
esac
STUB
  # Fake herdr-app, as the live window behaves (step 7 live): a model in the JSON file $STUB_HERDR_LS
  # ({spaces, focus, parked}); terminals carry their pane ("p<terminal>"). `ls` prints {spaces};
  # `status` prints {focused_pane, agent} (agent is NOT the focus); `do`: space.new (a new space with
  # a shell tab; shows it, answers {space, tab, terminal}), tab.rename, pane.focus (a listed terminal),
  # terminal.park (out of its tab, still known), terminal.keep (only a listed or parked terminal —
  # the window knows no other; into the focused terminal's tab). STUB_HERDR_RC: every call exits with
  # it; STUB_HERDR_DO_RC: every `do`; STUB_HERDR_KEEP_RC: only terminal.keep.
  cat > "$WORK/bin/herdr-app" <<'STUB'
#!/usr/bin/env bash
echo "herdr-app $*" >> "$STUB_LOG"
[ "${STUB_HERDR_RC:-0}" = 0 ] || exit "$STUB_HERDR_RC"
L="${STUB_HERDR_LS:-}"
upd() { [ -n "$L" ] && [ -f "$L" ] || return 0; jq "$@" "$L" > "$L.$$" && mv "$L.$$" "$L"; }
q() { [ -n "$L" ] && [ -f "$L" ] && jq -e "$@" "$L" >/dev/null 2>&1; }
no() { echo "{\"error\":\"no running terminal \\\"$1\\\"\"}"; exit 1; }
case "$1" in
  ls) if [ -n "$L" ] && [ -f "$L" ]; then jq '{spaces}' "$L"; else echo '{"spaces":[]}'; fi ;;
  status) f=""; [ -z "$L" ] || [ ! -f "$L" ] || f="$(jq -r '.focus // ""' "$L")"
          jq -cn --arg f "$f" '{focused_pane: (if $f == "" then null else "p" + $f end), agent: "t-some-other-agent"}' ;;
  do) [ "${STUB_HERDR_DO_RC:-0}" = 0 ] || exit "$STUB_HERDR_DO_RC"
      c="$2"; shift 2; A=("$@")
      arg() { local i=0; while [ $i -lt ${#A[@]} ]; do [ "${A[$i]}" != "--$1" ] || { echo "${A[$((i + 1))]}"; return; }; i=$((i + 2)); done; }
      t="$(arg terminal)"; listed='any(.spaces[]?.tabs[]?.terminals[]?; .terminal == $t)'
      case "$c" in
        space.new) n="$(jq '.spaces | length + 1' "$L")"
          upd --arg n "$(arg name)" --arg f "$(arg folder)" --arg i "s$n" \
            '.spaces += [{id: $i, name: $n, folder: $f, tabs: [{id: ($i + "-1"), name: "1",
               terminals: [{terminal: ($i + "-sh"), pane: ("p" + $i + "-sh")}]}]}] | .focus = ($i + "-sh")'
          echo "{\"space\":\"s$n\",\"tab\":\"s$n-1\",\"terminal\":\"s$n-sh\"}"; exit 0 ;;
        tab.rename) upd --arg i "$(arg id)" --arg n "$(arg name)" '(.spaces[].tabs[] | select(.id == $i) | .name) = $n' ;;
        pane.focus) q --arg t "$t" "$listed" || no "$t"; upd --arg t "$t" '.focus = $t' ;;
        terminal.park) q --arg t "$t" "$listed" || no "$t"
          upd --arg t "$t" '(.spaces[].tabs[].terminals) |= map(select(.terminal != $t)) | .parked = ((.parked // []) + [$t])'
          echo '{"pending":true}'; exit 0 ;;
        terminal.keep) [ "${STUB_HERDR_KEEP_RC:-0}" = 0 ] || exit "$STUB_HERDR_KEEP_RC"
          q --arg t "$t" "$listed or any((.parked // [])[]; . == \$t)" || no "$t"
          upd --arg t "$t" '.focus as $f | .parked = ((.parked // []) - [$t])
            | (.spaces[].tabs[] | select(any(.terminals[]; .terminal == $f)) | .terminals) += [{terminal: $t, pane: ("p" + $t)}]'
          echo "{\"pending\":true,\"pane\":\"p$t\"}"; exit 0 ;;
      esac
      echo '{"ok":true}' ;;
  *) exit 2 ;;
esac
STUB
  export HC_BIN="$WORK/bin/hc" HERDR_APP_BIN="$WORK/bin/herdr-app"
}

smoke_git_stub() {
  # `git remote get-url` must show the hosted URL while transport uses the local bare repo.
  # `SMOKE_ORIGIN=github` swaps it for the GitHub one; unset keeps smoke 1-4 on ADO, untouched.
  #
  # The integration switches below only fire on a push to an explicit `…:refs/heads/…` refspec —
  # the shape the integrator uses — so the fixtures' own `git push origin <branch>` calls stay
  # untouched. Pushes are logged to `$GIT_LOG` when that is set: a log SEPARATE from `$STUB_LOG`,
  # so the assertions of smoke 1-4 keep counting exactly what they count today.
  #   STUB_GIT_PRE_PUSH="<cmd>"    run just before the real push (a racing writer)
  #   STUB_GIT_PUSH_FAIL_AFTER=1   the push really lands, then the client gets an error
  #   STUB_GIT_PUSH_KILL=1         the push really lands, then the caller is SIGKILLed
  #   STUB_GIT_POST_PUSH="<cmd>"   run right after the real push (a writer landing on top of us)
  #   STUB_GIT_LSREMOTE_FAIL=1     every `ls-remote` fails (the network, mid-recovery)
  #   STUB_GIT_STATUS_FAIL=1       `git status` fails with EMPTY stdout (an unreadable repository)
  # `switch`/`checkout` are logged to `$GIT_LOG` as well, so a test can assert that a refused run
  # moved nothing in the clone.
  cat > "$WORK/bin/git" <<'STUB'
#!/usr/bin/env bash
a=("$@")
# Opt-in forced failure of one subcommand in one directory (team-next ordering tests).
if [ -n "${STUB_GIT_FAIL_DIR:-}" ] && [ "${1:-}" = -C ] && [ "${3:-}" = "${STUB_GIT_FAIL_CMD:-}" ] \
  && [ "$(cd "$2" 2>/dev/null && pwd -P)" = "$(cd "$STUB_GIT_FAIL_DIR" && pwd -P)" ]; then
  echo "stub: forced $3 failure" >&2; exit 128
fi
[ "${1:-}" != -C ] || shift 2
if [ "${1:-} ${2:-} ${3:-}" = "remote get-url origin" ]; then
  if [ "${SMOKE_ORIGIN:-ado}" = github ]; then echo "$GH_URL"; else echo "$ADO_URL"; fi
  exit 0
fi
if [ "${1:-}" = ls-remote ] && [ "${STUB_GIT_LSREMOTE_FAIL:-0}" = 1 ]; then
  echo "fatal: unable to access origin: Operation timed out" >&2
  exit 128
fi
if [ "${1:-}" = status ] && [ "${STUB_GIT_STATUS_FAIL:-0}" = 1 ]; then
  echo "fatal: not a git repository" >&2
  exit 128
fi
case "${1:-}" in
  switch|checkout) [ -z "${GIT_LOG:-}" ] || echo "git $*" >> "$GIT_LOG" ;;
esac
if [ "${1:-}" = push ]; then
  [ -z "${GIT_LOG:-}" ] || echo "git $*" >> "$GIT_LOG"
  case "$*" in
    *:refs/heads/*)
      [ -z "${STUB_GIT_PRE_PUSH:-}" ] || eval "$STUB_GIT_PRE_PUSH"
      if [ "${STUB_GIT_PUSH_FAIL_AFTER:-0}" = 1 ]; then
        "$REAL_GIT" "${a[@]}"
        echo "fatal: the remote end hung up unexpectedly" >&2
        exit 128
      fi
      if [ -n "${STUB_GIT_POST_PUSH:-}" ]; then
        "$REAL_GIT" "${a[@]}"; prc=$?
        eval "$STUB_GIT_POST_PUSH"
        exit "$prc"
      fi
      if [ "${STUB_GIT_PUSH_KILL:-0}" = 1 ]; then
        "$REAL_GIT" "${a[@]}"
        # Walks OUR OWN ancestor chain and kills every process in it that is the integrator (the
        # main one and the command-substitution fork). `pkill -f team-integrate.sh` was the first
        # try and is wrong twice over: it did not match the harness's `bash <script> <arg>` form on
        # macOS 15, and it would also kill any unrelated process whose command line merely MENTIONS
        # the script — an editor, a grep, the session that launched the suite.
        kp="$PPID"
        while [ -n "$kp" ] && [ "$kp" != 0 ] && [ "$kp" != 1 ]; do
          kc="$(ps -o command= -p "$kp" 2>/dev/null)"
          knext="$(ps -o ppid= -p "$kp" 2>/dev/null | tr -d ' ')"
          case "$kc" in *team-integrate.sh*) kill -KILL "$kp" 2>/dev/null || true ;; esac
          kp="$knext"
        done
        exit 0
      fi ;;
  esac
fi
exec "$REAL_GIT" "${a[@]}"
STUB
}

# The `gh` stub for the PR suites. NOT called by smoke_stubs: smoke 1-4 are ADO and must not gain a
# `gh` on PATH. All PR state is a file per PR in $GH_DIR; `state` is DERIVED from the bare origin
# (head reachable from base = MERGED) so the fixture cannot claim a lifecycle the refs contradict.
# Env switches: STUB_GH_AUTH (rc of `auth status`), STUB_GH_MERGEABLE (overrides `mergeable`),
# STUB_GH_ON_MERGED="<cmd>" (run ONCE, right after a `pr view` answers MERGED — the window between
# "the PR is closed" and the integrator's final look at the base),
# STUB_GH_ON_VIEW="<cmd>" (run ONCE, right after any `pr view` — the window between a caller's
# eligibility check and whatever it does next),
# STUB_GH_CREATE_FAIL_AFTER=1 (the PR is really created, then the client gets an error),
# STUB_GH_CREATE_RACE=draft|ready (the answer is lost AND the PR that lands has the opposite
# draft state to the one asked for — a concurrent writer won the race).
smoke_gh_stub() {
  : "${GH_DIR:?smoke_gh_stub needs GH_DIR}" "${GH_LOG:?smoke_gh_stub needs GH_LOG}"
  mkdir -p "$GH_DIR"
  cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
G="$GH_DIR"
# The head sha and lifecycle GitHub would report, derived from the refs in the bare origin.
# Both print their answer: `$(pr_oid …)` runs in a subshell, so a global would never come back.
pr_oid() {  # pr_oid <file> → the live head sha, or the one recorded when the branch is gone
  local o
  o="$("$REAL_GIT" --git-dir="$GH_BARE" rev-parse -q --verify \
    "refs/heads/$(jq -r '.headRefName' "$1")" || true)"
  [ -n "$o" ] || o="$(jq -r '.headRefOid // ""' "$1")"
  printf '%s' "$o"
}
pr_state() {  # pr_state <file> <head sha> → OPEN|CLOSED|MERGED
  if [ -n "$2" ] && "$REAL_GIT" --git-dir="$GH_BARE" merge-base --is-ancestor "$2" \
    "refs/heads/$(jq -r '.baseRefName' "$1")" 2>/dev/null; then
    echo MERGED
  elif [ "$(jq -r '.closed // false' "$1")" = true ]; then
    echo CLOSED
  else
    echo OPEN
  fi
}
pr_obj() {  # pr_obj <file> → the PR object with state/headRefOid/mergeable resolved
  local o st
  o="$(pr_oid "$1")"; st="$(pr_state "$1" "$o")"
  jq -c --arg o "$o" --arg s "$st" --arg m "${STUB_GH_MERGEABLE:-}" \
    '.headRefOid = $o | .state = $s | (if $m == "" then . else .mergeable = $m end)' "$1"
}
case "${1:-} ${2:-}" in
  "auth status") exit "${STUB_GH_AUTH:-0}" ;;
esac
case "${1:-}" in
  pr)
    case "${2:-}" in
      view)
        n="$3"; shift 3; q=""
        while [ $# -gt 0 ]; do case "$1" in -q|--jq) q="$2"; shift 2 ;; *) shift ;; esac; done
        [ -f "$G/pr-$n.json" ] || { echo "no pull requests found for #$n" >&2; exit 1; }
        if [ -n "$q" ]; then pr_obj "$G/pr-$n.json" | jq -r "$q"
        else pr_obj "$G/pr-$n.json"; fi
        if [ -n "${STUB_GH_ON_VIEW:-}" ] && [ ! -f "$G/on-view" ]; then
          : > "$G/on-view"
          ( set +e; eval "$STUB_GH_ON_VIEW" ) >/dev/null 2>&1 || true
        fi
        if [ -n "${STUB_GH_ON_MERGED:-}" ] && [ ! -f "$G/on-merged-$n" ] \
          && [ "$(pr_state "$G/pr-$n.json" "$(pr_oid "$G/pr-$n.json")")" = MERGED ]; then
          : > "$G/on-merged-$n"
          ( set +e; eval "$STUB_GH_ON_MERGED" ) >/dev/null 2>&1 || true
        fi ;;
      list)
        head=""; base=""; shift 2
        while [ $# -gt 0 ]; do case "$1" in
          --head) head="$2"; shift 2 ;; --base) base="$2"; shift 2 ;; *) shift ;; esac; done
        # `--head` filters by BRANCH NAME only — a fork's PR on the same name comes back too.
        out='[]'
        for f in "$G"/pr-*.json; do
          [ -f "$f" ] || continue
          [ "$(pr_state "$f" "$(pr_oid "$f")")" = OPEN ] || continue
          [ "$(jq -r '.headRefName' "$f")" = "$head" ] || continue
          [ -z "$base" ] || [ "$(jq -r '.baseRefName' "$f")" = "$base" ] || continue
          out="$(printf '%s' "$out" | jq -c --argjson p "$(pr_obj "$f")" '. + [$p]')"
        done
        printf '%s\n' "$out" ;;
      create)
        base=""; head=""; t=""; bf=""; draft=false; shift 2
        while [ $# -gt 0 ]; do case "$1" in
          --base) base="$2"; shift 2 ;; --head) head="$2"; shift 2 ;;
          --title) t="$2"; shift 2 ;; --body-file) bf="$2"; shift 2 ;;
          --draft) draft=true; shift ;; *) shift ;; esac; done
        n="$(cat "$G/next" 2>/dev/null || echo 41)"; echo $((n + 1)) > "$G/next"
        case "${STUB_GH_CREATE_RACE:-}" in
          draft) draft=true ;; ready) draft=false ;;
        esac
        jq -n --argjson n "$n" --argjson d "$draft" --arg h "$head" --arg b "$base" \
          --arg t "$t" --rawfile body "$bf" \
          '{number: $n, isDraft: $d, headRefName: $h, baseRefName: $b, title: $t,
            headRepositoryOwner: {login: "acme"}, headRepository: {name: "widgets"},
            mergeable: "MERGEABLE", body: $body, closed: false, headRefOid: ""}' \
          > "$G/pr-$n.json"
        # The uncertain write: the PR exists, the client never learns its number.
        [ -z "${STUB_GH_CREATE_RACE:-}" ] \
          || { echo "gh: timeout awaiting response headers" >&2; exit 1; }
        [ "${STUB_GH_CREATE_FAIL_AFTER:-0}" != 1 ] \
          || { echo "gh: timeout awaiting response headers" >&2; exit 1; }
        echo "https://github.com/acme/widgets/pull/$n" ;;
      ready)
        [ -f "$G/pr-$3.json" ] || { echo "no pull requests found for #$3" >&2; exit 1; }
        [ "$(jq -r '.isDraft' "$G/pr-$3.json")" = true ] \
          || { echo "Pull request #$3 is already marked as ready for review" >&2; exit 1; }
        jq '.isDraft = false' "$G/pr-$3.json" > "$G/t" && mv "$G/t" "$G/pr-$3.json"
        echo '{}' ;;
      edit)
        n="$3"; shift 3; bf=""
        while [ $# -gt 0 ]; do case "$1" in --body-file) bf="$2"; shift 2 ;; *) shift ;; esac; done
        [ -f "$G/pr-$n.json" ] || { echo "no pull requests found for #$n" >&2; exit 1; }
        [ -r "$bf" ] || { echo "gh: cannot read $bf" >&2; exit 1; }
        jq --rawfile b "$bf" '.body = $b' "$G/pr-$n.json" > "$G/t" && mv "$G/t" "$G/pr-$n.json"
        echo '{}' ;;
      *) echo "stub: gh pr ${2:-}" >&2; exit 1 ;;
    esac ;;
  *) echo "stub: gh $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$WORK/bin/gh"
}

# Fixture-only ref surgery in the bare origin, through a throwaway clone (a bare repo takes
# `refs/pull/*` without hooks, and no working tree is needed by the harness).
smoke_gh_wc() {  # smoke_gh_wc <tag> → a fresh clone of the bare origin in $SGW
  SGW="$WORK/wc-$1"
  rm -rf "$SGW"
  git clone --quiet "$WORK/origin.git" "$SGW"
}

smoke_gh_commit() {  # smoke_gh_commit <branch> <tag> — one new commit on <branch> in the origin
  local b="$1" t="$2" start="origin/$1"
  smoke_gh_wc "$t"
  git -C "$SGW" rev-parse -q --verify "$start" >/dev/null 2>&1 \
    || start="origin/${SMOKE_TRUNK:-develop}"
  git -C "$SGW" checkout --quiet -B "$b" "$start"
  printf '%s\n' "$t" > "$SGW/$t.txt"
  git -C "$SGW" add "$t.txt" && git -C "$SGW" commit --quiet -m "$t"
  git -C "$SGW" push --quiet origin "$b"
  rm -rf "$SGW"
}

smoke_gh_land() {  # smoke_gh_land <head> <base> — merge <head> into <base> in the origin
  smoke_gh_wc "land"
  git -C "$SGW" checkout --quiet -B "$2" "origin/$2"
  git -C "$SGW" merge --no-ff --no-edit --quiet "origin/$1"
  git -C "$SGW" push --quiet origin "$2"
  rm -rf "$SGW"
}

# Builds `refs/pull/<n>/merge` exactly as GitHub does: a merge commit whose parent 1 is the current
# base tip and parent 2 the PR head. The `+` force is FIXTURE-ONLY — a recomputed merge M2(T2,S) is
# not a descendant of M1, so a plain push would be rejected. Production never forces.
smoke_gh_pull() {  # smoke_gh_pull <pr> <head> <base>
  local n="$1"
  smoke_gh_wc "pull-$n"
  git -C "$SGW" checkout --quiet -B "$3" "origin/$3"
  if git -C "$SGW" merge --no-ff --no-edit --quiet "origin/$2" >/dev/null 2>&1; then
    git -C "$SGW" push --quiet origin "+HEAD:refs/pull/$n/merge"
  else
    git -C "$SGW" merge --abort || true    # a conflict leaves NO merge ref, like GitHub
  fi
  rm -rf "$SGW"
}

# An OCTOPUS merge ref: parent 1 the base, parent 2 the head, parent 3 somebody else's branch.
# `^1`/`^2` answer correctly here, so only the full parent list can reject it.
smoke_gh_pull_octopus() {  # smoke_gh_pull_octopus <pr> <head> <base> <extra>
  local n="$1"
  smoke_gh_wc "octo-$n"
  git -C "$SGW" checkout --quiet -B "$3" "origin/$3"
  git -C "$SGW" merge --no-ff --no-edit --quiet "origin/$2" "origin/$4"
  git -C "$SGW" push --quiet origin "+HEAD:refs/pull/$n/merge"
  rm -rf "$SGW"
}

smoke_gh_pull_stale() {  # smoke_gh_pull_stale <pr> <head> <base> — ref built, then the base moves
  smoke_gh_pull "$1" "$2" "$3"
  smoke_gh_commit "$3" "stale-$1"
}

smoke_gh_append() {  # smoke_gh_append <branch> <path> <line> — one commit appending <line> to <path>
  smoke_gh_wc "append"
  git -C "$SGW" checkout --quiet -B "$1" "origin/$1"
  mkdir -p "$(dirname "$SGW/$2")"
  printf '%s\n' "$3" >> "$SGW/$2"
  git -C "$SGW" add "$2" && git -C "$SGW" commit --quiet -m "append $2"
  git -C "$SGW" push --quiet origin "$1"
  rm -rf "$SGW"
}

# Usage: smoke_profile ['<jq filter>'] → the TT `teams` profile on stdout, optionally edited.
# These are exactly the values team-lib.sh and worker-next.sh used to hardcode.
smoke_profile() {
  jq -n '{schema: 1, teams: {
      tracker: "jira",
      pr_provider: "azure-devops",
      trunk: "develop",
      branch_types: ["feature", "bugfix", "hotfix", "chore", "refactor"],
      required_tools: ["git", "jq", "tmux", "claude", "codex", "az", "dotnet"],
      seed_files: [".env", ".claude/settings.local.json", ".agents/memory/user-profile.md"],
      env_file_required: true,
      build_check: "dotnet build AcmeShop2.API.sln",
      test_gate: ".claude/lib/test-gate.sh",
      gates: "auto",
      session_prefix: "smk"
    }}' | jq "${1:-.}"
}

smoke_repos() {
  git init --quiet --bare "$WORK/origin.git"
  SEED="$WORK/seed"
  mkdir -p "$SEED/.claude/lib" "$SEED/.claude/hooks" "$SEED/.claude/team/prompts"
  # branch-model.sh: integrate's remote branch cleanup reads the KEEP lists through it.
  cp "$SRC"/.claude/lib/team-*.sh "$SRC"/.claude/lib/session-host*.sh "$SRC"/.claude/lib/roles-lib.sh \
    "$SRC"/.claude/lib/branch-model.sh "$SEED/.claude/lib/"
  # Every runner exit paid a python3 audit (team-run.sh on_exit), and only team-audit-test.sh asserts
  # it: the fixture gets a no-op unless that suite asks for the real one.
  if [ "${SMOKE_REAL_AUDIT:-}" != 1 ]; then
    printf '%s\n' '#!/usr/bin/env bash' \
      '# fixture: the runner-exit audit is a no-op here; team-audit-test.sh keeps the real one' \
      'exit 0' > "$SEED/.claude/lib/team-audit.sh"
  fi
  cp "$SRC/.claude/lib/team_prompt_check.py" "$SRC/.claude/lib/team_prompt.py" \
    "$SRC/.claude/lib/team_prompt_classes.py" "$SRC/.claude/lib/team_prompt_settings.py" \
    "$SRC/.claude/lib/team_transcript.py" "$SRC/.claude/lib/team_settings_diff.py" \
    "$SRC/.claude/lib/team_audit.py" "$SRC/.claude/lib/team_prompt_authority.py" \
    "$SRC/.claude/lib/team_wrapup.py" "$SEED/.claude/lib/"
  mkdir -p "$SEED/.claude/hooks/lib"
  cp "$SRC/.claude/hooks/lib/guard_destructive_sql.py" "$SRC/.claude/hooks/lib/guard_team_egress.py" \
    "$SRC/.claude/hooks/lib/guard_team_egress_supervisor.py" \
    "$SRC/.claude/hooks/lib/guard_team_egress_loops.py" "$SEED/.claude/hooks/lib/"
  cp "$SRC/.claude/hooks/guard-team-egress.sh" "$SEED/.claude/hooks/"
  cp "$SRC/.claude/lib/notify.sh" "$SEED/.claude/lib/"  # lead_notify's sender (fixture HOME outbox)
  cp "$SRC/.claude/lib/worker-next.sh" "$SEED/.claude/lib/"
  cp "$SRC/.claude/lib/worker-lib.sh" "$SEED/.claude/lib/"
  cp "$SRC/.claude/lib/gate-lock.sh" "$SRC/.claude/lib/gate_lock.py" "$SEED/.claude/lib/"
  mkdir -p "$SEED/.agents/reference"
  cp "$SRC/.agents/reference/worker-clone.md" "$SEED/.agents/reference/"
  cp "$SRC/AGENTS.md" "$SEED/"
  cp "$SRC/.claude/hooks/guard-team-memory.sh" "$SEED/.claude/hooks/"
  # The ask channel: the stage hook and the template the runner materialises at every launch.
  cp "$SRC/.claude/hooks/team-ask-hook.sh" "$SEED/.claude/hooks/"
  cp "$SRC/.claude/team/stage-hooks.json" "$SEED/.claude/team/"
  # Fixture fix (starter import): the stage hook runs team_prompt_check.py, which imports hooks/lib.
  mkdir -p "$SEED/.claude/hooks/lib"
  cp "$SRC/.claude/lib/team_prompt_check.py" "$SEED/.claude/lib/"
  cp "$SRC"/.claude/hooks/lib/*.py "$SEED/.claude/hooks/lib/"  # never a stray __pycache__/
  cp "$SRC/.claude/hooks/lib/memory-domain.sh" "$SEED/.claude/hooks/lib/"  # team-lead.sh digest-check
  cp "$SRC"/.claude/team/prompts/*.md "$SEED/.claude/team/prompts/"
  cp "$SRC/.claude/team/baseline-ask.json" "$SEED/.claude/team/"  # the checker's production line
  # Without the tracker blocks every wrapup/planner render in smoke 1-4 dies (return 1).
  mkdir -p "$SEED/.claude/team/tracker"
  cp "$SRC"/.claude/team/tracker/*.md "$SEED/.claude/team/tracker/"
  # Same reason for the PR blocks: a prompt carrying {{PR_*}} with no block dir dies (return 1).
  mkdir -p "$SEED/.claude/team/pr"
  cp "$SRC"/.claude/team/pr/*.md "$SEED/.claude/team/pr/"
  cp "$SRC/.claude/team/roles.json" "$SRC/.claude/team/audit.json" "$SEED/.claude/team/"
  # Fixture fix (starter import): own profile, independent of the repo's (template) codex-profile.
  printf '# test fixture\n~/.codex-acmeshop\n' > "$SEED/.claude/codex-profile"
  printf '#!/usr/bin/env bash\necho "test-gate: total 3, passed 3, failed 0 (baseline 0, new 0, now passing 0)"\n' \
  > "$SEED/.claude/lib/test-gate.sh"
  # Fixture fix (starter import): the TT values the harness used to hardcode are now a profile.
  smoke_profile > "$SEED/.claude/project-profile.json"
  printf '.agents/team/\n.env\n' > "$SEED/.gitignore"
  # The prompt policy refuses a clone without settings; the real ask rules would refuse fixtures.
  # The egress hook entries let the runner's auto-mode preflight pass.
  jq -n '{permissions: {allow: [], ask: [], deny: []}, hooks: {PreToolUse: [
    {matcher: "WebFetch", hooks: [{type: "command", onFailure: "block",
      command: "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard-team-egress.sh\""}]},
    {matcher: "Bash", hooks: [{type: "command", onFailure: "block",
      command: "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard-team-egress.sh\""}]}]}}' \
    > "$SEED/.claude/settings.json"
  echo seed > "$SEED/README"
  git -C "$SEED" init --quiet
  git -C "$SEED" add -A && git -C "$SEED" commit --quiet -m seed
  git -C "$SEED" remote add origin "$ADO_URL"
  git -C "$SEED" push --quiet origin develop
  git -C "$SEED" switch --quiet -c rc && git -C "$SEED" rm --quiet .claude/lib/team-record.sh
  git -C "$SEED" commit --quiet -m "no harness" && git -C "$SEED" push --quiet origin rc
  git -C "$SEED" push --quiet origin develop:refs/heads/feature/AB-791-pushed

  git clone --quiet "$ADO_URL" "$WORK/main"
  MAIN="$WORK/main"
  echo "SECRET=x" > "$MAIN/.env"
  [ "$(git -C "$MAIN" remote get-url origin)" = "$ADO_URL" ] || fail "fixture: get-url shim"
  [ -f "$MAIN/.claude/team/prompts/qa.md" ] || fail "fixture: prompts missing"
  NEW="bash .claude/lib/team-new.sh"

}

# smoke_cancel_hook — writes $WORK/cancel-check.sh, sourced by a part's has-session hook after its
# call counter `n`: the first cause wins ($TD/cancel already there → nothing more, so the shutdown's
# own liveness probes never overwrite it); CANCEL_ON (a fixed string the runner printed to $WORK/out)
# stops the runner on that event, CANCEL_AT (a call count) is the safety cap. $WORK/cancel.why says
# which: `event` or `cap`. `run` truncates $WORK/out per call, so an earlier run's text never matches.
smoke_cancel_hook() {
  cat > "$WORK/cancel-check.sh" <<'CC'
if [ ! -e "$TD/cancel" ]; then
  if [ -n "${CANCEL_ON:-}" ] && grep -qF -- "$CANCEL_ON" "$WORK/out" 2>/dev/null; then
    echo event > "$WORK/cancel.why"; touch "$TD/cancel"
  elif [ -n "${CANCEL_AT:-}" ] && [ "$n" -ge "$CANCEL_AT" ]; then
    echo cap > "$WORK/cancel.why"; touch "$TD/cancel"
  fi
fi
CC
}
cancelled_by_event() {  # cancelled_by_event <label> — the runner stopped on CANCEL_ON, not on the cap
  [ "$(cat "$WORK/cancel.why" 2>/dev/null)" = event ] \
    || fail "$1: the runner was not stopped by its event '${CANCEL_ON:-}' ($(cat "$WORK/cancel.why" 2>/dev/null || echo none))"
}
on_event() { export CANCEL_ON="$1" CANCEL_AT=60; }  # on_event <line> — stop the runner on that line

# mkdir_spy <path glob> — writes $WORK/spy/mkdir (put "$WORK/spy" first on PATH) and empties
# $WORK/spy.log: a failed mkdir of a path matching the glob appends its caller's pid ($PPID). Lock
# attempts as a count, never a clock: one line per failed try of the held lock.
mkdir_spy() {
  mkdir -p "$WORK/spy"; : > "$WORK/spy.log"
  printf '%s\n' '#!/usr/bin/env bash' '/bin/mkdir "$@"; rc=$?' \
    "[ \"\$rc\" = 0 ] || case \"\${!#}\" in $1) echo \"\$PPID\" >> '$WORK/spy.log' ;; esac" \
    'exit "$rc"' > "$WORK/spy/mkdir"
  chmod +x "$WORK/spy/mkdir"
}

smoke_team() {  # smoke_team <ticket> <branch>; build a fresh team via the real producer.
  chmod 600 "$MAIN/.env"
  run "$MAIN" $NEW alfa "$1" "$2" origin/develop
  [ "$RC" = 0 ] || fail "fixture team creation"
  CLONE="$WORK/main-alfa"
  TD="$CLONE/.agents/team"
  BASE=$(git -C "$CLONE" rev-parse HEAD)
}
