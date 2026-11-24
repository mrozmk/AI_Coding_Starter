#!/usr/bin/env bash
# Team lifecycle, recovery and team-snapshot checks with an independent fixture.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

# ---- (3) team-new ----------------------------------------------------------------------------------
case_mark "(3) team-new"
run "$MAIN" $NEW alfa AB-790
expect 2 "Usage:" "team-new argc"
chmod 644 "$MAIN/.env"
run "$MAIN" $NEW alfa AB-790 feature/AB-790-x origin/develop brainstorm
expect 1 "chmod 600 .env" "team-new .env 644"
chmod 600 "$MAIN/.env"
run "$MAIN" $NEW alfa AB-790 feature/AB-790-x origin/rc brainstorm
expect 1 "base has no team harness" "team-new base without harness"
run "$MAIN" $NEW alfa AB-790 feature/AB-790-x origin/develop brainstorm
expect 0 "next:" "team-new happy path"
CLONE="$WORK/main-alfa"
[ "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" = feature/AB-790-x ] || fail "clone branch"
jq -e '.base_sha and .line == "develop" and .ticket == "AB-790"' "$CLONE/.agents/team/team.json" >/dev/null \
  || fail "team.json fields"
[ -f "$CLONE/.env" ] && [ ! -L "$CLONE/.env" ] && [ "$(stat -f %Lp "$CLONE/.env")" = 600 ] || fail ".env copy"
run "$MAIN" $NEW alfa AB-790 feature/AB-790-x origin/develop brainstorm
expect 1 "already exists" "team-new existing dir"
run "$MAIN" $NEW beta AB-790 feature/AB-790-x origin/develop brainstorm
expect 1 "already used by team alfa" "team-new branch of another team"
run "$MAIN" $NEW beta AB-791 feature/AB-791-pushed origin/develop brainstorm
expect 1 "already exists on origin" "team-new pushed branch"

# ---- (4) team-record -------------------------------------------------------------------------------
case_mark "(4) team-record"
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
case_mark "(5) guard-team-memory"
HOOK="$SRC/.claude/hooks/guard-team-memory.sh"
hook "$CLONE" '{"tool_input":{"file_path":".agents/memory/errors.md"}}'
expect 2 "written by the wrapup role only" "guard blocks memory in team mode"
hook "$CLONE" '{"tool_input":{"file_path":"src/Foo.cs"}}'
expect 0 "" "guard passes non-memory path"
hook "$CLONE" '{"tool_input":{"file_path":"docs/coding-standards.md"}}'
expect 2 "docs/coding-standards.md is written by the wrapup role only" "guard blocks the standards file"
hook "$CLONE" "{\"tool_input\":{\"file_path\":\"$CLONE/docs/coding-standards.md\"}}"
expect 2 "written by the wrapup role only" "guard blocks the standards file by absolute path"
hook "$CLONE" "{\"tool_input\":{\"file_path\":\"$CLONE/docs/./coding-standards.md\"}}"
expect 2 "written by the wrapup role only" "guard blocks an alias of the standards file"
hook "$CLONE" '{"tool_input":{"file_path":"docs/other.md"}}'
expect 0 "" "guard passes another docs path"
hook "$CLONE" '{"tool_input":{"file_path":"docs/old-coding-standards.md"}}'
expect 0 "" "guard passes a similar docs name"
mkdir -p "$CLONE/docs"
printf '# Coding standards\n' > "$CLONE/docs/coding-standards.md"
ln -s coding-standards.md "$CLONE/docs/alias.md"
hook "$CLONE" "{\"tool_input\":{\"file_path\":\"$CLONE/docs/alias.md\"}}"
expect 2 "written by the wrapup role only" "guard blocks a symlink of another name to the standards file"
rm -f "$CLONE/docs/alias.md" "$CLONE/docs/coding-standards.md"
hook "$MAIN" '{"tool_input":{"file_path":".agents/memory/errors.md"}}'
expect 0 "" "guard passes outside team mode"

# ---- one-question guard: exercise the synchronous command shipped in settings --------------------
case_mark "one-question guard: exercise the synchro"
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
# The ask channel returns every answer of a call, so a stage may ask several questions at once.
question_hook "$QROOT" "$TWO"
expect 0 "" "question guard passes two in team"
question_hook "$OUTSIDE" "$TWO"
expect 0 "" "question guard passes two outside team"

