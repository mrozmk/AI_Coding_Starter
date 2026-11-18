#!/usr/bin/env bash
# Role-session support: the SessionStart contract line (session-registry.sh), the role launch
# through roles.sh (the old launcher verbs are gone), the role profiles and their check, the tier-1 `answer` into
# a role prompt (team-answer.sh --session), preflight, the Reviewer deliver check, the SQL guard over
# the launcher verbs and the rollback. /roles itself: part `roles`.
# Fixture HOME and channel (registry + box from the channel step), stub claude / tmux / launchctl /
# crontab: nothing reads or writes the real ~/.agent-mail, ~/.agent-ops or a tmux server.
# It waits on pickup windows (ping → ack), so the runner keeps it out of a parallel batch.
# team-smoke: serial
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-watch-lib.sh"
smoke_init
smoke_team AB-1140 chore/AB-1140-sessions
watch_init
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
trap 'kill_roles; kill_loops; for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$WORK" "$SD"' EXIT
SS="bash .claude/lib/supervisor-sessions.sh"
RS="bash .claude/lib/roles.sh"
CHK="python3 -I .claude/lib/session_profile_check.py"
HOOKR="$MAIN/.claude/hooks/session-registry.sh"

# The checkout carries what /setup:teams installs for this layer.
cp "$SRC/.claude/lib/supervisor-sessions.sh" "$SRC/.claude/lib/session_profile_check.py" \
  "$SRC/.claude/lib/roles.sh" "$MAIN/.claude/lib/"
cp "$SRC/.claude/team/sessions/Supervisor.settings.json" "$SRC/.claude/team/sessions/Advisor.settings.json" \
  "$SRC/.claude/team/sessions/TeamLead.settings.json" "$MAIN/.claude/team/sessions/"
mkdir -p "$MAIN/.agents/reference/roles"; cp "$SRC"/.agents/reference/roles/*.md "$MAIN/.agents/reference/roles/"
cp "$SRC/.claude/hooks/session-registry.sh" "$MAIN/.claude/hooks/"
mkdir -p "$MAIN/tools"
cp -R "$SRC/tools/agent_mail" "$MAIN/tools/"; rm -rf "$MAIN/tools/agent_mail/tests"
find "$MAIN/tools" -name __pycache__ -prune -exec rm -rf {} +
# MAIN carries this repo's own settings (watch-lib). Where /setup:teams already ran, its ask rule for
# the kit installer outranks a local allow, and the leak cases (3) and (5) need the template's rules.
jq '.permissions.ask -= ["Bash(bash .claude/team/sessions/operator-kit/install.sh*)"]' \
  "$MAIN/.claude/settings.json" > "$WORK/main-settings.json" && mv "$WORK/main-settings.json" "$MAIN/.claude/settings.json"
cp "$SRC"/.claude/team/*.tmpl "$MAIN/.claude/team/"
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
# addressed by pane id (team-answer.sh targets `%<id>`).
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
  send-keys) case " $* " in *" Enter "*) [ -z "${STUB_ON_ENTER:-}" ] || eval "$STUB_ON_ENTER" ;; esac
    exit 0 ;;
  capture-pane) n="$(tgt "$@")"
    if [ -n "$n" ] && [ -f "${STUB_PANE_DIR:-/nonexistent}/$n" ]; then cat "$STUB_PANE_DIR/$n"
    elif [ -n "${STUB_PANE:-}" ]; then cat "$STUB_PANE"; fi ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/"*
role_prompt() {  # role_prompt <role> → tw_role_prompt's "<sub>\t<fp>\t<anchor>" line
  (cd "$MAIN" && bash -c '. .claude/lib/team-watch-lib.sh; tw_init "$PWD"; tw_role_prompt "$1"' _ "$1")
}
claude_lines() { grep -c '^claude --name' "$STUB_LOG" 2>/dev/null || true; }
wait_claude() {  # wait_claude <count>
  for _ in $(seq 1 50); do [ "$(claude_lines)" -ge "$1" ] && return 0; sleep 0.1; done
  cp "$STUB_LOG" "$WORK/out"; fail "expected $1 claude launches"
}
holder() { sleep 3000 > /dev/null 2>&1 & H=$!; PIDS="$PIDS $H"; }  # → H
no_keys() { ! grep -q '^tmux send-keys' "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "$1: keys were sent"; }; }

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
[ "$(jq -r '.session_id + " " + .role + " " + .team' "$TWD/sessions/Fable/session.json")" \
  = "0f0f0f0f-1111 Fable -" ] || fail "(1) the hook did not bind session.json to the session id"
echo "team-smoke-sessions: (1) SessionStart contract line OK"

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
grep "^claude --name SupervisorXY " "$STUB_LOG" | grep -q -- "--model opus --effort medium --settings .agents/team/watch/profiles/Supervisor.settings.json -- You are Supervisor." \
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
[ ! -e "$TWD/profiles/TeamLead.settings.json" ] || fail "(2) a refused materialize wrote a TeamLead profile"
run "$MAIN" $SS materialize Supervisor; expect 0 "profile Supervisor:" "(2) materialize Supervisor"
PF="$TWD/profiles/Supervisor.settings.json"
[ "$(stat -f %Lp "$PF")" = 600 ] && [ "$(stat -f %Lp "$TWD/profiles")" = 700 ] \
  || fail "(2) materialised profile not 600 in a 700 dir"
jq -e --arg c "Read(//$(dirname "$MP" | sed 's|^/||')/main-*/**)" \
  '(.permissions.allow | index($c)) and (tostring | contains("{{CLONES}}") | not)
   and .env.TEAM_SESSION_ROLE == "Supervisor"
   and (.permissions.deny | index("Bash(az repos pr update*)") | not)
   and (.permissions.deny | index("Bash(gh pr merge*)") | not)' "$PF" >/dev/null \
  || { cp "$PF" "$WORK/out"; fail "(2) materialised Supervisor: clones, env or a PR deny"; }
