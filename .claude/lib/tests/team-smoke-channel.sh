#!/usr/bin/env bash
# The channel config (team-channel.sh): the load and its refusals, the rendered local configs
# (watch probes, escalation adapter lines, solo, hand-written files kept), the role-filtered mail
# probes, and one escalation end to end through a fixture box with a fixture kit adapter.
# The HOME is throwaway (with a space in its path); nothing reads or writes the real ~/.agent-mail.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
BG=""
trap 'for p in $BG; do kill "$p" 2>/dev/null || true; done
  [ -z "$SPID" ] || kill "$SPID" 2>/dev/null || true; rm -rf "$WORK"' EXIT
export HOME="$WORK/home dir"; mkdir -p "$HOME"
unset AGENT_MAIL_BOX CODEX_HOME
REG="$HOME/.agent-mail/projects.json"
CH="bash .claude/lib/team-channel.sh"
WATCH="$MAIN/.agents/team/watch.local.json"; ESCF="$MAIN/.agents/team/escalation.local.json"
LIB="$MAIN/.claude/lib"

# The main checkout gets what /setup:teams installs for the channel: the vendored tool and the
# templates, committed (the tool copy is named after its commit).
mkdir -p "$MAIN/tools"
cp -R "$SRC/tools/agent_mail" "$MAIN/tools/"; rm -rf "$MAIN/tools/agent_mail/tests"
find "$MAIN/tools" -name __pycache__ -prune -exec rm -rf {} +
cp "$SRC"/.claude/team/*.tmpl "$MAIN/.claude/team/"
printf '__pycache__/\n' >> "$MAIN/.gitignore"
git -C "$MAIN" add -A && git -C "$MAIN" commit --quiet -m "channel fixture"
prof() {  # prof <jq filter> — edit the main checkout's profile in place
  jq "$1" "$MAIN/.claude/project-profile.json" > "$WORK/p" && mv "$WORK/p" "$MAIN/.claude/project-profile.json"
}

# ---- (1) not configured: a clear refusal, exit 3 ---------------------------------------------
run "$MAIN" $CH show
expect 3 "not configured — no teams.channel" "(1) no channel block"
prof '.teams.channel = {project_code: "QX", mail_suffix: "Qx", advisor: "pair"}'
run "$MAIN" $CH show
expect 3 "not configured — no .agents/team/channel.local.json" "(1) no local half"

# ---- (2) the channel step binds the box and renders; escalation waits for the kit adapter ------
run "$MAIN" bash .claude/lib/team-mail-setup.sh "$MAIN" --dry-run
expect 0 "plan	render" "(2) dry-run plans the render"
[ ! -e "$WATCH" ] || fail "(2) the dry-run rendered"
run "$MAIN" bash .claude/lib/team-mail-setup.sh "$MAIN"
expect 0 "write	.agents/team/watch.local.json" "(2) fresh setup renders the watch probes"
has "skip	.agents/team/escalation.local.json	no adapter at" "$WORK/out" \
  || fail "(2) escalation rendered without an adapter"
[ ! -e "$ESCF" ] || fail "(2) escalation.local.json written without an adapter"
! grep -q '{{' "$WATCH" || fail "(2) an unfilled placeholder"
jq -e --arg l "$(cd "$LIB" && pwd)" '(._generated | startswith("by team-channel.sh render"))
  and (.mail.TeamLead | contains("\"" + $l + "/team-mail.sh\" QX inbox --for TeamLeadQx --unread --limit 0"))
  and (.esc_mail.TeamLead | contains(" from=AdvisorQx "))
  and (.wake_mail.Advisor | contains("--for AdvisorQx "))
  and (.mail.Supervisor | contains("--for SupervisorQx "))' "$WATCH" >/dev/null \
  || { cp "$WATCH" "$WORK/out"; fail "(2) watch.local.json content"; }
! grep -q 'mail\.sqlite\|agent_mail\.py' "$WATCH" || fail "(2) a box or tool path in the probes"

# ---- (3) the exported values ------------------------------------------------------------------
run "$MAIN" $CH show
expect 0 "TEAM_CHANNEL_KEY=QX" "(3) show"
for want in TEAM_CHANNEL_SUFFIX=Qx TEAM_CHANNEL_TMUX_PREFIX=main TEAM_CHANNEL_ADVISOR=pair \
  TEAM_CHANNEL_NOTIFIER=none TEAM_CHANNEL_TEAMLEAD=TeamLeadQx TEAM_CHANNEL_REVIEWER=ReviewerQx \
  "TEAM_CHANNEL_BOX=$HOME/.agent-mail/main/mail.sqlite"; do
  grep -qxF "$want" "$WORK/out" || fail "(3) show lacks $want"
done
run "$MAIN" $CH name Advisor; expect 0 "AdvisorQx" "(3) name"
run "$MAIN" $CH name Opus; expect 2 "must be Supervisor|TeamLead|Advisor|Reviewer" "(3) bad role"
run "$MAIN" $CH get decisions_dir; expect 0 "$HOME/.agent-mail/main/decisions" "(3) get"

# ---- (4) the probes filter by role: turns wake, esc- replies from the Advisor only -------------
probe() { run "$MAIN" bash -c "$(jq -r "$1" "$WATCH")"; }
run "$MAIN" $CH turn Supervisor TeamLead --body "pick up AB-1"
expect 0 "SENT id=" "(4) turn"
run "$MAIN" bash .claude/lib/team-mail.sh QX send --from AdvisorQx --to TeamLeadQx --kind report \
  --thread esc-r1-q-1 --body "status: answer"
expect 0 "SENT id=" "(4) an esc- reply"
run "$MAIN" bash .claude/lib/team-mail.sh QX send --from ReviewerQx --to TeamLeadQx --kind report \
  --thread esc-r1-q-1 --body "opinion: agree"
expect 0 "SENT id=" "(4) a Reviewer note on the thread"
probe .mail.TeamLead; expect 0 "from=SupervisorQx kind=turn" "(4) mail probe"
[ "$(grep -c '^\[agent-mail\]' "$WORK/out")" = 1 ] || fail "(4) the mail probe passed an esc- line"
probe '.esc_mail.TeamLead'; expect 0 "from=AdvisorQx" "(4) esc_mail probe"
[ "$(grep -c '^\[agent-mail\]' "$WORK/out")" = 1 ] || fail "(4) esc_mail passed a non-Advisor line"
probe .mail.Supervisor; expect 0 "" "(4) empty probe"; [ ! -s "$WORK/out" ] || fail "(4) Supervisor has mail"

# ---- (5) refusals: stale local half, suffix drift, bad policy ----------------------------------
cp "$REG" "$WORK/reg.bak"
jq '.QX.tool = "/nowhere/agent_mail"' "$WORK/reg.bak" > "$REG"
run "$MAIN" $CH show; expect 3 "stale against registry entry QX" "(5) a re-pointed tool"
cp "$WORK/reg.bak" "$REG"
prof '.teams.channel.mail_suffix = "Zz"'
run "$MAIN" $CH show; expect 3 "would not match" "(5) suffix drift"
prof '.teams.channel.mail_suffix = "Qx" | .teams.channel.notifier = "bell"'
run "$MAIN" $CH show; expect 3 "notifier=bell must be" "(5) bad notifier"
prof 'del(.teams.channel.notifier) | del(.teams.channel.advisor)'
run "$MAIN" $CH get advisor; expect 0 "solo" "(5) advisor default without codex"
prof '.codex = true'
run "$MAIN" $CH get advisor; expect 0 "pair" "(5) advisor default with codex"

# ---- (6) the kit adapter appears: escalation renders; solo drops opinion; hand-written stays ----
KIT="$(jq -r .kit_dir "$MAIN/.agents/team/channel.local.json")"
mkdir -p "$KIT"
# A fixture adapter with the operator kit's contract (the real one ships with the kit): every
# address comes from the channel config, the reply filter is the Advisor's name, the opinion
# filter the Reviewer's.
cat > "$KIT/escalate.sh" <<'EOF'
set -euo pipefail
op="$1" payload="$2" qid="$5" thread="$6" seq="$7"
. .claude/lib/team-channel.sh; team_channel_load
M="bash .claude/lib/team-mail.sh $TEAM_CHANNEL_KEY"
newest() {  # newest <sender> → the newest unread message from <sender> on the thread, as JSON
  $M inbox --for "$TEAM_CHANNEL_TEAMLEAD" --unread --json --limit 0 \
    | jq -c --arg t "$thread" --arg s "$1" '[.[] | select(.thread == $t and .sender == $s)] | last // empty'
}
stage() {  # stage <json> → staged reply printed, acked
  local id f; id="$(jq -r .id <<<"$1")"; f="$(dirname "$payload")/$qid.reply-$id.md"
  { echo "mail-id: $id"; jq -r .body <<<"$1"; } > "$f"
  $M ack "$id" --by "$TEAM_CHANNEL_TEAMLEAD" >/dev/null; cat "$f"
}
case "$op" in
  send) bash .claude/lib/team-channel.sh turn TeamLead Advisor --thread "$thread" \
          --dedup-key "$thread-$seq" --body-file "$payload" | sed -n 's/^\(SENT id=[0-9]*\).*/\1/p' ;;
  peek) m="$(newest "$TEAM_CHANNEL_ADVISOR_NAME")"; if [ -n "$m" ]; then stage "$m"; else echo EMPTY; fi ;;
  wait) while m="$(newest "$TEAM_CHANNEL_ADVISOR_NAME")"; [ -z "$m" ]; do sleep 0.2; done; stage "$m" ;;
  opinion) m="$(newest "$TEAM_CHANNEL_REVIEWER")"
    [ -z "$m" ] || { echo "mail-id: $(jq -r .id <<<"$m")"; jq -r .body <<<"$m"; } ;;
