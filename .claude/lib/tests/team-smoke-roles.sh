#!/usr/bin/env bash
# /roles (roles.sh) over the session-host driver: up is idempotent, restarts a killed role and a dead
# `; read` pane, reports the trust dialog, places nothing under tmux; status, stop (record kept,
# stopped_at), here on the three backends (Herdr id, tmux session, a plain terminal's pid), the
# validator stopping everything, the legacy Advisor key, a project role added in the profile only,
# the window line, roles.lock; the SessionStart contract line (session-registry.sh).
# A stateful stub tmux (sessions are files) and stub claude / codex; nothing reaches a real server.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
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
nm() { local a; for a in "$@"; do case "$a" in =*) a="${a#=}"; echo "${a%%:*}"; return ;; esac; done; }
case "$1" in
  has-session) [ -f "$D/$(nm "$@")" ] && exit 0; echo "can't find session: $(nm "$@")" >&2; exit 1 ;;
  kill-session) rm -f "$D/$(nm "$@")"; exit 0 ;;
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
echo "$t \$* | role=\${TEAM_SESSION_ROLE-unset} addr=\${HARNESS_ADDRESS-unset} be=\${HARNESS_BACKEND-unset} cc=\${CLAUDECODE-unset}" >> "\$STUB_LOG"
[ -z "\${STUB_CLI_STAY:-}" ] || exec sleep 30
STUB
done
chmod +x "$WORK/bin/"*
clr() { : > "$STUB_LOG"; }
line() { grep -qF -- "$1" "$2" || { cp "$2" "$WORK/out" 2>/dev/null || true; fail "$3: no '$1'"; }; }
noline() { ! grep -qF -- "$1" "$2" || { cp "$2" "$WORK/out" 2>/dev/null || true; fail "$3: unexpected '$1'"; }; }
starts() { grep -c '^tmux new-session' "$STUB_LOG" || true; }

# ---- (1) up: three roles, argv, env, profiles, hints; a second up starts nothing -----------------
clr; run "$MAIN" $RS; expect 0 "Supervisor: started" "(1) up"
for r in Fable Astra; do line "$r: started" "$WORK/out" "(1) up"; done
line "  Supervisor: tmux attach -t smk-supervisor" "$WORK/out" "(1) hint"
noline "This window is not a role" "$WORK/out" "(1) plain shell"
[ "$(starts)" = 3 ] || fail "(1) $(starts) new-session calls, expected 3"
for r in Supervisor Fable Astra; do line "-e TEAM_SESSION_ROLE=$r -e HARNESS_ADDRESS=$r" "$STUB_LOG" "(1) env $r"; done
grep '^tmux new-session.* -s smk-astra ' "$STUB_LOG" > "$WORK/astra"
line "codex --no-daemon -m astra -c model_reasoning_effort=high 'You are Astra. Follow the role contract" "$WORK/astra" "(1) Astra argv"
line "Contract: .agents/reference/roles/advisor.md'" "$WORK/astra" "(1) Astra contract"
noline "--settings" "$WORK/astra" "(1) Astra settings"; noline "; read" "$WORK/astra" "(1) Astra read"
grep '^tmux new-session.* -s smk-fable ' "$STUB_LOG" > "$WORK/fable"
line "claude --name 'Fable' --session-id " "$WORK/fable" "(1) Fable argv"
line " --model fable --effort high --settings .agents/team/watch/profiles/Fable.settings.json -- 'You are Fable." "$WORK/fable" "(1) Fable flags"
line "; read" "$WORK/fable" "(1) Fable keeps its pane"
for r in Supervisor Fable; do
  [ "$(jq -r .env.TEAM_SESSION_ROLE "$MP/.agents/team/watch/profiles/$r.settings.json")" = "$r" ] \
    || fail "(1) materialised $r profile does not carry its own role"
done
[ "$(jq -r '.program + " " + (.session_id | length | tostring)' "$REG/Fable.json")" = "claude 36" ] \
  || fail "(1) Fable record lacks program/session_id: $(cat "$REG/Fable.json")"
