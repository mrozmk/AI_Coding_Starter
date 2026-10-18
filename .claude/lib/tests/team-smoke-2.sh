#!/usr/bin/env bash
# Wrapup, transcript and role-override checks with an independent fixture.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team TT-792 feature/TT-792-next

# ---- retry after a failed /start-team roles override ---------------------------------------------
cp "$TD/team.json" "$WORK/retry-team.json"
RETRY_HEAD="$(git -C "$CLONE" rev-parse HEAD)"
run "$MAIN" $TR alfa roles planner=claude-fable-5-1/high
expect 0 "roles override:" "retry fixture initial roles"
cp "$TD/roles.override.json" "$WORK/retry-roles.json"
RUN_ID=alfa-retry-fixture
printf '%s\n' "$RUN_ID" > "$TD/run"; mkdir -p "$TD/runs/$RUN_ID"
echo preserved > "$TD/runs/$RUN_ID/notes.md"
run "$MAIN" $TR alfa roles 'planner=x;y'
expect 1 "bad model" "start-team step 4a failure"
for retry_branch in feature/TT-792-next feature/TT-792-retry; do
  run "$MAIN" bash .claude/lib/team-next.sh alfa TT-792 "$retry_branch" origin/develop-netcore7
  expect 1 "resume with /start-team alfa" "same-ticket retry $retry_branch"
  cmp -s "$TD/team.json" "$WORK/retry-team.json" || fail "retry changed team.json"
  cmp -s "$TD/roles.override.json" "$WORK/retry-roles.json" || fail "retry changed roles"
  has "$RUN_ID" "$TD/run" && has preserved "$TD/runs/$RUN_ID/notes.md" || fail "retry archived run state"
  [ ! -e "$TD/archive" ] || fail "retry created an archive"
  [ "$(git -C "$CLONE" rev-parse HEAD)" = "$RETRY_HEAD" ] || fail "retry changed HEAD"
  [ "$(git -C "$CLONE" branch --show-current)" = feature/TT-792-next ] || fail "retry switched branch"
  ! git -C "$CLONE" rev-parse --verify --quiet refs/heads/feature/TT-792-retry >/dev/null \
    || fail "retry created a branch"
done
run "$MAIN" $TR alfa roles planner=claude-fable-5-1/xhigh
expect 0 "roles override:" "resume applies corrected roles"
run "$MAIN" $TR alfa status
expect 0 '"ticket":"TT-792"' "resume keeps ticket identity"
: > "$STUB_LOG"
run "$MAIN" $TR alfa
expect 5 "dead attempt 1 of planner" "resume launches existing clone"
has "new-session -d -s alfa-planner" "$STUB_LOG" || fail "resume did not launch planner"
has "--effort 'xhigh'" "$STUB_LOG" || fail "resume ignored corrected roles"
rm -f "$TD/session.json" "$TD/run"; rm -rf "$TD/runs/$RUN_ID"
run "$MAIN" $TR alfa roles --clear
expect 0 "roles override cleared" "retry fixture clears override"

commit_file wip.txt wip

# ---- (14) wrapup role ----------------------------------------------------------------------------
BR="$(jq -r .branch "$TD/team.json")"
RUN_ID=alfa-20261004-000000; echo "$RUN_ID" > "$TD/run"; mkdir -p "$TD/runs/$RUN_ID"
RD="$TD/runs/$RUN_ID"
rm -f "$TD/session.json"; rm -rf "$TD/lock" "$TD/acked"
git -C "$CLONE" push --quiet origin "$BR"
Q="$(git -C "$CLONE" rev-parse HEAD)"
TGT0="$(git -C "$CLONE" ls-remote origin refs/heads/develop-netcore7 | cut -f1)"
summary() { printf 'target_rev: %s\n## Planowanie\nok\n' "$1" > "$RD/wrapup-1.md"; }
mkrec coder "$Q"; mkrec qa "$Q"
session wrapup 1 "$Q"
commit_file .agents/memory/errors.md "lesson"
W1="$(git -C "$CLONE" rev-parse HEAD)"; point "$W1"
summary "$TGT0"; pr_w "$W1"
R=$(record --verdict done --pr 8371 --artifacts "$RD/wrapup-1.md")
run "$MAIN" $TR alfa check "$R"
expect 0 "valid:" "wrapup memory-only commit"
summary ""
run "$MAIN" $TR alfa check "$R"
expect 4 "target_rev" "wrapup summary without target_rev"
summary "$TGT0"
jq '.pr_id = null' "$R" > "$WORK/r.json" && mv "$WORK/r.json" "$R"
run "$MAIN" $TR alfa check "$R"
expect 4 "PR identity mismatch" "wrapup record without --pr"
commit_file src2.txt code
W2="$(git -C "$CLONE" rev-parse HEAD)"; point "$W2"; pr_w "$W2"
R=$(record --verdict done --pr 8371 --artifacts "$RD/wrapup-1.md")
run "$MAIN" $TR alfa check "$R"
expect 4 "outside .agents/memory/" "wrapup touched code"
point "$Q"; pr_w "$Q"
R=$(record --verdict done --pr 8371 --artifacts "$RD/wrapup-1.md")
run "$MAIN" $TR alfa check "$R"
expect 0 "valid:" "wrapup with nothing to save"
rm -f "$RD"/wrapup-1-*.json "$TD/session.json"

