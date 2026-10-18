#!/usr/bin/env bash
# Team lifecycle, recovery and dashboard checks with an independent fixture.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

# ---- (3) team-new ----------------------------------------------------------------------------------
run "$MAIN" $NEW alfa TT-790
expect 2 "Usage:" "team-new argc"
chmod 644 "$MAIN/.env"
run "$MAIN" $NEW alfa TT-790 feature/TT-790-x origin/develop-netcore7
expect 1 "chmod 600 .env" "team-new .env 644"
chmod 600 "$MAIN/.env"
run "$MAIN" $NEW alfa TT-790 feature/TT-790-x origin/rc
expect 1 "base has no team harness" "team-new base without harness"
run "$MAIN" $NEW alfa TT-790 feature/TT-790-x origin/develop-netcore7
expect 0 "next:" "team-new happy path"
CLONE="$WORK/main-alfa"
[ "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" = feature/TT-790-x ] || fail "clone branch"
jq -e '.base_sha and .line == "develop-netcore7" and .ticket == "TT-790"' "$CLONE/.agents/team/team.json" >/dev/null \
  || fail "team.json fields"
[ -f "$CLONE/.env" ] && [ ! -L "$CLONE/.env" ] && [ "$(stat -f %Lp "$CLONE/.env")" = 600 ] || fail ".env copy"
run "$MAIN" $NEW alfa TT-790 feature/TT-790-x origin/develop-netcore7
expect 1 "already exists" "team-new existing dir"
run "$MAIN" $NEW beta TT-790 feature/TT-790-x origin/develop-netcore7
expect 1 "already used by team alfa" "team-new branch of another team"
run "$MAIN" $NEW beta TT-791 feature/TT-791-pushed origin/develop-netcore7
expect 1 "already exists on origin" "team-new pushed branch"

# ---- (4) team-record -------------------------------------------------------------------------------
TD="$CLONE/.agents/team"
REC="bash .claude/lib/team-record.sh"
RUN_ID=alfa-20261002-000000
echo "$RUN_ID" > "$TD/run"
run "$CLONE" $REC --verdict done
expect 1 "not in team mode" "record without session"
BASE=$(git -C "$CLONE" rev-parse HEAD)
session planner 1 "$BASE"
run "$CLONE" $REC --verdict done
expect 0 "planner-1-1.json" "record seq 1"
run "$CLONE" $REC --verdict done
expect 0 "planner-1-2.json" "record seq 2 (no overwrite)"
run "$CLONE" $REC --verdict blocked
expect 2 "requires --message" "blocked without message"
run "$CLONE" $REC --verdict blocked --message "which endpoint?"
expect 0 "planner-1-3.json" "blocked with message"
has "- [planner 1] which endpoint?" "$TD/runs/$RUN_ID/notes.md" || fail "blocker not in notes"
rm -f "$TD/runs/$RUN_ID/"planner-*.json

# ---- (5) guard-team-memory -------------------------------------------------------------------------
HOOK="$SRC/.claude/hooks/guard-team-memory.sh"
hook "$CLONE" '{"tool_input":{"file_path":".agents/memory/errors.md"}}'
expect 2 "written by the wrapup role only" "guard blocks memory in team mode"
hook "$CLONE" '{"tool_input":{"file_path":"src/Foo.cs"}}'
expect 0 "" "guard passes non-memory path"
hook "$MAIN" '{"tool_input":{"file_path":".agents/memory/errors.md"}}'
expect 0 "" "guard passes outside team mode"

