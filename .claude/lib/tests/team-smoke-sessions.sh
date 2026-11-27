#!/usr/bin/env bash
# Role-session support: the SessionStart contract line (session-registry.sh), the role launch
# through roles.sh (the old launcher verbs are gone), the role profiles and their check, roles.sh here,
# preflight, the Reviewer deliver check, the SQL guard over the launcher verbs and the rollback. /roles itself: part `roles`.
# Fixture HOME and channel (registry + box from the channel step), stub claude / tmux / launchctl /
# crontab: nothing reads or writes the real ~/.agent-mail, ~/.agent-ops or a tmux server.
# It spawns role sessions and holds the outbox lock, so the runner keeps it out of a parallel batch.
# team-smoke: serial
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-sessions-lib.sh"
smoke_init
smoke_team AB-1140 chore/AB-1140-sessions
sessions_init
unset TEAM_SESSIONS_CLAUDE_FLAGS CODEX_HOME AGENT_MAIL_BOX TMUX TMUX_PANE HC_TERMINAL_ID \
  CLAUDECODE HARNESS_MAIN HARNESS_REGISTRY HARNESS_ADDRESS TEAM_SESSION_ROLE
export TEAM_ROLES_TRUST_SECS=1
ROLES_TMUX="smk-supervisor smk-teamlead smk-advisor smk-fable smk-astra"
kill_roles() {
  local n p
  for n in $ROLES_TMUX; do
    p="$(cat "$TMUXD/$n.pid" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true
    echo dead > "$TMUXD/$n.pid"
  done
}
trap 'kill_roles; for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$WORK" "$SD"' EXIT
SS="bash .claude/lib/supervisor-sessions.sh"
RS="bash .claude/lib/roles.sh"
CHK="python3 -I .claude/lib/session_profile_check.py"
HOOKR="$MAIN/.claude/hooks/session-registry.sh"

# The checkout carries what /setup:teams installs for this layer.
cp "$SRC/.claude/lib/supervisor-sessions.sh" "$SRC/.claude/lib/session_profile_check.py" \
  "$SRC/.claude/lib/roles.sh" "$MAIN/.claude/lib/"
cp "$SRC/.claude/team/sessions/Supervisor.settings.json" "$SRC/.claude/team/sessions/Advisor.settings.json" \
  "$MAIN/.claude/team/sessions/"
