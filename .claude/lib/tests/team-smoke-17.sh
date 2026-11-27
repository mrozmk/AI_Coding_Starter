#!/usr/bin/env bash
# The state-file class reader, the runner that notifies nobody, the newest prompt + redaction and
# the channel names: (P1) class reader, (131) runner notifies nobody, (77) newest prompt and
# redaction, (S1) channel names.
# It spawns stub sessions, so the runner keeps it out of a parallel batch.
# team-smoke: serial
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-sessions-lib.sh"
smoke_init
smoke_team AB-1139 chore/AB-1139-readers
sessions_init
session coder 1 "$BASE"
echo "2026-10-19T10:00:00Z permission_prompt Claude needs your permission" > "$RD/attention"
mkdir "$TD/lock"; echo $$ > "$TD/lock/pid"

# ---- (P1) the state-file class reader ignores .paused and honours a hand-written class switch ----
L="$MAIN/.claude/lib"
# Classes are off unless the profile enables them, so enable one: otherwise both class checks below
# would pass or fail on the profile alone and say nothing about the state file.
PF="$MAIN/.claude/project-profile.json"; cp "$PF" "$WORK/prof.before"
jq '.teams.policy.classes.merge_line = {enabled: true}' "$WORK/prof.before" > "$PF"
(. "$L/team-lib.sh"; echo '{"paused": {"Supervisor": {"since": "2026-11-04T08:00:00Z", "by": "x"}}}' > "$WD/state.json"
  team_class_on "$MAIN" merge-line) || fail "a pause changed the classes"
jq '. + {tiers: "off", classes: {"merge-line": "off"}}' "$WD/state.json" > "$WORK/st" && mv "$WORK/st" "$WD/state.json"
(. "$L/team-lib.sh"; ! team_class_on "$MAIN" merge-line) \
  || fail "class off next to a pause not honoured"
cp "$WORK/prof.before" "$PF"
echo "team-smoke-17: (P1) class reader OK"

# ---- (131) the runner notifies nobody, whatever TEAM_NOTIFY says ------------------------------------
for v in - 1; do
  : > "$STUB_LOG"
  if [ "$v" = - ]; then run "$MAIN" $TR alfa bogus; else run "$MAIN" env TEAM_NOTIFY=1 $TR alfa bogus; fi
  expect 2 "unknown command bogus" "runner die ($v)"
  ! has "declared loss" "$WORK/out" || fail "runner ($v): a declared-loss line"
  ! grep -q '^notify \|^osascript\|^notify-send' "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "the runner notified ($v)"; }
done
echo "team-smoke-17: (131) runner notifications OK"

# ---- (77) the newest prompt from the history, egress refused, redaction ------------------------
PC="python3 -I $SRC/.claude/lib/team_prompt_check.py"
{ printf 'Bash command\n  echo old\nDo you want to proceed?\n❯ 1. Yes\n  ⎿ old\n'
  printf 'Bash command\n'; for i in $(seq 1 45); do echo "  echo step $i"; done
  printf 'Do you want to proceed?\n❯ 1. Yes\n'; } > "$WORK/hist"
$PC --block < "$WORK/hist" > "$WORK/blk" || fail "(77) --block found no block"
[ "$(head -n 1 "$WORK/blk")" = "echo step 1" ] && ! grep -q 'echo old' "$WORK/blk" \
  || { cp "$WORK/blk" "$WORK/out"; fail "(77) --block is not the newest prompt"; }
