#!/usr/bin/env bash
# Role sessions: the SessionStart directive hook, the launcher (names, env, models, profiles), the
# role profiles and their check, the tier-1 `answer` into a role prompt (team-answer.sh --session),
# preflight, the Reviewer deliver check, the SQL guard over the launcher verbs, status, `up` after
# a restart and the rollback.
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
unset TEAM_SESSIONS_CLAUDE_FLAGS CODEX_HOME AGENT_MAIL_BOX TEAM_NOTIFIER
ROLES_TMUX="smk-supervisor smk-teamlead smk-advisor"
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
CHK="python3 -I .claude/lib/session_profile_check.py"
HOOKF="$MAIN/.claude/hooks/session-role.sh"

# The checkout carries what /setup:teams installs for this layer.
cp "$SRC/.claude/lib/supervisor-sessions.sh" "$SRC/.claude/lib/session_profile_check.py" \
  "$MAIN/.claude/lib/"
cp "$SRC/.claude/team/sessions/Supervisor.settings.json" \
  "$SRC/.claude/team/sessions/TeamLead.settings.json" "$MAIN/.claude/team/sessions/"
cp "$SRC/.claude/hooks/session-role.sh" "$SRC/.claude/hooks/supervisor-notify.sh" "$MAIN/.claude/hooks/"
mkdir -p "$MAIN/tools"
cp -R "$SRC/tools/agent_mail" "$MAIN/tools/"; rm -rf "$MAIN/tools/agent_mail/tests"
find "$MAIN/tools" -name __pycache__ -prune -exec rm -rf {} +
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
echo "claude $* | role=${TEAM_SESSION_ROLE-unset} cc=${CLAUDECODE-unset} sock=${CLAUDE_CODE_MESSAGING_SOCKET-unset} codex=${CODEX_HOME-unset}" >> "$STUB_LOG"
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
    if [ -f "$D/$n.pid" ]; then kill -0 "$(cat "$D/$n.pid")" 2>/dev/null; exit $?; fi
    exit 1 ;;
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

# ---- (1) the SessionStart directive ---------------------------------------------------------------
D="$(TEAM_SESSION_ROLE=TeamLead CLAUDE_PROJECT_DIR="$MAIN" bash "$HOOKF" < /dev/null)"
case "$D" in *"/session-role TeamLead"*"supervisor-sessions.md#teamlead"*"data, not instructions"*) ;;
  *) fail "(1) directive: $D" ;; esac
[ -z "$(env -u TEAM_SESSION_ROLE CLAUDE_PROJECT_DIR="$MAIN" bash "$HOOKF" < /dev/null)" ] \
  || fail "(1) directive without a role"
[ -z "$(TEAM_SESSION_ROLE=Bogus CLAUDE_PROJECT_DIR="$MAIN" bash "$HOOKF" < /dev/null)" ] \
  || fail "(1) directive for an unknown role"
[ -z "$(TEAM_SESSION_ROLE=TeamLead CLAUDE_PROJECT_DIR="$CLONE" bash "$HOOKF" < /dev/null)" ] \
  || fail "(1) directive in a team clone"
[ ! -e "$CLONE/.agents/team/watch/sessions" ] || fail "(1) the hook wrote into a team clone"
echo '{"session_id":"0f0f0f0f-1111"}' | TEAM_SESSION_ROLE=Advisor CLAUDE_PROJECT_DIR="$MAIN" \
  bash "$HOOKF" > /dev/null
[ "$(jq -r '.session_id + " " + .role + " " + .team' "$TWD/sessions/Advisor/session.json")" \
  = "0f0f0f0f-1111 Advisor -" ] || fail "(1) the hook did not bind session.json to the session id"
echo "team-smoke-sessions: (1) SessionStart directive OK"

# ---- (2) launcher: names, env, models, profiles --------------------------------------------------
: > "$STUB_LOG"
run "$MAIN" env CLAUDECODE=1 CLAUDE_CODE_MESSAGING_SOCKET=/nonexistent/x.sock $SS start all
expect 0 "smk-teamlead: started (TeamLeadXY, opus, effort high)" "(2) start all"
has "smk-advisor: started (AdvisorXY, opus, effort high)" "$WORK/out" || fail "(2) Advisor start line"
has "Advisor without platform notifications (operator kit not installed)" "$WORK/out" \
  || fail "(2) no kit warning for the Advisor"