# ---- (6) validation via `team-run.sh <team> check` ---------------------------------------------------
case_mark "(6) validation via team-run.sh <team> ch"
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
git -C "$CLONE" push --quiet origin feature/AB-790-x
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
case_mark "(9) QA report validator"
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
# teams.test_gate: none in the MAIN checkout's profile (the one the runner loads) → passed=0 is honest;
# failed > baseline still fails there.
PROF="$MAIN/.claude/project-profile.json"; cp "$PROF" "$WORK/prof.json"
jq '.teams.test_gate = "none"' "$WORK/prof.json" > "$PROF"
report 's/^Tests: passed=3/Tests: passed=0/'; run "$MAIN" $TR alfa check "$R"
expect 0 "valid:" "qa report zero tests, test gate none"
qa_case 's/^Tests: passed=3 failed=0 skipped=0 baseline=0/Tests: passed=0 failed=1 skipped=0 baseline=0/' "exceeds baseline" "qa report zero tests, gate none, new failure"
cp "$WORK/prof.json" "$PROF"
# The optional AC: line (team-mode.md §7): absent is fine; present, it must be well-formed, add up,
# and unconfirmed > 0 needs ready-with-warnings. deferred alone keeps Verdict: ready.
ac_case() {  # ac_case <AC line(s)> <verdict> <warnings> <rc> <expected text> <label>
  report "s/^Verdict: ready\$/Verdict: $2/;s/^Warnings: none\$/Warnings: $3/"
  printf '%s\n' "$1" >> "$QR"
  run "$MAIN" $TR alfa check "$R"; expect "$4" "$5" "$6"
}
report; run "$MAIN" $TR alfa check "$R"; expect 0 "valid:" "qa report without AC line"
ac_case 'AC: total=3 met=2 unconfirmed=1 deferred=0' ready-with-warnings 'AC E1-2.AC3 unconfirmed' 0 "valid:" "qa report AC well-formed with a warning"
ac_case 'AC: total=3 met=2 unconfirmed=0 deferred=1' ready none 0 "valid:" "qa report AC deferred under ready"
ac_case 'AC: total=08 met=07 unconfirmed=00 deferred=01' ready none 0 "valid:" "qa report AC leading zeros"
ac_case 'AC: total=0000000003 met=2 unconfirmed=0 deferred=1' ready none 0 "valid:" "qa report AC zero-padded count"
ac_case 'AC: total=3 met=2 deferred=1' ready none 4 "AC line malformed" "qa report AC malformed"
ac_case 'AC: total=1234567890 met=1234567890 unconfirmed=0 deferred=0' ready none 4 "AC line malformed" "qa report AC count too long"
ac_case "$(printf 'AC: total=1 met=1 unconfirmed=0 deferred=0\nAC: total=1 met=1 unconfirmed=0 deferred=0')" ready none 4 "AC: lines" "qa report AC twice"
ac_case 'AC: total=4 met=2 unconfirmed=0 deferred=1' ready none 4 "do not sum to total" "qa report AC bad sum"
ac_case 'AC: total=3 met=2 unconfirmed=1 deferred=0' ready 'AC E1-2.AC3 unconfirmed' 4 "needs Verdict: ready-with-warnings" "qa report AC unconfirmed under ready"
ac_case "$(printf 'AC: total=3 met=2 unconfirmed=1 deferred=0\nVerdict: ready-with-warnings')" ready 'AC E1-2.AC3 unconfirmed' 4 "needs Verdict: ready-with-warnings" "qa report AC unconfirmed with a later verdict line"
report
run "$MAIN" $TR alfa check "$R"
expect 0 "valid:" "qa valid"
jq '.pr_id = 9999' "$R" > "$WORK/r.json" && mv "$WORK/r.json" "$R"
run "$MAIN" $TR alfa check "$R"
expect 4 "PR identity mismatch" "qa pr_id differs from coder"
jq '.pr_id = 8371' "$R" > "$WORK/r.json" && mv "$WORK/r.json" "$R"
QA_REC="$R"

