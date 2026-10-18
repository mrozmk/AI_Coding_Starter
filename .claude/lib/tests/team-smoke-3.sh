#!/usr/bin/env bash
# Run modes (brainstorm · quick · cli), the self-closing window and old-clone compatibility (TT-790).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team TT-793 feature/TT-793-modes
BR="$(jq -r .branch "$TD/team.json")"
TGT0="$(git -C "$CLONE" ls-remote origin refs/heads/develop-netcore7 | cut -f1)"

setmode() {  # setmode <mode> | setmode -  (- = a team.json written before TT-790)
  if [ "$1" = - ]; then jq 'del(.mode)' "$TD/team.json" > "$WORK/tj"
  else jq --arg m "$1" '.mode = $m' "$TD/team.json" > "$WORK/tj"; fi
  mv "$WORK/tj" "$TD/team.json"
}
fresh_run() {  # fresh_run <run id> — a new run with no live state
  RUN_ID="$1"; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
  rm -f "$TD/session.json"; rm -rf "$TD/lock" "$TD/acked"
}

# ---- (19) mode in team.json + status ------------------------------------------------------------
[ "$(jq -r .mode "$TD/team.json")" = brainstorm ] || fail "team-new did not write mode brainstorm"
run "$MAIN" $TR alfa status
expect 0 "mode: brainstorm" "status shows the mode"
setmode -
run "$MAIN" $TR alfa status
expect 0 "mode: brainstorm" "team.json without mode reads as brainstorm"
setmode bogus
run "$MAIN" $TR alfa status
expect 1 "unknown mode" "status refuses an unknown mode"
setmode brainstorm

# ---- (20) team-new / team-next mode argument ----------------------------------------------------
git -C "$SEED" switch --quiet -c noprompts develop-netcore7
git -C "$SEED" rm --quiet .claude/team/prompts/planner-quick.md .claude/team/prompts/cli.md
git -C "$SEED" commit --quiet -m "no mode prompts" && git -C "$SEED" push --quiet origin noprompts
run "$MAIN" $NEW beta TT-794 feature/TT-794-x origin/develop-netcore7 bogus
expect 1 "mode 'bogus' must be one of" "team-new rejects a bad mode"
run "$MAIN" $NEW beta TT-794 feature/TT-794-x origin/noprompts quick
expect 1 "has no planner-quick.md" "team-new quick needs a TT-790 base"
run "$MAIN" $NEW beta TT-794 feature/TT-794-x origin/develop-netcore7 "brainstorm quick"
expect 1 "must be one of" "team-new rejects a multi-token mode"
[ ! -e "$WORK/main-beta" ] || fail "a rejected team-new created a clone"
run "$MAIN" bash .claude/lib/team-next.sh alfa TT-794 feature/TT-794-x origin/develop-netcore7 bogus
expect 1 "mode 'bogus' must be one of" "team-next rejects a bad mode"

# A mode change for the same key must fail before archiving or cutting an existing branch.
printf 'same-key-run\n' > "$TD/run"
printf '{"coder":{"model":"sonnet"}}\n' > "$TD/roles.override.json"
shasum -a 256 "$TD/team.json" "$TD/run" "$TD/roles.override.json" > "$WORK/same-key.sha"
for mode in quick cli; do
  run "$MAIN" bash .claude/lib/team-next.sh alfa TT-793 "$BR" origin/develop-netcore7 "$mode"
  expect 1 "resume with /start-team alfa" "same ticket in mode $mode"
  shasum -a 256 "$TD/team.json" "$TD/run" "$TD/roles.override.json" > "$WORK/after-key.sha"
  cmp -s "$WORK/same-key.sha" "$WORK/after-key.sha" || fail "same-key $mode changed team state"
  [ ! -e "$TD/archive" ] || fail "same-key $mode archived the ticket"
  [ "$(git -C "$CLONE" rev-parse HEAD)" = "$BASE" ] || fail "same-key $mode changed HEAD"
  [ "$(git -C "$CLONE" branch --show-current)" = "$BR" ] || fail "same-key $mode changed branch"
done