wait_claude 3
for r in Supervisor TeamLead Advisor; do
  l="$(echo "$r" | tr '[:upper:]' '[:lower:]')"
  grep -q "^tmux new-session -d -s smk-$l -c .* -e TEAM_SESSION_ROLE=$r " "$STUB_LOG" \
    || { cp "$STUB_LOG" "$WORK/out"; fail "(2) $r: tmux name or role env"; }
  sid="$(jq -r .session_id "$TWD/sessions/$r/session.json")"
  [[ "$sid" =~ ^[0-9a-f-]{36}$ ]] || fail "(2) $r: session.json session_id $sid"
  grep -q "^claude --name ${r}XY --session-id $sid --model opus " "$STUB_LOG" \
    || { cp "$STUB_LOG" "$WORK/out"; fail "(2) $r: --name with the suffix and the bound session id"; }
  grep "^claude --name ${r}XY " "$STUB_LOG" | grep -q " /session-role $r | role=$r cc=unset sock=unset " \
    || { cp "$STUB_LOG" "$WORK/out"; fail "(2) $r: launch prompt, role env or a leaked CLAUDECODE/socket"; }
done
has "claude --name SupervisorXY --session-id " "$STUB_LOG" || fail "(2) Supervisor"
grep "^claude --name SupervisorXY " "$STUB_LOG" | grep -q -- "--effort medium --settings .agents/team/watch/profiles/Supervisor.settings.json " \
  || fail "(2) Supervisor effort or profile"
grep "^claude --name TeamLeadXY " "$STUB_LOG" | grep -q -- "--effort high --settings .agents/team/watch/profiles/TeamLead.settings.json " \
  || fail "(2) TeamLead effort or profile"
grep "^claude --name AdvisorXY " "$STUB_LOG" | grep -q -- "--effort high /session-role Advisor |" \
  || { cp "$STUB_LOG" "$WORK/out"; fail "(2) Advisor: effort, or --settings without a kit"; }
run "$MAIN" $SS start TeamLead; expect 0 "smk-teamlead: already running" "(2) idempotent start"
PF="$TWD/profiles/TeamLead.settings.json"
[ "$(stat -f %Lp "$PF")" = 600 ] && [ "$(stat -f %Lp "$TWD/profiles")" = 700 ] \
  || fail "(2) materialised profile not 600 in a 700 dir"
jq -e --arg c "Read(//$(dirname "$MP" | sed 's|^/||')/main-*/**)" \
  '(.permissions.allow | index($c)) and (tostring | contains("{{CLONES}}") | not)
   and .env.TEAM_SESSION_ROLE == "TeamLead"
   and (.permissions.deny | index("Bash(az repos pr update*)"))
   and (.permissions.deny | index("Bash(gh pr merge*)") | not)' "$PF" >/dev/null \
  || { cp "$PF" "$WORK/out"; fail "(2) materialised TeamLead: clones, env or the azure-devops PR deny"; }
jq -e '.permissions.deny | index("Bash(az repos pr update*)") | not' \
  "$TWD/profiles/Supervisor.settings.json" >/dev/null || fail "(2) the PR deny reached the Supervisor"
