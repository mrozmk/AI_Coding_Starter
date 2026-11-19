#!/usr/bin/env bash
# The operator kit (it notifies nobody): the installer (dry-run, apply, verify, rollback, refusals,
# scheduler snippets), the out-of-repo health check and the role Stop hook
# — each against a fixture channel (registry, box, recipients) under a throwaway HOME with a space in
# its path. Stub binaries stand in for every platform tool (osascript, notify-send, tmux, pgrep,
# launchctl, crontab); nothing reads or writes the real ~/.agent-mail or talks to a tmux server.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
BG=""
trap 'for p in $BG; do kill "$p" 2>/dev/null || true; done
  [ -z "$SPID" ] || kill "$SPID" 2>/dev/null || true; rm -rf "$WORK"' EXIT
export HOME="$WORK/home dir"; mkdir -p "$HOME"
unset AGENT_MAIL_BOX CODEX_HOME TEAM_SESSION_ROLE
REG="$HOME/.agent-mail/projects.json"
LIB="$MAIN/.claude/lib"
OK_DIR=.claude/team/sessions/operator-kit
INST="bash $OK_DIR/install.sh"
M="bash .claude/lib/team-mail.sh QX"

# The checkout carries what /setup:teams installs: the tool, the templates, the kit, the hook.
mkdir -p "$MAIN/tools" "$MAIN/.claude/team/sessions"
cp -R "$SRC/tools/agent_mail" "$MAIN/tools/"; rm -rf "$MAIN/tools/agent_mail/tests"
find "$MAIN/tools" -name __pycache__ -prune -exec rm -rf {} +
cp "$SRC"/.claude/team/*.tmpl "$MAIN/.claude/team/"
cp -R "$SRC/$OK_DIR" "$MAIN/.claude/team/sessions/"
printf '__pycache__/\n' >> "$MAIN/.gitignore"
git -C "$MAIN" add -A && git -C "$MAIN" commit --quiet -m "kit fixture"
prof() { jq "$1" "$MAIN/.claude/project-profile.json" > "$WORK/p" && mv "$WORK/p" "$MAIN/.claude/project-profile.json"; }
prof '.teams.channel = {project_code: "QX", mail_suffix: "Qx", advisor: "pair"}'
run "$MAIN" bash .claude/lib/team-mail-setup.sh "$MAIN"; expect 0 "" "fixture: the channel step"
KIT="$(jq -r .kit_dir "$MAIN/.agents/team/channel.local.json")"
BOX="$(jq -r .box "$MAIN/.agents/team/channel.local.json")"
mailsum() { (cd "$(dirname "$BOX")" && shasum -a 256 mail.sqlite recipients.json); }

# Stubs: every platform tool logs its argv (a notifier binary must never be called); tmux/pgrep
# answer from fixture files.
SB="$WORK/kbin"; mkdir -p "$SB"
for b in osascript notify-send; do
  printf '#!/bin/bash\nprintf "%%s|" %s "$@" >> "%s/notify.log"; echo >> "%s/notify.log"\n' "$b" "$WORK" "$WORK" > "$SB/$b"
done
printf '#!/bin/bash\n[ "$1" = has-session ] && grep -qxF "${3#=}" "%s/up" 2>/dev/null\n' "$WORK" > "$SB/tmux"
printf '#!/bin/bash\nshift 2; grep -qE -- "$1" "%s/procs" 2>/dev/null\n' "$WORK" > "$SB/pgrep"
printf '#!/bin/bash\n[ "$1" = list ] && [ -f "%s/launchd" ] && grep -qxF "$2" "%s/launchd"\n' "$WORK" "$WORK" > "$SB/launchctl"
printf '#!/bin/bash\n[ "$1" = -l ] && cat "%s/crontab" 2>/dev/null; true\n' "$WORK" > "$SB/crontab"
chmod +x "$SB"/*
KP="$SB:$PATH"
nlog() { cat "$WORK/notify.log" 2>/dev/null || true; }

# ---- (I) the installer ------------------------------------------------------------------------
homesum() { find "$HOME" -type f -exec shasum -a 256 {} + | sort; }
mkdir -p "$KIT"; printf 'old health\n' > "$KIT/sessions-health.sh"   # a live file that predates the kit
printf 'old kit notifier\n' > "$KIT/notify.sh"   # an old kit's notifier: no longer the installer's
homesum > "$WORK/h0"; M0="$(mailsum)"
run "$MAIN" $INST --dry-run; expect 0 "" "(I) dry-run"
! has "escalate.sh" "$WORK/out" || fail "(I) the dry-run still names escalate.sh"
has "copy sessions-health.sh → $KIT/sessions-health.sh (backup $KIT/sessions-health.sh.bak-team-kit)" "$WORK/out" || fail "(I) dry-run backup line"
! has "notify.sh" "$WORK/out" || fail "(I) the dry-run still names notify.sh"
homesum > "$WORK/h1"; cmp -s "$WORK/h0" "$WORK/h1" || fail "(I) the dry-run changed a byte under HOME"
run "$MAIN" $INST --apply; expect 0 "installed $KIT/hooks/role-hooks.settings.json" "(I) apply"
[ ! -e "$KIT/escalate.sh" ] || fail "(I) apply installed the removed escalation adapter"
[ "$(grep -c '^installed ' "$WORK/out")" = 4 ] || fail "(I) apply installed $(grep -c '^installed ' "$WORK/out") targets"
[ "$(ls -ld "$KIT" | cut -c1-10)" = drwx------ ] || fail "(I) kit_dir is not mode 700"
[ -x "$KIT/sessions-health.sh" ] && [ -x "$KIT/hooks/mail-guard.sh" ] || fail "(I) scripts not executable"
jq -e --arg k "$KIT" '.hooks.Stop[0].hooks[0].command == "bash \"\($k)/hooks/mail-guard.sh\""
  and ([.hooks | keys[]] == ["Stop"])' "$KIT/hooks/role-hooks.settings.json" >/dev/null \
  || fail "(I) role-hooks.settings.json"
! grep -q '^NOTIFIER=' "$KIT/kit.conf" || fail "(I) kit.conf still carries NOTIFIER"
for want in PROJECT_CODE=QX SUPERVISOR_NAME=SupervisorQx LABEL=team.qx.sessions-health \
  "SESSIONS=main-supervisor main-teamlead main-advisor main-team-watch main-team-watch-dog" "KIT_DIR=$KIT"; do
  grep -qxF "$want" "$KIT/kit.conf" || { cp "$KIT/kit.conf" "$WORK/out"; fail "(I) kit.conf lacks $want"; }
done
run "$MAIN" $INST --verify; expect 0 "ok $KIT/kit.conf" "(I) verify clean"
echo tampered >> "$KIT/sessions-health.sh"
run "$MAIN" $INST --verify; expect 1 "differs $KIT/sessions-health.sh" "(I) verify sees a tampered copy"
run "$MAIN" $INST --apply; expect 0 "" "(I) re-apply"
[ "$(cat "$KIT/sessions-health.sh.bak-team-kit")" = "old health" ] || fail "(I) a re-apply replaced the first backup"
sed -i.x 's/^SUPERVISOR_NAME=.*/SUPERVISOR_NAME=Old/' "$KIT/kit.conf"; rm -f "$KIT/kit.conf.x"
run "$MAIN" $INST --verify; expect 1 "differs $KIT/kit.conf" "(I) verify sees a stale render"
run "$MAIN" $INST --apply; expect 0 "" "(I) re-apply after a stale render"
# A kit installed before the notification model: its hooks file still wires the removed hook.
jq '.hooks.Notification = [{matcher: "permission_prompt", hooks: [{type: "command", command: "bash x/supervisor-notify.sh"}]}]' \
  "$KIT/hooks/role-hooks.settings.json" > "$WORK/rh" && cp "$WORK/rh" "$KIT/hooks/role-hooks.settings.json"
