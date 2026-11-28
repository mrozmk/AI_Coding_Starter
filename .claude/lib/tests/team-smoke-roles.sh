#!/usr/bin/env bash
# /roles (roles.sh) over the session-host driver: up is idempotent, restarts a killed role and a dead
# `; read` pane, reports the trust dialog, places nothing under tmux; status, stop (record kept,
# stopped_at), here on the three backends (Herdr id, tmux session, a plain terminal's pid), the
# validator stopping everything, the legacy Advisor key, a project role added in the profile only,
# the window line, roles.lock; a Codex role's floating ("default", no -m) and pinned model; the
# SessionStart contract line (session-registry.sh); Linux tmux liveness (bash leads the pane, claude in
# its group), stop's leftover close and self-last order, here's probe-failure refusal.
# A stateful stub tmux (sessions are files) and stub claude / codex; nothing reaches a real server.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
cp "$WORK/bin/hc" "$WORK/hc.lib"   # the driver's fake hc; (12) replaces it, (L) brings it back
unset TMUX TMUX_PANE HC_TERMINAL_ID CLAUDECODE TEAM_SESSIONS_CLAUDE_FLAGS CODEX_HOME HARNESS_MAIN \
  HARNESS_REGISTRY HARNESS_ADDRESS TEAM_SESSION_ROLE
export TEAM_ROLES_TRUST_SECS=1 TEAM_ROLES_LOCK_WAIT=1
MP="$(cd "$MAIN" && pwd -P)"
REG="$MP/.agents/team/registry"
D="$WORK/tmuxd"; mkdir -p "$D"; export STUB_TMUX_DIR="$D" MAINP="$MP"
RS="bash $SRC/.claude/lib/roles.sh"
HOOKR="$SRC/.claude/hooks/session-registry.sh"