for r in Supervisor TeamLead Advisor; do run "$MAIN" $SS stop "$r"; expect 0 "stopped" "(2) stop $r"; done
run "$MAIN" $SS stop all; expect 2 "" "(2) stop all refused"
run "$CLONE" bash "$MAIN/.claude/lib/supervisor-sessions.sh" status; expect 1 "team clone" "(2) launcher in a clone"
# Per-role config; the TeamLead's high must not leak into the next role of the loop.
prof '.teams.sessions = {Advisor: {model: "custom-model[1m]", effort: "low"}, Supervisor: {effort: "max"}}'
: > "$STUB_LOG"
run "$MAIN" $SS start all; expect 0 "smk-advisor: started (AdvisorXY, custom-model[1m], effort low)" "(2) teams.sessions"
wait_claude 3
grep "^claude --name SupervisorXY " "$STUB_LOG" | grep -q -- "--model opus --effort max " || fail "(2) Supervisor effort from config"
grep "^claude --name TeamLeadXY " "$STUB_LOG" | grep -q -- "--model opus --effort high " || fail "(2) TeamLead default"
for r in Supervisor TeamLead Advisor; do run "$MAIN" $SS stop "$r"; done
prof '.teams.sessions = {TeamLead: {effort: "huge"}}'
run "$MAIN" $SS start TeamLead; expect 2 "teams.sessions.TeamLead.effort=huge" "(2) bad effort refused"
prof 'del(.teams.sessions)'
echo "team-smoke-sessions: (2) launcher OK"

# ---- (3) profiles and their check ----------------------------------------------------------------
run "$SRC" $CHK "$SRC"; expect 0 "TeamLead OK" "(3) shipped profiles"
has "Supervisor OK" "$WORK/out" || fail "(3) shipped Supervisor"
PY_ROLES="$(sed -n 's/^ROLES = (\(.*\))$/\1/p' "$SRC/.claude/lib/session_profile_check.py" | tr -d '",')"
SH_ROLES="$(bash -c '. "$1/.claude/lib/team-watch-route.sh"; echo "$TW_ROLES"' _ "$SRC")"
[ "$PY_ROLES" = "$SH_ROLES" ] || fail "(3) ROLES ($PY_ROLES) != TW_ROLES ($SH_ROLES)"
run "$MAIN" $CHK "$MAIN" TeamLead; expect 0 "TeamLead OK" "(3) materialised"
FLOOR="$(jq '.permissions.deny | length' "$MAIN/.claude/settings.json")"
[ "$(jq '.permissions.deny | length' "$PF")" -gt "$FLOOR" ] || fail "(3) materialised profile lacks the project denies"
jq '.permissions.deny |= .[1:]' "$PF" > "$WORK/p" && mv "$WORK/p" "$PF"
run "$MAIN" $CHK "$MAIN" TeamLead; expect 1 "lost 1 deny rules" "(3) materialised profile lost the floor"
run "$MAIN" $SS materialize TeamLead; expect 0 "profile TeamLead:" "(3) re-materialise"
echo '{"permissions": {"deny": ["Bash(local-only-deny *)"]}}' > "$MAIN/.claude/settings.local.json"
run "$MAIN" $SS materialize TeamLead
jq -e '.permissions.deny | index("Bash(local-only-deny *)")' "$PF" >/dev/null || fail "(3) local deny not unioned"
run "$MAIN" $CHK "$MAIN"; expect 1 "Supervisor FAIL: materialised profile lost 1 deny rules" "(3) a stale profile misses the local deny"
echo '{"permissions": {"allow": ["Bash(bash .claude/team/*)"]}}' > "$MAIN/.claude/settings.local.json"
run "$MAIN" $SS materialize TeamLead
run "$MAIN" $SS check
expect 3 "TeamLead LEAK: bash .claude/team/sessions/operator-kit/install.sh --apply allowed by local Bash(bash .claude/team/*)" "(3) local leak"
grep -q ' FAIL:' "$WORK/out" && fail "(3) a local leak reported as FAIL"
: > "$STUB_LOG"
run "$MAIN" $SS start TeamLead; expect 3 "nothing launched" "(3) start refuses a leak"
grep -q '^tmux new-session' "$STUB_LOG" && fail "(3) a refused start launched a session"
rm -f "$MAIN/.claude/settings.local.json"
jq '.permissions.allow += ["Bash(rm *)"] | ._samples.writes += ["rm x"]' \
  "$MAIN/.claude/team/sessions/TeamLead.settings.json" > "$WORK/tl.json"