# ---- (21) cli launch through the real runner — before any commit --------------------------------
setmode cli; fresh_run alfa-20261006-000001
echo '{"planner":{"model":"x"}}' > "$TD/roles.override.json"
cp "$TD/roles.override.json" "$WORK/cli-override"
for entry in cli=sonnet coder=sonnet; do
  : > "$STUB_LOG"
  TEAM_NOTIFY=1 run "$MAIN" $TR alfa roles "$entry"
  expect 1 "mode cli (fixed opus[1m]/medium)" "cli refuses $entry"
  cmp -s "$WORK/cli-override" "$TD/roles.override.json" || fail "cli roles changed the override"
  [ ! -s "$STUB_LOG" ] || fail "cli role refusal notified or launched a tool"
done
run "$MAIN" $TR alfa roles --clear
expect 0 "roles override cleared" "cli allows stale override cleanup"
[ ! -e "$TD/roles.override.json" ] || fail "cli roles --clear kept the override"
: > "$STUB_LOG"
TEAM_NOTIFY=1 run "$MAIN" $TR alfa roles coder=/high
expect 1 "mode cli" "cli refuses creating an override"
[ ! -e "$TD/roles.override.json" ] || fail "cli roles created an override"
[ ! -s "$STUB_LOG" ] || fail "cli role refusal notified or launched a tool"
cp "$WORK/cli-override" "$TD/roles.override.json"; : > "$STUB_LOG"
run "$MAIN" $TR alfa
expect 5 "dead attempt 2 of cli" "cli launch retries then stops"
has "-n alfa-cli --model 'opus[1m]' --effort 'medium' --disallowedTools AskUserQuestion -- " \
  "$STUB_LOG" || fail "cli launch lacks the fixed model/effort or the AskUserQuestion block"
jq -e --arg b "$BASE" '.role == "cli" and .mode == "cli" and .attempt == 2 and .input_rev == $b' \
  "$TD/session.json" >/dev/null || fail "cli session.json: $(cat "$TD/session.json")"
has "not a cli change" "$RD/cli-1.prompt.md" || fail "cli prompt not rendered from cli.md"
rm -f "$TD/session.json" "$TD/roles.override.json"; setmode brainstorm

# ---- (22) quick planner validation --------------------------------------------------------------
setmode quick; fresh_run alfa-20261006-000002
commit_file .agents/plans/active/p.md "# Feature: p"
session planner 1 "$BASE"
R=$(record --verdict done --artifacts .agents/plans/active/p.md)
run "$MAIN" $TR alfa check "$R"
expect 0 "valid:" "quick planner without a spec"
setmode brainstorm
run "$MAIN" $TR alfa check "$R"
expect 4 "no spec" "brainstorm planner still needs a spec"
rm -f "$TD/session.json"