printf 'Fetch\n  https://example.com/x\nDo you want to proceed?\n❯ 1. Yes\n' > "$WORK/fetch"
$PC "$MAIN" < "$WORK/fetch" 2> "$WORK/out" && fail "(77) WebFetch approved"
has "egress" "$WORK/out" && has "not bound" "$WORK/out" || fail "(77) an unbound WebFetch refusal does not say egress / not bound"
# #322: a Fetch prompt bound to its one pending WebFetch call is judged by the effect classifier,
# through the pane and through --input-json alike; an allowlisted read passes, a token is refused.
fx_fetch() {  # fx_fetch <url> — the pane (the real layout) and the transcript of one pending WebFetch call
  { printf '─%.0s' $(seq 120); printf '\n Fetch\n %s\n Do you want to allow Claude to fetch this content?\n' "$1"
    printf ' ❯ 1. Yes\n   2. No\n Esc to cancel\n'; } > "$WORK/fetchb"
  jq -nc --arg u "$1" '{type: "assistant", uuid: "a-tw1", message: {content: [{type: "tool_use",
    id: "tw1", name: "WebFetch", input: {url: $u, prompt: "p"}}]}}' > "$WORK/fetchb.jsonl"
  jq -nc --arg u "$1" '{tool_name: "WebFetch", tool_input: {url: $u, prompt: "p"}, cwd: "/tmp"}' > "$WORK/fetchb.json"
}
fx_fetch https://developer.mozilla.org/x
$PC "$MAIN" --strict --transcript "$WORK/fetchb.jsonl" < "$WORK/fetchb" 2> "$WORK/out" \
  || { cat "$WORK/out"; fail "(77) a bound allowlisted WebFetch is refused through the pane"; }
[ "$($PC "$MAIN" --input-json "$WORK/fetchb.json" | sed -n 1p)" = "tier: lead" ] \
  || fail "(77) an allowlisted WebFetch is not lead through --input-json"
fx_fetch "https://developer.mozilla.org/x?token=abc123def456"
$PC "$MAIN" --strict --transcript "$WORK/fetchb.jsonl" < "$WORK/fetchb" 2> "$WORK/out" \
  && fail "(77) a token URL approved through the pane"
has "egress" "$WORK/out" || fail "(77) the token URL refusal does not say egress"
$PC "$MAIN" --input-json "$WORK/fetchb.json" | grep -q "^tier: operator — refuse (egress denied)" \
  || fail "(77) a token URL is not refused through --input-json"
R="$(printf 'x token=abc --password p Bearer q\n' | bash -c ". $SRC/.claude/lib/team-lib.sh; team_redact")"
[ "$R" = "x token=*** --password *** Bearer ***" ] || fail "(77) redaction: $R"
printf 'Bash command\n  az storage blob list --sas-token s3cr3t\nDo you want to proceed?\n❯ 1. Yes\n' \
  > "$WORK/pane"
run "$MAIN" bash .claude/lib/team-snapshot.sh --out "$WORK/snap.json"; expect 0 "" "(77) snapshot"
jq -e '.teams[] | select(.team == "alfa") | .roles[] | select(.role == "coder")
  | .prompt_open and .screen == ["az storage blob list --sas-token ***"]
    and (.anchor | contains("s3cr3t") | not)' "$WORK/snap.json" >/dev/null \
  || { jq '.teams[].roles[] | select(.role == "coder")' "$WORK/snap.json" > "$WORK/out"
       fail "(77) snapshot screen is not the redacted block"; }
printf 'Bash command\n  npm run deploy -- --name app-x\nDo you want to proceed?\n❯ 1. Yes\n' > "$WORK/pane"
echo "team-smoke-17: (77) newest prompt and redaction OK"

# ---- (S1) channel names: no teams.channel → the dir slug; an invalid prefix is rc 3 ---------------
N="$WORK/My.Repo X"; mkdir -p "$N"; git -C "$N" init --quiet
R="$(bash -c '. "$1/team-channel.sh"; team_channel_names "$2" && echo "$TEAM_CHANNEL_TMUX_PREFIX $TEAM_CHANNEL_ADVISOR"' _ "$L" "$N")"
[ "$R" = "my-repo-x solo" ] || fail "S1: defaults without teams.channel: $R"
mkdir -p "$N/.claude"; echo '{"teams": {"channel": {"tmux_prefix": "a.b"}}}' > "$N/.claude/project-profile.json"
set +e; bash -c '. "$1/team-channel.sh"; team_channel_names "$2"' _ "$L" "$N" 2> "$WORK/out"; RC=$?; set -e
[ "$RC" = 3 ] && has "tmux_prefix=a.b must match" "$WORK/out" || fail "S1: an invalid prefix is not rc 3"
echo "team-smoke-17: (S1) channel names OK"
echo "team-smoke-17: OK"