run "$MAIN" $INST --verify; expect 1 "differs $KIT/hooks/role-hooks.settings.json" "(I) verify sees the old hooks file"
run "$MAIN" $INST --apply; expect 0 "" "(I) re-apply rewrites the old hooks file"
jq -e '.hooks | has("Notification") | not' "$KIT/hooks/role-hooks.settings.json" >/dev/null || fail "(I) re-apply kept Notification"
[ "$(cat "$KIT/notify.sh")" = "old kit notifier" ] && [ ! -e "$KIT/notify.sh.bak-team-kit" ] \
  || fail "(I) the installer touched an old kit notify.sh"
run "$MAIN" $INST --print-scheduler launchd; expect 0 "<string>team.qx.sessions-health</string>" "(I) launchd snippet"
has "<string>$KIT/sessions-health.sh</string>" "$WORK/out" || fail "(I) launchd snippet path"
run "$MAIN" $INST --print-scheduler cron; expect 0 "*/5 * * * * /bin/bash \"$KIT/sessions-health.sh\"" "(I) cron snippet"
# refusals: an unconfigured channel, an unsafe kit path, the kit in the mailbox dir — nothing written
CH="$MAIN/.agents/team/channel.local.json"; cp "$CH" "$WORK/ch.bak"
mv "$CH" "$WORK/ch.away"; run "$MAIN" $INST --verify; expect 3 "not configured" "(I) unconfigured"
mv "$WORK/ch.away" "$CH"
jq --arg k "$HOME/k\"x" '.kit_dir = $k' "$WORK/ch.bak" > "$CH"
run "$MAIN" $INST --apply; expect 1 "characters a hook command cannot carry" "(I) unsafe kit path"
[ ! -e "$HOME/k\"x" ] || fail "(I) wrote to an unsafe kit path"
jq --arg k "$(dirname "$BOX")" '.kit_dir = $k' "$WORK/ch.bak" > "$CH"
run "$MAIN" $INST --apply; expect 1 "kit_dir is the mailbox directory" "(I) kit in the mailbox dir"
[ ! -e "$(dirname "$BOX")/sessions-health.sh" ] || fail "(I) wrote into the mailbox dir"
cp "$WORK/ch.bak" "$CH"
# rollback: original restored, new files gone, no backup left
run "$MAIN" $INST --rollback; expect 0 "restored $KIT/sessions-health.sh" "(I) rollback"
[ "$(cat "$KIT/sessions-health.sh")" = "old health" ] || fail "(I) rollback did not restore the original"
[ "$(cat "$KIT/notify.sh")" = "old kit notifier" ] || fail "(I) rollback touched an old kit notify.sh"
[ ! -e "$KIT/kit.conf" ] && [ ! -e "$KIT/hooks/mail-guard.sh" ] \
  || fail "(I) rollback left a kit file"
