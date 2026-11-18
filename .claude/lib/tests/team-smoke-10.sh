#!/usr/bin/env bash
# team-remode.sh restarts a quick ticket in brainstorm mode after a Phase 0 failure or a TeamLead
# plan-gate remode.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
chmod 600 "$MAIN/.env"
run "$MAIN" $NEW alfa AB-1260 chore/AB-1260-x origin/develop quick
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
# The remoded run's notifications are resolved; another run's are not.
for r in "$RUN_ID" alfa-20990101-000000; do
  run "$MAIN" bash .claude/lib/notify.sh human_decision --project smk --team alfa --ticket AB-1260 --run "$r" \
    --decision x-1 --summary s --answer alfa-lead --main "$MAIN"; expect 0 "written" "seed a notification"
done
run "$MAIN" $REMODE alfa brainstorm
expect 0 "next:     /start-team alfa" "remode succeeds"
NST="$HOME/.agent-comms/outbox/state"
[ -f "$NST/smk_alfa_${RUN_ID}_x-1.resolved" ] && [ ! -e "$NST/smk_alfa_alfa-20990101-000000_x-1.resolved" ] \
  || { ls "$NST" > "$WORK/out" 2>&1; fail "remode did not resolve exactly the remoded run's notifications"; }
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
  bash .claude/lib/team-next.sh alfa AB-1261 chore/AB-1261-y origin/develop
expect 0 "was AB-1260" "team-next after remode"
echo "team-smoke-10: (e) team-next OK"

# ---- (f) a quick run closed by a TeamLead plan-gate remode (close_run's tree) --------------------
jq '.mode = "quick"' "$TD/team.json" > "$WORK/tj" && mv "$WORK/tj" "$TD/team.json"
BR=chore/AB-1261-y; BASE="$(jq -r .base_sha "$TD/team.json")"
RUN_ID=alfa-20261026-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
commit_file .agents/plans/active/q.md "# Quick plan"
TIP="$(git -C "$CLONE" rev-parse HEAD)"
jq -n --arg run "$RUN_ID" --arg b "$BASE" --arg t "$TIP" \
  '{team: "alfa", ticket: "AB-1261", run: $run, role: "planner", attempt: 1, seq: 1, branch: "x",
    input_rev: $b, output_rev: $t, verdict: "done", pr_id: null,
    artifacts: [".agents/plans/active/q.md"], evidence: [], notes: "", message: "",
    written_at: "2026-10-26T00:00:00Z"}' > "$RD/planner-1-1.json"
echo planner-1-1.json > "$TD/acked"; echo "ticket: AB-1261" > "$TD/order-brief.md"
run "$MAIN" $REMODE alfa brainstorm
expect 1 "not failed \"too big for quick" "a done record without a TeamLead remode"
jq -n '{gate: "plan", seq: 1, for: "planner-1-0.json", verdict: "remode"}' > "$RD/teamlead-plan-1.json"
run "$MAIN" $REMODE alfa brainstorm
expect 1 "the planner committed work" "a remode naming another record"
jq -n '{gate: "plan", seq: 2, for: "planner-1-1.json", verdict: "remode"}' > "$RD/teamlead-plan-2.json"
jq -n --arg r ".agents/team/runs/$RUN_ID/teamlead-plan-2.json" '{reason: "remode", ref: $r, pr_id: null}' \
  > "$RD/closed.json"
echo '{}' > "$RD/coder-1-1.json"
run "$MAIN" $REMODE alfa brainstorm
expect 1 "has coder-1-1.json — another role ran" "a TeamLead remode after a coder record"
rm -f "$RD/coder-1-1.json"
run "$MAIN" $REMODE alfa brainstorm
expect 0 "from HEAD" "remode after a TeamLead plan-gate remode"
[ "$(jq -r .mode "$TD/team.json")" = brainstorm ] || fail "(f) mode not brainstorm"
[ "$(git -C "$CLONE" rev-parse HEAD)" = "$TIP" ] || fail "(f) remode moved HEAD (history rewrite)"
[ -f "$TD/order-brief.md" ] || fail "(f) the order brief was not kept"
ls "$TD"/archive/AB-1261-remode-*/runs/"$RUN_ID"/teamlead-plan-2.json >/dev/null 2>&1 \
  || fail "(f) the closed run was not archived"
echo "team-smoke-10: (f) TeamLead remode OK"

echo "team-smoke-10: (a)-(f) OK"