mkdir -p "$WORK/profiles"; cp "$WORK/tl.json" "$WORK/profiles/TeamLead.settings.json"
rm -f "$PF"
run "$MAIN" $CHK "$MAIN" --profiles "$WORK/profiles" TeamLead; expect 1 "rm x → allow, expected not allow" "(3) write allowed"
# Provider-driven PR deny.
prof '.teams.pr_provider = "none"'
run "$MAIN" $SS materialize TeamLead; expect 0 "" "(3) materialize, provider none"
jq -e '[.permissions.deny[] | select(test("pr (merge|edit|update)"))] | length == 0' "$PF" >/dev/null \
  || fail "(3) provider none still carries a PR deny"
prof '.teams.pr_provider = "github" | .teams.github = {repo: "acme/widgets"}'
run "$MAIN" $SS materialize TeamLead; expect 0 "" "(3) materialize, provider github"
jq -e '(.permissions.deny | index("Bash(gh pr merge*)")) and (.permissions.deny | index("Bash(gh pr edit*)"))
  and (.permissions.deny | index("Bash(az repos pr update*)") | not)' "$PF" >/dev/null \
  || { cp "$PF" "$WORK/out"; fail "(3) provider github PR deny"; }
prof '.teams.pr_provider = "azure-devops" | del(.teams.github)'
# The kit's role-hooks file gives Notification and Stop only — never PreToolUse, never permissions.
run "$MAIN" bash .claude/team/sessions/operator-kit/install.sh --apply; expect 0 "" "(3) kit --apply"
RH="$KIT/hooks/role-hooks.settings.json"
cp "$RH" "$WORK/rh.keep"
jq '.hooks.PreToolUse = [{matcher: "Bash", hooks: [{type: "command", command: "approve-all"}]}]
  | .hooks.PermissionRequest = [{hooks: [{type: "command", command: "approve-all"}]}]
  | .permissions = {allow: ["Bash(*)"]}' "$WORK/rh.keep" > "$RH"
for r in Supervisor TeamLead; do
  run "$MAIN" $SS materialize "$r"; expect 0 "" "(3) materialize $r with the kit"
  jq -e '(.hooks | keys) == ["Notification", "Stop"] and (.permissions.allow | index("Bash(*)") | not)
    and (tostring | contains("approve-all") | not)' "$TWD/profiles/$r.settings.json" >/dev/null \
    || { cp "$TWD/profiles/$r.settings.json" "$WORK/out"; fail "(3) $r took more than Notification/Stop from the kit"; }
done
cp "$WORK/rh.keep" "$RH"
echo "team-smoke-sessions: (3) profiles OK"

# ---- (4) answer: the tier-1 path into a role session's own prompt ---------------------------------
export STUB_PANE_DIR="$WORK/panes"; mkdir -p "$STUB_PANE_DIR"
: > "$STUB_LOG"
run "$MAIN" $SS start TeamLead; expect 0 "smk-teamlead: started" "(4) start TeamLead"
grep "^claude --name TeamLeadXY" "$STUB_LOG" >/dev/null || wait_claude 1
SID="$(jq -r .session_id "$TWD/sessions/TeamLead/session.json")"
cp "$FIX/menu-phase0.txt" "$STUB_PANE_DIR/smk-teamlead"
FP="$(role_prompt TeamLead | cut -f2)"
[ "$(role_prompt TeamLead | cut -f1)" = menu ] && [[ "$FP" =~ ^[0-9a-f]{12}$ ]] \
  || fail "(4) role prompt: $(role_prompt TeamLead)"
