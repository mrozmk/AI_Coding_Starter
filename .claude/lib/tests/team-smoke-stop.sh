#!/usr/bin/env bash
# The runner's stops nobody saw before #99 (team-run-stop.sh). A rejected record goes back to its stage
# with the validator's reason, at most twice per attempt; the third stops the runner (exit 4) with one
# human_decision event and a resumed runner sends no second one. With a TeamLead the third rings the
# lead, the runner waits and no Operator event is sent. A stall (exit 3) sends one event, a resumed
# runner sends none again, and the event is resolved once the run goes on (a new attempt).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

smoke_team AB-1500 feature/AB-1500-x
RUN_ID=alfa-20261116-030000; RD="$TD/runs/$RUN_ID"
REG="$(cd "$MAIN" && pwd -P)/.agents/team/registry"; OB="$HOME/.agent-comms/outbox"
export WORK TD REG RD
prof() { jq "$1" "$MAIN/.claude/project-profile.json" > "$WORK/p" && mv "$WORK/p" "$MAIN/.claude/project-profile.json"; }

cat > "$WORK/hs.sh" <<'HS'
s="${3#=}"; s="${s#smk-}"
! grep -q -- "kill-session -t =smk-$s\$" "$STUB_LOG" || exit 1
grep -qx -- "$s" "$WORK/alive" 2>/dev/null && exit 0
exit 1
HS
export STUB_ON_HAS_SESSION=". '$WORK/hs.sh'"
# The fixture clock (+500 s a call; the qa limit is 10800 s). The stage "writes" its next record at REC2_AT / REC3_AT (a file
# prepared in $WORK appears in the run dir); past CANCEL_AT the runner is stopped — the net.
echo 1000000 > "$WORK/clock"
export TEAM_NOW_CMD='n=$(cat "$WORK/clock"); echo $((n + 500)) > "$WORK/clock"
  for k in 2 3; do eval "t=\${REC${k}_AT:-}"; [ -z "$t" ] || [ "$n" -lt "$t" ] || [ -e "$RD/qa-1-$k.json" ] || cp "$WORK/qa-1-$k.json" "$RD/"; done
  [ -z "${CANCEL_AT:-}" ] || [ "$n" -lt "$CANCEL_AT" ] || touch "$TD/cancel"
  echo "$n"'

reset() {
  rm -rf "$TD/lock" "$TD/cancel" "$TD/acked" "$TD/runs" "$TD/session.json" "$TD/teamlead.json" "$OB" \
    "$TD"/send-*.log "$TD/verdict-acked"
  : > "$STUB_LOG"; : > "$WORK/alive"; echo 1000000 > "$WORK/clock"
  unset CANCEL_AT REC2_AT REC3_AT
  echo "$RUN_ID" > "$TD/run"; mkdir -p "$RD"
}
qarec() {  # qarec <seq> <dir> — a qa done record the validator rejects: no accepted coder record
  jq -n --arg run "$RUN_ID" --argjson s "$1" --arg in "$BASE" --arg out "$(git -C "$CLONE" rev-parse HEAD)" \
    --arg br "$(jq -r .branch "$TD/team.json")" \
    '{team: "alfa", ticket: "AB-1500", run: $run, role: "qa", attempt: 1, seq: $s, branch: $br,
      input_rev: $in, output_rev: $out, verdict: "done", pr_id: 8371, artifacts: [],
      evidence: [".agents/team/runs/\($run)/qa-report-1.md"], notes: "", message: "",
      written_at: "2026-11-16T03:00:00Z"}' > "$2/qa-1-$1.json"
}
nev() { ls "$OB/events" 2>/dev/null | grep -c "_alfa_${RUN_ID}_$1\.json$" || true; }
resolved() { ls "$OB/state" 2>/dev/null | grep -q "_alfa_${RUN_ID}_$1\.resolved$"; }
rang() { cat "$TD/send-$1.log" "$STUB_LOG" 2>/dev/null | grep -cF -- "$2" || true; }  # doorbell tries
WHY="PR identity mismatch (qa pr_id 8371 is not the coder's)"