# ---- (7) team-merge-check ----------------------------------------------------------------------------
case_mark "(7) team-merge-check"
touch "$QA_REC.accepted"
rm -f "$TD/session.json"; WR_REC="${QA_REC%/*}/wrapup-1-1.json"  # merge check: no live role, wrapup done
jq '.role = "wrapup"' "$QA_REC" > "$WR_REC" && touch "$WR_REC.accepted"
pr_json false "$C1" queued
run "$MAIN" bash .claude/lib/team-merge-check.sh alfa
expect 3 "ADO merge not recalculated yet" "merge-check queued"
pr_json false "$C1" succeeded refs/heads/develop 0000000000000000000000000000000000000000
run "$MAIN" bash .claude/lib/team-merge-check.sh alfa
expect 3 "stale merge — target moved" "merge-check stale target"
git -C "$CLONE" push --quiet origin "$C1:refs/pull/8371/merge"
export MERGE_SHA="$C1"
pr_json false "$C1"
run "$MAIN" bash .claude/lib/team-merge-check.sh alfa
expect 0 "VERDICT: ok" "merge-check ok"
has "validated source=$C1 target=$BASE" "$WORK/out" || fail "merge-check validated pair"
[ "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" = feature/AB-790-x ] || fail "merge-check left clone detached"
rm -f "$QA_REC.accepted" "$WR_REC" "$WR_REC.accepted"

# ---- (8) runner recovery -----------------------------------------------------------------------------
case_mark "(8) runner recovery"
reset_runner() { rm -rf "$TD/lock" "$TD/cancel" "$TD/acked"; : > "$STUB_LOG"; }
set_branch() {  # point the clone branch and its origin tip at <sha> (fixture-only ref surgery)
  git -C "$CLONE" switch --quiet -C feature/AB-790-x "$1"
  git --git-dir="$WORK/origin.git" update-ref refs/heads/feature/AB-790-x "$1"
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
has "new-session -d -s smk-alfa-coder" "$STUB_LOG" || fail "coder retry not launched"
# tmux opens no window (#29): no Terminal window, no preview script, no preview warning.
! has osascript "$STUB_LOG" || fail "a tmux team run called osascript"
! has "preview window" "$WORK/out" || fail "a tmux team run tried a preview window"
has "-n alfa-coder --model 'opus[1m]' --effort 'medium' --permission-mode 'auto' --disallowedTools" \
  "$STUB_LOG" || fail "coder launch lacks its model/effort/permission from roles.json"
CODEX_REAL="$(cd "$HOME/.codex-acmeshop" && pwd -P)"
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
  run "$MAIN" $TR alfa
  expect 1 "roles.json" "invalid base config $bad"
  cmp -s "$TD/session.json" "$WORK/session.bak" || fail "bad base config changed session.json"
  has "new-session" "$STUB_LOG" && fail "bad base config launched a session"
  ! has "notify " "$STUB_LOG" || fail "a runner stop notified someone"
done
cp "$WORK/roles.bak" "$MAIN/.claude/team/roles.json"
rmdir "$HOME/.codex-acmeshop"
reset_runner; session coder 1 "$PLANNER_OUT"; cp "$TD/session.json" "$WORK/session.bak"
run "$MAIN" $TR alfa
expect 1 "Codex profile" "unresolvable Codex profile is refused"
cmp -s "$TD/session.json" "$WORK/session.bak" || fail "missing Codex profile changed session.json"
has "new-session" "$STUB_LOG" && fail "missing Codex profile launched a session"
mkdir "$HOME/.codex-acmeshop"


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

rmdir "$HOME/.codex-acmeshop"
reset_runner; session coder 1 "$PLANNER_OUT"; cp "$TD/session.json" "$WORK/session.bak"
run "$MAIN" $TR alfa
expect 1 "Codex profile" "invalid clone profile refuses despite valid main"
cmp -s "$TD/session.json" "$WORK/session.bak" || fail "invalid clone profile changed session.json"
has "new-session" "$STUB_LOG" && fail "invalid clone profile fell back or launched a session"
mkdir "$HOME/.codex-acmeshop"
cp "$WORK/main-profile.bak" "$MAIN/.claude/codex-profile"

# A declared Claude profile beats the runner's inherited CLAUDE_CONFIG_DIR (the tmux server's), is
# recorded in session.json, and the transcript reader follows the recorded dir. Fixture HOME only.
CP_BAK=""; [ ! -e "$MAIN/.claude/claude-profile" ] || { cp -p "$MAIN/.claude/claude-profile" "$WORK/claude-profile.bak"; CP_BAK=1; }
mkdir "$HOME/.claude-proj"
printf '# test fixture\n~/.claude-proj\n' > "$MAIN/.claude/claude-profile"
CLAUDE_REAL="$(cd "$HOME/.claude-proj" && pwd -P)"
reset_runner; session coder 1 "$PLANNER_OUT"
CLAUDE_CONFIG_DIR="$WORK/other-licence" run "$MAIN" $TR alfa
expect 5 "dead attempt 2 of coder" "declared Claude profile"
has "-e CLAUDE_CONFIG_DIR=$CLAUDE_REAL " "$STUB_LOG" || fail "runner did not pass the Claude profile"
has "other-licence" "$STUB_LOG" && fail "inherited CLAUDE_CONFIG_DIR overrode the Claude profile"
[ "$(jq -r '.claude_config_dir' "$TD/session.json")" = "$CLAUDE_REAL" ] \
  || fail "session.json does not record the Claude profile"
T_GOT="$( . "$MAIN/.claude/lib/team-lib.sh"
  CLAUDE_CONFIG_DIR="$WORK/other-licence" team_role_transcript "$CLONE" abc "$(jq -r '.claude_config_dir' "$TD/session.json")")"