run "$MAIN" $SS materialize Fable; expect 0 "profile Fable:" "(2) materialize Fable from the Advisor template"
jq -e '.env.TEAM_SESSION_ROLE == "Fable"' "$TWD/profiles/Fable.settings.json" >/dev/null \
  || fail "(2) the Fable profile carries the template's role"
run "$MAIN" $SS materialize Astra; expect 2 "Astra has no settings profile" "(2) a Codex role has no profile"
run "$MAIN" $SS materialize Advisor; expect 2 "Advisor has no settings profile" "(2) the legacy name is no role"
run "$CLONE" bash "$MAIN/.claude/lib/supervisor-sessions.sh" check; expect 1 "team clone" "(2) in a clone"
echo "team-smoke-sessions: (2) launch, removed verbs, materialise OK"

# ---- (3) profiles and their check ----------------------------------------------------------------
run "$SRC" $CHK "$SRC"; expect 0 "Supervisor OK" "(3) shipped profiles"
! has "TeamLead OK" "$WORK/out" || fail "(3) the retired TeamLead is still checked"
PY_ROLES="$(sed -n 's/^ROLES = (\(.*\))$/\1/p' "$SRC/.claude/lib/session_profile_check.py" | tr -d '",')"
SH_ROLES="$(bash -c '. "$1/.claude/lib/team-watch-route.sh"; echo "$TW_ROLES"' _ "$SRC")"
[ "$PY_ROLES" = "$SH_ROLES" ] || fail "(3) ROLES ($PY_ROLES) != TW_ROLES ($SH_ROLES)"
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
jq -e '(.hooks | keys) == ["Stop"] and (.permissions.allow | index("Bash(*)") | not)
  and (tostring | contains("approve-all") | not)' "$PF" >/dev/null \
  || { cp "$PF" "$WORK/out"; fail "(3) Supervisor took more than Stop from the kit"; }
cp "$WORK/rh.keep" "$RH"
echo "team-smoke-sessions: (3) profiles OK"

# ---- (4) answer: the tier-1 path into a role session's own prompt ---------------------------------
export STUB_PANE_DIR="$WORK/panes"; mkdir -p "$STUB_PANE_DIR"
: > "$STUB_LOG"
# The Advisor's own session (TW_PANE_ROLES), started directly. `materialize Advisor` is refused (the
# legacy name has no template), so its profile is a fixture: the Fable profile under the Advisor's role.
run "$MAIN" $SS answer TeamLead --fp 000000000000 pick 2; expect 2 "" "(4) the retired TeamLead is no answer target"
run "$MAIN" $SS materialize Fable; expect 0 "" "(4) materialize Fable"
jq '.env.TEAM_SESSION_ROLE = "Advisor"' "$TWD/profiles/Fable.settings.json" > "$WORK/adv.json"
( umask 077; cp "$WORK/adv.json" "$TWD/profiles/Advisor.settings.json" )
SID="0f0f0f0f-4444-4444-4444-444444444444"; mkdir -p "$TWD/sessions/Advisor"
jq -n --arg s "$SID" '{team: "-", role: "Advisor", run: "-", attempt: 1, session_id: $s}' > "$TWD/sessions/Advisor/session.json"
(cd "$MAIN" && tmux new-session -d -s smk-advisor -c "$MAIN" -e TEAM_SESSION_ROLE=Advisor \
  "claude --name AdvisorXY --session-id $SID")