mkdir -p "$MAIN/.agents/reference/roles"; cp "$SRC"/.agents/reference/roles/*.md "$MAIN/.agents/reference/roles/"
cp "$SRC/.claude/hooks/session-registry.sh" "$MAIN/.claude/hooks/"
mkdir -p "$MAIN/tools"
cp -R "$SRC/tools/agent_mail" "$MAIN/tools/"; rm -rf "$MAIN/tools/agent_mail/tests"
find "$MAIN/tools" -name __pycache__ -prune -exec rm -rf {} +
# MAIN carries this repo's own settings (sessions-lib). Where /setup:teams already ran, its ask rule for
# the kit installer outranks a local allow, and the leak cases (3) and (5) need the template's rules.
jq '.permissions.ask -= ["Bash(bash .claude/team/sessions/operator-kit/install.sh*)"]' \
  "$MAIN/.claude/settings.json" > "$WORK/main-settings.json" && mv "$WORK/main-settings.json" "$MAIN/.claude/settings.json"
cp -R "$SRC/.claude/team/sessions/operator-kit" "$MAIN/.claude/team/sessions/"
printf '__pycache__/\n' >> "$MAIN/.gitignore"
git -C "$MAIN" add -A && git -C "$MAIN" commit --quiet -m "sessions fixture"
prof() { jq "$1" "$MAIN/.claude/project-profile.json" > "$WORK/p" && mv "$WORK/p" "$MAIN/.claude/project-profile.json"; }
prof '.teams.channel += {mail_suffix: "XY", advisor: "pair"}'
run "$MAIN" bash .claude/lib/team-mail-setup.sh "$MAIN"; expect 0 "" "fixture: the channel step"
KIT="$(jq -r .kit_dir "$MAIN/.agents/team/channel.local.json")"
BOX="$(jq -r .box "$MAIN/.agents/team/channel.local.json")"
MP="$(cd "$MAIN" && pwd -P)"

# Stubs. claude: a role session that logs its argv and environment and stays up; launchctl and
# crontab: no scheduler entry; tmux: the watch stub plus pane ids, send-keys hooks and pane files
# addressed by pane id (`%<id>`).
cat > "$WORK/bin/claude" <<'STUB'
#!/usr/bin/env bash
[ "$*" != --version ] || { echo "${STUB_CLAUDE_VERSION:-2.1.301} (Claude Code)"; exit 0; }
echo "claude $* | role=${TEAM_SESSION_ROLE-unset} cc=${CLAUDECODE-unset} sock=${CLAUDE_CODE_MESSAGING_SOCKET-unset} codex=${CODEX_HOME-unset} ccd=${CLAUDE_CONFIG_DIR-unset}" >> "$STUB_LOG"
[ -n "${STUB_CLAUDE_EXIT:-}" ] || exec sleep 60
STUB
printf '#!/bin/bash\nexit 1\n' > "$WORK/bin/launchctl"
printf '#!/bin/bash\ntrue\n' > "$WORK/bin/crontab"
cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "$STUB_LOG"
D="$STUB_TMUX_DIR"
tgt() { local a n=""; for a in "$@"; do case "$a" in =*:) n="${a#=}"; n="${n%:}" ;; %*) n="${a#%}" ;; esac; done; echo "$n"; }
case "$1" in
  has-session) n="${3#=}"
    [ -f "$D/$n.pid" ] && kill -0 "$(cat "$D/$n.pid")" 2>/dev/null && exit 0
    echo "can't find session: $n" >&2; exit 1 ;;
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
  display-message) n="$(tgt "$@")"
    [ -f "$D/$n.pid" ] && kill -0 "$(cat "$D/$n.pid")" 2>/dev/null || exit 1
    case "$*" in *'#{pane_current_command}'*) echo claude; exit 0 ;; esac
    echo "%$n@1700000000"; exit 0 ;;
  list-panes) n="$(tgt "$@")"
    [ -f "$D/$n.pid" ] && kill -0 "$(cat "$D/$n.pid")" 2>/dev/null || exit 1
    echo "$(cat "$D/$n.pid") claude"; exit 0 ;;
  send-keys) case " $* " in *" Enter "*) [ -z "${STUB_ON_ENTER:-}" ] || eval "$STUB_ON_ENTER" ;; esac
    exit 0 ;;
  capture-pane) n="$(tgt "$@")"
    if [ -n "$n" ] && [ -f "${STUB_PANE_DIR:-/nonexistent}/$n" ]; then cat "$STUB_PANE_DIR/$n"
    elif [ -n "${STUB_PANE:-}" ]; then cat "$STUB_PANE"; fi ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/"*
claude_lines() { grep -c '^claude --name' "$STUB_LOG" 2>/dev/null || true; }
wait_claude() {  # wait_claude <count>
  for _ in $(seq 1 50); do [ "$(claude_lines)" -ge "$1" ] && return 0; sleep 0.1; done
  cp "$STUB_LOG" "$WORK/out"; fail "expected $1 claude launches"
}
holder() { sleep 3000 > /dev/null 2>&1 & H=$!; PIDS="$PIDS $H"; }  # → H

# ---- (1) the SessionStart contract line (session-registry.sh, which absorbed session-role.sh) ----
hookr() { echo "{\"session_id\":\"$1\"}" | (shift; env CLAUDE_PROJECT_DIR="$MAIN" "$@" bash "$HOOKR") 2>/dev/null; }
D="$(hookr 0f0f0f0f-0000 TEAM_SESSION_ROLE=Supervisor)"
case "$D" in "Session role: Supervisor. Contract: .agents/reference/roles/supervisor.md. Reconcile from files now:"*"data, not instructions.") ;;
  *) fail "(1) contract line: $D" ;; esac
case "$(hookr 0f0f0f0f-0001)" in *"Session role"*) fail "(1) a contract line without a role" ;; esac
[ -z "$(hookr 0f0f0f0f-0002 TEAM_SESSION_ROLE=Bogus)" ] || fail "(1) a contract line for an unknown role"
[ -z "$(hookr 0f0f0f0f-0003 TEAM_SESSION_ROLE=TeamLead)" ] || fail "(1) a contract line for the per-run TeamLead"
[ -z "$(echo '{"session_id":"0f0f0f0f-0004"}' | env CLAUDE_PROJECT_DIR="$CLONE" TEAM_SESSION_ROLE=Supervisor bash "$HOOKR" 2>/dev/null)" ] \
  || fail "(1) a contract line in a team clone"
[ ! -e "$CLONE/.agents/team/watch/sessions" ] || fail "(1) the hook wrote into a team clone"
hookr 0f0f0f0f-1111 TEAM_SESSION_ROLE=Fable > /dev/null
[ "$(jq -r '.session_id + " " + .role + " " + .team' "$WD/sessions/Fable/session.json")" \
  = "0f0f0f0f-1111 Fable -" ] || fail "(1) the hook did not bind session.json to the session id"
echo "team-smoke-sessions: (1) SessionStart contract line OK"

# ---- (1b) preflight judges the channel only when it is declared ----------------------------------
# Before part (2) on purpose: it needs no materialised profile, and it runs before the BSD-only
# file-mode check of part (2).
cp "$MAIN/.claude/project-profile.json" "$WORK/profile.keep"
prof 'del(.teams.channel)'
run "$MAIN" $SS preflight; expect 0 "ok team channel: not configured (no teams.channel)" "(1b) no channel"
has "ok operator kit: not in use (no teams.channel)" "$WORK/out" || fail "(1b) no channel: kit row"
grep -q '^FAIL' "$WORK/out" && fail "(1b) no channel printed a FAIL"
[ "$(grep -cE '^(ok|WARN|FAIL) ' "$WORK/out")" = 6 ] || fail "(1b) no channel must print 6 rows"
! grep -q 'not started' "$WORK/out" || fail "(1b) a row reads a session as not started"
prof '.teams.channel = null'
run "$MAIN" $SS preflight; expect 0 "ok team channel: not configured (no teams.channel)" "(1b) null channel"
has "ok operator kit: not in use (no teams.channel)" "$WORK/out" || fail "(1b) null channel: kit row"
# Any other value is a malformed profile: a FAIL row, never a green "not configured".
prof '.teams.channel = false'
run "$MAIN" $SS preflight; expect 1 "FAIL team channel loads — teams.channel is not an object" "(1b) channel false"
[ "$(grep -cE '^(ok|WARN|FAIL) ' "$WORK/out")" = 6 ] || fail "(1b) channel false must print 6 rows"
has "FAIL operator kit installed — not verified — teams.channel is not an object" "$WORK/out" || fail "(1b) channel false: kit row"
# A string fails the names check: preflight still prints its rows; materialize keeps refusing.
prof '.teams.channel = "x"'
run "$MAIN" $SS preflight; expect 1 "FAIL team channel loads — teams.channel is not an object" "(1b) channel string"
[ "$(grep -cE '^(ok|WARN|FAIL) ' "$WORK/out")" = 6 ] || fail "(1b) channel string must print 6 rows"
run "$MAIN" $SS materialize Supervisor; expect 3 "needs a valid teams.channel block" "(1b) materialize refuses a string channel"
cp "$WORK/profile.keep" "$MAIN/.claude/project-profile.json"
prof '.teams = false'
run "$MAIN" $SS preflight; expect 1 "FAIL team channel loads — teams.channel is not an object" "(1b) teams false"
cp "$WORK/profile.keep" "$MAIN/.claude/project-profile.json"
# A declared channel whose machine half is gone is a real fault.
mv "$MAIN/.agents/team/channel.local.json" "$WORK/channel.keep"
run "$MAIN" $SS preflight
expect 1 "FAIL team channel loads — error: team channel: not configured — no .agents/team/channel.local.json" "(1b) declared channel, local half missing"
has "FAIL operator kit installed" "$WORK/out" || fail "(1b) local half missing: kit row"
mv "$WORK/channel.keep" "$MAIN/.agents/team/channel.local.json"
# No exit code here: the fixture installs the operator kit only in part (3), so the kit row FAILs.
run "$MAIN" $SS preflight
has "ok team channel loads" "$WORK/out" || fail "(1b) channel restored"
! grep -q 'not started' "$WORK/out" || fail "(1b) a row reads a session as not started with a channel"
echo "team-smoke-sessions: (1b) preflight channel rows OK"

# ---- (2) roles.sh launches the roles; the old launcher verbs are gone; materialise per role ------
for v in start stop status up here; do
  run "$MAIN" $SS $v Supervisor; expect 2 "Starting, stopping and listing roles is roles.sh" "(2) $v is gone"
  grep -q 'deprecated' "$WORK/out" && fail "(2) $v still delegates"
done
: > "$STUB_LOG"
run "$MAIN" env CLAUDECODE=1 CLAUDE_CODE_MESSAGING_SOCKET=/nonexistent/x.sock $RS up
expect 0 "" "(2) roles.sh up"
for r in Supervisor Fable Astra; do has "$r: started" "$WORK/out" || fail "(2) $r start line"; done
wait_claude 2
grep "^claude --name SupervisorXY " "$STUB_LOG" | grep -q -- "--model opus --effort high --settings .agents/team/watch/profiles/Supervisor.settings.json -- You are Supervisor." \
  || { cp "$STUB_LOG" "$WORK/out"; fail "(2) Supervisor argv through roles.sh"; }
grep "^claude --name SupervisorXY " "$STUB_LOG" | grep -q " | role=Supervisor cc=unset sock=unset " \
  || { cp "$STUB_LOG" "$WORK/out"; fail "(2) role env, or a leaked CLAUDECODE/socket"; }
grep "^claude --name FableXY " "$STUB_LOG" | grep -q -- "--settings .agents/team/watch/profiles/Fable.settings.json " \
  || { cp "$STUB_LOG" "$WORK/out"; fail "(2) Fable profile"; }
grep -q 'TeamLead' "$WORK/out" && fail "(2) roles.sh up launched the TeamLead"
run "$MAIN" $RS stop Fable; expect 0 "Fable: stopped" "(2) stop Fable"
run "$MAIN" $RS stop all; kill_roles
# The global TeamLead is retired: no profile, with the default declaration or an explicit template.
run "$MAIN" $SS materialize TeamLead; expect 2 "the global TeamLead is retired" "(2) materialize TeamLead"
cp "$MAIN/.claude/project-profile.json" "$WORK/prof.keep"
prof '.teams.sessions.TeamLead.settings = "TeamLead"'
run "$MAIN" $SS materialize TeamLead; expect 2 "the global TeamLead is retired" \
  "(2) materialize TeamLead with a declared template"
cp "$WORK/prof.keep" "$MAIN/.claude/project-profile.json"
[ ! -e "$WD/profiles/TeamLead.settings.json" ] || fail "(2) a refused materialize wrote a TeamLead profile"
run "$MAIN" $SS materialize Supervisor; expect 0 "profile Supervisor:" "(2) materialize Supervisor"
PF="$WD/profiles/Supervisor.settings.json"
[ "$(stat -f %Lp "$PF")" = 600 ] && [ "$(stat -f %Lp "$WD/profiles")" = 700 ] \
  || fail "(2) materialised profile not 600 in a 700 dir"
jq -e --arg c "Read(//$(dirname "$MP" | sed 's|^/||')/main-*/**)" \
  '(.permissions.allow | index($c)) and (tostring | contains("{{CLONES}}") | not)
   and .env.TEAM_SESSION_ROLE == "Supervisor"
   and (.permissions.deny | index("Bash(az repos pr update*)") | not)
   and (.permissions.deny | index("Bash(gh pr merge*)") | not)' "$PF" >/dev/null \
  || { cp "$PF" "$WORK/out"; fail "(2) materialised Supervisor: clones, env or a PR deny"; }