# ---- (1) rejected, lead off: sent back twice with the reason, the third stops with one event --------
reset; echo alfa-qa > "$WORK/alive"; session qa 1 "$BASE"
qarec 1 "$RD"; qarec 2 "$WORK"; qarec 3 "$WORK"
export REC2_AT=1002000 REC3_AT=1004000 CANCEL_AT=1030000
run "$MAIN" $TR alfa; expect 4 "record qa-1-3.json rejected — session left alive" "(1) third rejection stops"
has "sent back to qa (1 of 2)" "$WORK/out" && has "sent back to qa (2 of 2)" "$WORK/out" || fail "(1) not sent back twice"
! has "sent back to qa (3 of 2)" "$WORK/out" || fail "(1) the third was sent back"
[ "$(rang qa "was rejected: $WHY. Fix the cause")" = 2 ] || { cat "$TD"/send-*.log >> "$WORK/out" 2>/dev/null || true; fail "(1) the stage was not told exactly twice, verbatim"; }
[ "$(ls "$RD" | grep -c '^rejected-qa-1-')" = 3 ] && [ "$(cat "$RD/rejected-qa-1-3")" = "$WHY" ] || fail "(1) rejected-<record> files"
[ -e "$RD/qa-1-1.json.answered" ] && [ ! -e "$RD/qa-1-3.json.answered" ] && [ "$(cat "$TD/acked")" = qa-1-2.json ] \
  || fail "(1) sent back = acked + answered; the third stays unacked"
[ "$(nev rejected-qa-1)" = 1 ] || fail "(1) not exactly one rejected event"
jq -e '.event == "human_decision" and .decision == "rejected-qa-1" and .source == "runner"
  and .answer.address == "alfa-qa"' \
  "$OB/events/"*"_alfa_${RUN_ID}_rejected-qa-1.json" >/dev/null || fail "(1) event file"
[ "$(cat "$RD/operator-rejected-qa-1")" = rejected-qa-1 ] || fail "(1) operator marker"
! has "stalled" "$WORK/out" || fail "(1) stalled"
rm -f "$TD/lock"; : > "$STUB_LOG"
run "$MAIN" $TR alfa; expect 4 "record qa-1-3.json rejected" "(1) a rerun validates the third again"
[ "$(nev rejected-qa-1)" = 1 ] && ! has "sent back" "$WORK/out" || fail "(1) a rerun sent again"
echo "team-smoke-stop: (1) rejected, lead off OK"

# ---- (2) stalled: one event, none again on resume, resolved when a new attempt launches -------------
reset; echo alfa-qa > "$WORK/alive"; session qa 1 "$BASE"
run "$MAIN" $TR alfa; expect 3 "stalled" "(2) stall"
[ "$(nev stalled-qa-1)" = 1 ] && [ -f "$RD/operator-stalled-qa-1" ] || fail "(2) not one stalled event"
jq -e '.event == "human_decision" and .decision == "stalled-qa-1" and .answer.address == "alfa-qa"' \
  "$OB/events/"*"_alfa_${RUN_ID}_stalled-qa-1.json" >/dev/null || fail "(2) stalled event file"
rm -f "$TD/lock"; echo 1000000 > "$WORK/clock"
run "$MAIN" $TR alfa; expect 3 "stalled" "(2) stalls again"
[ "$(nev stalled-qa-1)" = 1 ] || fail "(2) a resumed runner sent a second event"
rm -f "$TD/lock"; : > "$WORK/alive"; : > "$STUB_LOG"; echo 1000000 > "$WORK/clock"; export CANCEL_AT=1003000
mkrec coder "$BASE"; touch "$RD/coder-1-1.json.accepted"   # attempt 2 launches from the coder's revision
run "$MAIN" $TR alfa; expect 5 "operator item resolved: stalled-qa-1" "(2) a new attempt resolves it (attempt 2 then dies: no live fixture session)"
has "launched: qa attempt 2" "$WORK/out" && resolved stalled-qa-1 && [ ! -e "$RD/operator-stalled-qa-1" ] \
  || fail "(2) not resolved on the new attempt"