T="$HOME/.claude/projects/$(echo "$MP" | sed 's/[^A-Za-z0-9]/-/g')/$SID.jsonl"
mkdir -p "$(dirname "$T")"; cp "$FIX/t-menu-pending.jsonl" "$T"
: > "$STUB_LOG"
run "$MAIN" $SS answer TeamLead --fp 000000000000 pick 2; expect 1 "stale:" "(4) wrong fp"
run "$MAIN" env TEAM_SESSION_ROLE=TeamLead $SS answer TeamLead --fp "$FP" pick 2
expect 1 "never answers a role prompt" "(4) a role session answering"
run "$MAIN" $SS answer TeamLead --fp "$FP" yes; expect 1 "does not fit a menu" "(4) yes on a menu"
run "$MAIN" bash .claude/lib/team-answer.sh smk teamlead pick 2 --session TeamLead --clone "$CLONE"
expect 2 "exclude each other" "(4) --session with --clone"
mv "$TWD/sessions/TeamLead/session.json" "$WORK/sj.keep"
run "$MAIN" $SS answer TeamLead --fp "$FP" pick 2; expect 5 "no readable session.json" "(4) no session.json"
mv "$WORK/sj.keep" "$TWD/sessions/TeamLead/session.json"
no_keys "(4) refusals"
export STUB_ON_ENTER="jq -cn '{type: \"user\", uuid: \"u-done\", message: {content: [{type: \"tool_result\", tool_use_id: \"toolu_01menu\"}]}}' >> '$T'"
run "$MAIN" $SS answer TeamLead --fp "$FP" pick 2
expect 0 "answered TeamLead pick (fp $FP)" "(4) pick through team-answer.sh --session"
has "confirmed: yes (tool_result)" "$WORK/out" || fail "(4) the answer was not confirmed from the role's transcript"
[ "$(grep -c '^tmux send-keys -t %smk-teamlead Down' "$STUB_LOG")" = 1 ] \
  && has "tmux send-keys -t %smk-teamlead Enter" "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(4) pick keys"; }
unset STUB_ON_ENTER
printf 'Bash command\n  cat .env\nDo you want to proceed?\n❯ 1. Yes\n' > "$STUB_PANE_DIR/smk-teamlead"
FP2="$(role_prompt TeamLead | cut -f2)"
: > "$STUB_LOG"
run "$MAIN" $SS answer TeamLead --fp "$FP2" yes; expect 1 "Operator action:" "(4) ask-tier command"
run "$MAIN" $SS answer TeamLead --fp "$FP2" pick 1; expect 1 "does not fit a permission" "(4) pick on a permission"
no_keys "(4) policy refusals"
printf 'Bash command\n  bash .claude/lib/team-mail.sh --here inbox --for TeamLead --unread\nDo you want to proceed?\n❯ 1. Yes\n' \
  > "$STUB_PANE_DIR/smk-teamlead"
FP3="$(role_prompt TeamLead | cut -f2)"
run "$MAIN" $SS answer TeamLead --fp "$FP3" yes; expect 0 "answered TeamLead yes (fp $FP3)" "(4) tier 1 yes"
has "tmux send-keys -t =smk-teamlead: Enter" "$STUB_LOG" || fail "(4) Enter not sent"
: > "$STUB_LOG"
run "$MAIN" $SS answer TeamLead --fp "$FP3" no "out of scope"; expect 0 "answered TeamLead no" "(4) no"
has "Rejected by the Supervisor: out of scope. Do not work around it" "$STUB_LOG" || fail "(4) rejection text"
holder; echo "$H" > "$TMUXD/smk-supervisor.pid"
run "$MAIN" $SS here Supervisor; expect 1 "runs in tmux" "(4) here while tmux runs"
echo dead > "$TMUXD/smk-supervisor.pid"
: > "$STUB_LOG"
run "$MAIN" env STUB_CLAUDE_EXIT=1 CLAUDECODE=1 $SS here Supervisor; expect 0 "" "(4) here"
grep -q "^claude --name SupervisorXY --session-id [0-9a-f-]* --model opus --effort medium --settings .agents/team/watch/profiles/Supervisor.settings.json | role=Supervisor cc=unset" \
  "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(4) here did not exec claude as the Supervisor"; }
rm -f "$STUB_PANE_DIR/smk-teamlead"; run "$MAIN" $SS stop TeamLead
echo "team-smoke-sessions: (4) answer OK"

# ---- (5) preflight -------------------------------------------------------------------------------
mkrole SUP; mkrole TEAM
mailcfg true
run "$MAIN" $W routing split; expect 0 "" "(5) routing split"
as Supervisor SUP $W register; as TeamLead TEAM $W register; expect 0 "TeamLead registered" "(5) register"
for r in Supervisor TeamLead; do
  tag=SUP; [ "$r" = Supervisor ] || tag=TEAM
  run "$MAIN" $W ping "$r"; wait_recv "$tag" "PING $r" 15
  for n in $(cd "$MAIN" && $W pending "$r"); do run "$MAIN" env TEAM_SESSION_ROLE="$r" $W ack "$n"; done