run "$MAIN" $SS materialize Fable; expect 0 "profile Fable:" "(2) materialize Fable from the Advisor template"
jq -e '.env.TEAM_SESSION_ROLE == "Fable"' "$WD/profiles/Fable.settings.json" >/dev/null \
  || fail "(2) the Fable profile carries the template's role"
run "$MAIN" $SS materialize Astra; expect 2 "Astra has no settings profile" "(2) a Codex role has no profile"
run "$MAIN" $SS materialize Advisor; expect 2 "Advisor has no settings profile" "(2) the legacy name is no role"
run "$CLONE" bash "$MAIN/.claude/lib/supervisor-sessions.sh" check; expect 1 "team clone" "(2) in a clone"
echo "team-smoke-sessions: (2) launch, removed verbs, materialise OK"

# ---- (2b) the channel's Codex home differs from .claude/codex-profile: nothing is launched ------
mkdir -p "$HOME/.codex-other"
cp "$MAIN/.claude/codex-profile" "$WORK/codex-profile.keep"
printf '~/.codex-other\n' > "$MAIN/.claude/codex-profile"
run "$MAIN" $RS stop all; kill_roles; : > "$STUB_LOG"
run "$MAIN" $RS up Supervisor; expect 1 "of the team channel differs from" "(2b) up Supervisor"
has "rerun /setup:teams → channel" "$WORK/out" || fail "(2b) the refusal does not name the fix"
! grep -q '^claude --name SupervisorXY ' "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(2b) a Supervisor was launched"; }
cp "$WORK/codex-profile.keep" "$MAIN/.claude/codex-profile"
echo "team-smoke-sessions: (2b) a channel Codex home that differs from the profile refuses OK"