# The checkout carries the role templates and contracts (/setup:teams installs them).
mkdir -p "$MAIN/.claude/team/sessions" "$MAIN/.agents/reference/roles" "$MAIN/docs/roles"
cp "$SRC"/.claude/team/sessions/{Supervisor,Advisor,TeamLead}.settings.json "$MAIN/.claude/team/sessions/"
cp "$SRC"/.agents/reference/roles/*.md "$MAIN/.agents/reference/roles/"
echo "# Monitor role (fixture)" > "$MAIN/docs/roles/monitor.md"
P="$MAIN/.claude/project-profile.json"
jq --slurpfile ex "$SRC/.claude/project-profile.json.example" '.teams.sessions = $ex[0].teams.sessions' "$P" > "$WORK/prof.bak"
cp "$WORK/prof.bak" "$P"
prof() { jq "$1" "$WORK/prof.bak" > "$P"; }

cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "$STUB_LOG"
D="$STUB_TMUX_DIR"
[ "$1" != -S ] || shift 2   # the hook names the server socket
nm() { local a; for a in "$@"; do case "$a" in =*) a="${a#=}"; echo "${a%%:*}"; return ;; esac; done; }
case "$1" in
  has-session) [ -z "${STUB_HAS_SESSION_ERR:-}" ] || { echo "$STUB_HAS_SESSION_ERR" >&2; exit 1; }
    [ -f "$D/$(nm "$@")" ] && exit 0; echo "can't find session: $(nm "$@")" >&2; exit 1 ;;
  kill-session) [ -n "${STUB_KILL_KEEP:-}" ] || rm -f "$D/$(nm "$@")"; exit 0 ;;
  list-panes) n="$(nm "$@")"
    [ "${STUB_LIST_PANES_RC:-0}" = 0 ] || { echo "list-panes failed" >&2; exit "$STUB_LIST_PANES_RC"; }
    [ -f "$D/$n" ] || { echo "can't find session: $n" >&2; exit 1; }
    # A session file holds one pane per line: `<pid> <cmd>`, or a bare command (group 99999999, no claude).
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      case "$l" in *" "*) echo "$l" ;; *) echo "99999999 $l" ;; esac
    done < "$D/$n"; exit 0 ;;
  new-session) shift; n=""
    while [ $# -gt 0 ]; do case "$1" in -s) n="$2"; shift 2 ;; -c|-e) shift 2 ;; *) shift ;; esac; done
    [ ! -f "$D/$n" ] || { echo "duplicate session: $n" >&2; exit 1; }
    echo "${STUB_FG:-claude}" > "$D/$n"; exit 0 ;;
  display-message)
    case "$*" in
      *'#S'*) [ -n "${STUB_SELF:-}" ] || exit 1; echo "$STUB_SELF"; exit 0 ;;
      *'#{pane_current_command}'*) n="$(nm "$@")"; [ -f "$D/$n" ] || exit 1; cat "$D/$n"; exit 0 ;;
      *'#{session_path}'*) echo "$MAINP"; exit 0 ;;
      *'#{pane_pid}'*) echo 4242; exit 0 ;;
    esac
    echo "%1@1700000000"; exit 0 ;;
  capture-pane) [ -z "${STUB_PANE:-}" ] || cat "$STUB_PANE"; exit 0 ;;
esac
exit 0
STUB
for t in claude codex; do
  cat > "$WORK/bin/$t" <<STUB
#!/usr/bin/env bash
echo "$t \$* | role=\${TEAM_SESSION_ROLE-unset} addr=\${HARNESS_ADDRESS-unset} be=\${HARNESS_BACKEND-unset} cc=\${CLAUDECODE-unset} ch=\${CODEX_HOME-unset}" >> "\$STUB_LOG"
[ -z "\${STUB_CLI_STAY:-}" ] || exec sleep 30
STUB
done
chmod +x "$WORK/bin/"*
clr() { : > "$STUB_LOG"; }
line() { grep -qF -- "$1" "$2" || { cp "$2" "$WORK/out" 2>/dev/null || true; fail "$3: no '$1'"; }; }
noline() { ! grep -qF -- "$1" "$2" || { cp "$2" "$WORK/out" 2>/dev/null || true; fail "$3: unexpected '$1'"; }; }
starts() { grep -c '^tmux new-session' "$STUB_LOG" || true; }
nsline() { grep "^tmux new-session.* -s smk-$1 " "$STUB_LOG" > "$WORK/ns-$1" || true; }  # one role's start line

# ---- (1) up: three roles, argv, env, profiles, hints; a second up starts nothing -----------------
clr; run "$MAIN" $RS; expect 0 "Supervisor: started" "(1) up"
for r in Fable Astra; do line "$r: started" "$WORK/out" "(1) up"; done
line "Astra: started — model: CLI default · effort high" "$WORK/out" "(1) Astra model line"
line "  Supervisor: tmux attach -t smk-supervisor" "$WORK/out" "(1) hint"
noline "This window is not a role" "$WORK/out" "(1) plain shell"
noline "error: team channel" "$WORK/out" "(1) the optional channel's absence leaked to stderr"
for r in Supervisor Fable Astra; do for d in tmp new done; do
  [ -d "$MAIN/.agents/team/inbox/$r/$d" ] || fail "(1) no inbox $r/$d after up"; done; done
[ "$(starts)" = 3 ] || fail "(1) $(starts) new-session calls, expected 3"
for r in Supervisor Fable Astra; do
  lc="$(echo "$r" | tr '[:upper:]' '[:lower:]')"; nsline "$lc"
  line "-e TEAM_SESSION_ROLE=$r " "$WORK/ns-$lc" "(1) env $r"; line "-e HARNESS_ADDRESS=$r " "$WORK/ns-$lc" "(1) env $r"
done
grep '^tmux new-session.* -s smk-astra ' "$STUB_LOG" > "$WORK/astra"
line "codex --no-daemon -c model_reasoning_effort=high 'You are Astra. Follow the role contract" "$WORK/astra" "(1) Astra argv"
noline " -m " "$WORK/astra" "(1) Astra floating model"
line "Contract: .agents/reference/roles/advisor.md'" "$WORK/astra" "(1) Astra contract"
noline "--settings" "$WORK/astra" "(1) Astra settings"; noline "; read" "$WORK/astra" "(1) Astra read"
grep '^tmux new-session.* -s smk-fable ' "$STUB_LOG" > "$WORK/fable"
line "claude --name 'Fable' --session-id " "$WORK/fable" "(1) Fable argv"
line " --model fable --effort medium --settings .agents/team/watch/profiles/Fable.settings.json -- 'You are Fable." "$WORK/fable" "(1) Fable flags"
line "; read" "$WORK/fable" "(1) Fable keeps its pane"
for r in Supervisor Fable; do
  [ "$(jq -r .env.TEAM_SESSION_ROLE "$MP/.agents/team/watch/profiles/$r.settings.json")" = "$r" ] \
    || fail "(1) materialised $r profile does not carry its own role"
done
[ "$(jq -r '.program + " " + (.session_id | length | tostring)' "$REG/Fable.json")" = "claude 36" ] \
  || fail "(1) Fable record lacks program/session_id: $(cat "$REG/Fable.json")"
[ "$(jq -r '.program // "none"' "$REG/Astra.json")" = none ] || fail "(1) Astra record names a program"
[ ! -e "$HOME/.agent-mail" ] || fail "(1) up created ~/.agent-mail — agent-mail is an optional kit (#52)"
clr; run "$MAIN" $RS up; expect 0 "Supervisor: already running" "(1) second up"
for r in Fable Astra; do line "$r: already running" "$WORK/out" "(1) second up"; done
[ "$(starts)" = 0 ] || fail "(1) the second up started something"
echo "team-smoke-roles: (1) up, argv, profiles, idempotent OK"

# ---- (2) a killed role and a dead `; read` pane are started again; only them ----------------------
rm -f "$D/smk-fable"; echo bash > "$D/smk-supervisor"
clr; run "$MAIN" $RS; expect 0 "Fable: started" "(2) up"
line "Supervisor: started" "$WORK/out" "(2) dead pane"; line "Astra: already running" "$WORK/out" "(2) left alone"
[ "$(starts)" = 2 ] || fail "(2) $(starts) new-session calls, expected 2"
line "tmux kill-session -t =smk-supervisor" "$STUB_LOG" "(2) the dead pane was not replaced"
echo "team-smoke-roles: (2) restart OK"

# ---- (3) status, stop (record kept, stopped_at), place, up <Role> --------------------------------
mkdir -p "$MP/.agents/team/inbox/Supervisor/new"; touch "$MP/.agents/team/inbox/Supervisor/new/m1.md"
run "$MAIN" $RS stop Fable; expect 0 "Fable: stopped" "(3) stop"
[ ! -f "$D/smk-fable" ] || fail "(3) smk-fable still runs"
[ -n "$(jq -r '.stopped_at // empty' "$REG/Fable.json")" ] || fail "(3) the record lost or lacks stopped_at"
run "$MAIN" $RS stop Fable; expect 0 "Fable: not running" "(3) stop again"
run "$MAIN" $RS status; expect 0 "ROLE" "(3) status"
grep -E '^Supervisor +tmux +alive +starting +1 ' "$WORK/out" >/dev/null || fail "(3) Supervisor status row"
grep -E '^Fable +tmux +stopped +gone +0 ' "$WORK/out" >/dev/null || fail "(3) Fable status row"
grep -E '^Astra +tmux +alive +unknown ' "$WORK/out" >/dev/null || fail "(3) Astra status row"
run "$MAIN" $RS place Supervisor; expect 0 "tmux attach -t smk-supervisor" "(3) place"
run "$MAIN" $RS up TeamLead; expect 2 "not a standing, enabled role" "(3) up TeamLead"
clr; run "$MAIN" $RS up Fable; expect 0 "Fable: started" "(3) up Fable"
noline "Supervisor:" "$WORK/out" "(3) up Fable reported another role"
echo "team-smoke-roles: (3) status, stop, place, up <Role> OK"

# ---- (4) validation stops everything ---------------------------------------------------------------
run "$MAIN" $RS stop all; expect 0 "Astra: stopped" "(4) stop all"
bad() {  # bad <label> <jq> <expected error>
  prof "$2"; clr; run "$MAIN" $RS; expect 2 "$3" "(4) $1"
  [ "$(starts)" = 0 ] || fail "(4) $1 started a session"
}
bad "cli" '.teams.sessions.Fable.cli = "gemini"' "teams.sessions.Fable.cli=gemini must be claude|codex"
bad "model" '.teams.sessions.Fable.model = "bad model"' "teams.sessions.Fable.model=bad model is not a model name"
bad "effort" '.teams.sessions.Astra.effort = "huge"' "teams.sessions.Astra.effort=huge must be"
bad "contract" '.teams.sessions.Fable.contract = "docs/none.md"' "teams.sessions.Fable.contract=docs/none.md: no such file"
bad "two mains" '.teams.sessions.Fable.place.slot = "main"' "tab Supervisor has more than one main slot"
bad "codex settings" '.teams.sessions.Astra.settings = "Advisor"' "teams.sessions.Astra.settings is for claude roles only"
bad "codex model" '.teams.sessions.Astra.model = "bad model"' "teams.sessions.Astra.model=bad model is not a model name"
bad "empty model" '.teams.sessions.Fable.model = ""' "teams.sessions.Fable.model= is not a model name"
echo "team-smoke-roles: (4) validation OK"

# ---- (5) legacy Advisor; a project role from the profile only ---------------------------------------
prof '.teams.sessions = {Supervisor: {model: "opus", effort: "medium"}, Advisor: {model: "opus", effort: "high"}}'
clr; run "$MAIN" $RS; expect 0 "teams.sessions.Advisor is deprecated — read as Fable" "(5) legacy"
line "Fable: started" "$WORK/out" "(5) legacy Fable"; noline "Astra" "$WORK/out" "(5) legacy Astra"
run "$MAIN" $RS stop all; expect 0 "" "(5) stop"
prof '.teams.sessions.Monitor = {model: "opus", effort: "low", settings: "Supervisor",
  contract: "docs/roles/monitor.md", place: {tab: "Ops", slot: "main"}}'
clr; run "$MAIN" $RS up Monitor; expect 0 "Monitor: started" "(5) project role"
line "-e TEAM_SESSION_ROLE=Monitor" "$STUB_LOG" "(5) Monitor env"
line "--settings .agents/team/watch/profiles/Monitor.settings.json" "$STUB_LOG" "(5) Monitor profile"
[ "$(jq -r .env.TEAM_SESSION_ROLE "$MP/.agents/team/watch/profiles/Monitor.settings.json")" = Monitor ] \
  || fail "(5) the Monitor profile carries another role"
! grep -q Monitor "$SRC/.claude/lib/roles.sh" "$SRC/.claude/lib/roles-lib.sh" || fail "(5) the code names Monitor"
run "$MAIN" $RS stop Monitor; expect 0 "Monitor: stopped" "(5) stop Monitor"
cp "$WORK/prof.bak" "$P"
echo "team-smoke-roles: (5) legacy key, project role OK"

# ---- (5b) a Codex role's model: pinned → -m; none → floating; the rule never reaches a Claude role --
astra() {  # astra <label> <jq> — up Astra alone, its tmux line into $WORK/astra, stopped again
  prof "$2"; clr; run "$MAIN" $RS up Astra; expect 0 "Astra: started" "(5b) $1"
  grep '^tmux new-session.* -s smk-astra ' "$STUB_LOG" > "$WORK/astra" || true
}
astra "pinned" '.teams.sessions.Astra.model = "gpt-6-astra"'
line "Astra: started — model: gpt-6-astra · effort high" "$WORK/out" "(5b) pinned line"
line "codex --no-daemon -m gpt-6-astra -c model_reasoning_effort=high 'You are Astra." "$WORK/astra" "(5b) pinned argv"
run "$MAIN" $RS stop Astra; expect 0 "Astra: stopped" "(5b) stop pinned"
astra "no model" 'del(.teams.sessions.Astra.model)'
line "Astra: started — model: CLI default · effort high" "$WORK/out" "(5b) no-model line"
line "codex --no-daemon -c model_reasoning_effort=high 'You are Astra." "$WORK/astra" "(5b) no-model argv"
noline " -m " "$WORK/astra" "(5b) no-model -m"
run "$MAIN" $RS stop Astra; expect 0 "Astra: stopped" "(5b) stop no model"
astra "claude Astra" '.teams.sessions.Astra = {cli: "claude", effort: "high",
  contract: ".agents/reference/roles/advisor.md", place: {tab: "Supervisor", slot: "side"}}'
line " --model opus --effort high" "$WORK/astra" "(5b) claude Astra keeps the generic model"
noline "model: CLI default" "$WORK/out" "(5b) claude Astra model line"
run "$MAIN" $RS stop Astra; expect 0 "Astra: stopped" "(5b) stop claude Astra"
cp "$WORK/prof.bak" "$P"
echo "team-smoke-roles: (5b) codex model, floating and pinned OK"

# ---- (6) the window line; the trust dialog -----------------------------------------------------------
printf 'Do you trust the files in this folder?\n' > "$WORK/trust.txt"
clr; STUB_PANE="$WORK/trust.txt" TMUX=/tmp/fake,1,0 STUB_SELF=smk-other run "$MAIN" $RS up Fable
expect 0 "Fable: started (needs trust — pick Yes; Enter alone exits)" "(6) trust"; line "This window is not a role — close it." "$WORK/out" "(6) window"
noline "send-keys" "$STUB_LOG" "(6) the trust dialog was answered"
TMUX=/tmp/fake,1,0 STUB_SELF=smk-fable run "$MAIN" $RS up Fable; expect 0 "Fable: already running" "(6) role window"
noline "This window is not a role" "$WORK/out" "(6) a role's own window"
run "$MAIN" $RS stop Fable; expect 0 "" "(6) stop"
clr; STUB_PANE="$WORK/trust.txt" run "$MAIN" $RS up Astra
expect 0 "Astra: started (needs trust — pick Yes; Enter alone exits) — model: CLI default · effort high" "(6) codex trust"
run "$MAIN" $RS stop Astra; expect 0 "Astra: stopped" "(6) stop Astra"
echo "team-smoke-roles: (6) window line, trust OK"

# ---- (7) roles.lock: a live holder refuses, a killed one is reclaimed -----------------------------
sleep 30 & H=$!; SPID=$H
mkdir -p "$REG/roles.lock"; ps -o lstart= -p "$H" | sed 's/^ *//; s/ *$//' > "$REG/roles.lock/started"
echo "$H" > "$REG/roles.lock/pid"
clr; run "$MAIN" $RS up Fable; expect 1 "another /roles is running (pid $H)" "(7) busy"
[ "$(starts)" = 0 ] || fail "(7) a busy lock still started something"
clr; run "$MAIN" $RS stop Fable; expect 1 "another /roles is running (pid $H)" "(7) stop waits for roles.lock"
noline "kill-session" "$STUB_LOG" "(7) stop waits for roles.lock"
clr; TMUX=/tmp/fake,1,0 STUB_SELF=smk-other run "$MAIN" $RS here Fable
expect 1 "another /roles is running (pid $H)" "(7) here waits for roles.lock"
noline "claude --name" "$STUB_LOG" "(7) here waits for roles.lock"
kill -9 "$H"; wait "$H" 2>/dev/null || true; SPID=""
run "$MAIN" $RS up Fable; expect 0 "Fable: started" "(7) reclaimed"
[ ! -d "$REG/roles.lock" ] || fail "(7) the lock was left behind"
run "$MAIN" $RS stop all; expect 0 "" "(7) stop"
echo "team-smoke-roles: (7) roles.lock OK"