# ---- one-question guard: exercise the synchronous command shipped in settings --------------------
QCOMMAND=$(jq -er '.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion") |
  .hooks | select(length == 1) | .[0] | select(.type == "command" and .async != true) |
  .command' "$SRC/.claude/settings.json")
QROOT="$WORK/question-team"
OUTSIDE="$WORK/question-main"
for root in "$QROOT" "$OUTSIDE"; do
  mkdir -p "$root/.claude/hooks"
  cp "$SRC/.claude/hooks/guard-team-question.sh" "$root/.claude/hooks/"
done
mkdir -p "$QROOT/.agents/team"; printf '{}' > "$QROOT/.agents/team/session.json"
QUESTION=$(jq -nc '{header:"Choice",question:"Which option?",
  options:[{label:"A",description:"first"},{label:"B",description:"second"}]}')
ONE=$(jq -nc --argjson q "$QUESTION" '{tool_name:"AskUserQuestion",tool_input:{questions:[$q]}}')
TWO=$(jq -nc --argjson q "$QUESTION" \
  '{tool_name:"AskUserQuestion",tool_input:{questions:[$q,($q | .header="Next")]}}')
question_hook() {
  set +e
  printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" bash -c "$QCOMMAND" > "$WORK/out" 2>&1
  RC=$?; set -e
}
question_hook "$QROOT" "$ONE"
expect 0 "" "question guard passes one in team"
question_hook "$QROOT" "$TWO"
expect 2 "one question per AskUserQuestion call" "question guard blocks two in team"
has "only after receiving the answer" "$WORK/out" ||
  fail "question guard lacks sequence instruction"
question_hook "$OUTSIDE" "$TWO"
expect 0 "" "question guard passes two outside team"

# ---- (6) validation via `team-run.sh <team> check` ---------------------------------------------------
TR="bash .claude/lib/team-run.sh"
commit_file .agents/specs/s.md spec
commit_file .agents/plans/active/p.md plan
P1="$(git -C "$CLONE" rev-parse HEAD)"
session planner 1 "$BASE"
R=$(record --verdict done --artifacts .agents/specs/s.md,.agents/plans/active/missing.md)
run "$MAIN" $TR alfa check "$R"
expect 4 "artifact .agents/plans/active/missing.md not in" "planner missing artifact"
rm -f "$R"
commit_file .agents/plans/active/q.md plan2
R=$(record --verdict done --artifacts .agents/specs/s.md,.agents/plans/active/p.md,.agents/plans/active/q.md)
run "$MAIN" $TR alfa check "$R"
expect 4 "one standalone plan" "planner two plans"
rm -f "$R"
git -C "$CLONE" rm --quiet .agents/plans/active/q.md && git -C "$CLONE" commit --quiet -m "drop q"
R=$(record --verdict done --artifacts .agents/plans/active/p.md)
run "$MAIN" $TR alfa check "$R"
expect 4 "no spec" "planner without spec"
rm -f "$R"
R=$(record --verdict done --artifacts .agents/specs/s.md,.agents/plans/active)
run "$MAIN" $TR alfa check "$R"
expect 4 "not in" "planner artifact that is a directory"
rm -f "$R"
R=$(record --verdict done --artifacts .agents/specs/s.md,.agents/plans/active/p.md)
run "$MAIN" $TR alfa check "$R"
expect 0 "valid:" "planner valid"
touch "$R.accepted"; PLANNER_OUT="$(git -C "$CLONE" rev-parse HEAD)"

mkdir -p "$CLONE/.agents/plans/done"
git -C "$CLONE" mv .agents/plans/active/p.md .agents/plans/done/p.md
commit_file src.txt code
C1="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" push --quiet origin feature/TT-790-x
session coder 1 "$PLANNER_OUT"
R=$(record --verdict done --pr 8371 --artifacts .agents/plans/done/other.md)
pr_json true "$C1"
run "$MAIN" $TR alfa check "$R"
expect 4 "coder artifact is not .agents/plans/done/p.md" "coder hands over a foreign plan"
rm -f "$R"
R=$(record --verdict done --pr 8371 --artifacts .agents/plans/done/p.md)
pr_json false "$C1"
run "$MAIN" $TR alfa check "$R"
expect 4 "isDraft is not true" "coder PR not draft"
pr_json true "$C1" succeeded refs/heads/other
run "$MAIN" $TR alfa check "$R"
expect 4 "PR identity mismatch" "coder PR other target"
pr_json true "$C1"
run "$MAIN" $TR alfa check "$R"
expect 0 "valid:" "coder valid"
CODER_REC="$R"

# ---- (9) QA report validator -------------------------------------------------------------------------
session qa 1 "$C1"
touch "$CODER_REC.accepted"
QR="$TD/runs/$RUN_ID/qa-report-1.md"
report() {  # report [sed expression applied to a valid report]
  cat > "$QR" <<EOF
run: $RUN_ID
attempt: 1
output_rev: $C1
Verdict: ready
Gate code: passed
Gate design: skipped — backend change
Gate cross-model: warn
Gate final-build: passed
Tests: passed=3 failed=0 skipped=0 baseline=0
Warnings: none
Rethink signals: none
EOF
  [ -z "${1:-}" ] || sed -i '' -e "$1" "$QR"
}
R=$(record --verdict done --pr 8371 --evidence ".agents/team/runs/$RUN_ID/qa-report-1.md")
pr_json false "$C1"
qa_case() {  # qa_case <sed> <expected text> <label>
  report "$1"; run "$MAIN" $TR alfa check "$R"; expect 4 "$2" "$3"
}
qa_case '/^Rethink signals/d' "Rethink signals: none" "qa report without rethink line"
qa_case '/^Gate final-build/d' "missing Gate final-build" "qa report without final-build"
qa_case 's/^Gate final-build: passed$/Gate final-build: warn/' "Gate final-build must be passed" "qa report final-build warn"
qa_case 's/^Verdict: ready$/Verdict: escalated/' "Verdict must be ready" "qa report escalated"
qa_case 's/^Gate code: passed$/Gate code: skipped/' "Gate code skipped needs a reason" "qa report gate without reason"
qa_case 's/^Tests: passed=3/Tests: passed=x/' "Tests line malformed" "qa report non-integer tests"
qa_case 's/^Tests: passed=3/Tests: passed=0/' "no tests ran" "qa report zero tests"
qa_case 's/failed=0 skipped=0 baseline=0/failed=2 skipped=0 baseline=1/' "exceeds baseline" "qa report new failures"
report
run "$MAIN" $TR alfa check "$R"
expect 0 "valid:" "qa valid"
jq '.pr_id = 9999' "$R" > "$WORK/r.json" && mv "$WORK/r.json" "$R"
run "$MAIN" $TR alfa check "$R"
expect 4 "PR identity mismatch" "qa pr_id differs from coder"
jq '.pr_id = 8371' "$R" > "$WORK/r.json" && mv "$WORK/r.json" "$R"
QA_REC="$R"

# ---- (7) team-merge-check ----------------------------------------------------------------------------
touch "$QA_REC.accepted"
rm -f "$TD/session.json"; WR_REC="${QA_REC%/*}/wrapup-1-1.json"  # merge check: no live role, wrapup done
jq '.role = "wrapup"' "$QA_REC" > "$WR_REC" && touch "$WR_REC.accepted"
pr_json false "$C1" queued
run "$MAIN" bash .claude/lib/team-merge-check.sh alfa
expect 3 "ADO merge not recalculated yet" "merge-check queued"
pr_json false "$C1" succeeded refs/heads/develop-netcore7 0000000000000000000000000000000000000000
run "$MAIN" bash .claude/lib/team-merge-check.sh alfa
expect 3 "stale merge — target moved" "merge-check stale target"
git -C "$CLONE" push --quiet origin "$C1:refs/pull/8371/merge"
export MERGE_SHA="$C1"
pr_json false "$C1"
run "$MAIN" bash .claude/lib/team-merge-check.sh alfa
expect 0 "VERDICT: ok" "merge-check ok"
has "validated source=$C1 target=$BASE" "$WORK/out" || fail "merge-check validated pair"
[ "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" = feature/TT-790-x ] || fail "merge-check left clone detached"
rm -f "$QA_REC.accepted" "$WR_REC" "$WR_REC.accepted"

# ---- (8) runner recovery -----------------------------------------------------------------------------
reset_runner() { rm -rf "$TD/lock" "$TD/cancel" "$TD/acked"; : > "$STUB_LOG"; }
set_branch() {  # point the clone branch and its origin tip at <sha> (fixture-only ref surgery)
  git -C "$CLONE" switch --quiet -C feature/TT-790-x "$1"
  git --git-dir="$WORK/origin.git" update-ref refs/heads/feature/TT-790-x "$1"
}
reset_runner
session qa 1 "$C1"
rm -f "$QA_REC"
echo dirty > "$CLONE/untracked.txt"
run "$MAIN" $TR alfa
expect 5 "dead attempt 1 of qa" "dead attempt with dirty tree"
has "new-session" "$STUB_LOG" && fail "dirty dead attempt launched a session"
rm -f "$CLONE/untracked.txt"
reset_runner
session qa 2 "$C1"
run "$MAIN" $TR alfa
expect 5 "dead attempt 2 of qa" "dead attempt 2"
has "new-session" "$STUB_LOG" && fail "attempt 2 relaunched"
reset_runner
rm -f "$CODER_REC.accepted"; mv "$CODER_REC" "$WORK/coder.json"
session coder 1 "$PLANNER_OUT"
set_branch "$PLANNER_OUT"
run "$MAIN" $TR alfa
expect 5 "dead attempt 2 of coder" "no-trace retry then stop"
has "--disallowedTools AskUserQuestion -- \"\$(cat '" "$STUB_LOG" || fail "coder launch line lacks -- or --disallowedTools"
has "new-session -d -s alfa-coder" "$STUB_LOG" || fail "coder retry not launched"
has "warn: no preview window for alfa-coder" "$WORK/out" || fail "TEAM_ATTACH=all did not try a coder window"
has "-n alfa-coder --model 'opus[1m]' --effort 'medium' --disallowedTools" "$STUB_LOG" \
  || fail "coder launch lacks its model/effort from roles.json"
CODEX_REAL="$(cd "$HOME/.codex-taketask" && pwd -P)"
has "-e CODEX_HOME=$CODEX_REAL " "$STUB_LOG" || fail "coder launch lacks the per-session CODEX_HOME"
# The tmux server may have been started from another project's shell; the licence must be passed
# per session, and only when this process actually has one.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  has "-e CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR " "$STUB_LOG" \
    || fail "coder launch lacks the per-session CLAUDE_CONFIG_DIR"
else
  ! has "-e CLAUDE_CONFIG_DIR=" "$STUB_LOG" || fail "coder launch invented a CLAUDE_CONFIG_DIR"
fi
has "set-environment" "$STUB_LOG" && fail "runner touched the server-wide tmux environment"
[ "$(jq -r .attempt "$TD/session.json")" = 2 ] || fail "retry did not write attempt 2"
grep -Eq 'claude --session-id [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} -n alfa-coder' \
  "$STUB_LOG" || fail "coder launch lacks --session-id <uuid> before -n"
SID="$(cat "$TD/runs/$RUN_ID/coder-2.session" 2>/dev/null)"
has "claude --session-id $SID -n alfa-coder" "$STUB_LOG" || fail "coder-2.session differs from the launch line"
[ "$(jq -r .session_id "$TD/session.json")" = "$SID" ] || fail "session.json lacks the launched session_id"
has "PLAN" "$TD/runs/$RUN_ID/coder-2.prompt.md" && fail "prompt placeholder not rendered"
has ".agents/plans/active/p.md" "$TD/runs/$RUN_ID/coder-2.prompt.md" || fail "coder prompt lacks the plan"
cp "$MAIN/.claude/team/roles.json" "$WORK/roles.bak"
echo '{"coder":{"model":"opus; rm -rf x"}}' > "$MAIN/.claude/team/roles.json"
reset_runner; session coder 1 "$PLANNER_OUT"
cp "$TD/session.json" "$WORK/session.bak"
run "$MAIN" $TR alfa
expect 1 'bad model "opus; rm -rf x" for coder' "roles.json value is validated"
cmp -s "$TD/session.json" "$WORK/session.bak" || fail "bad base model changed session.json"
has "new-session" "$STUB_LOG" && fail "bad base model launched a session"
for bad in '{"planer":{"model":"opus"}}' '{"qa":{"modle":"opus"}}' \
  '{"coder":{"effort":"hihg"}}' '{"qa":{"effort":7}}'; do
  printf '%s\n' "$bad" > "$MAIN/.claude/team/roles.json"
  reset_runner; session coder 1 "$PLANNER_OUT"; cp "$TD/session.json" "$WORK/session.bak"
  TEAM_NOTIFY=1 run "$MAIN" $TR alfa
  expect 1 "roles.json" "invalid base config $bad"
  cmp -s "$TD/session.json" "$WORK/session.bak" || fail "bad base config changed session.json"
  has "new-session" "$STUB_LOG" && fail "bad base config launched a session"
  has "stopped (1)" "$STUB_LOG" || fail "runtime failure stopped notification suppressed"
done
cp "$WORK/roles.bak" "$MAIN/.claude/team/roles.json"
rmdir "$HOME/.codex-taketask"
reset_runner; session coder 1 "$PLANNER_OUT"; cp "$TD/session.json" "$WORK/session.bak"
run "$MAIN" $TR alfa
expect 1 "Codex profile" "unresolvable Codex profile is refused"
cmp -s "$TD/session.json" "$WORK/session.bak" || fail "missing Codex profile changed session.json"
has "new-session" "$STUB_LOG" && fail "missing Codex profile launched a session"
mkdir "$HOME/.codex-taketask"


cp "$MAIN/.claude/codex-profile" "$WORK/main-profile.bak"
mkdir "$WORK/main-profile"
printf '%s\n' "$WORK/main-profile" > "$MAIN/.claude/codex-profile"
MAIN_CODEX_REAL="$(cd "$WORK/main-profile" && pwd -P)"
reset_runner; session coder 1 "$PLANNER_OUT"
run "$MAIN" $TR alfa
expect 5 "dead attempt 2 of coder" "clone profile takes precedence over main"
has "-e CODEX_HOME=$CODEX_REAL " "$STUB_LOG" || fail "runner did not choose the clone profile"
has "-e CODEX_HOME=$MAIN_CODEX_REAL " "$STUB_LOG" && fail "main profile overrode the clone"

mv "$CLONE/.claude/codex-profile" "$WORK/clone-profile.bak"
reset_runner; rm -f "$TD/session.json"
# A fresh role exercises fallback rather than the dirty-tree retry refusal.
run "$MAIN" $TR alfa
expect 5 "dead attempt 1 of coder" "absent clone declaration falls back to main"
has "-e CODEX_HOME=$MAIN_CODEX_REAL " "$STUB_LOG" || fail "missing clone profile did not use main"
mv "$WORK/clone-profile.bak" "$CLONE/.claude/codex-profile"

rmdir "$HOME/.codex-taketask"
reset_runner; session coder 1 "$PLANNER_OUT"; cp "$TD/session.json" "$WORK/session.bak"
run "$MAIN" $TR alfa
expect 1 "Codex profile" "invalid clone profile refuses despite valid main"
cmp -s "$TD/session.json" "$WORK/session.bak" || fail "invalid clone profile changed session.json"
has "new-session" "$STUB_LOG" && fail "invalid clone profile fell back or launched a session"
mkdir "$HOME/.codex-taketask"
cp "$WORK/main-profile.bak" "$MAIN/.claude/codex-profile"

# stop with a live owner keeps the lock until the owner exits
reset_runner
mkdir "$TD/lock"; sleep 30 & OWNER=$!; echo "$OWNER" > "$TD/lock/pid"
run "$MAIN" $TR alfa stop
expect 1 "did not stop" "stop with live owner"
[ -d "$TD/lock" ] || fail "stop removed a live owner's lock"
kill "$OWNER"; wait "$OWNER" 2>/dev/null || true
run "$MAIN" $TR alfa stop
expect 0 "stopped" "stop after owner exit"
[ ! -d "$TD/lock" ] || fail "stop left the lock"

# ---- (8a) reconciliation, PR identity, cancel ------------------------------------------------------
mv "$WORK/coder.json" "$CODER_REC"
set_branch "$C1"
reset_runner
session coder 1 "$PLANNER_OUT"
pr_json true "$C1"
run "$MAIN" $TR alfa
has "accepted: $(basename "$CODER_REC")" "$WORK/out" || fail "unprocessed coder record not accepted"
[ -e "$CODER_REC.accepted" ] || fail "no .accepted for reconciled coder record"
has "new-session -d -s alfa-coder" "$STUB_LOG" && fail "reconciliation relaunched the coder"
has "new-session -d -s alfa-qa" "$STUB_LOG" || fail "next stage (qa) not launched after reconciliation"

reset_runner
session coder 1 "$PLANNER_OUT"
TEAM_ATTACH=planner run "$MAIN" $TR alfa
has "dead attempt 1 of coder" "$WORK/out" && fail "accepted record treated as a dead attempt"
has "new-session -d -s alfa-qa" "$STUB_LOG" || fail "accepted-record session.json did not advance to qa"
has "preview window for alfa-qa" "$WORK/out" && fail "TEAM_ATTACH=planner opened a qa window"
TEAM_ATTACH=some run "$MAIN" $TR alfa status
expect 2 "TEAM_ATTACH must be all or planner" "TEAM_ATTACH value is validated"

reset_runner
rm -f "$CODER_REC.accepted"
session coder 1 "$PLANNER_OUT"
pr_json true "$C1" queued
set +e
(cd "$MAIN" && STUB_TOUCH="$TD/cancel" TEAM_ADO_WAIT_SECS=5 $TR alfa) > "$WORK/out" 2>&1; RC=$?
set -e
expect 6 "cancelled by stop" "cancel during ADO re-query"
[ ! -e "$CODER_REC.accepted" ] || fail "cancelled run accepted the record"
has "new-session" "$STUB_LOG" && fail "cancelled run launched a session"
[ -f "$TD/session.json" ] || fail "cancel removed session.json"

# ---- (10) team-next: reuse the clone for the next ticket -------------------------------------------
NEXT="bash .claude/lib/team-next.sh"
reset_runner
run "$MAIN" $NEXT alfa TT-792 feature/TT-792-next origin/develop-netcore7
expect 1 "still open (session.json)" "next while a stage is open"
rm -f "$TD/session.json"; mkdir "$TD/lock"
run "$MAIN" $NEXT alfa TT-792 feature/TT-792-next origin/develop-netcore7
expect 1 "runner lock present" "next while the runner holds the lock"
rmdir "$TD/lock"; echo '{}' > "$TD/roles.override.json"
pr_json false "$C1"
run "$MAIN" $NEXT alfa TT-792 feature/TT-792-next origin/develop-netcore7
expect 1 "previous PR #8371 of TT-790 is active" "next with an open PR"
jq '.status = "completed"' "$STUB_PR" > "$WORK/pr2.json" && mv "$WORK/pr2.json" "$STUB_PR"
run "$MAIN" $NEXT alfa TT-792 feature/TT-792-next origin/develop-netcore7
expect 0 "was TT-790" "next after the PR completed"
[ "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" = feature/TT-792-next ] || fail "next did not switch branch"
! git -C "$CLONE" rev-parse --verify --quiet refs/heads/feature/TT-790-x >/dev/null || fail "old branch kept"
jq -e '.ticket == "TT-792" and .branch == "feature/TT-792-next"' "$TD/team.json" >/dev/null || fail "team.json not rewritten"
[ ! -e "$TD/runs" ] && [ ! -e "$TD/run" ] && [ ! -e "$TD/roles.override.json" ] || fail "previous run state not archived"
ls -d "$TD"/archive/TT-790-*/runs "$TD"/archive/TT-790-*/roles.override.json >/dev/null 2>&1 || fail "archive lacks the previous runs or roles override"
[ "$(stat -f %Lp "$CLONE/.env")" = 600 ] || fail "next did not re-seed .env"
commit_file wip.txt wip
run "$MAIN" $NEXT alfa TT-793 feature/TT-793-other origin/develop-netcore7
expect 1 "has commits on feature/TT-792-next but no PR" "next over unfinished work without a PR"

# ---- (11) team-watch and team-answer ---------------------------------------------------------------
WATCH="bash .claude/lib/team-watch.sh"
run "$MAIN" $WATCH --once alfa nobody
expect 0 "WATCH alfa: stage idle" "watch initial state"
has "WATCH nobody: no clone" "$WORK/out" || fail "watch did not report a missing clone"
printf 'Bash command\n  az webapp deploy --name shell-sk\nDo you want to proceed?\n❯ 1. Yes\n' > "$WORK/pane"
export STUB_PANE="$WORK/pane"
echo "$RUN_ID" > "$TD/run"; mkdir -p "$TD/runs/$RUN_ID"
(cd "$MAIN" && TEAM_WATCH_SECS=1 $WATCH alfa) > "$WORK/watch" 2>&1 & WPID=$!
sleep 2
session coder 1 "$BASE"; echo "2026-10-02T10:00:00Z permission_prompt Claude needs your permission" >> "$TD/runs/$RUN_ID/attention"
sleep 3; kill "$WPID"; wait "$WPID" 2>/dev/null || true
has "STAGE alfa: idle → coder attempt 1" "$WORK/watch" || { cat "$WORK/watch"; fail "watch missed the stage change"; }
has "ATTENTION alfa coder: permission_prompt" "$WORK/watch" || fail "watch missed the permission prompt"
has "|   az webapp deploy --name shell-sk" "$WORK/watch" || fail "watch did not show the role's screen"

ANSWER="bash .claude/lib/team-answer.sh"
: > "$STUB_LOG"
STUB_TMUX_ALIVE=0 STUB_PANE= run "$MAIN" $ANSWER alfa coder yes
expect 1 "no pending permission prompt" "answer yes without a prompt"
has "send-keys" "$STUB_LOG" && fail "answer sent keys without a prompt"
STUB_TMUX_ALIVE=0 run "$MAIN" $ANSWER alfa coder yes
expect 0 "sent yes to alfa-coder" "answer yes with a prompt"
has "send-keys -t =alfa-coder: Enter" "$STUB_LOG" || fail "answer yes did not press Enter"
: > "$STUB_LOG"
STUB_TMUX_ALIVE=0 run "$MAIN" $ANSWER alfa coder say "use the existing endpoint"
expect 1 "a menu or permission prompt is open" "answer say over a prompt"
has "send-keys" "$STUB_LOG" && fail "say typed over a permission prompt"
STUB_TMUX_ALIVE=0 STUB_PANE= run "$MAIN" $ANSWER alfa coder say "use the existing endpoint"
expect 0 "sent say" "answer say"
has "send-keys -t =alfa-coder: -l -- use the existing endpoint" "$STUB_LOG" || fail "answer say did not type the text"
run "$MAIN" $ANSWER alfa coder yes
expect 1 "not found" "answer to a dead session"
rm -f "$TD/session.json"; unset STUB_PANE

# ---- (12) team-snapshot and the dashboard server ---------------------------------------------------
SNAP="bash .claude/lib/team-snapshot.sh"
CL="$WORK/claude"; mkdir -p "$CL/sess-1/subagents"
printf '%s\n' '{"type":"assistant","effort":"high","message":{"model":"claude-opus-5-5"}}' \
  '{"type":"assistant","message":{"model":"<synthetic>"}}' > "$CL/sess-1.jsonl"
printf '%s\n' '{"type":"user","timestamp":"2026-10-03T10:00:00.123Z"}' \
  '{"type":"assistant","effort":"high","message":{"model":"claude-fable-5-1","stop_reason":"end_turn"}}' \
  > "$CL/sess-1/subagents/agent-a1.jsonl"
echo '{"agentType":"structure-reviewer","description":"smoke"}' > "$CL/sess-1/subagents/agent-a1.meta.json"
# a2 waits on a long tool call: silent for 10 min, yet still running.
echo '{"type":"assistant","message":{"model":"m","content":[{"type":"tool_use"}]}}' > "$CL/sess-1/subagents/agent-a2.jsonl"
touch -t "$(date -v-10M +%Y%m%d%H%M.%S)" "$CL/sess-1/subagents/agent-a2.jsonl"
export TEAM_DASH_PROJECT_DIR="$CL" TEAM_DASH_SESSION=sess-1
RUN_ID=alfa-20261003-000000; echo "$RUN_ID" > "$TD/run"; mkdir -p "$TD/runs/$RUN_ID"
session coder 1 "$BASE"
STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane" snap "prompt open" '.schema == 1 and (.codex | type == "array")
  and (coder | .status == "attention" and any(.actions[]; . == "bash .claude/lib/team-answer.sh alfa coder yes"))
  and .supervisor.model == "claude-opus-5-5"
  and (.subagents[] | select(.id == "a1") | .model == "claude-fable-5-1" and .status == "done")
  and (.subagents[] | select(.id == "a2") | .status == "running")'
STUB_TMUX_ALIVE=1 snap "killed session" '(coder | .status) == "stopped"'
STUB_TMUX_ALIVE=1 STUB_TMUX_ERR="protocol version mismatch" snap "tmux probe error" \
  '(coder | .status) == "unknown" and any(.errors[]; test("protocol version mismatch"))'
TEAM_DASH_SESSION= snap "empty session pin" '.supervisor.status == "unknown"'
R=$(record --verdict blocked --message "which endpoint?")
STUB_TMUX_ALIVE=0 STUB_PANE= snap "unresolved blocker" '(coder | .status == "blocked"
  and .record.message == "which endpoint?" and any(.actions[]; test(" say ")))
  and any(.events[]; .source == "alfa/coder" and .at != null and (.text | test("blocked")))'