# ---- (3) profiles and their check ----------------------------------------------------------------
run "$SRC" $CHK "$SRC"; expect 0 "Supervisor OK" "(3) shipped profiles"
! has "TeamLead OK" "$WORK/out" || fail "(3) the retired TeamLead is still checked"
PY_ROLES="$(sed -n 's/^ROLES = (\(.*\))$/\1/p' "$SRC/.claude/lib/session_profile_check.py" | tr -d '",')"
[ "$PY_ROLES" = Supervisor ] || fail "(3) ROLES ($PY_ROLES) is not the Supervisor alone"
run "$MAIN" $CHK "$MAIN" Supervisor; expect 0 "Supervisor OK" "(3) materialised"
FLOOR="$(jq '.permissions.deny | length' "$MAIN/.claude/settings.json")"
[ "$(jq '.permissions.deny | length' "$PF")" -gt "$FLOOR" ] || fail "(3) materialised profile lacks the project denies"
jq '.permissions.deny |= .[1:]' "$PF" > "$WORK/p" && mv "$WORK/p" "$PF"
run "$MAIN" $CHK "$MAIN" Supervisor; expect 1 "lost 1 deny rules" "(3) materialised profile lost the floor"
run "$MAIN" $SS materialize Supervisor; expect 0 "profile Supervisor:" "(3) re-materialise"
# The .env floor covers the Read tool too (R1): the materialised profile keeps the rule, and the
# check fails a profile without it through the Read(...) secrets samples.
jq -e '.permissions.ask | index("Read(**/.env*)")' "$PF" >/dev/null || fail "(3) materialised profile lacks Read(**/.env*)"
jq '.permissions.ask -= ["Read(**/.env*)"]' "$PF" > "$WORK/p" && mv "$WORK/p" "$PF"
run "$MAIN" $CHK "$MAIN" Supervisor; expect 1 "Supervisor FAIL: Read(services/api/.env.local) → prompt, expected ask or deny" "(3) the Read .env floor is checked"
run "$MAIN" $SS materialize Supervisor; expect 0 "profile Supervisor:" "(3) re-materialise after the Read probe"
# A local deny added after materialising: the profile is stale until the next materialize.
echo '{"permissions": {"deny": ["Bash(local-only-deny *)"]}}' > "$MAIN/.claude/settings.local.json"
! jq -e '.permissions.deny | index("Bash(local-only-deny *)")' "$PF" >/dev/null \
  || fail "(3) the profile has the local deny before materialize"