# ---- (23) cli record validation -----------------------------------------------------------------
setmode cli; fresh_run alfa-20261006-000003
session cli 1 "$BASE"
commit_file cli.txt change
C1="$(git -C "$CLONE" rev-parse HEAD)"; git -C "$CLONE" push --quiet origin "$BR"
pr_w "$C1"; jq '.isDraft = true' "$STUB_PR" > "$WORK/pw.json" && mv "$WORK/pw.json" "$STUB_PR"
R=$(record --verdict done --pr 8371)
run "$MAIN" $TR alfa check "$R"
expect 4 "isDraft is not false" "cli PR left as a draft"
pr_w "$C1"
run "$MAIN" $TR alfa check "$R"
expect 0 "valid:" "cli record with a published PR"
session planner 1 "$BASE"
R=$(record --verdict done --artifacts .agents/plans/active/p.md)
run "$MAIN" $TR alfa check "$R"
expect 4 "does not run in mode cli" "planner record in cli mode"
rm -f "$TD/session.json" "$RD"/*.json

# ---- (24) merge check and summary in cli mode ---------------------------------------------------
MC="bash .claude/lib/team-merge-check.sh"
mkrec cli "$C1"; merge_at "$C1"
run "$MAIN" $MC alfa
expect 0 "VERDICT: ok" "merge-check in cli mode"
commit_file late.txt late
C2="$(git -C "$CLONE" rev-parse HEAD)"; git -C "$CLONE" push --quiet origin "$BR"
run "$MAIN" $MC alfa
expect 3 "is not the cli revision" "merge-check after a push past the cli role"
point "$C1"; unset MERGE_SHA
for role in cli qa wrapup; do
  mkrec "$role" "$C1"
  jq '.attempt = 2' "$RD/$role-1-1.json" > "$RD/$role-2-1.json"
  touch "$RD/$role-2-1.json.accepted"
  jq '.attempt = 3' "$RD/$role-1-1.json" > "$RD/$role-3-1.json"
done
printf '## Co zmieniono\nAccepted CLI body.\n## Co to daje\nMniej klikania.\n' > "$RD/cli-2.md"
printf 'UNACCEPTED CLI body\n' > "$RD/cli-3.md"
printf 'PROMPT CLI body\n' > "$RD/cli-2.prompt.md"
touch -t 203001010000 "$RD/cli-3.md" "$RD/cli-2.prompt.md"
run "$MAIN" $TR alfa summary
expect 0 "mode: cli" "summary in cli mode"
has "pr: 8371" "$WORK/out" || fail "cli summary lacks the PR"
has "Accepted CLI body." "$WORK/out" || fail "cli summary ignores the accepted attempt"
grep -Eq 'UNACCEPTED|PROMPT' "$WORK/out" && fail "cli summary picked an unrelated file"
rm -f "$RD/cli-2.md"
run "$MAIN" $TR alfa summary
expect 0 "missing: cli-<n>.md" "cli summary does not fall back to another attempt"
grep -Eq 'UNACCEPTED|PROMPT' "$WORK/out" && fail "missing cli summary fell back"
printf 'UNACCEPTED CLI body\n' > "$RD/cli-2.md"
rm -f "$RD"/cli-*.json.accepted
run "$MAIN" $TR alfa summary
expect 0 "missing: cli-<n>.md" "cli summary without an accepted record"
has 'UNACCEPTED' "$WORK/out" && fail "cli summary shown without an accepted record"
setmode brainstorm; mkrec coder "$C1"
printf 'run: x\nVerdict: ready-with-warnings\nWarnings: one flaky test\nRethink signals: none\n' \
  > "$RD/qa-report-2.md"
printf 'Verdict: UNACCEPTED QA\n' > "$RD/qa-report-3.md"
printf 'Verdict: PROMPT QA\n' > "$RD/qa-report-2.prompt.md"
printf 'target_rev: %s\n## Co zakodowano\nAccepted wrapup body.\n' "$TGT0" > "$RD/wrapup-2.md"
printf 'UNACCEPTED wrapup body\n' > "$RD/wrapup-3.md"
printf 'PROMPT wrapup body\n' > "$RD/wrapup-2.prompt.md"
touch -t 203001010000 "$RD/qa-report-3.md" "$RD/qa-report-2.prompt.md" \
  "$RD/wrapup-3.md" "$RD/wrapup-2.prompt.md"
run "$MAIN" $TR alfa summary
expect 0 "Verdict: ready-with-warnings" "summary in brainstorm mode"
has "Warnings: one flaky test" "$WORK/out" || fail "summary lacks the QA warnings"
has "Accepted wrapup body." "$WORK/out" || fail "summary ignores the accepted wrapup attempt"
grep -Eq 'UNACCEPTED|PROMPT' "$WORK/out" && fail "summary picked an unrelated file"
has "target_rev:" "$WORK/out" && fail "summary leaks the target_rev line"
rm -f "$RD/qa-report-2.md" "$RD/wrapup-2.md"
run "$MAIN" $TR alfa summary
expect 0 "missing: qa-report-<n>.md" "summary names a missing source"
has "missing: wrapup-<n>.md" "$WORK/out" || fail "missing wrapup summary fell back"
grep -Eq 'UNACCEPTED|PROMPT' "$WORK/out" && fail "missing summary fell back"
printf 'Verdict: UNACCEPTED QA\n' > "$RD/qa-report-2.md"
printf 'UNACCEPTED wrapup body\n' > "$RD/wrapup-2.md"
rm -f "$RD"/qa-*.json.accepted "$RD"/wrapup-*.json.accepted
run "$MAIN" $TR alfa summary
expect 0 "missing: qa-report-<n>.md" "summary without accepted records"
has "missing: wrapup-<n>.md" "$WORK/out" || fail "unaccepted wrapup summary shown"
has 'UNACCEPTED' "$WORK/out" && fail "summary shown without accepted records"

# ---- (25) team-next sees the cli PR -------------------------------------------------------------
setmode cli; rm -f "$RD"/coder-1-1.json*; pr_w "$C1"
run "$MAIN" bash .claude/lib/team-next.sh alfa TT-795 feature/TT-795-x origin/develop-netcore7
expect 1 "previous PR #8371" "team-next refuses while the cli PR is active"

# ---- (26) the closer ----------------------------------------------------------------------------
mkdir -p "$WORK/psbin"
printf '#!/usr/bin/env bash\n[ -z "${STUB_PS_OUT:-}" ] || echo "$STUB_PS_OUT"\n' > "$WORK/psbin/ps"
chmod +x "$WORK/psbin/ps"; : > "$STUB_LOG"
PATH="$WORK/psbin:$PATH" run "$MAIN" bash .claude/lib/team-attach.sh --close /dev/ttys009
expect 0 "" "closer after the attach already ended"
grep -q '^osascript .*/dev/ttys009$' "$STUB_LOG" || fail "closer did not close the window by tty"
for a in "--close /tmp/x" "--close" "--close /dev/ttys009 extra"; do
  run "$MAIN" bash .claude/lib/team-attach.sh $a
  expect 2 "" "closer rejects '$a'"