basename "$R" > "$TD/acked"; mkdir "$TD/lock"; echo $$ > "$TD/lock/pid"
STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane" snap "acked blocker + prompt" \
  '(coder | .status) == "attention" and .teams[0].runner == "up"'
STUB_TMUX_ALIVE=0 STUB_PANE= snap "acked blocker, runner up" '(coder | .status) == "running"'
# No tmux session at all: the lock owner alone proves a run_in_background runner.
STUB_TMUX_ALIVE=1 snap "runner without tmux" '.teams[0].runner == "up"'
rm -f "$TD/lock/pid"
STUB_TMUX_ALIVE=1 snap "stale lock" '.teams[0].runner == "stale"'
rm -rf "$TD/lock" "$TD/acked" "$R"
TEAM_DASH_PROJECT_DIR="$WORK/none" snap "degraded" '.supervisor.status == "unknown" and (.errors | length > 0)'

PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
echo '{"schema":1}' > "$WORK/srv.json"
python3 "$SRC/.claude/dashboard/server.py" "$PORT" "$SRC/.claude/dashboard/index.html" "$WORK/srv.json" \
  > "$WORK/srv.log" 2>&1 & SPID=$!
http_status() {  # http_status <Host header> <path> → status code, or "down"
  python3 -c 'import sys, http.client as h
c = h.HTTPConnection("127.0.0.1", int(sys.argv[1]), timeout=2)
c.putrequest("GET", sys.argv[3], skip_host=True); c.putheader("Host", sys.argv[2]); c.endheaders()
print(c.getresponse().status)' "$PORT" "$1" "$2" 2>/dev/null || echo down
}
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(http_status "127.0.0.1:$PORT" /)" = down ] || break; sleep 0.5; done
[ "$(http_status "127.0.0.1:$PORT" /)" = 200 ] || fail "server: / for 127.0.0.1 not 200"
[ "$(http_status "localhost:$PORT" /snapshot.json)" = 200 ] || fail "server: snapshot for localhost not 200"
[ "$(http_status evil.example /snapshot.json)" = 403 ] || fail "server: foreign Host not 403"
[ "$(http_status "127.0.0.1:$PORT" /../.env)" = 404 ] || fail "server: path traversal not 404"
kill "$SPID" 2>/dev/null || true; wait "$SPID" 2>/dev/null || true; SPID=""
rm -f "$TD/session.json"; unset TEAM_DASH_PROJECT_DIR TEAM_DASH_SESSION