echo "team-smoke-stop: (2) stalled OK"

# ---- (3) rejected, lead on: the third rings the lead, the runner waits, no Operator event -----------
unset TEAM_SMOKE_NO_LEAD
mkdir -p "$CLONE/.claude/hooks" "$MAIN/.claude/team/sessions"
cp "$SRC/.claude/team/sessions/TeamLead-run.settings.json" "$MAIN/.claude/team/sessions/"
cp "$SRC/.claude/hooks/guard-teamlead-write.sh" "$SRC/.claude/hooks/guard-teamlead-bash.sh" "$CLONE/.claude/hooks/"
printf '## Ticket\nExport.\n\n## Not ordered\nnone stated\n\n## In-flight work\n- none\n' > "$WORK/brief.md"
run "$MAIN" bash .claude/lib/team-brief.sh write alfa "$WORK/brief.md"; expect 0 "" "(3) fixture brief"
reset; printf 'alfa-lead\nalfa-qa\n' > "$WORK/alive"; session qa 1 "$BASE"
jq -n --arg r "$RUN_ID" --arg m "$MAIN" '{team: "alfa", run: $r, session_id: "sid-alfa-lead", launch: 1, main_root: $m}' > "$TD/teamlead.json"
qarec 1 "$RD"; qarec 2 "$WORK"; qarec 3 "$WORK"
export REC2_AT=1002000 REC3_AT=1004000 CANCEL_AT=1030000
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: qa-1-3.json" "(3) third rejection waits for the lead"
W3="$(cat "$RD/rejected-qa-1-1")"; [ -n "$W3" ] || fail "(3) no reason kept"   # this case checks the routing
[ "$(rang lead "rejected qa 1: .agents/team/runs/$RUN_ID/qa-1-3.json — $W3 (3rd rejection, the stage is not asked again)")" -ge 1 ] \
  || { cat "$TD"/send-*.log >> "$WORK/out" 2>/dev/null || true; fail "(3) the lead was not rung for the third"; }
[ "$(rang lead "(sent back to the stage, 2 of 2)")" -ge 1 ] || fail "(3) the lead did not hear the sent-back"
[ "$(rang qa "was rejected: $W3")" = 2 ] || fail "(3) the stage was not told exactly twice"
[ "$(cat "$TD/acked")" = qa-1-3.json ] && [ ! -e "$RD/qa-1-3.json.answered" ] || fail "(3) the third is not acked for the lead"
[ "$(nev rejected-qa-1)" = 0 ] || fail "(3) an Operator event with the lead on"
! has "stalled" "$WORK/out" || fail "(3) the lead's wait counted as a stall"
echo "team-smoke-stop: (3) rejected, lead on OK"

# ---- (4) the lead's list after the 3rd rejection → the lead's say → the next record validates ----------
# A valid qa fixture (as part 23): spec + plan, the coder's work pushed, its PR; the hooks committed.
BR="$(jq -r .branch "$TD/team.json")"
git -C "$CLONE" add .claude/hooks && git -C "$CLONE" commit --quiet -m "fixture guard"
commit_file .agents/specs/s.md "# Spec"; commit_file .agents/plans/active/p.md "# Plan"
P_OUT="$(git -C "$CLONE" rev-parse HEAD)"
mkdir -p "$CLONE/.agents/plans/done"; git -C "$CLONE" mv .agents/plans/active/p.md .agents/plans/done/p.md
commit_file src/export.txt "export button"; C1="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" push --quiet origin "$BR"
[ -z "$(git -C "$CLONE" status --porcelain)" ] || fail "(4) fixture clone not clean"
pr_json false "$C1"; pr_set --arg b "refs/heads/$BR" '.sourceRefName = $b'
reset; printf 'alfa-lead\nalfa-qa\n' > "$WORK/alive"
jq -n --arg r "$RUN_ID" --arg m "$MAIN" '{team: "alfa", run: $r, session_id: "sid-alfa-lead", launch: 1, main_root: $m}' > "$TD/teamlead.json"
mkrec planner "$P_OUT"; jq '.artifacts = [".agents/specs/s.md", ".agents/plans/active/p.md"]' "$RD/planner-1-1.json" > "$WORK/r" \
  && mv "$WORK/r" "$RD/planner-1-1.json"; touch "$RD/planner-1-1.json.accepted"