case "$T_GOT" in "$CLAUDE_REAL/projects/"*/abc.jsonl) ;;
  *) fail "transcript reader did not follow the recorded Claude profile: $T_GOT" ;; esac
rmdir "$HOME/.claude-proj"
reset_runner; session coder 1 "$PLANNER_OUT"; cp "$TD/session.json" "$WORK/session.bak"
run "$MAIN" $TR alfa
expect 1 "Claude profile" "unresolvable Claude profile is refused"
cmp -s "$TD/session.json" "$WORK/session.bak" || fail "unresolvable Claude profile changed session.json"
has "new-session" "$STUB_LOG" && fail "unresolvable Claude profile launched a session"
if [ -n "$CP_BAK" ]; then cp -p "$WORK/claude-profile.bak" "$MAIN/.claude/claude-profile"
else rm -f "$MAIN/.claude/claude-profile"; fi

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
case_mark "(8a) reconciliation, PR identity, cancel"
mv "$WORK/coder.json" "$CODER_REC"
set_branch "$C1"
reset_runner
session coder 1 "$PLANNER_OUT"
pr_json true "$C1"
run "$MAIN" $TR alfa
has "accepted: $(basename "$CODER_REC")" "$WORK/out" || fail "unprocessed coder record not accepted"
[ -e "$CODER_REC.accepted" ] || fail "no .accepted for reconciled coder record"
has "new-session -d -s smk-alfa-coder" "$STUB_LOG" && fail "reconciliation relaunched the coder"
has "new-session -d -s smk-alfa-qa" "$STUB_LOG" || fail "next stage (qa) not launched after reconciliation"