done
beat() { echo "$(date -u +%s) 1 v$TWV" > "$TWD/beat"; echo "$(date -u +%s) 1 v$TWV" > "$TWD/dog.beat"; }
beat; run "$MAIN" $SS preflight; expect 0 "ok receivers live" "(5) preflight green"
grep -q '^FAIL' "$WORK/out" && fail "(5) preflight green printed a FAIL"
[ "$(grep -cE '^(ok|WARN|FAIL) ' "$WORK/out")" = 10 ] || fail "(5) preflight must print 10 rows"
for row in "ok team-watch loops beating" "ok escalations have live waiters" \
  "ok mail probe and picked ping per role" "ok team channel loads" "ok operator kit installed" \
  "ok role profiles" "ok notifier: osascript ok" \
  "ok health check: none — declared loss: a dead tmux server is noticed by nobody" \
  "ok Claude Code 2.1.301 — unverified: run team-watch.sh ping <role>"; do
  has "$row" "$WORK/out" || fail "(5) row: $row"
done
beat; run "$MAIN" env STUB_CLAUDE_VERSION=2.1.318 $SS preflight
expect 0 "ok Claude Code 2.1.318 — socket wire format verified on 2.1.318" "(5) verified CLI"
prof '.teams.channel.notifier = "none"'
# kit.conf carries the notifier, so the kit row shows the drift until the next --apply; the
# notifier row itself stays ok, with the loss spelled out.
beat; run "$MAIN" $SS preflight; expect 1 "ok notifier: none — declared loss" "(5) notifier none is an ok row"
has "FAIL operator kit installed — install.sh --verify exit 1" "$WORK/out" || fail "(5) kit drift after a notifier change"
prof '.teams.channel.notifier = "osascript"'
beat; run "$MAIN" env TEAM_SESSIONS_CLAUDE_FLAGS="--permission-mode bypassPermissions" $SS preflight
expect 1 "\"crossSessionInbound\": \"accept\" to $HOME/.claude/settings.json" "(5) bypass without crossSessionInbound"
[ ! -e "$HOME/.claude/settings.json" ] || fail "(5) preflight wrote the user settings"
mkdir -p "$HOME/.claude"; echo '{"crossSessionInbound": "accept"}' > "$HOME/.claude/settings.json"
beat; run "$MAIN" env TEAM_SESSIONS_CLAUDE_FLAGS="--permission-mode bypassPermissions" $SS preflight
expect 0 "ok Claude Code" "(5) bypass with crossSessionInbound"
rm -f "$HOME/.claude/settings.json"
# The socket check is team-watch-send.py's: same predicate, same wording; a refused socket fails.
chmod 644 "$SUP_SOCK"
beat; run "$MAIN" $SS preflight
expect 1 "FAIL receivers live — socket $SUP_SOCK refused mode 0644 — want mode 0600 owned by uid $(id -u)" "(5) refused socket"
run "$MAIN" $SS status; expect 0 "receiver Supervisor: pid $SUP_PID · socket refused mode 0644 · active" "(5) status socket state"
chmod 600 "$SUP_SOCK"
mv "$TWD/receivers/TeamLead.json" "$WORK/tl-recv.keep"
beat; run "$MAIN" $SS preflight; expect 0 "WARN receivers live — TeamLead not started" "(5) not-started role is a WARN"
mv "$WORK/tl-recv.keep" "$TWD/receivers/TeamLead.json"
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
run "$MAIN" $SS status; expect 0 "receiver: n/a (agent-mail)" "(6) status Advisor line"
has "  Reviewer: deliver ok" "$WORK/out" || fail "(6) status reviewer line"
kill "$FA" "$FB" 2>/dev/null || true
prof '.teams.channel.advisor = "solo"'
run "$MAIN" $SS reviewer; expect 0 "Reviewer: none (advisor solo)" "(6) solo"
prof '.teams.channel.advisor = "pair"'
echo "team-smoke-sessions: (6) reviewer OK"