# ---- (13) team-attach quotes the session target for zsh, on the session's OWN server ------------
: > "$STUB_LOG"
STUB_TMUX_ALIVE=0 run "$MAIN" bash .claude/lib/team-attach.sh alfa planner
expect 0 "attached to alfa-planner" "attach to a live session"
has "exec tmux -S '$STUB_TMUX_SOCK' attach -t '=alfa-planner'" "$STUB_LOG" \
  || fail "attach does not exec tmux on the session's socket with a quoted =NAME"
has "display-message -p -t =alfa-planner: #{socket_path}" "$STUB_LOG" \
  || fail "attach did not resolve the session's socket from the pane target"
has "warn: window opened but will not close by itself" "$WORK/out" || fail "attach: no tty must warn"
# Fail closed: without a socket the window would reach the DEFAULT server and could attach to a
# same-named session of another project. No window is opened at all.
: > "$STUB_LOG"
STUB_TMUX_SOCK="" STUB_TMUX_ALIVE=0 run "$MAIN" bash .claude/lib/team-attach.sh alfa planner
expect 1 "cannot resolve the tmux socket of alfa-planner" "attach refuses an unresolvable socket"
! has osascript "$STUB_LOG" || fail "a refused attach still opened a Terminal window"

echo "team-smoke-1: OK"