reset_runner
session coder 1 "$PLANNER_OUT"
TEAM_ATTACH=planner run "$MAIN" $TR alfa
has "dead attempt 1 of coder" "$WORK/out" && fail "accepted record treated as a dead attempt"
has "new-session -d -s smk-alfa-qa" "$STUB_LOG" || fail "accepted-record session.json did not advance to qa"
! has osascript "$STUB_LOG" && ! has "preview window" "$WORK/out" || fail "TEAM_ATTACH=planner: a tmux run tried a window"
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
case_mark "(10) team-next: reuse the clone for the"
NEXT="bash .claude/lib/team-next.sh"
reset_runner
run "$MAIN" $NEXT alfa AB-792 feature/AB-792-next origin/develop brainstorm
expect 1 "still open (session.json)" "next while a stage is open"
rm -f "$TD/session.json"; mkdir "$TD/lock"
run "$MAIN" $NEXT alfa AB-792 feature/AB-792-next origin/develop brainstorm
expect 1 "runner lock present" "next while the runner holds the lock"
rmdir "$TD/lock"; echo '{}' > "$TD/roles.override.json"
pr_json false "$C1"
run "$MAIN" $NEXT alfa AB-792 feature/AB-792-next origin/develop brainstorm
expect 1 "previous PR #8371 of AB-790 is active" "next with an open PR"
next_state() {  # the clone's ticket state as one comparable text
  local f
  for f in team.json run roles.override.json; do [ ! -f "$TD/$f" ] || shasum -a 256 "$TD/$f"; done
  [ ! -d "$TD/runs" ] || echo "runs present"
  git -C "$CLONE" rev-parse HEAD; git -C "$CLONE" branch --show-current
  ls "$TD/archive" 2>/dev/null || true
}
next_untouched() {  # next_untouched <label> — state as at the last next_state snapshot
  next_state > "$WORK/next.after"
  cmp -s "$WORK/next.before" "$WORK/next.after" || fail "$1 changed the clone state"
}
next_state > "$WORK/next.before"
pr_set '.status = "completed" | .lastMergeSourceCommit.commitId = "0001"'
run "$MAIN" $NEXT alfa AB-792 feature/AB-792-next origin/develop brainstorm
expect 1 "merged source" "next with commits after the merged PR source"
next_untouched "tip mismatch"
TIP=$(git -C "$CLONE" rev-parse refs/heads/feature/AB-790-x)
pr_set ".status = \"completed\" | .lastMergeSourceCommit.commitId = \"$TIP\""
STUB_GIT_FAIL_DIR="$CLONE" STUB_GIT_FAIL_CMD=fetch \
  run "$MAIN" $NEXT alfa AB-792 feature/AB-792-next origin/develop brainstorm
expect 1 "git fetch origin failed in" "next with a failing clone fetch"
next_untouched "fetch failure"
STUB_GIT_FAIL_DIR="$CLONE" STUB_GIT_FAIL_CMD=switch \
  run "$MAIN" $NEXT alfa AB-792 feature/AB-792-next origin/develop brainstorm
expect 128 "forced switch failure" "next with a failing switch"
next_untouched "switch failure"
! git -C "$CLONE" rev-parse --verify --quiet refs/heads/feature/AB-792-next >/dev/null \
  || fail "switch failure left the new branch"
git -C "$CLONE" branch feature/AB-792-next
next_state > "$WORK/next.before"
run "$MAIN" $NEXT alfa AB-792 feature/AB-792-next origin/develop brainstorm
expect 1 "already exists in" "next onto an existing local branch"
next_untouched "existing local branch"
git -C "$CLONE" branch --quiet -D feature/AB-792-next
run "$MAIN" $NEXT alfa AB-792 feature/AB-792-next origin/develop brainstorm
expect 0 "was AB-790" "next after the PR completed"
[ "$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)" = feature/AB-792-next ] || fail "next did not switch branch"
! git -C "$CLONE" rev-parse --verify --quiet refs/heads/feature/AB-790-x >/dev/null || fail "old branch kept"
jq -e '.ticket == "AB-792" and .branch == "feature/AB-792-next"' "$TD/team.json" >/dev/null || fail "team.json not rewritten"
[ ! -e "$TD/runs" ] && [ ! -e "$TD/run" ] && [ ! -e "$TD/roles.override.json" ] || fail "previous run state not archived"
ls -d "$TD"/archive/AB-790-*/runs "$TD"/archive/AB-790-*/roles.override.json >/dev/null 2>&1 || fail "archive lacks the previous runs or roles override"
[ "$(stat -f %Lp "$CLONE/.env")" = 600 ] || fail "next did not re-seed .env"
commit_file wip.txt wip
run "$MAIN" $NEXT alfa AB-793 feature/AB-793-other origin/develop brainstorm
expect 1 "has commits on feature/AB-792-next but no PR" "next over unfinished work without a PR"
NEXT_RUN=alfa-20261002-000001; mkdir -p "$TD/runs/$NEXT_RUN"; echo "$NEXT_RUN" > "$TD/run"
jq -n --arg run "$NEXT_RUN" '{team: "alfa", ticket: "AB-792", run: $run, role: "coder",
  attempt: 1, seq: 1, verdict: "done", pr_id: 8371}' > "$TD/runs/$NEXT_RUN/coder-1-1.json"