# ---- (15) team-merge-check with wrapup -----------------------------------------------------------
MC="bash .claude/lib/team-merge-check.sh"
run "$MAIN" $MC alfa
expect 3 "wrapup not done" "merge-check before wrapup"
session wrapup 1 "$Q"
run "$MAIN" $MC alfa
expect 3 "still live" "merge-check while a role is live"
rm -f "$TD/session.json"
point "$W1"; mkrec wrapup "$W1"; summary "$TGT0"; merge_at "$W1"
run "$MAIN" $MC alfa
expect 0 "VERDICT: ok" "merge-check after wrapup"
# The line gains the same memory file after the wrapup's target_rev.
mkdir -p "$MAIN/.agents/memory" && echo "other team" > "$MAIN/.agents/memory/errors.md"
git -C "$MAIN" add .agents/memory/errors.md && git -C "$MAIN" commit --quiet -m "other team memory"
git -C "$MAIN" push --quiet origin HEAD:develop-netcore7
TGT1="$(git -C "$MAIN" rev-parse HEAD)"
merge_at "$W1" "$TGT1"
run "$MAIN" $MC alfa
expect 3 "memory overlap: .agents/memory/errors.md" "merge-check memory overlap"
run "$MAIN" $MC alfa --memory-reviewed
expect 0 "memory overlap reviewed" "merge-check overlap reviewed"
summary 0000000000000000000000000000000000000000
run "$MAIN" $MC alfa --memory-reviewed
expect 3 "unknown or not comparable" "merge-check unknown target_rev"
summary "$TGT0"
commit_file .agents/memory/errors.md "supervisor fix"
F1="$(git -C "$CLONE" rev-parse HEAD)"; point "$F1"; merge_at "$F1" "$TGT1"
run "$MAIN" $MC alfa
expect 3 "not the wrapup revision" "merge-check fix on top without flag"
run "$MAIN" $MC alfa --memory-reviewed
expect 0 "supervisor memory fix after wrapup" "merge-check fix on top reviewed"
commit_file src3.txt code
F2="$(git -C "$CLONE" rev-parse HEAD)"; point "$F2"; merge_at "$F2" "$TGT1"
run "$MAIN" $MC alfa --memory-reviewed
expect 3 "outside .agents/memory/" "merge-check code on top of wrapup"
run "$MAIN" $MC alfa --bogus
expect 2 "Usage:" "merge-check bad flag"
unset MERGE_SHA; rm -f "$RD"/wrapup-1-1.json*; point "$Q"

# ---- (16) hook, notes, unlock, static checks -----------------------------------------------------
session wrapup 1 "$Q"
hook "$CLONE" '{"tool_input":{"file_path":".agents/memory/errors.md"}}'
expect 0 "" "guard lets wrapup write memory"
session coder 1 "$Q"
hook "$CLONE" '{"tool_input":{"file_path":".agents/memory/errors.md"}}'
expect 2 "written by the wrapup role only" "guard still blocks coder"
rm -f "$TD/session.json"
NF="$(cd "$CLONE" && . .claude/lib/team-lib.sh && team_notes_init alfa-notes-check)"
[ "$(grep '^## ' "$NF" | tr '\n' '|')" = "## Unattended decisions|## Learnings|## Follow-ups|## Blockers|" ] \
  || fail "notes headings: $(grep '^## ' "$NF" | tr '\n' '|')"
