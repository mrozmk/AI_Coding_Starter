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
[ "$1" != -S ] || shift 2   # the hook names the server socket
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
clr; run "$MAIN" $RS runs; expect 0 "" "(10) runs"
for l in "interrupted run alfa (alfa-20261115-100000, stage planner) — resume: /start-team alfa" \
  "interrupted run epsi (epsi-20261115-060000, stage coder, blocked) — resume: /start-team epsi" \
  "interrupted run iota (iota-20261115-040000, stage coder, failed) — resume: /start-team iota" \
  "interrupted run kappa (kappa-20261115-030000, stage cli) — resume: /start-team kappa" \
  "zeta: clone missing ($WORK/cl-zeta-gone)"; do line "$l" "$WORK/out" "(10) runs"; done
for t in beta gamma delta eta theta; do noline "run $t " "$WORK/out" "(10) $t listed"; done
[ "$(grep '^interrupted run' "$WORK/out" | head -n 1 | cut -d' ' -f3)" = kappa ] || fail "(10) not oldest first"
[ ! -s "$STUB_LOG" ] || fail "(10) runs called the host: $(cat "$STUB_LOG")"
[ -d "$WORK/cl-epsi/.agents/team/lock" ] || fail "(10) runs removed a stale lock"
run "$MAIN" $RS runs --json; expect 0 "" "(10) --json"
jq -e 'length == 4 and (map(.team) == ["kappa", "iota", "epsi", "alfa"])
  and (.[2] | .state == "blocked" and .stage == "coder" and .resume == "/start-team epsi" and (.clone | length) > 0 and .run == "epsi-20261115-060000")' \
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
line "claude --name 'Supervisor' --resume $S1 --model opus --effort medium --settings .agents/team/watch/profiles/Supervisor.settings.json; read" "$WORK/res" "(13) argv"
noline "--session-id" "$WORK/res" "(13) a new session id"; noline "You are Supervisor" "$WORK/res" "(13) bootstrap line"
run "$MAIN" $RS resume Astra; expect 2 "Codex roles restore fresh" "(13) Codex"
rm -f "$REG/Fable.json"; run "$MAIN" $RS resume Fable; expect 1 "no previous session for Fable" "(13) no record"
run "$MAIN" $RS stop all; expect 0 "" "(13) stop all"
echo "team-smoke-roles: (13) resume, stopped OK"

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

echo "team-smoke-roles: OK"
