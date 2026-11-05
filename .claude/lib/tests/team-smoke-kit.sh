#!/usr/bin/env bash
# The operator kit: the notifier, the installer (dry-run, apply, verify, rollback, refusals,
# scheduler snippets), the out-of-repo health check, the role Stop hook and the escalation adapter
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
unset AGENT_MAIL_BOX CODEX_HOME TEAM_SESSION_ROLE TEAM_NOTIFIER TEAM_NOTIFY_SOUND TEAM_NOTIFY_SOUND_ALARM
REG="$HOME/.agent-mail/projects.json"
LIB="$MAIN/.claude/lib"
OK_DIR=.claude/team/sessions/operator-kit
INST="bash $OK_DIR/install.sh"
ESCF="$MAIN/.agents/team/escalation.local.json"
M="bash .claude/lib/team-mail.sh QX"

# The checkout carries what /setup:teams installs: the tool, the templates, the kit, the hook.
mkdir -p "$MAIN/tools" "$MAIN/.claude/team/sessions"
cp -R "$SRC/tools/agent_mail" "$MAIN/tools/"; rm -rf "$MAIN/tools/agent_mail/tests"
find "$MAIN/tools" -name __pycache__ -prune -exec rm -rf {} +
cp "$SRC"/.claude/team/*.tmpl "$MAIN/.claude/team/"
cp -R "$SRC/$OK_DIR" "$MAIN/.claude/team/sessions/"
cp "$SRC/.claude/hooks/supervisor-notify.sh" "$MAIN/.claude/hooks/"
printf '__pycache__/\n' >> "$MAIN/.gitignore"
git -C "$MAIN" add -A && git -C "$MAIN" commit --quiet -m "kit fixture"
prof() { jq "$1" "$MAIN/.claude/project-profile.json" > "$WORK/p" && mv "$WORK/p" "$MAIN/.claude/project-profile.json"; }
prof '.teams.channel = {project_code: "QX", mail_suffix: "Qx", advisor: "pair", notifier: "osascript"}'
run "$MAIN" bash .claude/lib/team-mail-setup.sh "$MAIN"; expect 0 "" "fixture: the channel step"
KIT="$(jq -r .kit_dir "$MAIN/.agents/team/channel.local.json")"
BOX="$(jq -r .box "$MAIN/.agents/team/channel.local.json")"
mailsum() { (cd "$(dirname "$BOX")" && shasum -a 256 mail.sqlite recipients.json); }

# Stubs: every platform tool logs its argv; tmux/pgrep answer from fixture files.
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
NOTIFY="bash $OK_DIR/notify.sh"
nlog() { cat "$WORK/notify.log" 2>/dev/null || true; }

# ---- (N) the notifier ---------------------------------------------------------------------------
run "$MAIN" env PATH="$KP" $NOTIFY --backend osascript --alarm 'T"i\tle' $'line one\nline two'
expect 0 "" "(N) osascript"
has 'display notification "line one line two" with title "Title" sound name "Sosumi"' "$WORK/notify.log" \
  || { nlog > "$WORK/out"; fail "(N) osascript argv / sanitising"; }
: > "$WORK/notify.log"
run "$MAIN" env PATH="$KP" TEAM_NOTIFY_SOUND_ALARM= $NOTIFY --backend osascript --alarm T M
! grep -q 'sound name' "$WORK/notify.log" || fail "(N) set-but-empty alarm sound still sounded"
: > "$WORK/notify.log"
run "$MAIN" env PATH="$KP" $NOTIFY --backend notify-send --alarm T M
has "notify-send|-u|critical|--|T|M|" "$WORK/notify.log" || { nlog > "$WORK/out"; fail "(N) notify-send argv"; }
: > "$WORK/notify.log"
run "$MAIN" env PATH="$KP" $NOTIFY --backend none T M
[ ! -s "$WORK/notify.log" ] || fail "(N) none notified"
run "$MAIN" env PATH="$KP" TEAM_NOTIFIER=notify-send $NOTIFY T "$(printf 'x%.0s' $(seq 1 300))"
[ "$(awk -F'|' '{print length($6)}' "$WORK/notify.log")" = 200 ] \
  || { nlog > "$WORK/out"; fail "(N) TEAM_NOTIFIER fallback / the 200-char cut"; }
MB="$WORK/minbin"; mkdir -p "$MB"
for t in bash tr cut dirname cat; do ln -s "$(command -v $t)" "$MB/$t"; done
run "$MAIN" env PATH="$MB" bash $OK_DIR/notify.sh --backend osascript T M; expect 0 "" "(N) missing binary is silent"
[ ! -s "$WORK/out" ] || fail "(N) missing binary printed"
run "$MAIN" env PATH="$MB" bash $OK_DIR/notify.sh --check --backend osascript
expect 0 "notifier: osascript missing osascript" "(N) --check missing"
run "$MAIN" env PATH="$KP" $NOTIFY --check --backend notify-send; expect 0 "notifier: notify-send ok" "(N) --check ok"
run "$MAIN" $NOTIFY --check; expect 0 "notifier: none — declared loss" "(N) --check none"
echo "team-smoke-kit: (N) notifier OK"

# ---- (I) the installer ------------------------------------------------------------------------
homesum() { find "$HOME" -type f -exec shasum -a 256 {} + | sort; }
mkdir -p "$KIT"; printf 'old notifier\n' > "$KIT/notify.sh"   # a live file that predates the kit
homesum > "$WORK/h0"; M0="$(mailsum)"
run "$MAIN" $INST --dry-run; expect 0 "copy escalate.sh → $KIT/escalate.sh (new)" "(I) dry-run"
has "copy notify.sh → $KIT/notify.sh (backup $KIT/notify.sh.bak-team-kit)" "$WORK/out" || fail "(I) dry-run backup line"
homesum > "$WORK/h1"; cmp -s "$WORK/h0" "$WORK/h1" || fail "(I) the dry-run changed a byte under HOME"
[ ! -e "$ESCF" ] || fail "(I) the dry-run rendered escalation.local.json"
run "$MAIN" $INST --apply; expect 0 "installed $KIT/hooks/role-hooks.settings.json" "(I) apply"
has "write	.agents/team/escalation.local.json" "$WORK/out" || fail "(I) apply did not render the escalation config"
[ "$(grep -c '^installed ' "$WORK/out")" = 6 ] || fail "(I) apply installed $(grep -c '^installed ' "$WORK/out") targets"
[ "$(ls -ld "$KIT" | cut -c1-10)" = drwx------ ] || fail "(I) kit_dir is not mode 700"
[ -x "$KIT/escalate.sh" ] && [ -x "$KIT/hooks/mail-guard.sh" ] || fail "(I) scripts not executable"
jq -e --arg k "$KIT" '.hooks.Stop[0].hooks[0].command == "bash \"\($k)/hooks/mail-guard.sh\""
  and (.hooks.Notification[0].matcher == "permission_prompt|elicitation_dialog")
  and ([.hooks | keys[]] == ["Notification", "Stop"])' "$KIT/hooks/role-hooks.settings.json" >/dev/null \
  || fail "(I) role-hooks.settings.json"
for want in PROJECT_CODE=QX SUPERVISOR_NAME=SupervisorQx NOTIFIER=osascript LABEL=team.qx.sessions-health \
  "SESSIONS=main-supervisor main-teamlead main-advisor main-team-watch main-team-watch-dog" "KIT_DIR=$KIT"; do
  grep -qxF "$want" "$KIT/kit.conf" || { cp "$KIT/kit.conf" "$WORK/out"; fail "(I) kit.conf lacks $want"; }
done
jq -e --arg k "$KIT" '.send | startswith("bash \"\($k)/escalate.sh\" send")' "$ESCF" >/dev/null || fail "(I) escalation send line"
run "$MAIN" $INST --verify; expect 0 "ok $KIT/kit.conf" "(I) verify clean"
echo tampered >> "$KIT/escalate.sh"
run "$MAIN" $INST --verify; expect 1 "differs $KIT/escalate.sh" "(I) verify sees a tampered copy"
run "$MAIN" $INST --apply; expect 0 "" "(I) re-apply"
[ "$(cat "$KIT/notify.sh.bak-team-kit")" = "old notifier" ] || fail "(I) a re-apply replaced the first backup"
sed -i.x 's/^NOTIFIER=.*/NOTIFIER=none/' "$KIT/kit.conf"; rm -f "$KIT/kit.conf.x"
run "$MAIN" $INST --verify; expect 1 "differs $KIT/kit.conf" "(I) verify sees a stale render"
run "$MAIN" $INST --apply; expect 0 "" "(I) re-apply after a stale render"
run "$MAIN" env PATH="$KP" bash "$KIT/notify.sh" T M
has "osascript|" "$WORK/notify.log" || fail "(I) the installed notifier ignored kit.conf"
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
[ ! -e "$(dirname "$BOX")/escalate.sh" ] || fail "(I) wrote into the mailbox dir"
cp "$WORK/ch.bak" "$CH"
# rollback: original restored, new files gone, no backup left, generated config removed
run "$MAIN" $INST --rollback; expect 0 "restored $KIT/notify.sh" "(I) rollback"
[ "$(cat "$KIT/notify.sh")" = "old notifier" ] || fail "(I) rollback did not restore the original"
[ ! -e "$KIT/escalate.sh" ] && [ ! -e "$KIT/kit.conf" ] && [ ! -e "$KIT/hooks/mail-guard.sh" ] \
  || fail "(I) rollback left a kit file"