mkrec coder "$C1"; jq --arg in "$P_OUT" '.input_rev = $in | .artifacts = [".agents/plans/done/p.md"]' "$RD/coder-1-1.json" > "$WORK/r" \
  && mv "$WORK/r" "$RD/coder-1-1.json"; touch "$RD/coder-1-1.json.accepted"
{ echo "run: $RUN_ID"; echo "attempt: 1"; echo "output_rev: $C1"; echo "Verdict: ready"
  echo "Gate code: passed"; echo "Gate design: skipped — backend change"; echo "Gate cross-model: warn"
  echo "Gate final-build: passed"; echo "Tests: passed=3 failed=0 skipped=0 baseline=0"
  echo "Warnings: none"; echo "Rethink signals: none"; } > "$RD/qa-report-1.md"
SID=sid-qa-4; session qa 1 "$C1" "$SID"; T="$(transcript "$SID")"; mkdir -p "$(dirname "$T")"; : > "$T"
qa4() {  # qa4 <seq> <dir> <pr> — a qa done on C1; pr 9999 is not the coder's PR
  qarec "$1" "$2"; jq --arg c "$C1" --argjson p "$3" '.input_rev = $c | .output_rev = $c | .pr_id = $p' "$2/qa-1-$1.json" > "$WORK/r" \
    && mv "$WORK/r" "$2/qa-1-$1.json"
}
qa4 1 "$RD" 9999; qa4 2 "$WORK" 9999; qa4 3 "$WORK" 9999
export REC2_AT=1002000 REC3_AT=1004000 CANCEL_AT=1030000
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: qa-1-3.json" "(4) third rejection waits for the lead"
W4="PR identity mismatch (qa pr_id 9999 is not the coder's)"
run "$MAIN" bash .claude/lib/team-lead.sh pending alfa
expect 0 "rejected .agents/team/runs/$RUN_ID/qa-1-3.json — $W4" "(4) pending lists the rejected record"
[ "$(grep -c '^rejected ' "$WORK/out")" = 1 ] && ! grep -q '^stop \|^gate ' "$WORK/out" || fail "(4) pending lists more than the one rejected record"
rm -f "$TD/cancel"; export STUB_PANE="$FIX/idle.txt" STUB_TMUX_ALIVE=0; : > "$STUB_LOG"   # the stage session, alive again, at an idle prompt
run "$MAIN" env TEAM_SESSION_ROLE=TeamLead TEAM_RUN_TEAM=alfa bash .claude/lib/team-answer.sh alfa qa say "Use the coder's PR." \
  --authority teamlead --why "the coder's PR is the run's PR"
expect 0 "sent say" "(4) the lead's say"
[ -e "$RD/qa-1-3.json.answered" ] || fail "(4) the say wrote no .answered"
run "$MAIN" bash .claude/lib/team-lead.sh pending alfa
! has "rejected " "$WORK/out" || fail "(4) pending still lists the answered record"
unset STUB_PANE STUB_TMUX_ALIVE
qa4 4 "$RD" 8371; rm -f "$TD/lock" "$TD/cancel"; : > "$STUB_LOG"; echo 1000000 > "$WORK/clock"; unset REC2_AT REC3_AT
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: gate acceptance qa-1-4.json" "(4) the stage's next record validates"
! has "rejected: qa-1-4.json" "$WORK/out" || fail "(4) the fixed record was rejected"
echo "team-smoke-stop: (4) lead's list, say, revalidation OK"
echo "team-smoke-stop: OK"