esac
EOF
run "$MAIN" $CH render
expect 0 "write	.agents/team/escalation.local.json" "(6) render with the adapter"
has "keep	.agents/team/watch.local.json	identical" "$WORK/out" || fail "(6) watch not kept"
KQ="$(cd "$KIT" && pwd)"
for op in send wait opinion peek; do
  [ "$(jq -r ".$op" "$ESCF")" = "bash \"$KQ/escalate.sh\" $op \"\$1\" \"\$2\" \"\$3\" \"\$4\" \"\$5\" \"\$6\"" ] \
    || fail "(6) $op line: $(jq -r ".$op" "$ESCF")"
done
prof '.teams.channel.advisor = "solo"'
run "$MAIN" $CH render
expect 0 "rewrite	.agents/team/escalation.local.json" "(6) solo re-render"
jq -e 'has("opinion") | not' "$ESCF" >/dev/null || fail "(6) solo kept the opinion op"
prof '.teams.channel.advisor = "pair"'
run "$MAIN" $CH render; expect 0 "rewrite	.agents/team/escalation.local.json" "(6) back to pair"
cp "$ESCF" "$WORK/esc.bak"; jq 'del(._generated)' "$WORK/esc.bak" > "$ESCF"; cp "$ESCF" "$WORK/hand"
run "$MAIN" $CH render; expect 0 "hand-written" "(6) a hand-written file"
cmp -s "$ESCF" "$WORK/hand" || fail "(6) the hand-written file was replaced"
cp "$WORK/esc.bak" "$ESCF"