[ -z "$(find "$KIT" -name '*.bak-team-kit*')" ] || fail "(I) rollback left a backup"
[ ! -e "$ESCF" ] || fail "(I) rollback kept the generated escalation config"
# a hand-written escalation config survives a rollback
run "$MAIN" $INST --apply; expect 0 "" "(I) apply again"
jq 'del(._generated)' "$ESCF" > "$WORK/e" && mv "$WORK/e" "$ESCF"
run "$MAIN" $INST --rollback; expect 0 "escalation.local.json (hand-written" "(I) hand-written config kept"
[ -e "$ESCF" ] || fail "(I) rollback removed a hand-written config"
rm -f "$ESCF"
[ "$(mailsum)" = "$M0" ] || fail "(I) the kit touched the mailbox or recipients.json"
run "$MAIN" $INST --apply; expect 0 "" "(I) final apply for the next sections"
echo "team-smoke-kit: (I) installer OK"

# ---- (H) the health check ---------------------------------------------------------------------
hc() { run "$MAIN" env PATH="$KP" bash "$KIT/sessions-health.sh" "$@"; }
printf '%s\n' main-supervisor main-teamlead main-advisor main-team-watch main-team-watch-dog > "$WORK/up"
: > "$WORK/notify.log"; : > "$WORK/procs"
hc; expect 0 "" "(H) all up"
[ ! -s "$WORK/notify.log" ] || fail "(H) notified with everything up"
grep -vx main-advisor "$WORK/up" > "$WORK/up2"; mv "$WORK/up2" "$WORK/up"
hc; hc
[ "$(grep -c 'main-advisor down' "$WORK/notify.log")" = 1 ] || { nlog > "$WORK/out"; fail "(H) one notification per outage"; }
echo main-advisor >> "$WORK/up"
hc; [ ! -s "$KIT/sessions-health.state" ] || [ -z "$(tr -d '\n' < "$KIT/sessions-health.state")" ] \
  || fail "(H) recovery did not clear the state"