pr_set '.status = "abandoned"'
next_state > "$WORK/next.before"
run "$MAIN" $NEXT alfa AB-793 feature/AB-793-other origin/develop brainstorm
expect 1 "is abandoned" "next after an abandoned PR without --abandoned"
next_untouched "abandoned refusal"
run "$MAIN" $NEXT --abandoned alfa AB-793 feature/AB-793-other origin/develop brainstorm
expect 0 "kept:" "next --abandoned"
[ "$(git -C "$CLONE" branch --show-current)" = feature/AB-793-other ] \
  || fail "--abandoned did not switch"
git -C "$CLONE" rev-parse --verify --quiet refs/heads/feature/AB-792-next >/dev/null \
  || fail "--abandoned deleted the abandoned branch"
ls -d "$TD"/archive/AB-792-*/runs/"$NEXT_RUN" >/dev/null 2>&1 \
  || fail "--abandoned did not archive AB-792"

# ---- (11) a permission prompt on the stage's screen (the snapshot below reads it) -------------------
case_mark "(11) a permission prompt on the stage's"
# Nothing answers a pane any more (the screen sender is retired: the ask channel, team-ask.sh).
cp "$FIX/perm-awk.txt" "$WORK/pane"

# ---- (12) team-snapshot -------------------------------------------------------------------------
case_mark "(12) team-snapshot"
SNAP="bash .claude/lib/team-snapshot.sh"
CL="$WORK/claude"; mkdir -p "$CL/sess-1/subagents"
printf '%s\n' '{"type":"assistant","effort":"high","message":{"model":"claude-opus-5-5"}}' \
  '{"type":"assistant","message":{"model":"<synthetic>"}}' > "$CL/sess-1.jsonl"
printf '%s\n' '{"type":"user","timestamp":"2026-10-03T10:00:00.123Z"}' \
  '{"type":"assistant","effort":"high","message":{"model":"claude-fable-5-2","stop_reason":"end_turn"}}' \
  > "$CL/sess-1/subagents/agent-a1.jsonl"
echo '{"agentType":"structure-reviewer","description":"smoke"}' > "$CL/sess-1/subagents/agent-a1.meta.json"
# a2 waits on a long tool call: silent for 10 min, yet still running.
echo '{"type":"assistant","message":{"model":"m","content":[{"type":"tool_use"}]}}' > "$CL/sess-1/subagents/agent-a2.jsonl"
touch -t "$(date -v-10M +%Y%m%d%H%M.%S)" "$CL/sess-1/subagents/agent-a2.jsonl"
export TEAM_DASH_PROJECT_DIR="$CL" TEAM_DASH_SESSION=sess-1
RUN_ID=alfa-20261003-000000; echo "$RUN_ID" > "$TD/run"; mkdir -p "$TD/runs/$RUN_ID"
session coder 1 "$BASE"
STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane" snap "prompt open" '.schema == 1 and (.codex | type == "array")
  and (coder | .status == "attention"
    and .actions == ["bash .claude/lib/session-host.sh hint alfa-coder", "/start-team alfa"])
  and .supervisor.model == "claude-opus-5-5"
  and (.subagents[] | select(.id == "a1") | .model == "claude-fable-5-2" and .status == "done")
  and (.subagents[] | select(.id == "a2") | .status == "running")'
STUB_TMUX_ALIVE=1 snap "killed session" '(coder | .status) == "stopped"'
STUB_TMUX_ALIVE=1 STUB_TMUX_ERR="protocol version mismatch" snap "tmux probe error" \
  '(coder | .status) == "unknown" and any(.errors[]; test("protocol version mismatch"))'
TEAM_DASH_SESSION= snap "empty session pin" '.supervisor.status == "unknown"'
R=$(record --verdict blocked --message "which endpoint?")
STUB_TMUX_ALIVE=0 STUB_PANE= snap "unresolved blocker" '(coder | .status == "blocked"
  and .record.message == "which endpoint?"
  and .actions == ["bash .claude/lib/session-host.sh hint alfa-coder", "/start-team alfa"])
  and any(.events[]; .source == "alfa/coder" and .at != null and (.text | test("blocked")))'
# A run with a per-run TeamLead: the lead answers every stop, so the actions are its pending list.
jq -n --arg r "$RUN_ID" '{run: $r}' > "$TD/teamlead.json"
STUB_TMUX_ALIVE=0 STUB_PANE= snap "blocker in a lead run" '(coder | .status == "blocked"
  and .actions == ["bash .claude/lib/team-lead.sh pending alfa", "bash .claude/lib/session-host.sh hint alfa-lead"])'