done
: > "$STUB_LOG"
STUB_OSA_OUT=/dev/ttys010 STUB_TMUX_ALIVE=0 PATH="$WORK/psbin:$PATH" \
  run "$MAIN" bash .claude/lib/team-attach.sh alfa coder
expect 0 "opened:" "attach with a tty starts the closer"
has "warn:" "$WORK/out" && fail "attach with a tty still warned"
for _ in 1 2 3 4 5; do grep -q '^osascript .*/dev/ttys010$' "$STUB_LOG" && break; sleep 1; done
grep -q '^osascript .*/dev/ttys010$' "$STUB_LOG" || fail "background closer never closed the window"

# ---- (27) old clone without the new files -------------------------------------------------------
setmode -; fresh_run alfa-20261006-000004
mv "$CLONE/.claude/lib/team-modes.sh" "$CLONE/.claude/lib/team-validate.sh" "$WORK/"
run "$MAIN" $TR alfa status
expect 0 "mode: brainstorm" "old clone status"
run "$MAIN" $TR alfa stop
expect 0 "stopped" "old clone stop"
cp "$CLONE/.claude/lib/team-attach.sh" "$WORK/attach.clone"
cp "$MAIN/.claude/lib/team-attach.sh" "$WORK/attach.main"
printf '#!/usr/bin/env bash\necho OLD-ATTACH >> "$STUB_LOG"\n' > "$CLONE/.claude/lib/team-attach.sh"
printf '#!/usr/bin/env bash\necho NEW-ATTACH >> "$STUB_LOG"\n' > "$MAIN/.claude/lib/team-attach.sh"
: > "$STUB_LOG"
run "$MAIN" $TR alfa
expect 5 "dead attempt 1 of planner" "old clone launch"
has NEW-ATTACH "$STUB_LOG" || fail "runner did not use the main checkout's team-attach.sh"
has OLD-ATTACH "$STUB_LOG" && fail "runner used the clone's team-attach.sh"
cp "$WORK/attach.clone" "$CLONE/.claude/lib/team-attach.sh"
cp "$WORK/attach.main" "$MAIN/.claude/lib/team-attach.sh"
mv "$WORK/team-modes.sh" "$WORK/team-validate.sh" "$CLONE/.claude/lib/"
rm -f "$TD/session.json"; setmode brainstorm