[ -z "$(find "$KIT" -name '*.bak-team-kit*')" ] || fail "(I) rollback left a backup"
[ "$(mailsum)" = "$M0" ] || fail "(I) the kit touched the mailbox or recipients.json"
run "$MAIN" $INST --apply; expect 0 "" "(I) final apply for the next sections"
echo "team-smoke-kit: (I) installer OK"

# ---- (H) the health check ---------------------------------------------------------------------
hc() { run "$MAIN" env PATH="$KP" bash "$KIT/sessions-health.sh" "$@"; cat "$WORK/out" >> "$WORK/health.log"; }
printf '%s\n' main-supervisor main-teamlead main-advisor main-team-watch main-team-watch-dog > "$WORK/up"
: > "$WORK/notify.log"; : > "$WORK/procs"; : > "$WORK/health.log"
hc; expect 0 "" "(H) all up"
[ ! -s "$WORK/health.log" ] || fail "(H) logged an outage with everything up"
grep -vx main-advisor "$WORK/up" > "$WORK/up2"; mv "$WORK/up2" "$WORK/up"
hc; hc
[ "$(grep -c 'down: main-advisor$' "$WORK/health.log")" = 1 ] || { cp "$WORK/health.log" "$WORK/out"; fail "(H) one log line per outage"; }
echo main-advisor >> "$WORK/up"
hc; [ ! -s "$KIT/sessions-health.state" ] || [ -z "$(tr -d '\n' < "$KIT/sessions-health.state")" ] \
  || fail "(H) recovery did not clear the state"
[ "$(grep -c 'down' "$WORK/health.log")" = 1 ] || fail "(H) recovery logged an outage"
grep -vx main-supervisor "$WORK/up" > "$WORK/up2"; mv "$WORK/up2" "$WORK/up"
echo "claude --name SupervisorZz --model opus" > "$WORK/procs"
: > "$WORK/health.log"; hc
has "down: main-supervisor" "$WORK/health.log" || fail "(H) another project's Supervisor counted as up"
echo "claude --name SupervisorQx --model opus" > "$WORK/procs"
hc; [ "$(tr -d '\n' < "$KIT/sessions-health.state")" = "" ] || fail "(H) here-mode Supervisor not counted as up"
hc --scheduled; expect 1 "scheduled: none" "(H) not scheduled"
echo "*/5 * * * * /bin/bash \"$KIT/sessions-health.sh\"" > "$WORK/crontab"
hc --scheduled; expect 0 "scheduled: cron" "(H) cron"
rm -f "$WORK/crontab"
if [ "$(uname -s)" = Darwin ]; then
  echo team.qx.sessions-health > "$WORK/launchd"
  hc --scheduled; expect 0 "scheduled: launchd team.qx.sessions-health" "(H) launchd"
fi
[ ! -s "$WORK/notify.log" ] || { nlog > "$WORK/out"; fail "(H) the health check called a notifier binary"; }
echo "team-smoke-kit: (H) health check OK"