[ "$(grep -c 'down' "$WORK/notify.log")" = 1 ] || fail "(H) recovery notified"
grep -vx main-supervisor "$WORK/up" > "$WORK/up2"; mv "$WORK/up2" "$WORK/up"
echo "claude --name SupervisorZz --model opus" > "$WORK/procs"
: > "$WORK/notify.log"; hc
has "main-supervisor down" "$WORK/notify.log" || fail "(H) another project's Supervisor counted as up"
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
echo "team-smoke-kit: (H) health check OK"

# ---- (G) the role Stop hook -------------------------------------------------------------------
GUARD="$KIT/hooks/mail-guard.sh"
guard() {  # guard <role or -> [project dir]
  local r="$1" d="${2:-$MAIN}"
  if [ "$r" = - ]; then run "$MAIN" env -u TEAM_SESSION_ROLE CLAUDE_PROJECT_DIR="$d" bash "$GUARD" <<<'{}'
  else run "$MAIN" env TEAM_SESSION_ROLE="$r" CLAUDE_PROJECT_DIR="$d" bash "$GUARD" <<<'{}'; fi
}
run "$MAIN" $M send --from SupervisorQx --to TeamLeadQx --kind turn --thread esc-r1-q-9 --body x
guard TeamLead; expect 0 "" "(G) esc- only"; [ ! -s "$WORK/out" ] || fail "(G) blocked on an esc- turn"
run "$MAIN" $M send --from Supervisor --to TeamLead --kind turn --thread other --body x
guard TeamLead; [ ! -s "$WORK/out" ] || fail "(G) blocked on another project's recipient"
run "$MAIN" $M send --from SupervisorQx --to TeamLeadQx --kind turn --thread work-1 --body x
guard TeamLead; expect 0 "Unread agent-mail turn for TeamLeadQx" "(G) unread turn blocks"
jq -e '.decision == "block"' "$WORK/out" >/dev/null || fail "(G) not a block decision"
guard Advisor; [ ! -s "$WORK/out" ] || fail "(G) the Advisor was held"
guard -; [ ! -s "$WORK/out" ] || fail "(G) a role-less window was held"
mkdir -p "$WORK/fakeclone/.agents/team"; echo '{}' > "$WORK/fakeclone/.agents/team/team.json"
guard TeamLead "$WORK/fakeclone"; [ ! -s "$WORK/out" ] || fail "(G) a clone was held"
mv "$CH" "$WORK/ch.away"; guard TeamLead; [ ! -s "$WORK/out" ] || fail "(G) held without a channel"
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
cp "$WORK/tw.real" "$LIB/team-watch.sh"; rm -f "$LIB/monitoring.sh" "$MAIN/.claude/team/sessions/monitoring.json"
guard Supervisor; expect 0 "thread=chat-1" "(G) the real team-watch.sh, no batch pending: only the mail holds"
echo "team-smoke-kit: (G) stop hook OK"