wait_claude 1
cp "$FIX/menu-phase0.txt" "$STUB_PANE_DIR/smk-advisor"
FP="$(role_prompt Advisor | cut -f2)"
[ "$(role_prompt Advisor | cut -f1)" = menu ] && [[ "$FP" =~ ^[0-9a-f]{12}$ ]] \
  || fail "(4) role prompt: $(role_prompt Advisor)"
T="$HOME/.claude/projects/$(echo "$MP" | sed 's/[^A-Za-z0-9]/-/g')/$SID.jsonl"
mkdir -p "$(dirname "$T")"; cp "$FIX/t-menu-pending.jsonl" "$T"
: > "$STUB_LOG"
run "$MAIN" $SS answer Advisor --fp 000000000000 pick 2; expect 1 "stale:" "(4) wrong fp"
run "$MAIN" env TEAM_SESSION_ROLE=Advisor $SS answer Advisor --fp "$FP" pick 2
expect 1 "never answers a role prompt" "(4) a role session answering"
run "$MAIN" $SS answer Advisor --fp "$FP" yes; expect 1 "does not fit a menu" "(4) yes on a menu"
run "$MAIN" bash .claude/lib/team-answer.sh smk advisor pick 2 --session Advisor --clone "$CLONE"
expect 2 "exclude each other" "(4) --session with --clone"
mv "$TWD/sessions/Advisor/session.json" "$WORK/sj.keep"
run "$MAIN" $SS answer Advisor --fp "$FP" pick 2; expect 5 "no readable session.json" "(4) no session.json"
mv "$WORK/sj.keep" "$TWD/sessions/Advisor/session.json"
no_keys "(4) refusals"
export STUB_ON_ENTER="jq -cn '{type: \"user\", uuid: \"u-done\", message: {content: [{type: \"tool_result\", tool_use_id: \"toolu_01menu\"}]}}' >> '$T'"
run "$MAIN" $SS answer Advisor --fp "$FP" pick 2
expect 0 "answered Advisor pick (fp $FP)" "(4) pick through team-answer.sh --session"
has "confirmed: yes (tool_result)" "$WORK/out" || fail "(4) the answer was not confirmed from the role's transcript"
[ "$(grep -c '^tmux send-keys -t %smk-advisor Down' "$STUB_LOG")" = 1 ] \
  && has "tmux send-keys -t %smk-advisor Enter" "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(4) pick keys"; }
unset STUB_ON_ENTER
printf 'Bash command\n  cat .env\nDo you want to proceed?\n❯ 1. Yes\n' > "$STUB_PANE_DIR/smk-advisor"
FP2="$(role_prompt Advisor | cut -f2)"
: > "$STUB_LOG"
run "$MAIN" $SS answer Advisor --fp "$FP2" yes; expect 1 "Operator action:" "(4) ask-tier command"
run "$MAIN" $SS answer Advisor --fp "$FP2" pick 1; expect 1 "does not fit a permission" "(4) pick on a permission"
no_keys "(4) policy refusals"
printf 'Bash command\n  bash .claude/lib/team-mail.sh --here inbox --for Advisor --unread\nDo you want to proceed?\n❯ 1. Yes\n' \
  > "$STUB_PANE_DIR/smk-advisor"
FP3="$(role_prompt Advisor | cut -f2)"
run "$MAIN" $SS answer Advisor --fp "$FP3" yes; expect 0 "answered Advisor yes (fp $FP3)" "(4) tier 1 yes"
has "tmux send-keys -t =smk-advisor: Enter" "$STUB_LOG" || fail "(4) Enter not sent"
: > "$STUB_LOG"
run "$MAIN" $SS answer Advisor --fp "$FP3" no "out of scope"; expect 0 "answered Advisor no" "(4) no"
has "Rejected by the Supervisor: out of scope. Do not work around it" "$STUB_LOG" || fail "(4) rejection text"
holder; echo "$H" > "$TMUXD/smk-supervisor.pid"
run "$MAIN" $RS here Supervisor; expect 1 "Supervisor is already running" "(4) here while tmux runs"
echo dead > "$TMUXD/smk-supervisor.pid"
run "$MAIN" env CLAUDECODE=1 $RS here Supervisor
expect 1 "open a new terminal and run: bash .claude/lib/roles.sh here Supervisor" "(4) here inside Claude"
: > "$STUB_LOG"
run "$MAIN" env STUB_CLAUDE_EXIT=1 $RS here Supervisor; expect 0 "" "(4) here"
grep -q "^claude --name SupervisorXY --session-id [0-9a-f-]* --model opus --effort medium --settings .agents/team/watch/profiles/Supervisor.settings.json -- You are Supervisor.* | role=Supervisor cc=unset" \
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
rm -f "$STUB_PANE_DIR/smk-advisor" "$TWD/profiles/Advisor.settings.json"
run "$MAIN" tmux kill-session -t =smk-advisor
echo "team-smoke-sessions: (4) answer OK"