mkdir "$TD/lock"
run "$MAIN" $TR alfa unlock
expect 1 "no pid recorded" "unlock without a pid"
echo $$ > "$TD/lock/pid"
run "$MAIN" $TR alfa unlock
expect 1 "is alive" "unlock a live runner"
echo 999999 > "$TD/lock/pid"; touch -t "$(date -v-1M +%Y%m%d%H%M.%S)" "$TD/lock"
run "$MAIN" $TR alfa unlock
expect 0 "removed stale lock" "unlock a dead runner"
[ ! -e "$TD/lock" ] || fail "unlock left the lock"
run "$MAIN" bash .claude/lib/team-run.sh
expect 2 "Exit:" "team-run usage prints exit codes"
[ "$(wc -l < "$SRC/.claude/lib/team-snapshot.sh")" -lt 500 ] || fail "team-snapshot.sh reached 500 lines"
bad="$(grep -o '{{[A-Z_]*}}' "$SRC/.claude/team/prompts/wrapup.md" | sort -u \
  | grep -vxE '\{\{(TEAM|TICKET|BRANCH|LINE|BASE_SHA|RUN|ATTEMPT|PLAN|SPEC|PR|ORG_URL|QA_REPORT|BUILD_CHECK|TEST_GATE|TRACKER_READ|TRACKER_WRAPUP|TRACKER_TASK|PR_HOST_KIND|PR_HOST|PR_CREATE|PR_CREATE_READY|PR_PUBLISH|PR_BODY_GET|PR_BODY_SET|PR_TOOL|GATES_NOTE)\}\}' || true)"
[ -z "$bad" ] || fail "wrapup prompt has unrendered keys: $bad"
! grep -q innerHTML "$SRC/.claude/dashboard/index.html" || fail "dashboard uses innerHTML"
! grep -nE -- "-t =[a-z<]" "$SRC/.agents/reference/team-pipeline.md" "$SRC/.claude/commands/monitor.md" \
  || fail "unquoted tmux -t =NAME in docs"

# ---- (17) snapshot: skill trail, sub-agent runs, role transcript, resume hint ---------------------
CL2="$WORK/claude2"; mkdir -p "$CL2/s2/subagents" "$MAIN/.claude/agents"
cp "$SRC/.claude/agents/correctness-reviewer.md" "$MAIN/.claude/agents/"
skill_line() {  # skill_line <ts> <skill>
  jq -cn --arg t "$1" --arg s "$2" '{type: "assistant", timestamp: $t,
    message: {model: "m", content: [{type: "tool_use", name: "Skill", input: {skill: $s}}]}}'
}
{ jq -cn '{type: "user", timestamp: "2026-10-04T10:00:00Z",
    message: {content: "<command-message>prime</command-message>\n<command-name>/prime</command-name>"}}'
  skill_line 2026-10-04T10:01:00Z check-implementation
  skill_line 2026-10-04T10:02:00Z gates:verify-implementation; } > "$CL2/s2.jsonl"
echo '{"type":"assistant","message":{"model":"m","stop_reason":"end_turn"}}' > "$CL2/s2/subagents/agent-b1.jsonl"
echo '{"agentType":"correctness-reviewer","description":"finder"}' > "$CL2/s2/subagents/agent-b1.meta.json"
echo '{"type":"assistant","message":{"model":"m"}}' > "$CL2/s3.jsonl"
export TEAM_DASH_PROJECT_DIR="$CL2" TEAM_DASH_SESSION=s2
snap "skill trail" '(.supervisor.skills | map(.skill)) == ["/prime","/check-implementation","/gates:verify-implementation"]
  and (.subagents[] | select(.id == "b1") | .owner == "/check-implementation"
       and .runs[0] == {skill: "/code-review", how: "preloaded"})'