# ---- (E) the escalation adapter ---------------------------------------------------------------
escr() { run "$MAIN" env TEAM_SESSION_ROLE=TeamLead bash "$KIT/escalate.sh" "$@"; }
Q="$WORK/q"; mkdir -p "$Q"; printf '# q-1\nWhich design?\n' > "$Q/q-1.payload.md"
export TEAM_ESCALATE_ADAPTER_POLL=0.2
escr send "$Q/q-1.payload.md" alfa coder q-1 esc-r1-q-1 1
expect 0 "SENT id=" "(E) send"
ID1="$(tail -n 1 "$WORK/out" | sed -nE 's/^SENT id=([0-9]+)( .*)?$/\1/p')"; [ -n "$ID1" ] || fail "(E) SENT is not the last line"
has "to=AdvisorQx,ReviewerQx kind=turn awaiting=AdvisorQx" "$WORK/out" || fail "(E) pair recipients"
escr send "$Q/q-1.payload.md" alfa coder q-1 esc-r1-q-1 1
[ "$(tail -n 1 "$WORK/out" | sed -nE 's/^SENT id=([0-9]+).*/\1/p')" = "$ID1" ] || fail "(E) a resend is not deduplicated"
run "$MAIN" $M inbox --for AdvisorQx --unread --limit 0; expect 0 "thread=esc-r1-q-1" "(E) in the Advisor's inbox"
has "Team escalation from TeamLeadQx" "$WORK/out" || fail "(E) protocol header"
pk() { escr peek "$Q/q-1.payload.md" alfa coder q-1 esc-r1-q-1 1; }
pk; expect 0 "EMPTY" "(E) peek, nothing yet"
run "$MAIN" $M send --from Advisor --to TeamLeadQx --kind report --thread esc-r1-q-1 --body "status: answer"
pk; expect 0 "EMPTY" "(E) a reply from another project's Advisor is ignored"
printf 'status: answer\ndecided-by: analysts\n\nUse the queue.\n' > "$WORK/reply"
run "$MAIN" $M send --from AdvisorQx --to TeamLeadQx --kind report --thread esc-r1-q-1 --body-file "$WORK/reply"
pk; expect 0 "status: answer" "(E) peek stages the Advisor's reply"
has "Use the queue." "$WORK/out" || fail "(E) reply body"
ls "$Q"/q-1.reply-*.md >/dev/null 2>&1 || fail "(E) reply not staged"
pk; expect 0 "EMPTY" "(E) the staged reply was acked"
D="$(jq -r .decisions_dir "$CH")"
printf 'status: answer\ndecided-by: operator\noperator-ref: nope.md sha256:deadbeef\n\nGo.\n' > "$WORK/reply"
run "$MAIN" $M send --from AdvisorQx --to TeamLeadQx --kind report --thread esc-r1-q-2 --body-file "$WORK/reply"
escr wait "$Q/q-1.payload.md" alfa coder q-2 esc-r1-q-2 1
expect 0 "status: unverified-operator-ref" "(E) an unverifiable operator-ref"
printf 'thread: esc-r1-q-3\nOperator decision: go ahead\n' > "$D/2026-11-04-q3.md"
SUM="$(shasum -a 256 "$D/2026-11-04-q3.md" | cut -c1-12)"
printf 'status: answer\ndecided-by: operator\noperator-ref: 2026-11-04-q3.md sha256:%s\n\nGo.\n' "$SUM" > "$WORK/reply"
run "$MAIN" $M send --from AdvisorQx --to TeamLeadQx --kind report --thread esc-r1-q-3 --body-file "$WORK/reply"
escr wait "$Q/q-1.payload.md" alfa coder q-3 esc-r1-q-3 1
expect 0 "status: answer" "(E) a verified operator-ref"
run "$MAIN" $M send --from ReviewerQx --to AdvisorQx --kind turn --thread esc-r1-q-1 --body "opinion: disagree"
run "$MAIN" $M send --from ReviewerQx --to AdvisorQx --kind turn --thread esc-r1-q-1 --body "opinion: agree"
opi() { escr opinion "$Q/q-1.payload.md" alfa coder q-1 esc-r1-q-1 1; }
opi; expect 0 "opinion: agree" "(E) opinion: the newest Reviewer message"
! has "disagree" "$WORK/out" || fail "(E) opinion printed an older message"
run "$MAIN" $M inbox --for AdvisorQx --unread --limit 0; expect 0 "from=ReviewerQx" "(E) opinion acked nothing"
prof '.teams.channel.advisor = "solo"'
opi; expect 2 "no Reviewer (advisor solo)" "(E) solo has no opinion"
escr send "$Q/q-1.payload.md" alfa coder q-4 esc-r1-q-4 1
expect 0 "to=AdvisorQx kind=turn" "(E) solo sends to the Advisor only"
prof '.teams.channel.advisor = "pair"'
run "$MAIN" bash "$KIT/escalate.sh" bogus x; expect 2 "usage" "(E) usage"