[ "$(jq -r '.program // "none"' "$REG/Astra.json")" = none ] || fail "(1) Astra record names a program"
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
grep -E '^Fable +tmux +gone +gone +0 ' "$WORK/out" >/dev/null || fail "(3) Fable status row"
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
bad "two mains" '.teams.sessions.Fable.place.slot = "main"' "tab Lead has more than one main slot"
bad "codex settings" '.teams.sessions.Astra.settings = "Advisor"' "teams.sessions.Astra.settings is for claude roles only"
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

# ---- (6) the window line; the trust dialog -----------------------------------------------------------
printf 'Do you trust the files in this folder?\n' > "$WORK/trust.txt"
clr; STUB_PANE="$WORK/trust.txt" TMUX=/tmp/fake,1,0 STUB_SELF=smk-other run "$MAIN" $RS up Fable
expect 0 "Fable: started (needs trust)" "(6) trust"; line "This window is not a role — close it." "$WORK/out" "(6) window"
noline "send-keys" "$STUB_LOG" "(6) the trust dialog was answered"
TMUX=/tmp/fake,1,0 STUB_SELF=smk-fable run "$MAIN" $RS up Fable; expect 0 "Fable: already running" "(6) role window"
noline "This window is not a role" "$WORK/out" "(6) a role's own window"
run "$MAIN" $RS stop Fable; expect 0 "" "(6) stop"
echo "team-smoke-roles: (6) window line, trust OK"

# ---- (7) roles.lock: a live holder refuses, a killed one is reclaimed -----------------------------
sleep 30 & H=$!; SPID=$H
mkdir -p "$REG/roles.lock"; ps -o lstart= -p "$H" | sed 's/^ *//; s/ *$//' > "$REG/roles.lock/started"
echo "$H" > "$REG/roles.lock/pid"
clr; run "$MAIN" $RS up Fable; expect 1 "another /roles is running (pid $H)" "(7) busy"
[ "$(starts)" = 0 ] || fail "(7) a busy lock still started something"
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
# tmux: the record names this tmux session
echo claude > "$D/smk-mine"
clr; TMUX=/tmp/fake,1,0 STUB_SELF=smk-mine run "$MAIN" $RS here Supervisor; expect 0 "" "(8) tmux: here"
line "be=tmux" "$STUB_LOG" "(8) tmux: env"
[ "$(jq -r '.backend + " " + .name' "$REG/Supervisor.json")" = "tmux smk-mine" ] || fail "(8) tmux: record"
run "$MAIN" $RS status; grep -E '^Supervisor +tmux +alive ' "$WORK/out" >/dev/null || fail "(8) tmux: status"
clr; run "$MAIN" $RS up Supervisor; expect 0 "Supervisor: already running" "(8) tmux: up"
run "$MAIN" $RS stop Supervisor; expect 0 "Supervisor: stopped" "(8) tmux: stop"
[ ! -f "$D/smk-mine" ] || fail "(8) tmux: the session survived stop"
# Herdr: recorded, left alone until the Herdr backend exists
clr; HC_TERMINAL_ID=t9 run "$MAIN" $RS here Supervisor; expect 0 "" "(8) herdr: here"
[ "$(jq -r '.backend + " " + .handle' "$REG/Supervisor.json")" = "herdr t9" ] || fail "(8) herdr: record"
run "$MAIN" $RS status; grep -E '^Supervisor +herdr +unknown ' "$WORK/out" >/dev/null || fail "(8) herdr: status"
clr; run "$MAIN" $RS up Supervisor; expect 0 "Supervisor: recorded on herdr — left as it is" "(8) herdr: up"
[ "$(starts)" = 0 ] || fail "(8) herdr: up started a session"
run "$MAIN" $RS stop Supervisor; expect 1 "Supervisor: recorded on herdr — stop it in Herdr" "(8) herdr: stop"
rm -f "$REG/Supervisor.json"
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

echo "team-smoke-roles: OK"