run "$MAIN" $CHK "$MAIN"; expect 1 "Supervisor FAIL: materialised profile lost 1 deny rules" "(3) a stale profile misses the local deny"
run "$MAIN" $SS materialize Supervisor
jq -e '.permissions.deny | index("Bash(local-only-deny *)")' "$PF" >/dev/null || fail "(3) local deny not unioned"
echo '{"permissions": {"allow": ["Bash(bash .claude/team/*)"]}}' > "$MAIN/.claude/settings.local.json"
run "$MAIN" $SS materialize Supervisor
run "$MAIN" $SS check
expect 3 "Supervisor LEAK: bash .claude/team/sessions/operator-kit/install.sh --apply allowed by local Bash(bash .claude/team/*)" "(3) local leak"
grep -q ' FAIL:' "$WORK/out" && fail "(3) a local leak reported as FAIL"
: > "$STUB_LOG"
run "$MAIN" bash .claude/lib/roles.sh up Supervisor; expect 1 "nothing launched" "(3) up refuses a leak"
grep -q '^tmux new-session' "$STUB_LOG" && fail "(3) a refused up launched a session"
rm -f "$MAIN/.claude/settings.local.json"
jq '.permissions.allow += ["Bash(rm *)"] | ._samples.writes += ["rm x"]' \
  "$MAIN/.claude/team/sessions/Supervisor.settings.json" > "$WORK/sup.json"
mkdir -p "$WORK/profiles"; cp "$WORK/sup.json" "$WORK/profiles/Supervisor.settings.json"
rm -f "$PF"
run "$MAIN" $CHK "$MAIN" --profiles "$WORK/profiles" Supervisor; expect 1 "rm x → allow, expected not allow" "(3) write allowed"
# The kit's role-hooks file gives Stop only — never PreToolUse, never permissions, never an old
# kit's Notification entry (it calls a removed hook).
run "$MAIN" bash .claude/team/sessions/operator-kit/install.sh --apply; expect 0 "" "(3) kit --apply"
RH="$KIT/hooks/role-hooks.settings.json"
cp "$RH" "$WORK/rh.keep"
jq '.hooks.Notification = [{matcher: "permission_prompt", hooks: [{type: "command", command: "bash x/supervisor-notify.sh"}]}]
  | .hooks.PreToolUse = [{matcher: "Bash", hooks: [{type: "command", command: "approve-all"}]}]
  | .hooks.PermissionRequest = [{hooks: [{type: "command", command: "approve-all"}]}]
  | .permissions = {allow: ["Bash(*)"]}' "$WORK/rh.keep" > "$RH"