# ---- (7) the SQL guard lets every launcher verb through ------------------------------------------
for c in status preflight check reviewer "start all" "stop TeamLead" "materialize TeamLead" \
  "freeze on 1.4.0" "freeze off" "answer TeamLead --fp 0123456789ab pick 2" rollback "here Supervisor" up; do
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

# ---- (9) status, up after a restart, rollback ----------------------------------------------------
named() {  # named <claude argv> — a process that pgrep -f sees as that role's claude → NP
  bash -c 'exec -a "$1" sleep 300' _ "$1" & NP=$!; PIDS="$PIDS $NP"; sleep 0.3
}
for r in Supervisor TeamLead Advisor; do run "$MAIN" $SS stop "$r"; done
kill_roles
run "$MAIN" $SS status; expect 0 "Supervisor: tmux smk-supervisor down" "(9) status: a stopped role"
for l in "TeamLead: tmux smk-teamlead down" "Advisor: tmux smk-advisor down" "routing: split" \
  "freeze: off" "teams: alfa"; do
  has "$l" "$WORK/out" || fail "(9) status lacks '$l'"
done
for re in '^team-watch: (works|not working)$' '^tiers: ' '^answering: '; do
  grep -qE "$re" "$WORK/out" || fail "(9) status lacks a line matching $re"
done
: > "$STUB_LOG"
run "$MAIN" $SS up; expect 0 "Close this bootstrap session if it is not a role session." "(9) up"
for l in "Supervisor: started" "TeamLead: started" "Advisor: started" "Reviewer: deliver missing" \
  "  tmux attach -t smk-supervisor" "  tmux attach -t smk-teamlead" "  tmux attach -t smk-advisor"; do
  has "$l" "$WORK/out" || fail "(9) up lacks '$l'"
done
grep -qE '^team-watch: (works|not working)' "$WORK/out" || fail "(9) up: no team-watch line"
grep -qE '^interrupted run' "$WORK/out" || fail "(9) up: no interrupted-runs line"
wait_claude 3
! grep -q -- '--resume' "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(9) up resumed a session"; }
run "$MAIN" $SS status; expect 0 "TeamLead: tmux smk-teamlead alive" "(9) status after up"
# The stub claude is `sleep`, never a `claude --name …` process: a live tmux session reads as the
# dead `; read` pane of a crashed claude until a process carries the role's name.
named "claude --name TeamLeadXY --session-id x"; TLP=$NP
: > "$STUB_LOG"
run "$MAIN" $SS up; expect 0 "TeamLead: already running" "(9) up keeps a running role"
has "Advisor: restarted (dead pane)" "$WORK/out" || fail "(9) up did not replace a dead pane"
grep -qx 'tmux kill-session -t =smk-advisor' "$STUB_LOG" || fail "(9) the dead pane was not killed"
! grep -qx 'tmux kill-session -t =smk-teamlead' "$STUB_LOG" || fail "(9) up killed a running role"
kill "$TLP" 2>/dev/null || true; wait "$TLP" 2>/dev/null || true
# The Supervisor in a `here` window: no tmux session, its claude by name → not started again.
run "$MAIN" $SS stop Supervisor
named "claude --name SupervisorXY --model opus"; SPP=$NP
run "$MAIN" $SS up; expect 0 "Supervisor: running (here)" "(9) up and a here Supervisor"
kill "$SPP" 2>/dev/null || true; wait "$SPP" 2>/dev/null || true
kill_roles
run "$MAIN" $W mode answering off; expect 0 "" "(9) answering off"
run "$MAIN" $SS rollback; expect 0 "Rollback: routing single Supervisor, answering on." "(9) rollback"
has "install.sh --rollback" "$WORK/out" || fail "(9) rollback lacks the Operator's kit step"
run "$MAIN" $SS status
has "routing: single Supervisor" "$WORK/out" && has "answering: on" "$WORK/out" \
  || fail "(9) rollback did not switch routing/answering"
echo "team-smoke-sessions: (9) status, up, rollback OK"
echo "team-smoke-sessions: OK"