TEAM_DASH_SESSION=s3 snap "no skill starts" '.supervisor.skills == [] and (.errors | all(test("skill") | not))'
chmod 000 "$CL2/s3.jsonl"
TEAM_DASH_SESSION=s3 snap "unreadable transcript" '(.supervisor.skills // null) == null and (.errors | length > 0)'
chmod 644 "$CL2/s3.jsonl"

sub_tool() {  # <id> <tool> <result id | ->
  { jq -cn '{type: "assistant", timestamp: "2026-10-06T00:00:00Z",
      message: {model: "m", content: [{type: "thinking", thinking: "checking"}]}}'
    jq -cn --arg id "call-$1" --arg tool "$2" '{type: "assistant",
      message: {model: "m", stop_reason: "tool_use",
        content: [{type: "tool_use", id: $id, name: $tool, input: {}}]}}'
    if [ "$3" != - ]; then
      jq -cn --arg id "$3" '{type: "user", message: {
        content: [{type: "tool_result", tool_use_id: $id, content: "returned"}]}}'
    fi; } > "$CL2/s2/subagents/agent-$1.jsonl"
}
sub_stale() { touch -t "$(date -v-"$2"S +%Y%m%d%H%M.%S)" "$CL2/s2/subagents/agent-$1.jsonl"; }
sub_tool handback SubagentHandback call-handback
snap "fresh handback" 'any(.subagents[]; .id == "handback" and .status == "done")'
sub_stale handback 600
snap "stale handback" 'any(.subagents[]; .id == "handback" and .status == "done")
  and any(.events[]; .text == "finished agent")'
sub_tool unreturned SubagentHandback -
snap "fresh unreturned handback" 'any(.subagents[]; .id == "unreturned" and .status == "running")'
sub_stale unreturned 600
sub_tool failed SubagentHandback call-failed
jq -c 'if .type == "user" then .message.content[0].is_error = true else . end' \
  "$CL2/s2/subagents/agent-failed.jsonl" > "$WORK/failed-handback"
mv "$WORK/failed-handback" "$CL2/s2/subagents/agent-failed.jsonl"
snap "fresh failed handback" 'any(.subagents[]; .id == "failed" and .status == "running")'
sub_stale failed 600
sub_tool wrong-id SubagentHandback other-call; sub_stale wrong-id 600
sub_tool pending Bash -; sub_stale pending 600
echo '{"type":"assistant","message":{"model":"m","content":[]}}' \
  > "$CL2/s2/subagents/agent-abandoned.jsonl"
sub_stale abandoned 600
echo '{"type":"assistant","message":{"model":"m","content":[]}}' \
  > "$CL2/s2/subagents/agent-active.jsonl"
sub_tool resumed SubagentHandback call-resumed
echo '{"type":"assistant","message":{"model":"m","content":[]}}' \
  >> "$CL2/s2/subagents/agent-resumed.jsonl"
sub_stale resumed 600
sub_stale b1 600
snap "sub-agent status rules" '
  (.subagents | map({key: .id, value: .status}) | from_entries) as $s
  | $s.handback == "done" and $s.b1 == "done" and $s.unreturned == "idle"
    and $s["wrong-id"] == "idle" and $s.failed == "idle"
    and $s.abandoned == "idle" and $s.resumed == "idle"
    and $s.active == "running" and $s.pending == "running"'
sub_stale pending 3700
snap "expired pending tool" 'any(.subagents[]; .id == "pending" and .status == "idle")'
for n in $(seq 1 14); do
  sub_tool "finished-$n" SubagentHandback "call-finished-$n"
  sub_stale "finished-$n" "$((180 + n))"
done
# Finishes < 10 min always stay (TT-823); only the two older ones fall beyond the cap.
snap "fresh finishes beat the cap" '
  (.subagents | map(select(.status == "done")) | length) == 14
  and (.subagents | map(select(.status != "done")) | length) == 7
  and any(.errors[]; . == "subagents: 2 older finished hidden")'
for n in $(seq 1 14); do rm -f "$CL2/s2/subagents/agent-finished-$n.jsonl"; done