run "$MAIN" $SS materialize Supervisor; expect 0 "" "(3) materialize Supervisor with the kit"
# #323: the template's own PreToolUse/PermissionRequest entries (the clearance hook) stay; the kit
# adds Stop and nothing else.
jq -e '((.hooks | keys) - ["PermissionRequest", "PreToolUse"]) == ["Stop"] and (.permissions.allow | index("Bash(*)") | not)
  and ([(.hooks.PreToolUse // [])[], (.hooks.PermissionRequest // [])[] | .hooks[].command]
       | all(contains("/.claude/hooks/team-clearance-hook.sh")))
  and (tostring | contains("approve-all") | not)' "$PF" >/dev/null \
  || { cp "$PF" "$WORK/out"; fail "(3) Supervisor took more than Stop from the kit"; }
cp "$WORK/rh.keep" "$RH"
echo "team-smoke-sessions: (3) profiles OK"

# ---- (4) roles.sh here ---------------------------------------------------------------------------
holder; echo "$H" > "$TMUXD/smk-supervisor.pid"
run "$MAIN" $RS here Supervisor; expect 1 "Supervisor is already running" "(4) here while tmux runs"
echo dead > "$TMUXD/smk-supervisor.pid"
run "$MAIN" env CLAUDECODE=1 $RS here Supervisor
expect 1 "open a new terminal and run: bash .claude/lib/roles.sh here Supervisor" "(4) here inside Claude"
: > "$STUB_LOG"
run "$MAIN" env STUB_CLAUDE_EXIT=1 $RS here Supervisor; expect 0 "" "(4) here"
grep -q "^claude --name SupervisorXY --session-id [0-9a-f-]* --model opus --effort high --settings .agents/team/watch/profiles/Supervisor.settings.json -- You are Supervisor.* | role=Supervisor cc=unset" \
  "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(4) here did not exec claude as the Supervisor"; }
# A declared Claude profile: `here` execs on it; an unresolvable one refuses before the record.
mkdir -p "$WORK/claude-home"; CH_REAL="$(cd "$WORK/claude-home" && pwd -P)"
printf '# fixture\n%s\n' "$WORK/claude-home" > "$MAIN/.claude/claude-profile"
: > "$STUB_LOG"
run "$MAIN" env STUB_CLAUDE_EXIT=1 CLAUDE_CONFIG_DIR="$WORK/other" $RS here Supervisor; expect 0 "" "(4) here with a Claude profile"
grep -q "^claude --name SupervisorXY .* ccd=$CH_REAL\$" "$STUB_LOG" \
  || { cp "$STUB_LOG" "$WORK/out"; fail "(4) here did not run on the Claude profile"; }
printf '%s\n' "$WORK/no-such-home" > "$MAIN/.claude/claude-profile"
cp "$MP/.agents/team/registry/Supervisor.json" "$WORK/sup-rec.bak"
: > "$STUB_LOG"
run "$MAIN" env STUB_CLAUDE_EXIT=1 $RS here Supervisor; expect 1 "Claude profile" "(4) here refuses an unresolvable Claude profile"
grep -q '^claude ' "$STUB_LOG" && fail "(4) an unresolvable Claude profile still ran claude"
cmp -s "$MP/.agents/team/registry/Supervisor.json" "$WORK/sup-rec.bak" || fail "(4) a refused here rewrote the record"
rm -f "$MAIN/.claude/claude-profile" "$MP/.agents/team/registry/Supervisor.json"
echo "team-smoke-sessions: (4) here OK"

# ---- (5) preflight -------------------------------------------------------------------------------
run "$MAIN" $SS preflight; expect 0 "ok team channel loads" "(5) preflight green"
grep -q '^FAIL' "$WORK/out" && fail "(5) preflight green printed a FAIL"
! grep -qE 'receivers live|team-watch loops|mail probe and picked ping' "$WORK/out" || fail "(5) preflight prints no team-watch row"
[ "$(grep -cE '^(ok|WARN|FAIL) ' "$WORK/out")" = 6 ] || fail "(5) preflight must print 6 rows"
for row in "ok team channel loads" "ok operator kit installed" \
  "ok role profiles" "ok notifications: config: missing (~/.agent-comms/notify.json) · herdr off · imessage off" \
  "ok health check: none — declared loss: a dead tmux server is noticed by nobody" \
  "ok Claude Code 2.1.301 — unverified: check the doorbell (session-host.sh send) by hand"; do
  has "$row" "$WORK/out" || fail "(5) row: $row"
done
! grep -q 'not started' "$WORK/out" || fail "(5) a row reads a session as not started"
run "$MAIN" env STUB_CLAUDE_VERSION=2.1.318 $SS preflight
expect 0 "ok Claude Code 2.1.318 — socket wire format verified on 2.1.318" "(5) verified CLI"
# A sender that cannot report its state is a FAIL row, not a silent ok.
cp "$MAIN/.claude/lib/notify.sh" "$WORK/notify.keep"; printf '#!/usr/bin/env bash\necho broken; exit 1\n' > "$MAIN/.claude/lib/notify.sh"
run "$MAIN" $SS preflight; expect 1 "FAIL notifications — notify.sh --check exit 1: broken" "(5) a failing notify.sh --check"
cp "$WORK/notify.keep" "$MAIN/.claude/lib/notify.sh"
# A flush or a send holding the outbox lock never stalls or fails the row (the holder dies with the part).
OBX="$HOME/.agent-comms/outbox"; mkdir -p "$OBX/events"; chmod 700 "$HOME/.agent-comms" "$OBX"
KEEP_TRAP="$(trap -p EXIT | sed "s/^trap -- '//; s/' EXIT\$//")"; sleep 300 & LHOLD=$!
trap "kill $LHOLD 2>/dev/null || true; $KEEP_TRAP" EXIT
mkdir "$OBX/.flush.lock"; echo "$LHOLD" > "$OBX/.flush.lock/pid"
t0=$SECONDS; run "$MAIN" $SS preflight; expect 0 "ok notifications: config: missing" "(5) preflight with the outbox lock held"
[ $((SECONDS - t0)) -lt 10 ] || fail "(5) preflight waited $((SECONDS - t0)) s for the outbox lock"
has "outbox: 0 events (prune skipped: outbox busy)" "$WORK/out" || fail "(5) the notifications row on a busy outbox"
kill "$LHOLD"; wait "$LHOLD" 2>/dev/null || true; trap "$KEEP_TRAP" EXIT; rm -rf "$OBX/.flush.lock"
run "$MAIN" env TEAM_SESSIONS_CLAUDE_FLAGS="--permission-mode bypassPermissions" $SS preflight
expect 1 "\"crossSessionInbound\": \"accept\" to $HOME/.claude/settings.json" "(5) bypass without crossSessionInbound"
[ ! -e "$HOME/.claude/settings.json" ] || fail "(5) preflight wrote the user settings"
mkdir -p "$HOME/.claude"; echo '{"crossSessionInbound": "accept"}' > "$HOME/.claude/settings.json"
run "$MAIN" env TEAM_SESSIONS_CLAUDE_FLAGS="--permission-mode bypassPermissions" $SS preflight
expect 0 "ok Claude Code" "(5) bypass with crossSessionInbound"
# With a Claude profile the check reads the profile's settings, not the inherited dir's.
mkdir -p "$WORK/claude-pf"; PF_REAL="$(cd "$WORK/claude-pf" && pwd -P)"
printf '%s\n' "$WORK/claude-pf" > "$MAIN/.claude/claude-profile"
run "$MAIN" env TEAM_SESSIONS_CLAUDE_FLAGS="--permission-mode bypassPermissions" $SS preflight
expect 1 "\"crossSessionInbound\": \"accept\" to $PF_REAL/settings.json" "(5) bypass checks the Claude profile's settings"
echo '{"crossSessionInbound": "accept"}' > "$WORK/claude-pf/settings.json"
rm -f "$HOME/.claude/settings.json"
run "$MAIN" env TEAM_SESSIONS_CLAUDE_FLAGS="--permission-mode bypassPermissions" $SS preflight
expect 0 "ok Claude Code" "(5) bypass with crossSessionInbound in the Claude profile"
rm -f "$MAIN/.claude/claude-profile"
rm -f "$HOME/.claude/settings.json"
mv "$MAIN/.claude/team/sessions/operator-kit/install.sh" "$WORK/install.keep"
run "$MAIN" $SS preflight; expect 1 "FAIL operator kit installed — not shipped" "(5) kit absent"
mv "$WORK/install.keep" "$MAIN/.claude/team/sessions/operator-kit/install.sh"
echo '{"permissions": {"allow": ["Bash(bash .claude/team/*)"]}}' > "$MAIN/.claude/settings.local.json"
run "$MAIN" $SS preflight; expect 1 "FAIL role profiles — local allow leak (Operator: settings.local.json)" "(5) leak row"
rm -f "$MAIN/.claude/settings.local.json"
echo "team-smoke-sessions: (5) preflight OK"

# ---- (6) reviewer: the deliver loop of THIS box, never another project's same-name loop ----------
run "$MAIN" $SS reviewer; expect 0 "Reviewer: deliver missing — restore per .agents/reference/agent-mail.md → Bring-up" "(6) none running"
fake() { bash -c 'exec -a "$1" sleep 300' _ "python3 -I -B -u /x/agent_mail_deliver.py --box $1 --recipient ReviewerXY" & PIDS="$PIDS $!"; F=$!; }
fake "$WORK/projb/mail.sqlite"; FB=$F; sleep 0.3
run "$MAIN" $SS reviewer; expect 0 "Reviewer: deliver missing" "(6) project B's same-name loop must not count"
fake "$BOX"; FA=$F; sleep 0.3
run "$MAIN" $SS reviewer; expect 0 "Reviewer: deliver ok" "(6) this box's loop"
kill "$FA" "$FB" 2>/dev/null || true
prof '.teams.channel.advisor = "solo"'
run "$MAIN" $SS reviewer; expect 0 "Reviewer: none (advisor solo)" "(6) solo"
prof '.teams.channel.advisor = "pair"'
echo "team-smoke-sessions: (6) reviewer OK"

# ---- (7) the SQL guard lets every supervisor-sessions.sh verb through ----------------------------
for c in preflight check reviewer "materialize Supervisor" "freeze on 1.4.0" "freeze status" "freeze off" rollback; do
  jq -n --arg c "bash .claude/lib/supervisor-sessions.sh $c" --arg w "$SRC" \
    '{tool_name: "Bash", cwd: $w, tool_input: {command: $c}}' > "$WORK/payload"
  run "$SRC" env CLAUDE_PROJECT_DIR="$SRC" bash .claude/hooks/guard-destructive-sql.sh < "$WORK/payload"
  expect 0 "" "(7) guard on supervisor-sessions.sh $c"
  [ ! -s "$WORK/out" ] || fail "(7) the guard decided on supervisor-sessions.sh $c"
done
run "$MAIN" $SS freeze on 1.4.0; expect 0 "freeze: on — 1.4.0 (operator," "(7) freeze on"
run "$MAIN" env TEAM_SESSION_ROLE=Supervisor $SS freeze status; expect 0 "freeze: on — 1.4.0" "(7) freeze status"
run "$MAIN" $SS freeze off; expect 0 "freeze: off" "(7) freeze off"
echo "team-smoke-sessions: (7) SQL guard and freeze OK"
# ---- (8) auto-merge on a stale merge: provider-driven restart, never a missing-file exec ----------
mkrec qa "$BASE"
printf 'Verdict: ready\nGate final-build: passed (0 failed)\n' > "$RD/qa-report-1.md"
printf '#!/usr/bin/env bash\necho "stale merge — target moved"; exit 3\n' > "$WORK/mc-stale.sh"
AM="bash .claude/lib/team-automerge-check.sh"
run "$MAIN" env TEAM_AUTOMERGE_MERGE_CHECK="$WORK/mc-stale.sh" $AM alfa
expect 1 "AUTOMERGE: no — stale merge, restart not available for azure-devops — restart the merge on PR 8371" "(8) no restart verb"
printf '#!/usr/bin/env bash\necho "restart $1" >> "$STUB_LOG"\n' > "$WORK/restart.sh"
: > "$STUB_LOG"
run "$MAIN" env TEAM_AUTOMERGE_MERGE_CHECK="$WORK/mc-stale.sh" TEAM_AUTOMERGE_RESTART="$WORK/restart.sh" \
  TEAM_AUTOMERGE_RECALC_TRIES=1 TEAM_AUTOMERGE_RECALC_SLEEP=0 $AM alfa
expect 1 "(after one restart merge)" "(8) a project restart script runs once"
[ "$(grep -c '^restart 8371$' "$STUB_LOG")" = 1 ] || fail "(8) the restart script did not run once"
echo "team-smoke-sessions: (8) auto-merge restart OK"

# ---- (9) rollback ----------------------------------------------------------------------------------
kill_roles
run "$MAIN" $SS rollback; expect 0 "Rollback:" "(9) rollback"
has "install.sh --rollback" "$WORK/out" || fail "(9) rollback lacks the Operator's kit step"
! has "team-watch" "$WORK/out" || fail "(9) rollback names team-watch"
echo "team-smoke-sessions: (9) rollback OK"
echo "team-smoke-sessions: OK"