# ---- (G) the role Stop hook -------------------------------------------------------------------
GUARD="$KIT/hooks/mail-guard.sh"
guard() {  # guard <role or -> [project dir]
  local r="$1" d="${2:-$MAIN}"
  if [ "$r" = - ]; then run "$MAIN" env -u TEAM_SESSION_ROLE CLAUDE_PROJECT_DIR="$d" bash "$GUARD" <<<'{}'
  else run "$MAIN" env TEAM_SESSION_ROLE="$r" CLAUDE_PROJECT_DIR="$d" bash "$GUARD" <<<'{}'; fi
}
run "$MAIN" $M send --from AdvisorQx --to SupervisorQx --kind turn --thread esc-r1-q-9 --body x
guard Supervisor; expect 0 "" "(G) esc- only"; [ ! -s "$WORK/out" ] || fail "(G) blocked on an esc- turn"
run "$MAIN" $M send --from Advisor --to Supervisor --kind turn --thread other --body x
guard Supervisor; [ ! -s "$WORK/out" ] || fail "(G) blocked on another project's recipient"
run "$MAIN" $M send --from AdvisorQx --to SupervisorQx --kind turn --thread work-1 --body x
guard Supervisor; expect 0 "Unread agent-mail turn for SupervisorQx" "(G) unread turn blocks"
jq -e '.decision == "block"' "$WORK/out" >/dev/null || fail "(G) not a block decision"
# The retired global TeamLead holds nothing, whatever its mail.
run "$MAIN" $M send --from SupervisorQx --to TeamLeadQx --kind turn --thread work-2 --body x
guard TeamLead; expect 0 "" "(G) TeamLead"; [ ! -s "$WORK/out" ] || fail "(G) the retired TeamLead was held"
guard Advisor; [ ! -s "$WORK/out" ] || fail "(G) the Advisor was held"
guard -; [ ! -s "$WORK/out" ] || fail "(G) a role-less window was held"
mkdir -p "$WORK/fakeclone/.agents/team"; echo '{}' > "$WORK/fakeclone/.agents/team/team.json"
guard Supervisor "$WORK/fakeclone"; [ ! -s "$WORK/out" ] || fail "(G) a clone was held"
mv "$CH" "$WORK/ch.away"; guard Supervisor; [ ! -s "$WORK/out" ] || fail "(G) held without a channel"
mv "$WORK/ch.away" "$CH"
# the team-watch and monitoring layers, stubbed: pending batches, a paused Supervisor
cp "$LIB/team-watch.sh" "$WORK/tw.real"
printf '#!/bin/bash\n# Usage: bash .claude/lib/team-watch.sh pending <role> [<since>] | status\necho "$*" >> "%s/tw.log"\n[ "$1" = pending ] && echo 7\nexit 0\n' "$WORK" > "$LIB/team-watch.sh"
guard Supervisor; expect 0 "Unacked team-watch message(s) for Supervisor: 7" "(G) pending blocks"
mkdir -p "$MAIN/.claude/team/sessions"
echo '{"roles": {"Supervisor": {"pause": {"pass": {"mail_threads": ["incident-"]}}}}}' > "$MAIN/.claude/team/sessions/monitoring.json"
printf '#!/bin/bash\n[ "$1" = paused ] && echo "2026-11-04T08:00:00Z (Operator)"\n' > "$LIB/monitoring.sh"
run "$MAIN" $M send --from TeamLeadQx --to SupervisorQx --kind turn --thread chat-1 --body x
run "$MAIN" $M send --from TeamLeadQx --to SupervisorQx --kind turn --thread incident-1 --body x
guard Supervisor; expect 0 "thread=incident-1" "(G) a paused Supervisor holds its pass threads"
! has "thread=chat-1" "$WORK/out" || fail "(G) a paused role was held on a routine thread"
grep -q '^pending Supervisor 2026-11-04T08:00:00Z$' "$WORK/tw.log" || fail "(G) the pause since was not passed"
# An older team-watch.sh (no pending/status in its usage) takes any word as a team name and polls
# forever: the guard must not call it at all. The stand-in logs every call, so a call is seen even
# if a timeout would have ended it.
rm -f "$LIB/monitoring.sh" "$MAIN/.claude/team/sessions/monitoring.json"
printf '#!/bin/bash\n# Usage: bash .claude/lib/team-watch.sh <team>...\necho "$*" >> "%s/tw-old.log"\nexit 0\n' \
  "$WORK" > "$LIB/team-watch.sh"
guard Supervisor; expect 0 "thread=chat-1" "(G) an older team-watch.sh: the unread turn still blocks"
[ ! -s "$WORK/tw-old.log" ] || fail "(G) the guard called an older team-watch.sh: $(cat "$WORK/tw-old.log")"
cp "$WORK/tw.real" "$LIB/team-watch.sh"
guard Supervisor; expect 0 "thread=chat-1" "(G) the real team-watch.sh, no batch pending: only the mail holds"
echo "team-smoke-kit: (G) stop hook OK"

echo "team-smoke-kit: OK"