# ---- (8) here: refused inside Claude and while alive; three backends --------------------------------
CLAUDECODE=1 run "$MAIN" $RS here Supervisor
expect 1 "open a new terminal and run: bash .claude/lib/roles.sh here Supervisor" "(8) inside Claude"
run "$MAIN" $RS up Supervisor; expect 0 "" "(8) start"
run "$MAIN" $RS here Supervisor; expect 1 "Supervisor is already running" "(8) alive"
run "$MAIN" $RS stop Supervisor; expect 0 "" "(8) stop"
# a plain terminal: the record holds this shell's pid; exec keeps it
clr; ( cd "$MAIN" && STUB_CLI_STAY=1 exec $RS here Supervisor ) > "$WORK/here.out" 2>&1 & HP=$!; SPID=$HP
disown "$HP"
for _ in $(seq 1 50); do grep -q '^claude ' "$STUB_LOG" 2>/dev/null && break; sleep 0.1; done
line "claude --name Supervisor --session-id " "$STUB_LOG" "(8) none: exec"
line "--settings .agents/team/watch/profiles/Supervisor.settings.json -- You are Supervisor." "$STUB_LOG" "(8) none: argv"
line "role=Supervisor addr=Supervisor be=none cc=unset" "$STUB_LOG" "(8) none: env"
[ "$(jq -r '.backend + " " + (.pid | tostring)' "$REG/Supervisor.json")" = "none $HP" ] \
  || fail "(8) none: record $(cat "$REG/Supervisor.json")"
run "$MAIN" $RS status; grep -E '^Supervisor +none +alive ' "$WORK/out" >/dev/null || fail "(8) none: status"
clr; run "$MAIN" $RS up; expect 0 "Supervisor: already running" "(8) none: up"
grep -q -- '-s smk-supervisor ' "$STUB_LOG" && fail "(8) none: up started a second Supervisor"
run "$MAIN" bash "$SRC/.claude/lib/session-host.sh" hint Supervisor; expect 0 "a plain terminal (tty " "(8) none: hint"
grep -q 'not a tty' "$WORK/out" && fail "(8) none: the hint carries tty's error text"
run "$MAIN" $RS stop Supervisor; expect 0 "Supervisor: stopped" "(8) none: stop"
for _ in $(seq 1 30); do kill -0 "$HP" 2>/dev/null || break; sleep 0.1; done; SPID=""
! kill -0 "$HP" 2>/dev/null || fail "(8) none: the CLI survived stop"
run "$MAIN" $RS stop all; expect 0 "" "(8) stop all"
# tmux: the record names this tmux session; its pid (exec keeps it) is the role's identity
echo claude > "$D/smk-mine"
clr; ( cd "$MAIN" && TMUX=/tmp/fake,1,0 STUB_SELF=smk-mine STUB_CLI_STAY=1 exec $RS here Supervisor ) \
  > "$WORK/here-t.out" 2>&1 & HP=$!; SPID=$HP