# ---- (29) dashboard folding and the "czeka na Ciebie" bar (TT-823) ------------------------------
CL3="$WORK/claude3"; SUBS="$CL3/s9/subagents"; mkdir -p "$SUBS"
echo '{"type":"assistant","message":{"model":"m"}}' > "$CL3/s9.jsonl"
export TEAM_DASH_PROJECT_DIR="$CL3" TEAM_DASH_SESSION=s9
ago() { date -v-"$1"S +%Y%m%d%H%M.%S; }
for n in $(seq 1 12); do
  echo '{"type":"assistant","message":{"model":"m","content":[]}}' > "$SUBS/agent-live-$n.jsonl"
done
fin() {  # fin <id> <age secs>
  echo '{"type":"assistant","message":{"model":"m","stop_reason":"end_turn"}}' > "$SUBS/agent-$1.jsonl"
  touch -t "$(ago "$2")" "$SUBS/agent-$1.jsonl"
}
fin fresh 60
for n in $(seq 1 12); do fin "old-$n" "$((7200 + n))"; done
snap "fresh finish beyond the cap" '(.subagents | map({key: .id, value: .}) | from_entries) as $s
  | ($s.fresh.finished_at | type) == "string" and $s["live-1"].finished_at == null
  and $s["old-11"] != null and $s["old-12"] == null
  and (.subagents | map(select(.status != "done")) | length) == 12
  and any(.errors[]; . == "subagents: 1 older finished hidden")'

TEAM='.teams[] | select(.team == "alfa")'
fresh_run alfa-20261006-000005
mkrec wrapup "$BASE"
pr_json false "$BASE"; jq '.status = "completed"' "$STUB_PR" > "$WORK/pc" && mv "$WORK/pc" "$STUB_PR"
snap "merged PR frees the team" "($TEAM | .state == \"free\" and .pr_status == \"completed\")
  and .attention == []"