# The clone's transcripts live beside the supervisor's project dir, named after the clone path.
WR='(.teams[0].roles[] | select(.role == "wrapup")'
# The snapshot sees the clone path git resolves (/private/var on macOS), not the mktemp spelling.
CP="$WORK/$(. "$SRC/.claude/lib/team-lib.sh" && team_project_slug "$(cd "$CLONE" && pwd -P)")"; mkdir -p "$CP"
role_t() {  # role_t <file> <first prompt>
  { jq -cn --arg p "$2" '{type: "user", timestamp: "2026-10-03T00:00:00.5Z", message: {content: $p}}'
    skill_line 2026-10-03T00:01:00Z execute; } > "$CP/$1.jsonl"
}
# coder and qa are accepted in this run, so the live role is the wrapup.
session wrapup 1 "$Q"
role_t r1 "You are the wrapup of team alfa working on TT-792. Context: run \`$RUN_ID\`,
attempt \`1\`, plan x."
STUB_TMUX_ALIVE=0 STUB_PANE= snap "role transcript" "$WR"' | .skills | map(.skill)) == ["/execute"]'
role_t r2 "You are the wrapup of team alfa. run \`$RUN_ID\`, attempt \`1\`"
STUB_TMUX_ALIVE=0 STUB_PANE= snap "two role transcripts" \
  "$WR"' | .skills) == null and any(.errors[]; test("transcript not identified \\(2 candidates\\)"))'
rm -f "$CP/r2.jsonl"; role_t r1 "Unrelated session in the clone"
STUB_TMUX_ALIVE=0 STUB_PANE= snap "foreign transcript" "$WR"' | .skills) == null'
rm -f "$TD/session.json"; mkrec coder "$Q" blocked
STUB_TMUX_ALIVE=1 snap "resume hint" '.teams[0].resume_hint == "/start-team alfa"'
rm -f "$RD/coder-1-1.json"; unset TEAM_DASH_PROJECT_DIR TEAM_DASH_SESSION

# ---- (18) per-ticket roles override -------------------------------------------------------------
OV="$TD/roles.override.json"
RUN_ID=alfa-20261005-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
rm -f "$TD/session.json"; rm -rf "$TD/lock" "$TD/acked"
run "$MAIN" $TR alfa roles planner=claude-fable-5-1/high
expect 0 'roles override: {"planner":{"model":"claude-fable-5-1","effort":"high"}}' "roles writes"
run "$MAIN" $TR alfa roles coder=/xhigh
expect 0 '"coder":{"effort":"xhigh"}' "roles merges"
has '"model": "claude-fable-5-1"' "$OV" || fail "roles merge dropped planner"
cp "$OV" "$WORK/ov.bak"
for bad in "planner=x;y" planer=opus planner= planner "planner coder=opus" \
  coder=/hihg coder=/HIGH; do
  : > "$STUB_LOG"
  TEAM_NOTIFY=1 run "$MAIN" $TR alfa roles "$bad"
  expect 1 "error:" "roles rejects $bad"
  has "osascript" "$STUB_LOG" && fail "roles refusal sent a stopped notification"
  cmp -s "$OV" "$WORK/ov.bak" || fail "rejected roles entry $bad changed the file"
done
run "$MAIN" $TR alfa status
expect 0 'roles override: {"planner"' "status shows the override"
for args in '' '--clear coder=/high'; do
  : > "$STUB_LOG"
  TEAM_NOTIFY=1 run "$MAIN" $TR alfa roles $args
  expect 2 "usage:" "roles refuses usage $args"
  has "osascript" "$STUB_LOG" && fail "roles usage refusal notified stopped"
  cmp -s "$OV" "$WORK/ov.bak" || fail "usage refusal changed override"
done
run "$MAIN" $TR alfa roles coder=/hihg coder=/high
expect 0 '"coder":{"effort":"high"}' "validate final candidate, not intermediate entries"
echo '{"coder":{"effort":"hihg"}}' > "$OV"
run "$MAIN" $TR alfa roles coder=/xhigh
expect 0 '"effort":"xhigh"' "overwrite repairs old invalid value"
for bad in '{"planer":{"model":"opus"}}' '{"qa":{"modle":"opus"}}' '{' '{} {}' \
  '{"coder":"opus"}' '{"coder":null}'; do
  printf '%s\n' "$bad" > "$OV"; cp "$OV" "$WORK/invalid-ov.bak"; : > "$STUB_LOG"
  TEAM_NOTIFY=1 run "$MAIN" $TR alfa roles coder=/high
  expect 1 "roles --clear" "existing invalid override $bad"
  cmp -s "$OV" "$WORK/invalid-ov.bak" || fail "refusal rewrote old invalid override"
  has "osascript" "$STUB_LOG" && fail "old override refusal notified stopped"
done
echo '{"coder":"opus"}' > "$OV"
run "$MAIN" $TR alfa roles coder=/high
expect 1 "coder is not an object" "non-object role reaches candidate validation"
cp "$WORK/ov.bak" "$OV"
cp "$CLONE/.claude/lib/team-lib.sh" "$WORK/team-lib.bak"
sed 's/TEAM_ROLES="planner coder qa wrapup"/TEAM_ROLES="planner coder qa"/' \
  "$WORK/team-lib.bak" > "$CLONE/.claude/lib/team-lib.sh"
run "$MAIN" $TR alfa roles wrapup=/high
expect 1 "unknown role wrapup" "override keys still follow old clone roles"
cmp -s "$OV" "$WORK/ov.bak" || fail "unknown clone role changed override"
mv "$CLONE/.claude/lib/team-roles.sh" "$WORK/team-roles.sh"; : > "$STUB_LOG"
run "$MAIN" $TR alfa
expect 5 "dead attempt 1 of planner" "planner launch with override"
has "-n alfa-planner --model 'claude-fable-5-1' --effort 'high' -- " "$STUB_LOG" \
  || fail "planner launch lacks the override model/effort"
mv "$WORK/team-roles.sh" "$CLONE/.claude/lib/team-roles.sh"
cp "$WORK/team-lib.bak" "$CLONE/.claude/lib/team-lib.sh"
rm -f "$TD/session.json"; mkrec planner "$Q"; session coder 1 "$Q"; : > "$STUB_LOG"
cp "$TD/session.json" "$WORK/session.bak"
echo '{"coder":{"model":"x; rm -rf y"}}' > "$OV"
run "$MAIN" $TR alfa
expect 1 'bad model "x; rm -rf y" for coder in ' "override value validated at launch"
has "roles.override.json" "$WORK/out" || fail "override error does not name the file"
[ "$(jq -r .attempt "$TD/session.json")" = 1 ] || fail "rejected override recorded an attempt"
has "new-session" "$STUB_LOG" && fail "rejected override launched a session"
cmp -s "$TD/session.json" "$WORK/session.bak" || fail "bad override model changed session.json"
cp "$WORK/ov.bak" "$OV"; : > "$STUB_LOG"
run "$MAIN" $TR alfa
expect 5 "dead attempt 2 of coder" "resume after fixing the override"
has "-n alfa-coder --model 'opus[1m]' --effort 'xhigh' --disallowedTools" "$STUB_LOG" \
  || fail "coder lacks roles.json model + override effort"
for effort in low medium high xhigh max; do
  run "$MAIN" $TR alfa roles "coder=/$effort"
  expect 0 "roles override:" "write valid effort $effort"
  session coder 1 "$Q"; : > "$STUB_LOG"
  run "$MAIN" $TR alfa
  expect 5 "dead attempt 2 of coder" "launch valid effort $effort"
  has "--effort '$effort'" "$STUB_LOG" || fail "launch dropped valid effort $effort"
done
for f in '{"planer":{"model":"opus"}}' '{' '{} {}' '{"qa":{"modle":"opus"}}' \
  '{"coder":{"effort":"hihg"}}' '{"coder":{"effort":"high\n"}}' \
  '{"coder":{"model":"opus\n"}}' '{"coder":{"effort":7}}'; do
  printf '%s\n' "$f" > "$OV"; rm -f "$TD/session.json"; session coder 1 "$Q"
  cp "$TD/session.json" "$WORK/session.bak"; : > "$STUB_LOG"
  run "$MAIN" $TR alfa; expect 1 "roles.override.json" "invalid override file $f"
  cmp -s "$TD/session.json" "$WORK/session.bak" || fail "invalid override changed session.json"
  has "new-session" "$STUB_LOG" && fail "invalid override launched a session"
  run "$MAIN" $TR alfa status
  expect 0 "roles override: invalid — " "status diagnoses invalid override $f"
  case "$f" in *'\n'*)
    has '\n" for coder' "$WORK/out" || fail "status did not JSON-escape invalid value" ;;
  esac
done
rm -f "$TD/session.json"; cp "$WORK/ov.bak" "$OV"
PL='(.teams[0].roles[] | select(.role == "planner"))'
snap "override in dashboard" "$PL"' | .model == "claude-fable-5-1" and .effort == "high"'
BASE_ROLES="$MAIN/.claude/team/roles.json"; CLONE_ROLES="$CLONE/.claude/team/roles.json"
cp "$BASE_ROLES" "$WORK/dashboard-base.bak"; cp "$CLONE_ROLES" "$WORK/dashboard-clone.bak"
jq '.teams[0].roles | map({role, model, effort})' "$WORK/snap.json" > "$WORK/config.before"
for overlay in without with; do
  if [ "$overlay" = without ]; then rm -f "$OV"; else cp "$WORK/ov.bak" "$OV"; fi
  for fixture in '{"coder":{"effort":"hihg"}}|bad effort "hihg" for coder' \
    '{"planer":{"model":"opus"}}|unknown role planer' \
    '{"plan\ner":{}}|unknown role plan er' \
    '{"qa":{"modle":"opus"}}|unknown field qa.modle' \
    '{"coder":{"model":"x;y"}}|bad model "x;y" for coder' \
    '{|not a single JSON object' '{} {}|not a single JSON object' \
    '{"coder":7}|coder is not an object' \
    '{"qa":{"effort":7}}|bad effort for qa: not a string'; do
    printf '%s\n' "${fixture%%|*}" > "$BASE_ROLES"
    reason="$(jq -Rn --arg msg "${fixture#*|}" '$msg')"
    snap "invalid base $overlay: ${fixture#*|}" \
      "(.teams[0].roles | length == 4 and all(.model == null and .effort == null))
       and any(.errors[]; startswith(\"alfa: invalid \") and contains(\"roles.json\")
         and contains($reason))"
  done
done
cp "$WORK/dashboard-base.bak" "$BASE_ROLES"
snap "base restored" '.errors | all(contains("roles.json") | not)'
jq '.teams[0].roles | map({role, model, effort})' "$WORK/snap.json" > "$WORK/config.after"
cmp -s "$WORK/config.before" "$WORK/config.after" || fail "restored base changed role config"
rm -f "$BASE_ROLES"
snap "clone base fallback" '.errors | all(contains("roles.json") | not)'
jq '.teams[0].roles | map({role, model, effort})' "$WORK/snap.json" > "$WORK/config.after"
cmp -s "$WORK/config.before" "$WORK/config.after" || fail "clone fallback changed role config"
echo '{"coder":{"effort":"hihg"}}' > "$CLONE_ROLES"
snap "bad clone base fallback" \
  '(.teams[0].roles | length == 4 and all(.model == null and .effort == null))
   and any(.errors[]; contains("main-alfa/.claude/team/roles.json") and contains("bad effort"))'
rm -f "$CLONE_ROLES"
snap "both bases missing with override" "($PL"' | .model == "claude-fable-5-1")
  and (.teams[0].roles[] | select(.role == "coder") | .model == null and .effort == "xhigh")
  and (.errors | all(contains("roles.json") | not))'
rm -f "$OV"
snap "both bases and override missing" \
  '(.teams[0].roles | length == 4 and all(.model == null and .effort == null))
   and (.errors | all(contains("roles.json") | not))'
cp "$WORK/dashboard-base.bak" "$BASE_ROLES"; cp "$WORK/dashboard-clone.bak" "$CLONE_ROLES"
cp "$WORK/ov.bak" "$OV"
echo '{' > "$OV"
snap "invalid override in dashboard" "($PL"' | .model == "opus[1m]")
  and any(.errors[]; test("roles.override.json"))'
run "$MAIN" $TR alfa roles --clear; expect 0 "roles override cleared" "roles --clear"
[ ! -e "$OV" ] || fail "roles --clear left the file"
run "$MAIN" $TR alfa roles --clear; expect 0 "cleared" "roles --clear is idempotent"
rm -f "$TD/session.json" "$RD"/planner-1-1.json*

echo "team-smoke-2: OK"