disown "$HP"
for _ in $(seq 1 50); do grep -q '^claude ' "$STUB_LOG" 2>/dev/null && break; sleep 0.1; done
line "claude --name Supervisor --session-id " "$STUB_LOG" "(8) tmux: here"
line "be=tmux" "$STUB_LOG" "(8) tmux: env"
[ "$(jq -r '.backend + " " + .name' "$REG/Supervisor.json")" = "tmux smk-mine" ] || fail "(8) tmux: record"
run "$MAIN" $RS status; grep -E '^Supervisor +tmux +alive ' "$WORK/out" >/dev/null || fail "(8) tmux: status"
clr; run "$MAIN" $RS up Supervisor; expect 0 "Supervisor: already running" "(8) tmux: up"
run "$MAIN" $RS stop Supervisor; expect 0 "Supervisor: stopped" "(8) tmux: stop"
[ ! -f "$D/smk-mine" ] || fail "(8) tmux: the session survived stop"
kill "$HP" 2>/dev/null || true; SPID=""   # the stub's kill-session only removes the file
# Herdr (step 6): the record's handle is driven through the fake hc like any session
clr; HC_TERMINAL_ID=t9 run "$MAIN" $RS here Supervisor; expect 0 "" "(8) herdr: here"
[ "$(jq -r '.backend + " " + .handle' "$REG/Supervisor.json")" = "herdr t9" ] || fail "(8) herdr: record"
STUB_HC_ADDR=t9 run "$MAIN" $RS status; grep -E '^Supervisor +herdr +alive +idle ' "$WORK/out" >/dev/null || fail "(8) herdr: status"
clr; STUB_HC_ADDR=t9 run "$MAIN" $RS up Supervisor; expect 0 "Supervisor: already running" "(8) herdr: up"
[ "$(starts)" = 0 ] || fail "(8) herdr: up started a session"
rm -f "$WORK/hc-gone"; clr; STUB_HC_ADDR=t9 STUB_HC_GONE_FILE="$WORK/hc-gone" run "$MAIN" $RS stop Supervisor
expect 0 "Supervisor: stopped" "(8) herdr: stop"; line "hc send t9 /exit" "$STUB_LOG" "(8) herdr: /exit"
line "hc rm t9" "$STUB_LOG" "(8) herdr: rm"
rm -f "$REG/Supervisor.json" "$WORK/hc-gone"
# No UUID generator (no uuidgen, Python refusing uuid4): a claude role is never started with an
# empty --session-id, and here leaves the record as it was.
run "$MAIN" $RS up Supervisor; expect 0 "" "(u) start"; run "$MAIN" $RS stop Supervisor; expect 0 "" "(u) stop"
cp "$REG/Supervisor.json" "$WORK/sup-u.bak"
PY3="$(command -v python3)"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/uuidgen"
printf '#!/bin/sh\ncase "$*" in *uuid.uuid4*) exit 1 ;; esac\nexec "%s" "$@"\n' "$PY3" > "$WORK/bin/python3"
chmod +x "$WORK/bin/uuidgen" "$WORK/bin/python3"
clr; run "$MAIN" $RS up Fable
[ "$RC" != 0 ] || fail "(u) no UUID generator: no start, no record: exit 0"
line "Fable: failed: no session id" "$WORK/out" "(u) no UUID generator: no start, no record"
noline "-s smk-fable" "$STUB_LOG" "(u) no UUID generator: no start, no record"
! jq -e 'select(.session_id == "")' "$REG"/*.json >/dev/null 2>&1 \
  || fail "(u) no UUID generator: no start, no record: an empty session_id"
clr; run "$MAIN" $RS here Supervisor
[ "$RC" != 0 ] || fail "(u) here without a UUID generator keeps the record: exit 0"
noline "claude --name" "$STUB_LOG" "(u) here without a UUID generator keeps the record"
cmp -s "$REG/Supervisor.json" "$WORK/sup-u.bak" || fail "(u) here without a UUID generator keeps the record: record changed"
rm -f "$WORK/bin/uuidgen" "$WORK/bin/python3" "$REG/Supervisor.json"
echo "team-smoke-roles: (8) here on herdr / tmux / a plain terminal OK"

# ---- (9) SessionStart: the contract line on every source, session.json on the live id -------------
hook() {  # hook <sid> <source> [env…]
  local sid="$1" src="$2"; shift 2
  printf '{"session_id":"%s","source":"%s"}' "$sid" "$src" \
    | (cd "$MAIN" && env CLAUDE_PROJECT_DIR="$MP" "$@" bash "$HOOKR") > "$WORK/out" 2>&1
}
jq -n '{address: "Supervisor", kind: "role", backend: "tmux", name: "smk-supervisor"}' > "$REG/Supervisor.json"
n=0
for src in startup clear compact; do
  n=$((n + 1)); hook "aaaaaaaa-000$n" "$src" TEAM_SESSION_ROLE=Supervisor HARNESS_ADDRESS=Supervisor HARNESS_REGISTRY="$REG"
  line "Session role: Supervisor. Contract: .agents/reference/roles/supervisor.md. Reconcile from files now: inbox .agents/team/inbox/Supervisor/new," "$WORK/out" "(9) $src"
  [ "$(jq -r .session_id "$MP/.agents/team/watch/sessions/Supervisor/session.json")" = "aaaaaaaa-000$n" ] \
    || fail "(9) $src: session.json not on the live id"
  [ "$(jq -r .session_id "$REG/Supervisor.json")" = "aaaaaaaa-000$n" ] || fail "(9) $src: record not on the live id"
done
# The batch gate's due lines follow the Supervisor's contract line — the Supervisor's only. The
# fixture suite only has to exist (`due` validates the command, never runs it).
cp "$P" "$WORK/prof.9"
mkdir -p "$MAIN/.claude/lib/tests"
printf '#!/usr/bin/env bash\ntouch "%s/suite-ran"; exit 1\n' "$WORK" > "$MAIN/.claude/lib/tests/team-suite.sh"
jq --arg l "$(git -C "$MAIN" symbolic-ref --short HEAD)" '.teams.batch_gate = {line: $l, gates: {here: {repo: "."}}}' \
  "$WORK/prof.9" > "$P"
hook aaaaaaaa-0009 startup TEAM_SESSION_ROLE=Supervisor HARNESS_ADDRESS=Supervisor HARNESS_REGISTRY="$REG"
case "$(sed -n 1p "$WORK/out")" in "Session role: Supervisor. Contract:"*) ;; *) fail "(9) due: the contract line is not first" ;; esac
case "$(sed -n 2p "$WORK/out")" in "batch due (here):"*) ;; *) fail "(9) due: no batch due (here): line second" ;; esac
hook bbbbbbbb-0009 startup TEAM_SESSION_ROLE=Astra HARNESS_ADDRESS=Astra HARNESS_REGISTRY="$REG"
noline "batch" "$WORK/out" "(9) due: Astra got a batch line"
cp "$WORK/prof.9" "$P"
hook aaaaaaaa-0010 startup TEAM_SESSION_ROLE=Supervisor HARNESS_ADDRESS=Supervisor HARNESS_REGISTRY="$REG"
[ "$(wc -l < "$WORK/out" | tr -d ' ')" = 1 ] || fail "(9) due: without a block the Supervisor got more than its line"
[ ! -e "$WORK/suite-ran" ] || fail "(9) due: the hook ran the suite"
hook bbbbbbbb-0001 startup TEAM_SESSION_ROLE=Astra HARNESS_ADDRESS=Astra HARNESS_REGISTRY="$REG"
line "Contract: .agents/reference/roles/advisor.md." "$WORK/out" "(9) Astra without a record"
hook cccccccc-0001 startup TEAM_SESSION_ROLE=Ghost
[ ! -s "$WORK/out" ] || fail "(9) an undeclared role printed: $(cat "$WORK/out")"
hook cccccccc-0002 startup TEAM_SESSION_ROLE=TeamLead
noline "Session role" "$WORK/out" "(9) TeamLead (standing false) got a contract"
# a here claim (backend none) runs the same branch
jq -n --arg p "$$" '{address: "Fable", kind: "role", backend: "none", pid: ($p | tonumber)}' > "$REG/Fable.json"
hook dddddddd-0001 resume TEAM_SESSION_ROLE=Fable HARNESS_ADDRESS=Fable HARNESS_REGISTRY="$REG"
line "Session role: Fable. Contract: .agents/reference/roles/advisor.md." "$WORK/out" "(9) here claim"
echo "team-smoke-roles: (9) contract line OK"

# ---- (10) runs: interrupted team runs from anchors + clone files, read-only --------------------------
mkdir -p "$MP/.agents/team/anchors"
T0=0
mkteam() {  # mkteam <team> <run> [mode] → CL (the clone's .agents/team)
  local c="$WORK/cl-$1"; mkdir -p "$c/.agents/team/runs/$2"
  jq -n --arg t "$1" --arg m "${3:-brainstorm}" '{team: $t, mode: $m}' > "$c/.agents/team/team.json"
  printf '%s\n' "$2" > "$c/.agents/team/run"
  jq -n --arg t "$1" --arg c "$(cd "$c" && pwd -P)" '{team: $t, clone: $c}' > "$MP/.agents/team/anchors/$1.json"
  CL="$c/.agents/team"
}
rec() {  # rec <dir> <role> <attempt> <verdict> [accepted] — each newer than the last
  T0=$((T0 + 1)); local f="$1/$2-$3-2026111510$(printf '%04d' "$T0").json"
  mkdir -p "$1"; jq -n --arg r "$2" --arg v "$4" '{role: $r, verdict: $v}' > "$f"
  touch -t "2026111510$(printf '%02d' $((T0 / 60))).$(printf '%02d' $((T0 % 60)))" "$f"
  [ -z "${5:-}" ] || touch "$f.accepted"
}
mkteam alfa alfa-20261115-100000; echo '{"role": "planner", "attempt": 1}' > "$CL/session.json"
mkteam beta beta-20261115-090000; rec "$CL/runs/beta-20261115-090000" planner 1 done y
  rec "$CL/runs/beta-20261115-090000" wrapup 1 done y
mkteam gamma gamma-20261115-080000; echo '{}' > "$CL/runs/gamma-20261115-080000/closed.json"
mkteam delta delta-20261115-070000; mkdir -p "$CL/lock"; echo $$ > "$CL/lock/pid"
mkteam epsi epsi-20261115-060000; mkdir -p "$CL/lock"; echo 99999 > "$CL/lock/pid"
  rec "$CL/runs/epsi-20261115-060000" planner 1 done y; rec "$CL/runs/epsi-20261115-060000" coder 1 blocked
jq -n --arg c "$WORK/cl-zeta-gone" '{team: "zeta", clone: $c}' > "$MP/.agents/team/anchors/zeta.json"
mkteam eta eta-x; printf 'eta/../x\n' > "$CL/run"
mkteam theta theta-20261115-050000; jq -n '{run: "theta-20261115-050000", round: 2}' > "$CL/round"
  rec "$CL/runs/theta-20261115-050000/r2" wrapup 1 done y
mkteam iota iota-20261115-040000; jq -n '{run: "iota-20261115-040000", round: 2}' > "$CL/round"
  rec "$CL/runs/iota-20261115-040000" wrapup 1 done y; rec "$CL/runs/iota-20261115-040000/r2" coder 1 failed
mkteam kappa kappa-20261115-030000 cli
# A wrapup's proposals stop under a TeamLead (#104) waits for the lead, not for the Operator.
mkteam lam lam-20261115-035000; rec "$CL/runs/lam-20261115-035000" wrapup 1 blocked
  f="$(ls "$CL/runs/lam-20261115-035000"/wrapup-1-*.json)"
  jq '.proposals = "x/wrapup_proposals-1_1.json"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
# Mode lead (#296): no stage yet — the TeamLead was choosing; a verdict the runner has not applied
# yet changes nothing.
mkteam lamb lamb-20261115-110000 lead
mkteam mu mu-20261115-120000 lead; echo '{"gate": "mode", "verdict": "quick"}' > "$CL/runs/mu-20261115-120000/teamlead-mode-1.json"
clr; run "$MAIN" $RS runs; expect 0 "" "(10) runs"
for l in "interrupted run alfa (alfa-20261115-100000, stage planner) — resume: /start-team alfa" \
  "interrupted run epsi (epsi-20261115-060000, stage coder, blocked) — resume: /start-team epsi" \
  "interrupted run iota (iota-20261115-040000, stage coder, failed) — resume: /start-team iota" \
  "interrupted run kappa (kappa-20261115-030000, stage cli) — resume: /start-team kappa" \
  "interrupted run lam (lam-20261115-035000, stage wrapup, proposals) — resume: /start-team lam" \
  "interrupted run lamb (lamb-20261115-110000, stage mode choice) — resume: /start-team lamb" \
  "interrupted run mu (mu-20261115-120000, stage mode choice) — resume: /start-team mu" \
  "zeta: clone missing ($WORK/cl-zeta-gone)"; do line "$l" "$WORK/out" "(10) runs"; done
for t in beta gamma delta eta theta; do noline "run $t " "$WORK/out" "(10) $t listed"; done
[ "$(grep '^interrupted run' "$WORK/out" | head -n 1 | cut -d' ' -f3)" = kappa ] || fail "(10) not oldest first"
[ ! -s "$STUB_LOG" ] || fail "(10) runs called the host: $(cat "$STUB_LOG")"
[ -d "$WORK/cl-epsi/.agents/team/lock" ] || fail "(10) runs removed a stale lock"
run "$MAIN" $RS runs --json; expect 0 "" "(10) --json"
jq -e 'length == 7 and (map(.team) == ["kappa", "lam", "iota", "epsi", "alfa", "lamb", "mu"])
  and (.[1].state == "proposals") and (.[3] | .state == "blocked" and .stage == "coder" and .resume == "/start-team epsi" and (.clone | length) > 0 and .run == "epsi-20261115-060000")' \
  "$WORK/out" >/dev/null || fail "(10) --json shape: $(cat "$WORK/out")"
rm -f "$MP"/.agents/team/anchors/*.json
run "$MAIN" $RS runs; expect 0 "interrupted runs: none" "(10) none"
echo "team-smoke-roles: (10) runs OK"

# ---- (11) ad-hoc resume lines; status shows both lists ----------------------------------------------
mkdir -p "$WORK/hcd"; export HC_BIN="$WORK/bin/hc"
cat > "$WORK/bin/hc" <<'STUB'
#!/usr/bin/env bash
echo "hc $*" >> "$STUB_LOG"
[ "$1" = get ] && [ -f "$STUB_HC_DIR/$2" ] || exit 1
cat "$STUB_HC_DIR/$2"
STUB
chmod +x "$WORK/bin/hc"; export STUB_HC_DIR="$WORK/hcd"
ad() {  # ad <address> <backend> <handle> <sid|""> [jq extra]
  jq -n --arg a "$1" --arg b "$2" --arg h "$3" --arg s "$4" --arg cwd "$WORK/a b'c" --arg p "$$" \
    "{address: \$a, kind: \"adhoc\", backend: \$b, handle: \$h, name: \$h, tab: null, cwd: \$cwd,
      claude_pid: (\$p | tonumber)} + (if \$s == \"\" then {} else {session_id: \$s} end) ${5:-}" > "$REG/$1.json"
}
ad adhoc-smk-gone tmux smk-gone aaaaaaaa-0001
echo claude > "$D/smk-live"; ad adhoc-smk-live tmux smk-live aaaaaaaa-0002
echo bash > "$D/smk-shell"; ad adhoc-smk-shell tmux smk-shell aaaaaaaa-0003
ad adhoc-smk-nosid tmux smk-nosid ""
ad adhoc-smk-ended tmux smk-ended aaaaaaaa-0004 '+ {ended_at: "2026-11-15T10:00:00Z", end_reason: "prompt_input_exit"}'
ad adhoc-t1 herdr t1 aaaaaaaa-0005 '+ {tab: "Work"}'
echo '{"foreground": {"argv": ["/opt/bin/claude", "--x"]}}' > "$WORK/hcd/t2"; ad adhoc-t2 herdr t2 aaaaaaaa-0006
echo '{"foreground": {"argv": ["zsh"]}}' > "$WORK/hcd/t3"; ad adhoc-t3 herdr t3 aaaaaaaa-0007
clr; run "$MAIN" $RS status; expect 0 "ad-hoc sessions (gone):" "(11) status"
line "interrupted runs:" "$WORK/out" "(11) status runs header"
Q="cd '$WORK/a b'\''c' && claude --resume"
for l in "  smk-gone — $Q aaaaaaaa-0001" "  smk-shell — $Q aaaaaaaa-0003" "  Work — $Q aaaaaaaa-0005" \
  "  t3 — $Q aaaaaaaa-0007"; do line "$l" "$WORK/out" "(11) resume line"; done
for x in aaaaaaaa-0002 aaaaaaaa-0004 aaaaaaaa-0006 smk-nosid; do noline "$x" "$WORK/out" "(11) $x"; done
line "hc get t1 --json" "$STUB_LOG" "(11) the Herdr probe"
noline "kill-session" "$STUB_LOG" "(11) a kept terminal was touched"
rm -f "$D/smk-live" "$D/smk-shell" "$REG"/adhoc-*.json
echo "team-smoke-roles: (11) ad-hoc lines OK"

# ---- (12) SessionEnd marks the conversation's own ad-hoc record; the next start clears it -----------
hk() {  # hk <sid> <event|""> [reason]
  printf '{"session_id":"%s","hook_event_name":"%s","reason":"%s"}' "$1" "$2" "${3:-}" \
    | (cd "$MAIN" && env CLAUDE_PROJECT_DIR="$MP" TMUX=/tmp/fake,1,0 TMUX_PANE=%1 STUB_SELF=smk-adh bash "$HOOKR") \
    > "$WORK/out" 2>&1
}
hk bbbbbbbb-0001 SessionStart; [ -f "$REG/adhoc-smk-adh.json" ] || fail "(12) no ad-hoc record"
hk bbbbbbbb-0099 SessionEnd other
[ -z "$(jq -r '.ended_at // empty' "$REG/adhoc-smk-adh.json")" ] || fail "(12) another session id marked the record"
hk bbbbbbbb-0001 SessionEnd prompt_input_exit
[ "$(jq -r '.end_reason' "$REG/adhoc-smk-adh.json")" = prompt_input_exit ] \
  && [ -n "$(jq -r '.ended_at // empty' "$REG/adhoc-smk-adh.json")" ] || fail "(12) SessionEnd did not mark it"
run "$MAIN" $RS status; noline "claude --resume bbbbbbbb-0001" "$WORK/out" "(12) an ended conversation got a resume line"
hk bbbbbbbb-0002 SessionStart
[ -z "$(jq -r '.ended_at // empty' "$REG/adhoc-smk-adh.json")" ] \
  && [ "$(jq -r .session_id "$REG/adhoc-smk-adh.json")" = bbbbbbbb-0002 ] || fail "(12) the next start kept ended_at"
run "$MAIN" $RS status; line "smk-adh — cd '$MP' && claude --resume bbbbbbbb-0002" "$WORK/out" "(12) a crashed one"
rm -f "$REG"/adhoc-*.json
echo "team-smoke-roles: (12) SessionEnd OK"

# ---- (13) resume <Role>; status `stopped` ----------------------------------------------------------
run "$MAIN" $RS up Supervisor; expect 0 "Supervisor: started" "(13) start"
S1="$(jq -r .session_id "$REG/Supervisor.json")"
run "$MAIN" $RS resume Supervisor; expect 1 "Supervisor is running" "(13) alive"
run "$MAIN" $RS stop Supervisor; expect 0 "" "(13) stop"
run "$MAIN" $RS status; grep -E '^Supervisor +tmux +stopped +gone ' "$WORK/out" >/dev/null || fail "(13) stopped row"
clr; run "$MAIN" $RS resume Supervisor; expect 0 "Supervisor: resumed $S1" "(13) resume"
grep '^tmux new-session.* -s smk-supervisor ' "$STUB_LOG" > "$WORK/res"
line "claude --name 'Supervisor' --resume $S1 --model opus --effort high --settings .agents/team/watch/profiles/Supervisor.settings.json; read" "$WORK/res" "(13) argv"
noline "--session-id" "$WORK/res" "(13) a new session id"; noline "You are Supervisor" "$WORK/res" "(13) bootstrap line"
[ "$(jq -r '.session_id // empty' "$REG/Supervisor.json")" = "$S1" ] || fail "(13) the resumed record lost its session id"
run "$MAIN" $RS resume Astra; expect 2 "Codex roles restore fresh" "(13) Codex"
rm -f "$REG/Fable.json"; run "$MAIN" $RS resume Fable; expect 1 "no previous session for Fable" "(13) no record"
run "$MAIN" $RS stop all; expect 0 "" "(13) stop all"
echo "team-smoke-roles: (13) resume, stopped OK"

# ---- (13b) resume rings a role whose inbox holds messages, once; an empty inbox → no ring ------------
IB="$MAIN/.agents/team/inbox/Supervisor/new"; mkdir -p "$IB"; rm -f "$IB"/*; echo a > "$IB/m1.md"; echo b > "$IB/m2.md"
RING="inbox: 2 waiting — reconcile .agents/team/inbox/Supervisor/new"
clr; run "$MAIN" $RS resume Supervisor; expect 0 "Supervisor: resumed $S1" "(13b) resume"
grep -q "^Supervisor: resumed $S1.*, inbox 2 \(rung\|waiting — ring [0-9]*\)$" "$WORK/out" || fail "(13b) the ring word"
n="$( { grep -F -- "$RING" "$STUB_LOG"; grep -F -- "$RING" "$REG/send-Supervisor.log" 2>/dev/null; } | wc -l | tr -d ' ')"
[ "$n" = 1 ] || { cp "$STUB_LOG" "$WORK/out"; fail "(13b) $n doorbells with the inbox line, want 1"; }
noline "You are Supervisor" "$STUB_LOG" "(13b) bootstrap line"
run "$MAIN" $RS stop Supervisor; expect 0 "" "(13b) stop"
rm -f "$IB"/* "$REG/send-Supervisor.log"
clr; run "$MAIN" $RS resume Supervisor; expect 0 "Supervisor: resumed $S1" "(13b) empty inbox"
! has "inbox" "$WORK/out" || fail "(13b) an empty inbox printed a ring"
! grep -q "reconcile .agents/team/inbox" "$STUB_LOG" || fail "(13b) an empty inbox was rung"
run "$MAIN" $RS stop all; expect 0 "" "(13b) stop all"
echo "team-smoke-roles: (13b) resume rings a waiting inbox OK"

# ---- (13c) Codex home from .claude/codex-profile: Codex and Claude roles; none; unresolvable --------
CP="$MAIN/.claude/codex-profile"; cp "$CP" "$WORK/codex-profile.bak"
CH="$(cd "$HOME/.codex-acmeshop" && pwd -P)"
# the fixture's value line
clr; run "$MAIN" $RS up Astra; expect 0 "Astra: started" "(13c) value: up Astra"
nsline astra; line "-e CODEX_HOME=$CH " "$WORK/ns-astra" "(13c) value: up Astra"
clr; run "$MAIN" $RS up Fable; expect 0 "Fable: started" "(13c) value: up Fable"
nsline fable; line "-e CODEX_HOME=$CH " "$WORK/ns-fable" "(13c) value: up Fable"
run "$MAIN" $RS stop all; expect 0 "" "(13c) value: stop all"
clr; run "$MAIN" $RS resume Supervisor; expect 0 "Supervisor: resumed $S1" "(13c) value: resume Supervisor"
nsline supervisor; line "-e CODEX_HOME=$CH " "$WORK/ns-supervisor" "(13c) value: resume Supervisor"
run "$MAIN" $RS stop all; expect 0 "" "(13c) value: stop after resume"
clr; run "$MAIN" $RS here Astra; expect 0 "" "(13c) value: here Astra"
grep -q "^codex .* ch=$CH\$" "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(13c) value: here Astra: no ch=$CH"; }
# no value line
printf '# template — no value\n' > "$CP"
LCH="$WORK/launcher-ch"; mkdir -p "$LCH"
clr; run "$MAIN" env CODEX_HOME="$LCH" $RS up Astra; expect 0 "Astra: started" "(13c) none: up Astra"
nsline astra; noline "CODEX_HOME=" "$WORK/ns-astra" "(13c) none: up Astra"
clr; run "$MAIN" env CODEX_HOME="$LCH" $RS up Fable; expect 0 "Fable: started" "(13c) none: up Fable"
nsline fable; line "-e CODEX_HOME=$LCH " "$WORK/ns-fable" "(13c) none: up Fable keeps the launcher's"
run "$MAIN" $RS stop all; expect 0 "" "(13c) none: stop all"
clr; run "$MAIN" $RS here Astra; expect 0 "" "(13c) none: here Astra"
grep -q '^codex .* ch=unset$' "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(13c) none: here Astra: no ch=unset"; }
# a value that does not resolve
printf '~/.codex-missing\n' > "$CP"
NORES="Codex profile $HOME/.codex-missing from .claude/codex-profile does not resolve — no session launched"
clr; run "$MAIN" $RS up Astra; expect 1 "$NORES" "(13c) unresolvable: up Astra"
[ "$(starts)" = 0 ] || fail "(13c) unresolvable: up Astra started $(starts) sessions"
cp "$REG/Astra.json" "$WORK/astra-rec.bak"
clr; run "$MAIN" $RS here Astra; expect 1 "$NORES" "(13c) unresolvable: here Astra"
! grep -q '^codex ' "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(13c) unresolvable: here Astra ran codex"; }
cmp -s "$REG/Astra.json" "$WORK/astra-rec.bak" || fail "(13c) unresolvable: here Astra changed the record"
cp "$WORK/codex-profile.bak" "$CP"
echo "team-smoke-roles: (13c) Codex home from .claude/codex-profile OK"

# ---- (14) restart simulation: roles, one interrupted run, two ad-hoc sessions, nothing resumed ------
run "$MAIN" $RS; expect 0 "" "(14) roles up"
mkteam alfa alfa-20261115-100000; echo '{"role": "coder", "attempt": 1}' > "$CL/session.json"
ad adhoc-smk-a tmux smk-a cccccccc-0001; ad adhoc-smk-b tmux smk-b cccccccc-0002
echo claude > "$D/smk-a"; echo claude > "$D/smk-b"
rm -f "$D"/*   # the machine restarted: every session is gone
clr; run "$MAIN" $RS; expect 0 "interrupted run alfa (alfa-20261115-100000, stage coder) — resume: /start-team alfa" "(14) up"
for r in Supervisor Fable Astra; do line "$r: started" "$WORK/out" "(14) $r"; done
[ "$(grep -c '^interrupted run ' "$WORK/out")" = 1 ] || fail "(14) interrupted-run lines"
[ "$(grep -c ' && claude --resume cccccccc-000' "$WORK/out")" = 2 ] || fail "(14) ad-hoc lines"
noline "team-run.sh" "$STUB_LOG" "(14) a runner was started"; noline "start-team" "$STUB_LOG" "(14) /start-team ran"
[ "$(starts)" = 3 ] || fail "(14) $(starts) sessions started, expected 3"
echo "team-smoke-roles: (14) restart simulation OK"

# ---- (15) Linux tmux: bash leads the pane, claude runs in its group (#266) --------------------------
# A process named claude in a known group: a symlink to bash (a multi-call coreutils refuses a renamed
# sleep). Gone expectations never use this group — the suite shares process groups — only 99999999.
mkdir -p "$WORK/pgt"; ln -sf "$(command -v bash)" "$WORK/pgt/claude"
"$WORK/pgt/claude" -c 'sleep 60; :' & PGT=$!; SPID=$PGT
PGTG="$(ps -o pgid= -p "$PGT" | tr -d ' ')"
sjq() { jq -r ".${2} // empty" "$REG/$1.json"; }
run "$MAIN" $RS stop all; expect 0 "" "(15) clean slate"; rm -f "$D"/smk-*
clr; run "$MAIN" $RS up; expect 0 "Supervisor: started" "(15) start"
for r in Fable Astra; do line "$r: started" "$WORK/out" "(15) start"; done
echo "$PGTG bash" > "$D/smk-supervisor"; echo "$PGTG bash" > "$D/smk-fable"
clr; run "$MAIN" $RS up; expect 0 "Supervisor: already running" "(15) up leaves live roles alone"
line "Fable: already running" "$WORK/out" "(15) up leaves live roles alone"
[ "$(starts)" = 0 ] || fail "(15) up leaves live roles alone: $(starts) sessions started"
noline "kill-session" "$STUB_LOG" "(15) up leaves live roles alone"
run "$MAIN" $RS status; expect 0 "" "(15) status"
grep -E '^Supervisor +tmux +alive ' "$WORK/out" >/dev/null && grep -E '^Fable +tmux +alive ' "$WORK/out" >/dev/null \
  || fail "(15) status"
printf '99999999 bash\n%s bash\n' "$PGTG" > "$D/smk-fable"
clr; run "$MAIN" $RS up Fable; expect 0 "Fable: already running" "(15) a split pane, a shell selected"
[ "$(starts)" = 0 ] || fail "(15) a split pane, a shell selected: a session started"
STUB_LIST_PANES_RC=1 run "$MAIN" $RS stop Fable; expect 1 "Fable: failed: liveness probe (exit 1)" "(15) stop on an unclassifiable pane"
[ -f "$D/smk-fable" ] || fail "(15) stop on an unclassifiable pane: the session was closed"
clr; STUB_LIST_PANES_RC=1 run "$MAIN" $RS up Fable; expect 1 "Fable: failed: liveness probe" "(15) up on an unclassifiable pane"
[ "$(starts)" = 0 ] || fail "(15) up on an unclassifiable pane: a session started"
noline "kill-session" "$STUB_LOG" "(15) up on an unclassifiable pane"
# Stop all from the Supervisor's own session: the others first, itself last and not gracefully.
clr; HARNESS_ADDRESS=Supervisor run "$MAIN" $RS stop all; expect 0 "Supervisor: stopped" "(15) the caller's own role goes last"
for r in Fable Astra; do line "$r: stopped" "$WORK/out" "(15) the caller's own role goes last"; done
ks="$(grep -n 'kill-session -t =smk-supervisor' "$STUB_LOG" | head -n 1 | cut -d: -f1)"
kf="$(grep -n 'kill-session -t =smk-fable' "$STUB_LOG" | head -n 1 | cut -d: -f1)"
ka="$(grep -n 'kill-session -t =smk-astra' "$STUB_LOG" | head -n 1 | cut -d: -f1)"
[ -n "$ks" ] && [ -n "$kf" ] && [ -n "$ka" ] && [ "$ks" -gt "$kf" ] && [ "$ks" -gt "$ka" ] \
  || { cp "$STUB_LOG" "$WORK/out"; fail "(15) the caller's own role goes last: kill order"; }
noline "send-keys -t =smk-supervisor:" "$STUB_LOG" "(15) the caller's own role goes last"
[ ! -e "$REG/Supervisor.lock" ] && [ ! -e "$REG/roles.lock" ] || fail "(15) the caller's own role goes last: a lock left behind"
[ -n "$(sjq Supervisor stopped_at)" ] || fail "(15) the caller's own role goes last: no stopped_at"
# A self-stop whose session survives: reported, stopped_at put back.
run "$MAIN" $RS up Supervisor; expect 0 "Supervisor: started" "(15) restart Supervisor"
echo "$PGTG bash" > "$D/smk-supervisor"; old="$(sjq Supervisor stopped_at)"
clr; STUB_KILL_KEEP=1 HARNESS_ADDRESS=Supervisor run "$MAIN" $RS stop Supervisor
expect 1 "Supervisor: still running" "(15) a refused self-stop is reported"
[ "$(sjq Supervisor stopped_at)" = "$old" ] || fail "(15) a refused self-stop is reported: stopped_at changed"
run "$MAIN" $RS stop Supervisor; expect 0 "Supervisor: stopped" "(15) clean up"
# The program exited, its `; read` shell waits: the driver-launched session is closed.
run "$MAIN" $RS up Fable; expect 0 "Fable: started" "(15) restart Fable"; echo bash > "$D/smk-fable"
clr; run "$MAIN" $RS stop Fable; expect 0 "Fable: not running (closed its leftover shell)" "(15) stop closes a leftover shell"
[ ! -f "$D/smk-fable" ] || fail "(15) stop closes a leftover shell: the session stayed"
[ -n "$(sjq Fable stopped_at)" ] || fail "(15) stop closes a leftover shell: no stopped_at"
run "$MAIN" $RS up Fable; expect 0 "Fable: started" "(15) restart Fable"; printf 'bash\nvim\n' > "$D/smk-fable"
clr; run "$MAIN" $RS stop Fable
expect 0 "Fable: not running (session smk-fable has other panes — left open)" "(15) a leftover with another pane stays open"
[ -f "$D/smk-fable" ] || fail "(15) a leftover with another pane stays open: closed"
noline "kill-session" "$STUB_LOG" "(15) a leftover with another pane stays open"
rm -f "$D/smk-fable"
# An earlier failure of the batch: the caller does not stop itself (its exit status would be lost).
run "$MAIN" $RS up; expect 0 "" "(15) all up"
echo "$PGTG bash" > "$D/smk-supervisor"; echo "x bash" > "$D/smk-fable"
clr; HARNESS_ADDRESS=Supervisor run "$MAIN" $RS stop all; expect 1 "Fable: failed: liveness probe (exit 1)" "(15) a failed batch does not stop the caller"
line "Supervisor: not stopped — an earlier role failed" "$WORK/out" "(15) a failed batch does not stop the caller"
noline "kill-session -t =smk-supervisor" "$STUB_LOG" "(15) a failed batch does not stop the caller"
echo claude > "$D/smk-fable"; run "$MAIN" $RS stop all; expect 0 "" "(15) clean up"
# A `here` terminal whose role ended, another Claude in a sibling pane: the Operator's terminal stays.
echo claude > "$D/smk-mine"
TMUX=/tmp/fake,1,0 STUB_SELF=smk-mine run "$MAIN" $RS here Supervisor; expect 0 "" "(15) here"
printf 'bash\n%s claude\n' "$PGTG" > "$D/smk-mine"
clr; run "$MAIN" $RS stop Supervisor
expect 0 "Supervisor: not running (its terminal smk-mine is not a role wrapper — left open)" "(15) a here terminal stays open"
[ -f "$D/smk-mine" ] || fail "(15) a here terminal stays open: closed"
noline "kill-session" "$STUB_LOG" "(15) a here terminal stays open"
run "$MAIN" $RS status; ! grep -E '^Supervisor +tmux +alive ' "$WORK/out" >/dev/null || fail "(15) a here terminal stays open: status alive"
# here over a session it cannot classify: refused, the record untouched, no CLI.
cp "$REG/Supervisor.json" "$WORK/sup.bak"
clr; STUB_HAS_SESSION_ERR='protocol version mismatch' TMUX=/tmp/fake,1,0 STUB_SELF=smk-mine run "$MAIN" $RS here Supervisor
expect 1 "refused: Supervisor: liveness probe failed" "(15) here refuses an unclassifiable session"
cmp -s "$REG/Supervisor.json" "$WORK/sup.bak" || fail "(15) here refuses an unclassifiable session: record changed"
noline "claude --name" "$STUB_LOG" "(15) here refuses an unclassifiable session"
kill "$PGT" 2>/dev/null || true; wait "$PGT" 2>/dev/null || true; SPID=""
rm -f "$REG/Supervisor.json" "$D"/smk-*
echo "team-smoke-roles: (15) Linux tmux liveness OK"

# ---- (L) the Herdr layout (#35): tab Supervisor and one tab per team over a model window ----------------
# The fake herdr-app keeps a window model in $STUB_HERDR_LS; `hc label … herdr.space=` adopts into it.
cp "$WORK/hc.lib" "$WORK/bin/hc"; chmod +x "$WORK/bin/hc"
export TEAM_SESSION_HOST=herdr   # the smoke lib pins tmux; existing records keep their own backend
export TEAM_LAYOUT_POLL=0 TEAM_LAYOUT_LOCK_WAIT=1 STUB_HERDR_LS="$WORK/herdr-ls.json"
rm -f "$REG"/*.json
hrec() {  # hrec <address> <handle> <cli> [kind] [jq extra]
  jq -n --arg a "$1" --arg h "$2" --arg c "$3" --arg k "${4:-role}" --arg cwd "$MP" \
    '{address: $a, kind: $k, backend: "herdr", handle: $h, name: $h, cwd: $cwd, cli: $c,
      started_at: "2026-11-15T00:00:00Z"} '"${5:-}" > "$REG/$1.json"
}
win() { jq -n --arg f "$MP" "$1" > "$STUB_HERDR_LS"; }   # win '<jq building the window>'
SPACE='{id: "s1", name: "smk", folder: $f, tabs: []}'
seq_of() { { grep -E '^(herdr-app do |hc label )' "$STUB_LOG" || true; } | sed 's/^herdr-app do //' > "$WORK/seq"; }
keep_log() { cat "$STUB_LOG" >> "$WORK/layout-all"; }
hrec Supervisor t1 claude; hrec Fable t2 claude; hrec Astra t3 codex

# The /roles window: a pane of another space, focused before placement.
OTHER='{id: "s0", name: "work", folder: "/elsewhere", tabs: [{id: "tb0", name: "1", terminals: [{terminal: "t9", pane: "pt9"}]}]}'

# (L1) no space for the main checkout: /roles up creates it (the Operator asked) from space.new's
# reply; the new space is shown, so the focus goes back to the /roles window at the end
win '{spaces: ['"$OTHER"'], focus: "t9"}'
clr; run "$MAIN" $RS; expect 0 "created: Herdr space smk for $MP" "(L1) up"; keep_log
line "herdr-app do space.new --name smk --folder $MP" "$STUB_LOG" "(L1) space.new"
line "placed: Supervisor in Supervisor" "$WORK/out" "(L1) placed into the new space"
seq_of; [ "$(tail -n 1 "$WORK/seq")" = "pane.focus --terminal t9" ] || { cp "$WORK/seq" "$WORK/out"; fail "(L1) focus not given back"; }
jq -e '[.spaces[] | select(.id == "s2") | .tabs[] | select(.name == "Supervisor") | .terminals[].terminal] == ["t1", "t2", "t3"]' \
  "$STUB_HERDR_LS" >/dev/null || { cp "$STUB_HERDR_LS" "$WORK/out"; fail "(L1) Supervisor in the new space"; }

# (L2) an empty space: Supervisor adopted (the tab named Supervisor), Fable by label beside it, Astra
# adopted, parked and kept under Fable (terminal.keep knows no unadopted terminal), then the focus
# back to the pane focused before (focused_pane, not status.agent)
win '{spaces: ['"$OTHER"', '"$SPACE"'], focus: "t9"}'
clr; run "$MAIN" $RS; expect 0 "placed: Supervisor in Supervisor" "(L2) up"; keep_log
for r in Fable Astra; do line "placed: $r in Supervisor" "$WORK/out" "(L2) $r"; done
# A placed role needs no hint, and the layout lock is no address (step-7 live fixes).
noline "once placed" "$WORK/out" "(L2) hint for a placed role"; noline "session-host:" "$WORK/out" "(L2) lock noise"
seq_of
printf '%s\n' "hc label t1 herdr.space=s1" "tab.rename --id tbt1 --name Supervisor" "hc label t2 herdr.space=s1 herdr.tab=tbt1" \
  "hc label t3 herdr.space=s1 herdr.tab=tbt1" "terminal.park --terminal t3" "pane.focus --terminal t2" \
  "terminal.keep --terminal t3 --place down" "pane.focus --terminal t9" > "$WORK/seq.want"
cmp -s "$WORK/seq" "$WORK/seq.want" || { diff "$WORK/seq.want" "$WORK/seq" > "$WORK/out" || true; fail "(L2) placement sequence"; }
noline "agent.focus" "$STUB_LOG" "(L2) agent.focus"
jq -e '[.spaces[] | select(.id == "s1") | .tabs[] | select(.name == "Supervisor") | .terminals[].terminal] == ["t1", "t2", "t3"]
  and .focus == "t9"' "$STUB_HERDR_LS" >/dev/null || { cp "$STUB_HERDR_LS" "$WORK/out"; fail "(L2) Supervisor tab or focus"; }
run "$MAIN" $RS status; grep -E '^Supervisor +herdr +alive .* pane: Supervisor$' "$WORK/out" >/dev/null || fail "(L2) status pane column"
# (L2a) a role with no record on a machine without tmux: no backend named, `gone` — never a failed probe
mv "$REG/Astra.json" "$WORK/Astra.keep"
TMUX_BIN=no-such-tmux run "$MAIN" $RS status; grep -E '^Astra +- +gone +gone ' "$WORK/out" >/dev/null || fail "(L2a) a role with no record, no tmux"
mv "$WORK/Astra.keep" "$REG/Astra.json"

# (L2b) the keep after a park fails: the terminal is adopted back by label, never left paneless,
# and the focus still goes back
win '{spaces: ['"$OTHER"', '"$SPACE"'], focus: "t9"}'
clr; STUB_HERDR_KEEP_RC=1 run "$MAIN" $RS
expect 0 "warn: placement Astra: herdr-app do terminal.keep failed (adopted back by label)" "(L2b) keep fails"; keep_log
seq_of; [ "$(tail -n 2 "$WORK/seq" | head -n 1)" = "hc label t3 herdr.space=s1 herdr.tab=tbt1" ] \
  && [ "$(tail -n 1 "$WORK/seq")" = "pane.focus --terminal t9" ] || { cp "$WORK/seq" "$WORK/out"; fail "(L2b) not adopted back, or no focus back"; }
jq -e '[.spaces[].tabs[].terminals[].terminal] | index("t3") != null' "$STUB_HERDR_LS" >/dev/null || fail "(L2b) Astra without a pane"
win '{spaces: ['"$OTHER"', {id: "s1", name: "smk", folder: $f, tabs: [{id: "tbL", name: "Supervisor", terminals:
  [{terminal: "t1", pane: "pt1"}, {terminal: "t2", pane: "pt2"}, {terminal: "t3", pane: "pt3"}]}]}], focus: "t9"}'

# (L3) all placed: a second up issues no placement command (and moves no focus)
clr; run "$MAIN" $RS; expect 0 "Supervisor: already running" "(L3) up"; keep_log
seq_of; [ ! -s "$WORK/seq" ] || { cp "$WORK/seq" "$WORK/out"; fail "(L3) placement commands on a second up"; }
noline "once placed" "$WORK/out" "(L3) hint for a placed role"

# (L4) a team session into its own tab (named after the team) by label only, never a focus; a runner
# never creates the space
hrec alfa-lead t5 claude team; hrec beta-lead t7 claude team; hrec gamma-lead t8 claude team
win '{spaces: [{id: "s1", name: "smk", folder: $f, tabs: [{id: "tbA", name: "alfa", terminals: [{terminal: "t6"}]}]}], focus: "t1"}'
clr; run "$MAIN" $RS place alfa-lead; expect 0 "placed: alfa-lead in alfa" "(L4) into its tab"; keep_log
line "hc label t5 herdr.space=s1 herdr.tab=tbA" "$STUB_LOG" "(L4) label"; noline "session-host:" "$WORK/out" "(L4) lock noise"
noline "tab.rename" "$STUB_LOG" "(L4) renamed"; noline "focus" "$STUB_LOG" "(L4) focus moved"
clr; run "$MAIN" $RS place alfa-lead; expect 0 "already placed: alfa-lead in alfa" "(L4) again"; keep_log
noline "hc label" "$STUB_LOG" "(L4) relabelled"
win '{spaces: ['"$SPACE"'], focus: "t1"}'
clr; run "$MAIN" $RS place alfa-lead; expect 0 "placed: alfa-lead in alfa" "(L4) no team tab yet"; keep_log
line "hc label t5 herdr.space=s1" "$STUB_LOG" "(L4) space label"; line "tab.rename --id tbt5 --name alfa" "$STUB_LOG" "(L4) rename"
win '{spaces: [], focus: "t1"}'
clr; run "$MAIN" $RS place alfa-lead
expect 0 "warn: placement alfa-lead: open the project as a Herdr space (or run /roles)" "(L4) no space"; keep_log
noline "space.new" "$STUB_LOG" "(L4) a runner created a space"; line "  alfa-lead: hc attach t5 · herdr: t5" "$WORK/out" "(L4) hint"
# (L4b) the lead first, then its stage: the lead left, the stage right, in the team's tab
hrec alfa-coder t11 claude team
win '{spaces: ['"$SPACE"'], focus: "t1"}'
clr; run "$MAIN" $RS place alfa-lead; run "$MAIN" $RS place alfa-coder; expect 0 "placed: alfa-coder in alfa" "(L4b) stage"; keep_log
jq -e '[.spaces[0].tabs[] | select(.name == "alfa")] | length == 1 and .[0].terminals[0].terminal == "t5"
  and .[0].terminals[1].terminal == "t11"' "$STUB_HERDR_LS" >/dev/null \
  || { cp "$STUB_HERDR_LS" "$WORK/out"; fail "(L4b) lead left, stage right in one tab"; }
# (L4c) a team named like a roles tab (Supervisor, its old name Lead, any case) is never placed
hrec lead-lead t12 claude team
win '{spaces: [{id: "s1", name: "smk", folder: $f, tabs: [{id: "tbL", name: "Supervisor", terminals: [{terminal: "t1"}]}]}], focus: "t1"}'
clr; run "$MAIN" $RS place lead-lead; expect 0 "warn: placement lead-lead: team lead has the name of a roles tab — not placed" "(L4c) refused"
keep_log; noline "hc label" "$STUB_LOG" "(L4c) labelled into the roles tab"; rm -f "$REG/lead-lead.json"
# (L4d) after a herdr-core restart: the window keeps the team's tab (its old terminal gone); the
# relaunched lead is adopted into that tab, no second tab, no rename
hrec alfa-lead t15 claude team
win '{spaces: [{id: "s1", name: "smk", folder: $f, tabs: [{id: "tbA", name: "alfa", terminals: []}]}], focus: "t1"}'
clr; run "$MAIN" $RS place alfa-lead; expect 0 "placed: alfa-lead in alfa" "(L4d) restored"; keep_log
line "hc label t15 herdr.space=s1 herdr.tab=tbA" "$STUB_LOG" "(L4d) label into the kept tab"; noline "tab.rename" "$STUB_LOG" "(L4d) renamed"
jq -e '[.spaces[0].tabs[] | select(.name == "alfa")] | length == 1' "$STUB_HERDR_LS" >/dev/null || fail "(L4d) a second alfa tab"
hrec alfa-lead t5 claude team

# (L5) the window does not answer: up and place exit 0 with a warning and the hint
clr; STUB_HERDR_RC=1 run "$MAIN" $RS place alfa-lead
expect 0 "warn: placement alfa-lead: Herdr window not open or not answering" "(L5) place"; keep_log
clr; STUB_HERDR_RC=1 run "$MAIN" $RS; expect 0 "warn: placement Supervisor: Herdr window not open" "(L5) up"; keep_log
line "  Supervisor: hc attach t1" "$WORK/out" "(L5) an unplaced role keeps its hint"
STUB_HERDR_RC=1 run "$MAIN" $RS status; grep -E '^Fable .* pane: \?$' "$WORK/out" >/dev/null || fail "(L5) pane: ?"
win '{spaces: ['"$SPACE"'], focus: "t9"}'
clr; STUB_HERDR_DO_RC=1 run "$MAIN" $RS; expect 0 "warn: placement Supervisor: herdr-app do tab.rename failed" "(L5) do fails"; keep_log

# (L6) two teams in the same second: one tab each, none twice (the layout lock, #35 / #77); and a
# team's lead and stage in the same second: one tab for the team
win '{spaces: ['"$SPACE"'], focus: "t1"}'
clr; ( TEAM_LAYOUT_LOCK_WAIT=10 bash -c "cd '$MAIN' && $RS place alfa-lead" > "$WORK/p1" 2>&1 & \
  TEAM_LAYOUT_LOCK_WAIT=10 bash -c "cd '$MAIN' && $RS place beta-lead" > "$WORK/p2" 2>&1 & wait ); keep_log
[ "$(grep -c 'tab.rename .* --name alfa' "$STUB_LOG")" = 1 ] && [ "$(grep -c 'tab.rename .* --name beta' "$STUB_LOG")" = 1 ] \
  || { cp "$STUB_LOG" "$WORK/out"; fail "(L6) a team tab made twice or not at all"; }
jq -e '[.spaces[0].tabs[] | select(.name == "alfa") | .terminals[].terminal] == ["t5"]
  and [.spaces[0].tabs[] | select(.name == "beta") | .terminals[].terminal] == ["t7"]' "$STUB_HERDR_LS" >/dev/null \
  || { cp "$STUB_HERDR_LS" "$WORK/out"; fail "(L6) each lead in its own tab"; }
win '{spaces: ['"$SPACE"'], focus: "t1"}'
clr; ( TEAM_LAYOUT_LOCK_WAIT=10 bash -c "cd '$MAIN' && $RS place alfa-lead" > "$WORK/p1" 2>&1 & \
  TEAM_LAYOUT_LOCK_WAIT=10 bash -c "cd '$MAIN' && $RS place alfa-coder" > "$WORK/p2" 2>&1 & wait ); keep_log
[ "$(grep -c 'tab.rename .* --name alfa' "$STUB_LOG")" = 1 ] \
  && jq -e '[.spaces[0].tabs[] | select(.name == "alfa")] | length == 1 and (.[0].terminals | map(.terminal) | sort == ["t11", "t5"])' \
    "$STUB_HERDR_LS" >/dev/null || { cp "$STUB_HERDR_LS" "$WORK/out"; fail "(L6) one team, two tabs"; }
rm -f "$REG/alfa-coder.json"

# (L9) a project role with its own place.tab gets its own tab
prof '.teams.sessions.Monitor = {cli: "claude", model: "opus", effort: "medium",
  contract: "docs/roles/monitor.md", place: {tab: "Ops", slot: "main"}}'
hrec Monitor t4 claude
win '{spaces: [{id: "s1", name: "smk", folder: $f, tabs: [{id: "tbL", name: "Supervisor",
  terminals: [{terminal: "t1"}, {terminal: "t2"}, {terminal: "t3"}]}]}], focus: "t9"}'
clr; run "$MAIN" $RS; expect 0 "placed: Monitor in Ops" "(L9) up"; keep_log
line "hc label t4 herdr.space=s1" "$STUB_LOG" "(L9) label"; line "tab.rename --id tbt4 --name Ops" "$STUB_LOG" "(L9) rename"
noline "focus" "$STUB_LOG" "(L9) a focus moved or given back with no move"
cp "$WORK/prof.bak" "$P"; rm -f "$REG/Monitor.json"

# (L10) a replaced terminal (another created_ms under the handle) is never placed
hrec gamma-lead t8 claude team '+ {created_ms: "1"}'
win '{spaces: ['"$SPACE"'], focus: "t1"}'
clr; run "$MAIN" $RS place gamma-lead; expect 0 "warn: placement gamma-lead: gamma-lead: no live terminal of ours" "(L10) replaced"; keep_log
noline "hc label" "$STUB_LOG" "(L10) labelled"

# (L11) /roles names a held start: a recognised screen, or no status yet — never a key
printf '%s\n' " 3 new MCP servers found in this project" " ❯ [ ] alpha" > "$WORK/mcp.scr"
printf '%s\n' " Do you want to work in this folder?" " ❯ 1. Yes, I trust this folder" "   2. No, exit" > "$WORK/trust.scr"
: > "$WORK/blank.scr"; rm -f "$D"/*   # no tmux session of (14) left under the name
for c in "mcp.scr|startup dialog open" "trust.scr|needs trust — pick Yes; Enter alone exits" "blank.scr|no status yet"; do
  rm -f "$REG/Supervisor.json"
  clr; STUB_HERDR_RC=1 STUB_HC_NONAME=1 STUB_HC_ADDR=t1 STUB_HC_STATUS=null STUB_HC_SCREEN="$WORK/${c%%|*}" \
    run "$MAIN" $RS up Supervisor
  expect 0 "Supervisor: started (${c#*|})" "(L11) ${c#*|}"; noline "hc keys" "$STUB_LOG" "(L11) a key sent"
done

# (L12) resume under Herdr with mail waiting: the new terminal has no status yet, so the ring is
# deferred, never forced (the left `; read` shell makes the old one gone)
IB="$MAIN/.agents/team/inbox/Supervisor/new"; mkdir -p "$IB"; rm -f "$IB"/*; echo a > "$IB/m1.md"
clr; STUB_HERDR_RC=1 STUB_HC_NONAME=1 STUB_HC_ADDR=t1 STUB_HC_STATUS=null STUB_HC_SCREEN="$WORK/blank.scr" \
  STUB_HC_FG=/bin/sh STUB_HC_FG_NAME=sh STUB_HC_FG_PID=999999 TEAM_ROLES_TRUST_SECS=1 run "$MAIN" $RS resume Supervisor
expect 0 ", inbox 1 waiting — ring deferred (still starting)" "(L12) deferred ring"
noline "hc send" "$STUB_LOG" "(L12) a send into a starting terminal"
rm -f "$IB"/*

# (L7) no placement ever ended a terminal or touched a layout; (L8) tmux: no herdr-app at all
! grep -E 'terminal\.kill|pane\.close|tab\.close|space\.close|layout\.set|layout\.reset|^hc (kill|rm) ' "$WORK/layout-all" \
  > "$WORK/out" || fail "(L7) a placement ended a terminal or touched a layout"
export TEAM_SESSION_HOST=tmux
jq '.backend = "tmux" | .name = "smk-alfa-lead"' "$REG/alfa-lead.json" > "$WORK/r" && mv "$WORK/r" "$REG/alfa-lead.json"
clr; run "$MAIN" $RS place alfa-lead; expect 0 "alfa-lead: tmux attach -t smk-alfa-lead" "(L8) tmux place"
noline "herdr-app" "$STUB_LOG" "(L8) herdr-app under tmux"
unset STUB_HERDR_LS
echo "team-smoke-roles: (L) Herdr layout OK"

echo "team-smoke-roles: OK"
