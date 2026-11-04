#!/usr/bin/env bash
# team-remode.sh restarts a quick ticket in brainstorm mode after a Phase 0 failure.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
chmod 600 "$MAIN/.env"
run "$MAIN" $NEW alfa AB-1260 chore/AB-1260-x origin/develop-netcore7 quick
expect 0 "" "fixture quick team creation"
CLONE="$WORK/main-alfa"; TD="$CLONE/.agents/team"; BASE=$(git -C "$CLONE" rev-parse HEAD)
BR=chore/AB-1260-x
RUN_ID=alfa-20261025-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
session planner 1 "$BASE"
REMODE="bash .claude/lib/team-remode.sh"

prec() {  # prec <verdict> <message> — the unaccepted planner record 1-1 of this run
  jq -n --arg v "$1" --arg m "$2" --arg run "$RUN_ID" --arg b "$BASE" \
    '{team: "alfa", ticket: "AB-1260", run: $run, role: "planner", attempt: 1, seq: 1,
      branch: "chore/AB-1260-x", input_rev: $b, output_rev: $b, verdict: $v, pr_id: null,
      artifacts: [], evidence: [], notes: "", message: $m, written_at: "2026-10-25T00:00:00Z"}' \
    > "$RD/planner-1-1.json"
}
unchanged() {  # unchanged <label> — a refusal left the quick run in place
  [ "$(jq -r .mode "$TD/team.json")" = quick ] || fail "$1: mode changed"
  [ "$(cat "$TD/run")" = "$RUN_ID" ] || fail "$1: run changed"
  [ ! -e "$TD/archive" ] || fail "$1: archived"
  [ -f "$TD/session.json" ] || fail "$1: session.json gone"
  [ ! -d "$TD/lock" ] || fail "$1: runner lock left behind"
}
not_stopped() {  # not_stopped <label> — a pre-check refusal never ran stop
  [ ! -e "$TD/cancel" ] || fail "$1: a pre-check refusal ran stop"
}

# ---- (a) refusals before stop -------------------------------------------------------------------
run "$MAIN" $REMODE alfa brainstorm
expect 1 "no planner record in run $RUN_ID" "remode without a record"
unchanged "no record"; not_stopped "no record"
for vm in "failed|gate failed" "blocked|too big for quick: x"; do
  prec "${vm%%|*}" "${vm#*|}"
  run "$MAIN" $REMODE alfa brainstorm
  expect 1 "last record planner-1-1.json is ${vm%%|*}" "remode after ${vm%%|*} \"${vm#*|}\""
  unchanged "${vm%%|*} record"; not_stopped "${vm%%|*} record"
done
prec failed "too big for quick: x"
run "$MAIN" $REMODE alfa quick
expect 1 "only brainstorm" "remode to quick"
not_stopped "target quick"
commit_file planner.txt work
run "$MAIN" $REMODE alfa brainstorm
expect 1 "the planner committed work" "remode after a planner commit"
unchanged "planner commit"; not_stopped "planner commit"
git -C "$CLONE" switch --quiet -C "$BR" "$BASE"
STUB_GIT_FAIL_DIR="$CLONE" STUB_GIT_FAIL_CMD=status run "$MAIN" $REMODE alfa brainstorm
expect 1 "git status failed in" "remode with an unreadable clone status"
unchanged "status failure"; not_stopped "status failure"
echo "team-smoke-10: (a) refusals OK"

# ---- (b) a record written during stop is caught under the lock ----------------------------------
STUB_ON_HAS_SESSION="[ -e '$WORK/raced' ] || { touch '$WORK/raced'
  jq '.seq = 2 | .verdict = \"done\" | .message = \"\"' '$RD/planner-1-1.json' \
    > '$RD/planner-1-2.json'; }" \
  run "$MAIN" $REMODE alfa brainstorm
expect 1 "last record planner-1-2.json is done" "remode race re-check"
unchanged "race"
rm -f "$RD/planner-1-2.json" "$TD/cancel"
STUB_ON_HAS_SESSION="rm -f '$TD/cancel'" run "$MAIN" $REMODE alfa brainstorm
expect 1 "a runner started during stop" "remode with a runner started during stop"
unchanged "runner race"
rm -f "$TD/cancel"
echo "team-smoke-10: (b) race re-check OK"

# ---- (c) success --------------------------------------------------------------------------------
printf '## Follow-ups\n- [planner 1] split the remode doc — team-pipeline.md\n' > "$RD/notes.md"
prec failed "too big for quick: spans 9 files"
echo planner-1-1.json > "$TD/acked"
run "$MAIN" $REMODE alfa brainstorm
expect 0 "next:     /start-team alfa" "remode succeeds"
[ "$(jq -r .mode "$TD/team.json")" = brainstorm ] || fail "remode left the mode"
[ "$(jq -r .base_sha "$TD/team.json")" = "$BASE" ] || fail "remode changed base_sha"
[ "$(jq -r .branch "$TD/team.json")" = "$BR" ] || fail "remode changed the branch"
ls "$TD"/archive/AB-1260-remode-*/runs/"$RUN_ID"/planner-1-1.json >/dev/null 2>&1 \
  || fail "remode did not archive the failed run"
[ ! -e "$TD/session.json" ] && [ ! -e "$TD/acked" ] || fail "remode left session.json or acked"
NEW_RUN="$(cat "$TD/run")"
[ "$NEW_RUN" != "$RUN_ID" ] || fail "remode kept the run id"
has "split the remode doc" "$TD/runs/$NEW_RUN/notes.md" || fail "remode did not carry the notes"
[ "$(git -C "$CLONE" branch --show-current)" = "$BR" ] \
  && [ "$(git -C "$CLONE" rev-parse HEAD)" = "$BASE" ] || fail "remode moved the clone branch"
[ ! -d "$TD/lock" ] || fail "remode left the runner lock"
echo "team-smoke-10: (c) success OK"

# ---- (d) the next launch is a brainstorm planner on the same ticket -----------------------------
run "$MAIN" $TR alfa
expect 5 "dead attempt 2 of planner" "brainstorm launch after remode"
jq -e '.mode == "brainstorm" and .role == "planner"' "$TD/session.json" >/dev/null \
  || fail "session.json after remode: $(cat "$TD/session.json")"
has "/brainstorm AB-1260" "$TD/runs/$NEW_RUN/planner-1.prompt.md" || fail "prompt is not brainstorm"
! has 'mode `quick`' "$TD/runs/$NEW_RUN/planner-1.prompt.md" || fail "prompt still quick"
echo "team-smoke-10: (d) brainstorm launch OK"

# ---- (e) team-next to another ticket works afterwards -------------------------------------------
rm -f "$TD/session.json"
run "$MAIN" perl -e 'alarm 30; exec @ARGV' \
  bash .claude/lib/team-next.sh alfa AB-1261 chore/AB-1261-y origin/develop-netcore7
expect 0 "was AB-1260" "team-next after remode"
echo "team-smoke-10: (e) team-next OK"

echo "team-smoke-10: (a)-(e) OK"