# ---- (5) preflight -------------------------------------------------------------------------------
mkrole SUP
mailcfg true
run "$MAIN" $W routing split; expect 0 "" "(5) routing split"
as Supervisor SUP $W register; expect 0 "Supervisor registered" "(5) register"
run "$MAIN" $W ping Supervisor; wait_recv SUP "PING Supervisor" 15
for n in $(cd "$MAIN" && $W pending Supervisor); do run "$MAIN" env TEAM_SESSION_ROLE=Supervisor $W ack "$n"; done
beat() { echo "$(date -u +%s) 1 v$TWV" > "$TWD/beat"; echo "$(date -u +%s) 1 v$TWV" > "$TWD/dog.beat"; }
beat; run "$MAIN" $SS preflight; expect 0 "ok receivers live" "(5) preflight green"
grep -q '^FAIL' "$WORK/out" && fail "(5) preflight green printed a FAIL"
[ "$(grep -cE '^(ok|WARN|FAIL) ' "$WORK/out")" = 10 ] || fail "(5) preflight must print 10 rows"
for row in "ok team-watch loops beating" "ok escalations have live waiters" \
  "ok mail probe and picked ping per role" "ok team channel loads" "ok operator kit installed" \
  "ok role profiles" "ok notifications: config: missing (~/.agent-comms/notify.json) · herdr off · imessage off" \
  "ok health check: none — declared loss: a dead tmux server is noticed by nobody" \
  "ok Claude Code 2.1.301 — unverified: run team-watch.sh ping <role>"; do
  has "$row" "$WORK/out" || fail "(5) row: $row"