pr_json false "$BASE"
snap "active PR awaits merge" "($TEAM | .state == \"awaiting_merge\")
  and (.attention | map(select(.kind == \"merge\")) | .[0] | .pr_id == 8371
    and .commands == [\"bash .claude/lib/team-merge-check.sh alfa\", \"/pr-merge 8371\"])"
mv "$STUB_PR" "$WORK/pr.saved"
snap "az failure" "($TEAM | .state == \"pr_unknown\" and .pr_status == \"unknown\")
  and .attention == [] and any(.errors[]; . == \"alfa: PR 8371 status unknown\")"
mv "$WORK/pr.saved" "$STUB_PR"

export TEAM_DASH_CACHE="$WORK/cache1"; mkdir -p "$TEAM_DASH_CACHE"
snap "cache fill" "($TEAM | .state == \"awaiting_merge\")"
: > "$STUB_LOG"
snap "cache hit" "($TEAM | .state == \"awaiting_merge\")"
has "repos pr show" "$STUB_LOG" && fail "cached PR state still called az"
export TEAM_DASH_CACHE="$WORK/cache2"; mkdir -p "$TEAM_DASH_CACHE"
SECONDS=0
STUB_AZ_SLEEP=6 TEAM_DASH_PR_SECS=1 snap "slow az" "($TEAM | .state == \"pr_unknown\")"
[ "$SECONDS" -lt 5 ] || fail "slow az held the snapshot ${SECONDS}s"
grep -qx unknown "$TEAM_DASH_CACHE/pr-alfa-8371" || fail "timeout not cached as unknown"
unset TEAM_DASH_CACHE

mkdir -p "$TD/lock"; echo 999999 > "$TD/lock/pid"; : > "$STUB_LOG"
snap "stale runner is not free" "($TEAM | .runner == \"stale\" and .state == null)"
has "repos pr show" "$STUB_LOG" && fail "a stale runner asked ADO"
rm -rf "$TD/lock" "$RD/wrapup-1-1.json"*

CP3="$WORK/$(. "$SRC/.claude/lib/team-lib.sh" && team_project_slug "$(cd "$CLONE" && pwd -P)")"
mkdir -p "$CP3"; session coder 1 "$BASE"
jq -cn --arg p "You are the coder of team alfa. run \`$RUN_ID\`, attempt \`1\`" \
  '{type: "user", timestamp: "2026-10-03T00:00:00Z", message: {content: $p}}' > "$CP3/c1.jsonl"
T0=$(( $(date +%s) - 100 ))
touch -t "$(date -r "$T0" +%Y%m%d%H%M.%S)" "$CP3/c1.jsonl"
echo "$(date -u -r "$T0" +%Y-%m-%dT%H:%M:%SZ) idle_prompt Claude is waiting" > "$RD/attention"
STUB_TMUX_ALIVE=0 STUB_PANE= snap "question in the same second" 'coder.status == "attention"
  and (.attention[] | select(.kind == "attention") | .tmux == "alfa-coder" and .role == "coder")'
touch -t "$(date -r "$((T0 + 5))" +%Y%m%d%H%M.%S)" "$CP3/c1.jsonl"
STUB_TMUX_ALIVE=0 STUB_PANE= snap "answered question" 'coder.status == "running" and .attention == []'
mkrec coder "$BASE" blocked
echo "$(date -u -r "$((T0 + 5))" +%Y-%m-%dT%H:%M:%SZ) idle_prompt Claude is waiting" > "$RD/attention"
STUB_TMUX_ALIVE=0 STUB_PANE= snap "idle on a blocked record" 'coder.status == "blocked"
  and (.attention | map(.kind) == ["blocked"])'
rm -f "$RD/coder-1-1.json"
rm -f "$TD/session.json" "$RD/attention"

mkrec coder "$BASE" blocked
jq '.message = "Which DTO field?"' "$RD/coder-1-1.json" > "$WORK/b" && mv "$WORK/b" "$RD/coder-1-1.json"
snap "blocked record in the bar" '.attention | map(select(.kind == "blocked")) | .[0]
  | .text == "Which DTO field?" and .team == "alfa" and (.commands | index("/start-team alfa"))'
rm -f "$RD/coder-1-1.json"

# TT-826: ADO can reactivate an abandoned PR, so only `completed` is cached for good.
export TEAM_DASH_CACHE="$WORK/cache3"; mkdir -p "$TEAM_DASH_CACHE"
mkrec wrapup "$BASE"; pr_json false "$BASE"
echo abandoned > "$TEAM_DASH_CACHE/pr-alfa-8371"
touch -t "$(ago 120)" "$TEAM_DASH_CACHE/pr-alfa-8371"
: > "$STUB_LOG"
snap "abandoned → active" "($TEAM | .state == \"awaiting_merge\")"
has "repos pr show" "$STUB_LOG" || fail "an old abandoned cache entry was not rechecked"
echo abandoned > "$TEAM_DASH_CACHE/pr-alfa-8371"; : > "$STUB_LOG"
snap "fresh abandoned cache" "($TEAM | .state == \"free\")"
has "repos pr show" "$STUB_LOG" && fail "a fresh abandoned cache entry still called az"
unset TEAM_DASH_CACHE; rm -f "$RD/wrapup-1-1.json"*

# An approved permission prompt during a long tool run leaves no open question.
session coder 1 "$BASE"; touch -t "$(date -r "$T0" +%Y%m%d%H%M.%S)" "$CP3/c1.jsonl"
echo "$(date -u -r "$T0" +%Y-%m-%dT%H:%M:%SZ) permission_prompt Claude needs your permission" \
  > "$RD/attention"
STUB_TMUX_ALIVE=0 STUB_PANE= snap "permission_prompt skipped" 'coder.status == "running"
  and .attention == []'

# Role-card commands follow the pane: text question → say, menu → pick/other, prompt → yes/no.
echo "$(date -u -r "$T0" +%Y-%m-%dT%H:%M:%SZ) idle_prompt Claude is waiting" > "$RD/attention"
ACT='coder.actions | map(split(" ")[4]) as $v'
STUB_TMUX_ALIVE=0 STUB_PANE= snap "question offers say" "coder.status == \"attention\"
  and ($ACT | (\$v | index(\"say\")) and (\$v | index(\"yes\") | not))"
printf 'Which one?\n❯ 1. A\n  2. Type something.\nEnter to select · ↑/↓ to navigate\n' \
  > "$WORK/pane-menu"
STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane-menu" snap "menu offers pick/other" "$ACT
  | (\$v | index(\"pick\")) and (\$v | index(\"other\")) and (\$v | index(\"say\") | not)
  and (\$v | index(\"yes\") | not)"
printf 'Ship it?\n❯ 1. Yes\n  2. No\n  3. Type something.\nEnter to select\n' > "$WORK/pane-yn"
STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane-yn" snap "Yes/No menu offers pick/other" "$ACT
  | (\$v | index(\"pick\")) and (\$v | index(\"yes\") | not) and (\$v | index(\"no\") | not)"
printf 'Bash command\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n' > "$WORK/pane-prompt"
STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane-prompt" snap "prompt offers yes/no" "$ACT
  | (\$v | index(\"yes\")) and (\$v | index(\"no\")) and (\$v | index(\"say\") | not)"
rm -f "$TD/session.json" "$RD/attention"

# Finished = the mode's last role: a failed wrapup line must not let qa pass for the last role.
mkrec qa "$BASE"; mkrec wrapup "$BASE"
jq '.attempt = "x"' "$RD/wrapup-1-1.json" > "$WORK/w" && mv "$WORK/w" "$RD/wrapup-1-1.json"
: > "$STUB_LOG"
snap "failed last role is not finished" '(.teams[] | select(.team == "alfa") | .state == null)
  and any(.errors[]; . == "alfa/wrapup: failed")'
has "repos pr show" "$STUB_LOG" && fail "a team without its last role asked ADO"
rm -f "$RD"/qa-1-1.json* "$RD"/wrapup-1-1.json*

# One hung ADO costs one timeout per snapshot, not one per finished team.
: > "$STUB_LOG"; SECONDS=0
( W="$WORK/w5"; mkdir -p "$W"; : > "$W/errors"; NOW="$(date -u +%s)"
  err() { printf '%s\n' "$*" >> "$W/errors"; }
  age() { echo $(( NOW - $(stat -f %m "$1") )); }
  . "$CLONE/.claude/lib/team-lib.sh"; . "$CLONE/.claude/lib/team-pr-state.sh"
  cd "$CLONE"; export STUB_AZ_SLEEP=6 TEAM_DASH_PR_SECS=1
  pr_state "$CLONE" alfa 8371; pr_state "$CLONE" beta 8372 ) > "$WORK/out" 2>&1
[ "$(tr '\n' ' ' < "$WORK/out")" = "unknown unknown " ] || fail "pr_state after a timeout"
[ "$(grep -c 'repos pr show' "$STUB_LOG")" = 1 ] || fail "az called again after a timeout"
[ "$SECONDS" -lt 4 ] || fail "hung ADO held two teams ${SECONDS}s"
has "beta: PR 8372 skipped" "$WORK/w5/errors" || fail "skipped PR not reported"
unset TEAM_DASH_PROJECT_DIR TEAM_DASH_SESSION

# ---- (28) static checks -------------------------------------------------------------------------
[ "$(wc -l < "$SRC/.claude/lib/team-run.sh")" -lt 500 ] || fail "team-run.sh reached 500 lines"
[ "$(wc -l < "$SRC/.claude/dashboard/index.html")" -lt 500 ] || fail "index.html reached 500 lines"
for f in "$SRC"/.claude/lib/team-snapshot-*.sh; do
  [ "$(wc -l < "$f")" -lt 500 ] || fail "$(basename "$f") reached 500 lines"
done
for p in planner-quick cli; do
  bad="$(grep -o '{{[A-Z_]*}}' "$SRC/.claude/team/prompts/$p.md" | sort -u \
    | grep -vxE '\{\{(TEAM|TICKET|BRANCH|LINE|BASE_SHA|RUN|ATTEMPT|PLAN|SPEC|PR|ORG_URL|QA_REPORT|BUILD_CHECK|TEST_GATE)\}\}' || true)"
  [ -z "$bad" ] || fail "$p prompt has unrendered keys: $bad"
done
! grep -n 'busy of' "$SRC/.claude/lib/team-attach.sh" || fail "team-attach.sh polls Terminal's busy flag"

# ---- (30) accepted QA launches the actual wrapup prompt (TT-827) ---------------------------------
setmode brainstorm; fresh_run alfa-20261006-000005
WRAP_REV="$(git -C "$CLONE" rev-parse HEAD)"
for role in planner coder qa; do mkrec "$role" "$WRAP_REV"; done
jq '.artifacts = [".agents/plans/done/accepted.md"]' "$RD/coder-1-1.json" > "$WORK/coder"
mv "$WORK/coder" "$RD/coder-1-1.json"
# A prior attempt accepted B/create-1; attempt 2 must retain that mapping, even if A is now listed.
jq -n --arg marker "[wrapup $RUN_ID create-1]" \
  '{drafts: {"create-1": {accepted: true, summary: "B", parent: "TT-780", uploads: [],
    marker: $marker, description: ("B draft\n" + $marker)}},
    intents: {"create-1": {state: "done", draft_id: "create-1", issue_key: "TT-901"}}}' \
  > "$RD/wrapup-state.json"
cp "$RD/wrapup-state.json" "$WORK/wrapup-state"
: > "$STUB_LOG"
run "$MAIN" $TR alfa
expect 5 "dead attempt 2 of wrapup" "wrapup launch retries then stops with stubbed Claude"
WP="$RD/wrapup-1.prompt.md"
has "wrapup of team alfa working on TT-793" "$WP" || fail "wrapup lacks team/ticket context"
has "plan \`.agents/plans/done/accepted.md\`, PR \`8371\`" "$WP" || fail "wrong wrapup inputs"
has ".agents/team/runs/$RUN_ID/qa-report-1.md" "$WP" || fail "wrapup lacks accepted QA context"
! grep -q '{{[A-Z_]*}}' "$WP" || fail "wrapup has unrendered placeholders"
for rule in 'Fetch TT-793 with `fields="parent"`' 'issuetype.name == "Epic"' \
  'Never use the run' 'parent Epic: <key> — <summary>' \
  'Show that full dry-run once before the question.' \
  ".agents/team/runs/$RUN_ID/wrapup-1.md" \
  'A choice accepts exactly the displayed, saved draft' \
  'no second dry-run and no "Tworzę? [y/n/edit]"' \
  'separate pending intent' 'read-only issue inspection' \
  'a `done` creation is never repeated' 'Re-read the active TT sprint' \
  '.agents/memory/domain/jira.md'; do
  has "$rule" "$WP" || fail "rendered wrapup lacks rule: $rule"
done
has "[wrapup $RUN_ID <op>-<n>]" "$WP" || fail "wrapup lost the recovery marker"
WP2="$RD/wrapup-2.prompt.md"
has 'attempt `2`' "$WP2" || fail "runner did not render retry attempt 2"
for rule in ".agents/team/runs/$RUN_ID/wrapup-state.json" \
  'Reuse saved accepted drafts and markers verbatim' 'never regenerate or renumber them' \
  'Recommendation numbers are display' 'stable intent id → issue key mapping' \
  'No new/unaccepted recommendations → step 8 for saved accepted work still unfinished' \
  'final line equals the exact saved marker'; do
  has "$rule" "$WP2" || fail "attempt 2 wrapup lacks recovery rule: $rule"
done
cmp -s "$WORK/wrapup-state" "$RD/wrapup-state.json" || fail "runner rewrote accepted B/create-1"
for p in .claude/team/prompts/wrapup.md .claude/skills/jira/SKILL.md \
  .agents/reference/team-mode.md .claude/lib/tests/team-smoke-3.sh; do
  [ "$(wc -l < "$SRC/$p")" -le 500 ] || fail "$p exceeds 500 lines"
done

echo "team-smoke-3: OK"