rm -f "$TD/teamlead.json"
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

rm -f "$TD/session.json"; unset TEAM_DASH_PROJECT_DIR TEAM_DASH_SESSION

# ---- (14) the follow-up cap at team-new / team-next (team-lineage.sh) ------------------------------
case_mark "(14) the follow-up cap at team-new / tea"
LIN="bash .claude/lib/team-lineage.sh"; LD="$MAIN/.agents/team/lineage"
for t in AB-790 AB-792 AB-793; do
  [ "$(grep -c "\"ticket\":\"$t\"" "$LD/starts.jsonl")" = 1 ] || fail "(14) $t not recorded once by team-new/team-next"
done
jq -e '.origin_ticket == "AB-793" and .parent_ticket == null' "$TD/team.json" >/dev/null \
  || fail "(14) team.json of a first ticket: origin_ticket is the ticket, parent_ticket null"
run "$MAIN" $LIN record AB-801 x1 --follow-up-of AB-790; expect 0 "recorded AB-801 (origin AB-790)" "(14) follow-up 1"
run "$MAIN" $LIN record AB-802 x2 --follow-up-of AB-801; expect 0 "recorded AB-802 (origin AB-790)" "(14) follow-up 2"
run "$MAIN" $NEW gamma AB-803 feature/AB-803-x origin/develop brainstorm --follow-up-of AB-802
expect 9 "follow-up 3 of origin AB-790 (AB-801, AB-802 started) — needs the Operator's consent" "(14) team-new refuses the third"
[ ! -e "$WORK/main-gamma" ] || fail "(14) a refused team-new made a clone"
! grep -q '"ticket":"AB-803"' "$LD/starts.jsonl" || fail "(14) a refused team-new was recorded"
run "$MAIN" $NEW gamma AB-803 feature/AB-803-x origin/develop brainstorm --follow-up-of AB-803
expect 2 "cannot be a follow-up of itself" "(14) team-new on a contradiction"
[ ! -e "$WORK/main-gamma" ] || fail "(14) a contradiction made a clone"
run "$MAIN" $NEW gamma AB-803 feature/AB-803-x origin/develop brainstorm --follow-up-of
expect 2 "--follow-up-of needs a ticket key" "(14) team-new --follow-up-of without a value"
next_state > "$WORK/next.before"
run "$MAIN" $NEXT alfa AB-804 feature/AB-804-x origin/develop brainstorm --follow-up-of AB-790
expect 9 "needs the Operator's consent" "(14) team-next refuses the third"
next_untouched "(14) a refused team-next"
run "$MAIN" $NEW gamma AB-811 feature/AB-811-x origin/develop brainstorm --follow-up-of AB-810
expect 0 "next:" "(14) a free follow-up"
jq -e '.parent_ticket == "AB-810" and .origin_ticket == "AB-810"' "$WORK/main-gamma/.agents/team/team.json" >/dev/null \
  || fail "(14) team.json lineage of a follow-up"
[ "$(grep -c '"ticket":"AB-811"' "$LD/starts.jsonl")" = 1 ] || fail "(14) the free follow-up is not recorded once"
# A record that loses the race under the lock: a hard stop after provisioning, no next: line.
cp "$MAIN/.claude/lib/team-lineage.sh" "$WORK/lin-real.sh"
printf '#!/usr/bin/env bash\n[ "$1" != record ] || { echo "follow-up 3 of origin AB-1 — needs the consent" >&2; exit 9; }\nexec bash "%s" "$@"\n' \
  "$WORK/lin-real.sh" > "$MAIN/.claude/lib/team-lineage.sh"
run "$MAIN" $NEW delta AB-821 feature/AB-821-x origin/develop brainstorm
expect 9 "needs the consent" "(14) a failed record stops team-new"
! has "next:" "$WORK/out" || fail "(14) a failed record still printed next:"
jq -e '.ticket == "AB-821" and .origin_ticket == "AB-821"' "$WORK/main-delta/.agents/team/team.json" >/dev/null \
  || fail "(14) the clone of a failed record is not left in place with its lineage"
git -C "$MAIN" checkout --quiet -- .claude/lib/team-lineage.sh

echo "team-smoke-1: OK"