done
beat; run "$MAIN" env STUB_CLAUDE_VERSION=2.1.318 $SS preflight
expect 0 "ok Claude Code 2.1.318 — socket wire format verified on 2.1.318" "(5) verified CLI"
# A sender that cannot report its state is a FAIL row, not a silent ok.
cp "$MAIN/.claude/lib/notify.sh" "$WORK/notify.keep"; printf '#!/usr/bin/env bash\necho broken; exit 1\n' > "$MAIN/.claude/lib/notify.sh"
beat; run "$MAIN" $SS preflight; expect 1 "FAIL notifications — notify.sh --check exit 1: broken" "(5) a failing notify.sh --check"
cp "$WORK/notify.keep" "$MAIN/.claude/lib/notify.sh"
# A flush or a send holding the outbox lock never stalls or fails the row (the holder dies with the part).
OBX="$HOME/.agent-comms/outbox"; mkdir -p "$OBX/events"; chmod 700 "$HOME/.agent-comms" "$OBX"
KEEP_TRAP="$(trap -p EXIT | sed "s/^trap -- '//; s/' EXIT\$//")"; sleep 300 & LHOLD=$!
trap "kill $LHOLD 2>/dev/null || true; $KEEP_TRAP" EXIT
mkdir "$OBX/.flush.lock"; echo "$LHOLD" > "$OBX/.flush.lock/pid"
t0=$SECONDS; beat; run "$MAIN" $SS preflight; expect 0 "ok notifications: config: missing" "(5) preflight with the outbox lock held"
[ $((SECONDS - t0)) -lt 10 ] || fail "(5) preflight waited $((SECONDS - t0)) s for the outbox lock"
has "outbox: 0 events (prune skipped: outbox busy)" "$WORK/out" || fail "(5) the notifications row on a busy outbox"
kill "$LHOLD"; wait "$LHOLD" 2>/dev/null || true; trap "$KEEP_TRAP" EXIT; rm -rf "$OBX/.flush.lock"
beat; run "$MAIN" env TEAM_SESSIONS_CLAUDE_FLAGS="--permission-mode bypassPermissions" $SS preflight
expect 1 "\"crossSessionInbound\": \"accept\" to $HOME/.claude/settings.json" "(5) bypass without crossSessionInbound"
[ ! -e "$HOME/.claude/settings.json" ] || fail "(5) preflight wrote the user settings"
mkdir -p "$HOME/.claude"; echo '{"crossSessionInbound": "accept"}' > "$HOME/.claude/settings.json"
beat; run "$MAIN" env TEAM_SESSIONS_CLAUDE_FLAGS="--permission-mode bypassPermissions" $SS preflight
expect 0 "ok Claude Code" "(5) bypass with crossSessionInbound"
# With a Claude profile the check reads the profile's settings, not the inherited dir's.
mkdir -p "$WORK/claude-pf"; PF_REAL="$(cd "$WORK/claude-pf" && pwd -P)"
printf '%s\n' "$WORK/claude-pf" > "$MAIN/.claude/claude-profile"
beat; run "$MAIN" env TEAM_SESSIONS_CLAUDE_FLAGS="--permission-mode bypassPermissions" $SS preflight
expect 1 "\"crossSessionInbound\": \"accept\" to $PF_REAL/settings.json" "(5) bypass checks the Claude profile's settings"
echo '{"crossSessionInbound": "accept"}' > "$WORK/claude-pf/settings.json"
rm -f "$HOME/.claude/settings.json"
beat; run "$MAIN" env TEAM_SESSIONS_CLAUDE_FLAGS="--permission-mode bypassPermissions" $SS preflight
expect 0 "ok Claude Code" "(5) bypass with crossSessionInbound in the Claude profile"
rm -f "$MAIN/.claude/claude-profile"
rm -f "$HOME/.claude/settings.json"
# The socket check is team-watch-send.py's: same predicate, same wording; a refused socket fails.
chmod 644 "$SUP_SOCK"
beat; run "$MAIN" $SS preflight
expect 1 "FAIL receivers live — socket $SUP_SOCK refused mode 0644 — want mode 0600 owned by uid $(id -u)" "(5) refused socket"
chmod 600 "$SUP_SOCK"
mv "$TWD/receivers/Supervisor.json" "$WORK/sup-recv.keep"
beat; run "$MAIN" $SS preflight; has "WARN receivers live — Supervisor not started" "$WORK/out" \
  || fail "(5) a not-started Supervisor is not a WARN"
mv "$WORK/sup-recv.keep" "$TWD/receivers/Supervisor.json"
mv "$MAIN/.claude/team/sessions/operator-kit/install.sh" "$WORK/install.keep"
beat; run "$MAIN" $SS preflight; expect 1 "FAIL operator kit installed — not shipped" "(5) kit absent"
mv "$WORK/install.keep" "$MAIN/.claude/team/sessions/operator-kit/install.sh"
echo '{"permissions": {"allow": ["Bash(bash .claude/team/*)"]}}' > "$MAIN/.claude/settings.local.json"
beat; run "$MAIN" $SS preflight; expect 1 "FAIL role profiles — local allow leak (Operator: settings.local.json)" "(5) leak row"
rm -f "$MAIN/.claude/settings.local.json"
mkdir -p "$RD/questions"
printf 'role: coder\nattempt: 1\nkind: blocked\n\n## Summary\nx\n\n## Escalation\nstarted: 2026-10-19T10:00:00Z tier 2\n' \
  > "$RD/questions/q-9.md"
beat; run "$MAIN" $SS preflight; expect 1 "FAIL escalations have live waiters — alfa/q-9(escalating)" "(5) orphaned escalation"
rm -f "$RD/questions/q-9.md"
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

# ---- (7) the SQL guard lets every launcher verb through ------------------------------------------
for c in status preflight check reviewer "start all" "stop Supervisor" "materialize Supervisor" \
  "freeze on 1.4.0" "freeze off" "answer Advisor --fp 0123456789ab pick 2" rollback "here Supervisor" up; do
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
run "$MAIN" $W mode answering off; expect 0 "" "(9) answering off"
run "$MAIN" $SS rollback; expect 0 "Rollback: routing single Supervisor, answering on." "(9) rollback"
has "install.sh --rollback" "$WORK/out" || fail "(9) rollback lacks the Operator's kit step"
r9="$(cd "$MAIN" && bash -c '. .claude/lib/team-watch-lib.sh; tw_init "$PWD"; echo "$(tw_routing) / $(tw_answering)"')"
case "$r9" in "single Supervisor / on"*) ;; *) fail "(9) rollback did not switch routing/answering: $r9" ;; esac
echo "team-smoke-sessions: (9) rollback OK"
echo "team-smoke-sessions: OK"
