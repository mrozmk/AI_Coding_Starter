#!/usr/bin/env bash
# The channel config (team-channel.sh): the load and its refusals, the rendered local configs
# (watch probes, solo, hand-written files kept) and the role-filtered mail probes.
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
WATCH="$MAIN/.agents/team/watch.local.json"
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

# ---- (2) the channel step binds the box and renders ------------------------------------------
run "$MAIN" bash .claude/lib/team-mail-setup.sh "$MAIN" --dry-run
expect 0 "plan	render" "(2) dry-run plans the render"
[ ! -e "$WATCH" ] || fail "(2) the dry-run rendered"
run "$MAIN" bash .claude/lib/team-mail-setup.sh "$MAIN"
expect 0 "write	.agents/team/watch.local.json" "(2) fresh setup renders the watch probes"
! has "escalation" "$WORK/out" || fail "(2) render still names escalation"
! grep -q '{{' "$WATCH" || fail "(2) an unfilled placeholder"
jq -e --arg l "$(cd "$LIB" && pwd)" '(._generated | startswith("by team-channel.sh render"))
  and (.mail.Supervisor | contains("\"" + $l + "/team-mail.sh\" QX inbox --for SupervisorQx --unread --limit 0"))
  and (.mail | has("TeamLead") | not) and (has("esc_mail") | not)
  and (.mail_unread | contains("--for SupervisorQx "))
  and (has("wake_mail") | not)' "$WATCH" >/dev/null \
  || { cp "$WATCH" "$WORK/out"; fail "(2) watch.local.json content"; }
! grep -q 'mail\.sqlite\|agent_mail\.py' "$WATCH" || fail "(2) a box or tool path in the probes"

# ---- (3) the exported values ------------------------------------------------------------------
run "$MAIN" $CH show
expect 0 "TEAM_CHANNEL_KEY=QX" "(3) show"
for want in TEAM_CHANNEL_SUFFIX=Qx TEAM_CHANNEL_TMUX_PREFIX=main TEAM_CHANNEL_ADVISOR=pair \
  TEAM_CHANNEL_TEAMLEAD=TeamLeadQx TEAM_CHANNEL_REVIEWER=ReviewerQx \
  "TEAM_CHANNEL_BOX=$HOME/.agent-mail/main/mail.sqlite"; do
  grep -qxF "$want" "$WORK/out" || fail "(3) show lacks $want"
done
run "$MAIN" $CH name Advisor; expect 0 "AdvisorQx" "(3) name"
run "$MAIN" $CH name Opus; expect 2 "must be Supervisor|TeamLead|Advisor|Reviewer" "(3) bad role"
run "$MAIN" $CH get decisions_dir; expect 0 "$HOME/.agent-mail/main/decisions" "(3) get"

# ---- (4) the probes filter by role: the split probe passes turns, the single one drops esc- ----
probe() { run "$MAIN" bash -c "$(jq -r "$1" "$WATCH")"; }
run "$MAIN" $CH turn Advisor Supervisor --body "pick up AB-1"
expect 0 "SENT id=" "(4) turn"
run "$MAIN" bash .claude/lib/team-mail.sh QX send --from ReviewerQx --to SupervisorQx --kind report \
  --thread esc-r1-q-1 --body "opinion: agree"
expect 0 "SENT id=" "(4) a Reviewer note on an esc- thread"
run "$MAIN" bash .claude/lib/team-mail.sh QX send --from ReviewerQx --to SupervisorQx --kind turn \
  --thread esc-r1-q-1 --body "your turn on the escalation"
expect 0 "SENT id=" "(4) a turn on an esc- thread"
# Split: kind=turn only — the report waits, both turns wake.
probe .mail.Supervisor; expect 0 "from=AdvisorQx kind=turn" "(4) split mail probe"
[ "$(grep -c '^\[agent-mail\]' "$WORK/out")" = 2 ] && ! grep -q ' kind=report ' "$WORK/out" \
  || fail "(4) the split probe is not the two turns"
# Single window: every kind, but never an esc- thread line.
probe .mail_unread; expect 0 "from=AdvisorQx kind=turn" "(4) single-window probe"
[ "$(grep -c '^\[agent-mail\]' "$WORK/out")" = 1 ] || fail "(4) the single-window probe passed an esc- line"

# ---- (5) refusals: stale local half, suffix drift, bad policy ----------------------------------
cp "$REG" "$WORK/reg.bak"
jq '.QX.tool = "/nowhere/agent_mail"' "$WORK/reg.bak" > "$REG"
run "$MAIN" $CH show; expect 3 "stale against registry entry QX" "(5) a re-pointed tool"
jq '.QX.decisions_dir = "/moved/decisions"' "$WORK/reg.bak" > "$REG"
run "$MAIN" $CH show; expect 3 "decisions_dir or codex_home differ" "(5) a moved decisions dir"
jq '.QX.codex_home = "/moved/codex"' "$WORK/reg.bak" > "$REG"
run "$MAIN" $CH show; expect 3 "decisions_dir or codex_home differ" "(5) a moved codex home"
cp "$WORK/reg.bak" "$REG"
run "$MAIN" $CH show; expect 0 "" "(5) the matching local half still loads"
prof '.teams.channel.mail_suffix = "Zz"'
run "$MAIN" $CH show; expect 3 "would not match" "(5) suffix drift"
prof '.teams.channel.mail_suffix = "Qx" | .teams.channel.notifier = "bell"'
run "$MAIN" $CH show; expect 0 "warn: teams.channel.notifier was removed and is ignored" "(5) a leftover notifier key warns"
[ "$(grep -c 'notifier' "$WORK/out")" = 1 ] || fail "(5) the notifier key: not exactly one line"
run "$MAIN" bash -c ". .claude/lib/team-channel.sh; team_channel_names; team_channel_names; bash .claude/lib/team-channel.sh get advisor"
[ "$(grep -c 'notifier was removed' "$WORK/out")" = 1 ] || fail "(5) the notifier warning is not once per process tree"
prof 'del(.teams.channel.notifier) | del(.teams.channel.advisor)'
run "$MAIN" $CH get advisor; expect 0 "solo" "(5) advisor default without codex"
prof '.codex = true'
run "$MAIN" $CH get advisor; expect 0 "pair" "(5) advisor default with codex"

# ---- (8) turn takes --kind turn (the default, with --awaiting) or --kind info only --------------
run "$MAIN" $CH turn Supervisor TeamLead --kind turn --thread k8 --body "explicit turn"
expect 0 "kind=turn awaiting=TeamLeadQx" "(8) --kind turn keeps the wake-up"
run "$MAIN" $CH turn Supervisor TeamLead --kind info --thread k8 --body "fyi"
expect 0 "kind=info awaiting=-" "(8) --kind info wakes nobody"
run "$MAIN" $CH turn Supervisor TeamLead --kind report --thread k8 --body "x"
expect 2 "--kind must be turn or info (got 'report')" "(8) another kind is refused"
run "$MAIN" $CH turn Supervisor TeamLead --thread k8 --body "x" --kind
expect 2 "--kind must be turn or info (got '')" "(8) a bare --kind is refused"

echo "team-smoke-channel: OK"