# ---- (7) one escalation through the fixture box: send, Advisor reply, ANSWER -------------------
smoke_team AB-1301 chore/AB-1301-channel
RUN_ID=alfa-20261104-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"
mkdir -p "$RD/questions"; session coder 1 "$BASE"
export TEAM_ESCALATE_UNIT_SECS=1 TEAM_ESCALATE_POLL=0.2 TEAM_ESCALATE_PEEK_SECS=1
QF="$RD/questions/q-1.md"; T="esc-$RUN_ID-q-1"
printf '# q-1 — alfa coder attempt 1\nrole: coder\nattempt: 1\nrun: %s\nkind: blocked\n' "$RUN_ID" > "$QF"
printf 'record: -\nanchor: x\nfingerprint: v2:none\nopened: 2026-11-04T00:00:00Z\n\n' >> "$QF"
printf '## Summary\nWhich design?\n\n## Context\n- last blocker: -\n\n## Screen\n    x\n' >> "$QF"
(cd "$MAIN" && exec bash .claude/lib/team-escalate.sh alfa coder 2 "$QF" --blocks x) \
  > "$WORK/esc.out" 2>&1 &
BGP=$!; BG="$BG $BGP"
i=0; until grep -q '^sent: ' "$QF" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 100 ] || { cp "$WORK/esc.out" "$WORK/out"; fail "(7) never sent"; }; sleep 0.2
done
run "$MAIN" bash .claude/lib/team-mail.sh QX inbox --for AdvisorQx --unread --limit 0
expect 0 "from=TeamLeadQx kind=turn awaiting=AdvisorQx thread=$T" "(7) the request in the Advisor's inbox"
printf 'status: answer\ndecided-by: analysts\n\nUse the queue.\n' > "$WORK/reply"
run "$MAIN" bash .claude/lib/team-mail.sh QX send --from AdvisorQx --to TeamLeadQx --kind report \
  --thread "$T" --body-file "$WORK/reply"
expect 0 "SENT id=" "(7) the Advisor replies"
wait "$BGP" && RC=0 || RC=$?
cp "$WORK/esc.out" "$WORK/out"
expect 0 "ANSWER" "(7) the escalation closes on the reply"
has "Use the queue." "$WORK/out" || fail "(7) the answer text"
grep -q '^reply: [0-9]* answer' "$QF" || fail "(7) the reply is not in the ledger"

echo "team-smoke-channel: OK"