# One escalation end to end: team-escalate.sh → the rendered config → the installed adapter.
smoke_team AB-1302 chore/AB-1302-kit
RUN_ID=alfa-20261104-000001; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"
mkdir -p "$RD/questions"; session coder 1 "$BASE"
export TEAM_ESCALATE_UNIT_SECS=1 TEAM_ESCALATE_POLL=0.2 TEAM_ESCALATE_PEEK_SECS=1
QF="$RD/questions/q-1.md"; T="esc-$RUN_ID-q-1"
printf '# q-1 — alfa coder attempt 1\nrole: coder\nattempt: 1\nrun: %s\nkind: blocked\n' "$RUN_ID" > "$QF"
printf 'record: -\nanchor: x\nfingerprint: v2:none\nopened: 2026-11-04T00:00:00Z\n\n' >> "$QF"
printf '## Summary\nWhich design?\n\n## Context\n- last blocker: -\n\n## Screen\n    x\n' >> "$QF"
(cd "$MAIN" && TEAM_SESSION_ROLE=TeamLead exec bash .claude/lib/team-escalate.sh alfa coder 2 "$QF" --blocks x) \
  > "$WORK/esc.out" 2>&1 &
BGP=$!; BG="$BG $BGP"
i=0; until grep -q '^sent: ' "$QF" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 100 ] || { cp "$WORK/esc.out" "$WORK/out"; fail "(E) never sent"; }; sleep 0.2
done
run "$MAIN" $M inbox --for ReviewerQx --unread --limit 0; expect 0 "thread=$T" "(E) the Reviewer got the copy"
printf 'status: answer\ndecided-by: analysts\n\nUse the queue.\n' > "$WORK/reply"
run "$MAIN" $M send --from AdvisorQx --to TeamLeadQx --kind report --thread "$T" --body-file "$WORK/reply"
wait "$BGP" && RC=0 || RC=$?
cp "$WORK/esc.out" "$WORK/out"
expect 0 "ANSWER" "(E) team-escalate closes on the reply through the kit adapter"
grep -q '^reply: [0-9]* answer' "$QF" || fail "(E) the reply is not in the ledger"
echo "team-smoke-kit: (E) escalation adapter OK"

echo "team-smoke-kit: OK"
