#!/usr/bin/env bash
# Acceptance against the order: the qa done waits for the lead's acceptance gate; accept needs the
# blind check and a complete brief (one decision per QA warning); ready and one `accepted` event
# only after accept and a done wrapup; abandon goes through an abandon_decision; the acceptance
# patch carries no spec or plan line. Rework rounds (team-lead.md §9): storage under r<n>/, the
# rework coder on the same PR, the budget and its Operator grant, quick mode, crash recovery; the
# lead's notes and the shared log (team-lead.md §10).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

smoke_team AB-1600 feature/AB-1600-x
BR=feature/AB-1600-x; SUP="$MAIN/.agents/team/inbox/Supervisor/new"
export WORK TD
prof() { jq "$1" "$MAIN/.claude/project-profile.json" > "$WORK/p" && mv "$WORK/p" "$MAIN/.claude/project-profile.json"; }
mkdir -p "$MAIN/.claude/team/sessions" "$CLONE/.claude/hooks"
cp "$SRC/.claude/team/sessions/TeamLead.settings.json" "$MAIN/.claude/team/sessions/"
cp "$SRC/.claude/hooks/guard-teamlead-write.sh" "$SRC/.claude/hooks/guard-teamlead-bash.sh" "$CLONE/.claude/hooks/"
cp "$SRC/.claude/lib/team-watch-send.py" "$MAIN/.claude/lib/"
git -C "$CLONE" add .claude/hooks && git -C "$CLONE" commit --quiet -m "fixture guard"
# abandon_decision events of the current run in notify.sh's outbox (the fixture HOME)
nab() { jq -r --arg r "$RUN_ID" 'select(.event == "abandon_decision" and .run == $r) | .id' \
  "$HOME/.agent-comms/outbox/events/"*.json 2>/dev/null | grep -c . || true; }
printf '## Ticket\nExport button.\n\n## Not ordered\nCSV import\n\n## In-flight work\n- none\n' > "$WORK/brief.md"
run "$MAIN" bash .claude/lib/team-brief.sh write alfa "$WORK/brief.md"; expect 0 "" "fixture brief"
# This run's spec and plan, then the coder's work, pushed: the qa revision is C1.
commit_file .agents/specs/s.md "# Spec
Speculative: a CSV import nobody ordered."
commit_file .agents/plans/active/p.md "# Plan
1. Add the export button."
P_OUT="$(git -C "$CLONE" rev-parse HEAD)"
mkdir -p "$CLONE/.agents/plans/done"; git -C "$CLONE" mv .agents/plans/active/p.md .agents/plans/done/p.md
commit_file src/export.txt "export button"
C1="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" push --quiet origin "$BR"
[ -z "$(git -C "$CLONE" status --porcelain)" ] || fail "fixture clone not clean"
pr_json false "$C1"; pr_set --arg b "refs/heads/$BR" '.sourceRefName = $b'

smoke_cancel_hook
cat > "$WORK/hs.sh" <<'HS'
n=$(( $(cat "$WORK/hs.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/hs.n"
s="${3#=}"; s="${s#smk-}"   # alive lists and cases name addresses; tmux names carry smk-
. "$WORK/cancel-check.sh"
! grep -q -- "kill-session -t =smk-$s\$" "$STUB_LOG" || exit 1
grep -qx -- "$s" "$WORK/alive" 2>/dev/null && exit 0
exit 1
HS
export STUB_ON_HAS_SESSION=". '$WORK/hs.sh'" STUB_PANE="$FIX/idle.txt"
greset() {  # greset <alive sessions...> — a runner start: lock, cancel, logs cleared
  rm -rf "$TD/lock" "$TD/cancel" "$WORK/hs.n" "$WORK/cancel.why"; : > "$STUB_LOG"; printf '%s\n' "$@" > "$WORK/alive"
  unset CANCEL_ON; export CANCEL_AT=12
}
TR="bash .claude/lib/team-run.sh"
V() { run "$CLONE" env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-verdict.sh "$@"; }
# The lead records every answer with the tuning question (team-lead.md §10).
ldec() { if [ "$1" = answer ]; then set -- "$@" --tuning none --why fixture; fi
  run "$CLONE" env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-lead.sh decision "$@"; }
rec_json() {  # rec_json <role> <input> <output> <pr|null> <artifacts json> — record 1-1, done
  jq -n --arg role "$1" --arg in "$2" --arg out "$3" --argjson pr "$4" --argjson a "$5" \
    --arg run "$RUN_ID" --arg br "$BR" --arg ev ".agents/team/runs/$RUN_ID/qa-report-1.md" \
    '{team: "alfa", ticket: "AB-1600", run: $run, role: $role, attempt: 1, seq: 1, branch: $br,
      input_rev: $in, output_rev: $out, verdict: "done", pr_id: $pr, artifacts: $a,
      evidence: (if $role == "qa" then [$ev] else [] end), notes: "", message: "",
      written_at: "2026-11-15T10:00:00Z"}' > "$RD/$1-1-1.json"
}
setup_run() {  # setup_run <run id> [qa verdict line] [warnings] — planner and coder accepted, qa done
  RUN_ID="$1"; RD="$TD/runs/$RUN_ID"; rm -rf "$RD" "$TD/acked" "$TD/verdict-acked"
  mkdir -p "$RD"; echo "$RUN_ID" > "$TD/run"
  jq -n --arg r "$RUN_ID" --arg m "$MAIN" '{team: "alfa", run: $r, session_id: "sid-lead", main_root: $m}' \
    > "$TD/teamlead.json"
  rec_json planner "$BASE" "$P_OUT" null '[".agents/specs/s.md", ".agents/plans/active/p.md"]'
  touch "$RD/planner-1-1.json.accepted"
  rec_json coder "$P_OUT" "$C1" 8371 '[".agents/plans/done/p.md"]'; touch "$RD/coder-1-1.json.accepted"
  { echo "run: $RUN_ID"; echo "attempt: 1"; echo "output_rev: $C1"; echo "Verdict: ${2:-ready}"
    echo "Gate code: passed"; echo "Gate design: skipped — backend change"; echo "Gate cross-model: warn"
    echo "Gate final-build: passed"; echo "Tests: passed=3 failed=0 skipped=0 baseline=0"
    echo "Warnings: ${3:-none}"; echo "Rethink signals: none"; } > "$RD/qa-report-1.md"
  rec_json qa "$C1" "$C1" 8371 '[]'
  session qa 1 "$C1"
}
brief() {  # brief [warnings section lines] — the acceptance brief, written after the blind check
  { echo "## Ordered vs delivered"; echo "- export button → src/export.txt"
    echo; echo "## Scope delta"; echo "none"; echo; echo "## Fit risks"; echo "none"
    echo; echo "## Open defects"; echo "none"; echo; echo "## Warnings"; printf '%s\n' "${1:-none}"
    echo; echo "## Recommendation"; echo "accept"; } > "$RD/acceptance-brief.md"
}
unset TEAM_SMOKE_NO_LEAD

# ---- (z) a lead launched with ask_operator lists its verification-only answers (seventh heading) --
case_mark "(z) verification-only answers listed"
setup_run alfa-20261115-090000
jq '.ask_operator = true' "$TD/teamlead.json" > "$WORK/tj" && mv "$WORK/tj" "$TD/teamlead.json"
mkdir -p "$RD/asks"
# a-3 the lead decided itself as verification-only; a-4 at teamlead authority, only quoting the marker
(cd "$CLONE" && . "$MAIN/.claude/lib/team-ask.sh" && ask_init "$TD" \
  && ask_answer_write a-3 '{"id":"a-3","form":"text","value":"prove AC-2 in the smoke step","authority":"teamlead","why":"verification-only: same AC, the test moves","decision":"","answered_at":"2026-11-15T09:00:00Z","lead_session_id":"sid-lead"}' \
  && ask_answer_write a-4 '{"id":"a-4","form":"text","value":"the plan calls this verification-only: keep the wording","authority":"teamlead","why":"the order names it","decision":"","answered_at":"2026-11-15T09:00:01Z","lead_session_id":"sid-lead"}') \
  || fail "(z) fixture answers"
echo "- export button → src/export.txt" > "$RD/blind-check.md"
zbrief() { brief; printf '\n## Decided by the TeamLead\n%s\n' "$1" >> "$RD/acceptance-brief.md"; }
zbrief "- a-4 — wording kept → as ordered — the order names it"
V acceptance accept --for qa-1-1.json --message ok; expect 8 "no line for verification-only answer a-3" "(z) a-3 not listed"
brief; V acceptance accept --for qa-1-1.json --message ok
expect 8 "lacks the heading '## Decided by the TeamLead'" "(z) a six-heading brief from an ask_operator lead"
zbrief "- a-3 — where AC-2 is proven → the smoke step — verification-only: same AC, the test moves"
V acceptance accept --for qa-1-1.json --message ok; expect 0 "teamlead-acceptance-1.json" "(z) a-3 listed, a-4 not required"
setup_run alfa-20261115-091000
echo "- export button → src/export.txt" > "$RD/blind-check.md"; brief
V acceptance accept --for qa-1-1.json --message ok; expect 0 "teamlead-acceptance-1.json" "(z) an older lead: six headings"
echo "team-smoke-23: (z) verification-only answers listed under ## Decided by the TeamLead OK"

setup_run alfa-20261115-100000

# ---- (a) qa done with the lead on: validated, the acceptance gate rung, no wrapup yet -------------
case_mark "(a) qa done with the lead on: validated"
greset alfa-lead alfa-qa
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: gate acceptance qa-1-1.json" "(a) runner"
! has "-s smk-alfa-wrapup" "$STUB_LOG" || fail "(a) the wrapup launched before a verdict"
grep -qsF "gate acceptance: .agents/team/runs/$RUN_ID/qa-1-1.json" "$STUB_LOG" "$TD/send-lead.log" \
  || fail "(a) the lead was not rung for the acceptance gate"
[ "$(cat "$TD/acked")" = qa-1-1.json ] || fail "(a) qa record not acked"
echo "team-smoke-23: (a) acceptance gate OK"

# ---- (b) accept needs the blind check first, then a complete brief -------------------------------
case_mark "(b) accept needs the blind check first"
V acceptance accept --for qa-1-1.json --message ok; expect 8 "blind-check.md missing" "(b) no blind check"
brief; touch -t "$(date -v-10S +%Y%m%d%H%M.%S)" "$RD/acceptance-brief.md"   # strictly older (-ot)
echo "- export button → src/export.txt" > "$RD/blind-check.md"
V acceptance accept --for qa-1-1.json --message ok; expect 8 "older than blind-check.md" "(b) brief before the blind check"
brief; sed -i.bak '/^## Fit risks$/d' "$RD/acceptance-brief.md"
V acceptance accept --for qa-1-1.json --message ok; expect 8 "lacks the heading '## Fit risks'" "(b) missing heading"
V acceptance accept --for qa-1-1.json --message ok; [ ! -e "$RD/teamlead-acceptance-1.json" ] || fail "(b) a refused accept wrote a verdict"
V acceptance remode --for qa-1-1.json --message x; expect 4 "not allowed at the acceptance gate" "(b) bad verdict"
echo "team-smoke-23: (b) blind check + brief OK"

# ---- (c) ready-with-warnings: one decision line per warning ---------------------------------------
case_mark "(c) ready-with-warnings: one decision li"
sed -i.bak 's/^Verdict: ready$/Verdict: ready-with-warnings/; s/^Warnings: none$/Warnings: flaky e2e, slow build/' "$RD/qa-report-1.md"
brief "- flaky e2e → follow-up — tracked as a test-infra ticket"
V acceptance accept --for qa-1-1.json --message ok; expect 8 "no '- slow build → keep|fix|follow-up" "(c) a warning without a decision"
brief "- flaky e2e → follow-up — test-infra ticket
- slow build → keep"
V acceptance accept --for qa-1-1.json --message ok; expect 8 "slow build" "(c) a decision without a reason"
brief "- flaky e2e → follow-up — test-infra ticket
- slow build → keep — within the build budget"
V acceptance accept --for qa-1-1.json --message "covers the order"; expect 0 "teamlead-acceptance-1.json" "(c) all warnings decided"
echo "team-smoke-23: (c) warnings OK"

# ---- (d) accept → qa accepted, wrapup launched; after the wrapup one accepted event and ready ------
case_mark "(d) accept → qa accepted, wrapup launc"
greset alfa-lead alfa-qa; export CANCEL_AT=40
# count kept: (d) asserts no accepted event while wrapup is unfinished — a later poll must have the chance to emit it
run "$MAIN" $TR alfa
[ -e "$RD/qa-1-1.json.accepted" ] || fail "(d) qa record not accepted (exit $RC)"
has "launched: wrapup attempt 1" "$WORK/out" || fail "(d) the wrapup did not launch"
[ ! -d "$SUP" ] || ! grep -l '^event: accepted' "$SUP"/* >/dev/null 2>&1 || fail "(d) accepted before the wrapup"
rec_json wrapup "$C1" "$C1" 8371 '[]'; touch "$RD/wrapup-1-1.json.accepted"; rm -f "$TD/session.json"
greset alfa-lead
run "$MAIN" $TR alfa; expect 0 "ready: bash .claude/lib/team-merge-check.sh alfa" "(d) ready"
[ "$(grep -l '^event: accepted' "$SUP"/* | wc -l | tr -d ' ')" = 1 ] || fail "(d) not exactly one accepted event"
grep -q "^ref: runs/$RUN_ID/acceptance-brief.md" "$(grep -l '^event: accepted' "$SUP"/*)" || fail "(d) accepted ref"
[ -s "$RD/accepted.sent" ] || fail "(d) no accepted.sent guard"
echo "team-smoke-23: (d) accept → wrapup → ready OK"

# ---- (e) a resume after ready sends no second accepted ---------------------------------------------
case_mark "(e) a resume after ready sends no second"
greset alfa-lead
run "$MAIN" $TR alfa; expect 0 "ready:" "(e) resume after ready"
[ "$(grep -l '^event: accepted' "$SUP"/* | wc -l | tr -d ' ')" = 1 ] || fail "(e) a second accepted event"
echo "team-smoke-23: (e) single accepted OK"

# ---- (f) abandon-recommended goes through an abandon_decision; decision close closes the run -------
case_mark "(f) abandon-recommended goes through an"
setup_run alfa-20261115-110000
greset alfa-lead alfa-qa; run "$MAIN" $TR alfa; expect 6 "gate acceptance qa-1-1.json" "(f) gate rung"
V acceptance abandon-recommended --for qa-1-1.json --message x; expect 4 "needs --decision" "(f) bare abandon"
ldec open alfa --source qa-1-1.json --question "Abandon AB-1600? The export duplicates beta's work." \
  --notify abandon_decision; expect 0 "[d-1]" "(f) open the abandon decision"
ldec open alfa --source qa-1-1.json --question "Other?"; expect 0 "[d-2]" "(f) a human_decision one"
V acceptance abandon-recommended --for qa-1-1.json --decision d-2 --message x
expect 4 "not a pending decision opened with --notify abandon_decision" "(f) the wrong decision"
V acceptance abandon-recommended --for qa-1-1.json --decision d-1 --message "duplicate of beta"
expect 0 "teamlead-acceptance-1.json" "(f) abandon-recommended"
ldec withdraw alfa d-2 --why "not needed"; expect 0 "" "(f) withdraw d-2"
greset alfa-lead alfa-qa; run "$MAIN" $TR alfa; expect 6 "" "(f) runner waits on the decision"
[ ! -e "$RD/closed.json" ] || fail "(f) abandon-recommended closed the run by itself"
[ "$(nab)" = 1 ] || fail "(f) not exactly one abandon_decision event"
LTX="$(transcript sid-lead)"; mkdir -p "$(dirname "$LTX")"
jq -cn --arg ts "$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ)" \
  '{type: "user", uuid: "u-op", timestamp: $ts, message: {role: "user", content: "d-1 close it"}}' >> "$LTX"
ldec answer alfa d-1 --text "close it" --outcome close; expect 0 "answered: d-1 (close)" "(f) Operator answer"
V decision close --for qa-1-1.json --decision d-1 --message "Operator: close it"; expect 0 "" "(f) decision close"
# The run's inbox messages leave new/ when close_run ends it; another run's stay.
IBA="$MAIN/.agents/team/inbox/alfa"; mkdir -p "$IBA/new"
printf -- '---\nid: m1\nrun: %s\n---\nx\n' "$RUN_ID" > "$IBA/new/20261115T110001Z-Supervisor-message.md"
printf -- '---\nid: m2\nrun: alfa-20990101-000000\n---\nx\n' > "$IBA/new/20261115T110002Z-Supervisor-message.md"
# ...and its notifications are resolved; another run's are not (notify.sh resolve --all).
for r in "$RUN_ID" alfa-20990101-000000; do
  run "$MAIN" bash .claude/lib/notify.sh human_decision --project smk --team alfa --ticket AB-1600 --run "$r" \
    --decision x-1 --summary s --answer alfa-lead --main "$MAIN"; expect 0 "written" "(f) seed a notification"
done
greset alfa-lead alfa-qa; run "$MAIN" $TR alfa; expect 8 "closed: abandon — PR 8371 to abandon before team-next" "(f) the run closes"
NST="$HOME/.agent-comms/outbox/state"
[ -f "$NST/smk_alfa_${RUN_ID}_x-1.resolved" ] && [ ! -e "$NST/smk_alfa_alfa-20990101-000000_x-1.resolved" ] \
  || { ls "$NST" > "$WORK/out" 2>&1; fail "(f) close_run did not resolve exactly the run's notifications"; }
[ -f "$IBA/done/20261115T110001Z-Supervisor-message.md" ] && [ ! -e "$IBA/new/20261115T110001Z-Supervisor-message.md" ] \
  && [ -f "$IBA/new/20261115T110002Z-Supervisor-message.md" ] \
  || { ls -R "$IBA" > "$WORK/out"; fail "(f) close_run did not move exactly the run's inbox message to done/"; }
rm -f "$IBA/new/20261115T110002Z-Supervisor-message.md" "$IBA/done/20261115T110001Z-Supervisor-message.md"
jq -e '.reason == "abandon"' "$RD/closed.json" >/dev/null || fail "(f) closed.json"
grep -l '^event: closed' "$SUP"/* | xargs grep -l "run: $RUN_ID" >/dev/null || fail "(f) no closed event"
[ "$(nab)" = 1 ] || fail "(f) a second abandon event"
echo "team-smoke-23: (f) abandon through a decision OK"

# ---- (g) no lead (the fixture seam): ready as without a lead, no inbox file ------------------------
case_mark "(g) no lead (the fixture seam): ready as"
setup_run alfa-20261115-120000; touch "$RD/qa-1-1.json.accepted"
rec_json wrapup "$C1" "$C1" 8371 '[]'; touch "$RD/wrapup-1-1.json.accepted"; rm -f "$TD/session.json"
N0="$(ls "$SUP" | wc -l | tr -d ' ')"
greset; TEAM_SMOKE_NO_LEAD=1 run "$MAIN" $TR alfa; expect 0 "ready:" "(g) ready without a lead"
[ "$(ls "$SUP" | wc -l | tr -d ' ')" = "$N0" ] && [ ! -e "$RD/accepted.sent" ] || fail "(g) an inbox file without a lead"
echo "team-smoke-23: (g) no lead OK"

# ---- (h) the acceptance patch holds no line of this run's spec or plan -----------------------------
case_mark "(h) the acceptance patch holds no line o"
run "$CLONE" bash .claude/lib/team-lead.sh diff alfa; expect 0 "acceptance-diff.patch" "(h) diff"
has "src/export.txt" "$RD/acceptance-diff.patch" || fail "(h) the delivery is not in the patch"
! grep -q 'Speculative\|Add the export button' "$RD/acceptance-diff.patch" || fail "(h) spec or plan lines in the patch"
! grep -q '\.agents/specs/\|\.agents/plans/' "$RD/acceptance-diff.stat" || fail "(h) spec or plan in the stat"
echo "team-smoke-23: (h) blind patch OK"

# ---- (i) a lead resumed after the qa was accepted: ready, but no accepted event without a verdict
case_mark "(i) a lead resumed after the qa was acce"
setup_run alfa-20261115-130000; touch "$RD/qa-1-1.json.accepted"
rec_json wrapup "$C1" "$C1" 8371 '[]'; touch "$RD/wrapup-1-1.json.accepted"; rm -f "$TD/session.json"
greset alfa-lead; run "$MAIN" $TR alfa; expect 0 "accepted event skipped: no acceptance accept verdict" "(i) ready"
has "ready:" "$WORK/out" || fail "(i) not ready"
! grep -l '^event: accepted' "$SUP"/* 2>/dev/null | xargs grep -l "run: $RUN_ID" >/dev/null 2>&1 || fail "(i) an accepted event without a brief"
[ ! -e "$RD/accepted.sent" ] || fail "(i) accepted.sent without an event"
echo "team-smoke-23: (i) accepted only after an accept verdict OK"

# ---- (j) decision close is not limited to the acceptance gate: it closes the run at the plan gate -
case_mark "(j) decision close is not limited to the"
setup_run alfa-20261115-140000; rm -f "$RD"/coder-* "$RD"/qa-* "$RD"/planner-1-1.json.accepted
session planner 1 "$BASE"; echo planner-1-1.json > "$TD/acked"
ldec open alfa --source planner-1-1.json --question "Close AB-1600 at the plan gate?"; expect 0 "[d-1]" "(j) open"
jq -cn --arg ts "$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ)" \
  '{type: "user", uuid: "u-op-j", timestamp: $ts, message: {role: "user", content: "d-1 close"}}' >> "$LTX"
ldec answer alfa d-1 --text "close" --outcome close; expect 0 "answered: d-1 (close)" "(j) answer"
V decision close --for planner-1-1.json --decision d-1 --message "Operator: close"; expect 0 "" "(j) decision close"
greset alfa-lead alfa-planner; run "$MAIN" $TR alfa; expect 8 "closed: abandon — clone free" "(j) the run closes at the plan gate"
jq -e '.reason == "abandon"' "$RD/closed.json" >/dev/null || fail "(j) closed.json"
echo "team-smoke-23: (j) close at the plan gate OK"

# ---- rework fixtures: a launched session stays alive until it is killed ------------------------------
case_mark "rework fixtures: a launched session stay"
cat > "$WORK/hs2.sh" <<'HS'
n=$(( $(cat "$WORK/hs.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/hs.n"
s="${3#=}"
. "$WORK/cancel-check.sh"
l="$(grep -E -- "new-session -d -s $s |kill-session -t =$s\$" "$STUB_LOG" | tail -n 1)"
case "$l" in *new-session*) exit 0 ;; *kill-session*) exit 1 ;; esac
grep -qx -- "${s#smk-}" "$WORK/alive" 2>/dev/null && exit 0
exit 1
HS
export STUB_ON_HAS_SESSION=". '$WORK/hs2.sh'"
rec2() {  # rec2 <role> <input> <output> <pr> [verdict] — the round-2 record 1-1
  mkdir -p "$RD/r2"
  jq -n --arg role "$1" --arg in "$2" --arg out "$3" --argjson pr "$4" --arg v "${5:-done}" \
    --arg run "$RUN_ID" --arg br "$BR" --arg ev ".agents/team/runs/$RUN_ID/r2/qa-report-1.md" \
    '{team: "alfa", ticket: "AB-1600", run: $run, round: 2, role: $role, attempt: 1, seq: 1, branch: $br,
      input_rev: $in, output_rev: $out, verdict: $v, pr_id: $pr, artifacts: [],
      evidence: (if $role == "qa" then [$ev] else [] end), notes: "", message: "fix",
      written_at: "2026-11-15T11:00:00Z"}' > "$RD/r2/$1-1-1.json"
}
report() {  # report <file> <output rev> — a ready qa report of attempt 1
  { echo "run: $RUN_ID"; echo "attempt: 1"; echo "output_rev: $2"; echo "Verdict: ready"
    echo "Gate code: passed"; echo "Gate design: skipped — backend change"; echo "Gate cross-model: warn"
    echo "Gate final-build: passed"; echo "Tests: passed=3 failed=0 skipped=0 baseline=0"
    echo "Warnings: none"; echo "Rethink signals: none"; } > "$1"
}
rework_ready() {  # rework_ready <run id> — round 1 at the acceptance gate, the qa revision $Q1
  setup_run "$1"; jq --arg q "$Q1" '.output_rev = $q' "$RD/qa-1-1.json" > "$WORK/r" && mv "$WORK/r" "$RD/qa-1-1.json"
  echo qa-1-1.json > "$TD/acked"; printf -- '- remove the CSV import (not ordered)\n' > "$RD/rework-2.md"
}
commit_file src/qa-fix.txt "qa fix"; Q1="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" push --quiet origin "$BR"; pr_set --arg s "$Q1" '.lastMergeSourceCommit.commitId = $s'

# ---- (k) rework → r2/, the coder relaunched on the round-1 qa revision with the order rendered -------
case_mark "(k) rework → r2/, the coder relaunched"
rework_ready alfa-20261115-150000
V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-3.md --message x
expect 4 "rework needs --ref runs/$RUN_ID/rework-2.md" "(k) wrong round in --ref"
V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-2.md --message "remove the CSV import"
expect 0 "teamlead-acceptance-1.json" "(k) rework"
jq -e --arg r ".agents/team/runs/$RUN_ID/rework-2.md" '.for == "qa-1-1.json" and .ref == $r' "$RD/teamlead-acceptance-1.json" >/dev/null || fail "(k) verdict for/ref"
greset alfa-lead alfa-qa; on_event "launched: coder attempt 1"
run "$MAIN" $TR alfa; expect 6 "round 2 started" "(k) runner"; cancelled_by_event "(k) runner"
has "kill-session -t =smk-alfa-qa" "$STUB_LOG" || fail "(k) the qa session was not ended"
has "launched: coder attempt 1" "$WORK/out" || fail "(k) the coder did not relaunch"
jq -e --arg r "$RUN_ID" '.run == $r and .round == 2 and .pr_published == true' "$TD/round" >/dev/null || fail "(k) round file"
[ ! -e "$TD/round-transition" ] && [ -d "$RD/r2" ] || fail "(k) transition left or no r2/"
jq -e --arg q "$Q1" '.round == 2 and .role == "coder" and .input_rev == $q' "$TD/session.json" >/dev/null \
  || fail "(k) session.json: $(cat "$TD/session.json")"
P2="$RD/r2/coder-1.prompt.md"
has ".agents/team/runs/$RUN_ID/rework-2.md" "$P2" && has "round \`2\`" "$P2" && has "updated PR 8371" "$P2" \
  && has ".agents/team/runs/$RUN_ID/r2/notes.md" "$P2" || fail "(k) round-2 prompt not rendered"
[ -s "$RD/r2/coder-1.session" ] && [ ! -e "$RD/coder-1.prompt.md" ] || fail "(k) round-2 prompt/session not under r2/"
grep -qsF "round 2 started" "$STUB_LOG" "$TD/send-lead.log" || fail "(k) the lead was not rung"
run "$MAIN" $TR alfa status; expect 0 "run: $RUN_ID round 2" "(k) status"
echo "team-smoke-23: (k) rework opens round 2 OK"

# ---- (l) the round-2 coder: same PR and a descendant of the qa revision, else rejected ---------------
case_mark "(l) the round-2 coder: same PR and a des"
rm -f "$TD/cancel"  # the last runner was stopped by the fixture; `check` honours the stop too
git -C "$CLONE" checkout --quiet -B "$BR" "$C1"; commit_file src/side.txt "not on the qa revision"
X="$(git -C "$CLONE" rev-parse HEAD)"; rec2 coder "$Q1" "$X" 8371
run "$MAIN" $TR alfa check "$RD/r2/coder-1-1.json"; expect 4 "does not descend from the previous qa revision" "(l) non-descendant rev"
git -C "$CLONE" checkout --quiet -B "$BR" "$Q1"; commit_file src/export.txt "export button without CSV import"
C2="$(git -C "$CLONE" rev-parse HEAD)"; git -C "$CLONE" push --quiet origin "$BR"
rec2 coder "$Q1" "$C2" 9999
run "$MAIN" $TR alfa check "$RD/r2/coder-1-1.json"; expect 4 "is not round 1's PR" "(l) another PR id"
rec2 coder "$Q1" "$C2" 8371; pr_set --arg s "$C2" '.lastMergeSourceCommit.commitId = $s | .isDraft = true'
run "$MAIN" $TR alfa check "$RD/r2/coder-1-1.json"; expect 4 "isDraft is not false" "(l) a published PR must stay published"
pr_set '.isDraft = false'
greset alfa-lead; run "$MAIN" $TR alfa; expect 6 "accepted: coder-1-1.json" "(l) round-2 coder accepted"
[ -e "$RD/r2/coder-1-1.json.accepted" ] || fail "(l) not accepted under r2/"
has "launched: qa attempt 1" "$WORK/out" || fail "(l) the round-2 qa did not launch"
jq -e --arg c "$C2" '.round == 2 and .role == "qa" and .input_rev == $c' "$TD/session.json" >/dev/null || fail "(l) qa session.json"
echo "team-smoke-23: (l) round-2 coder on the published PR OK"

# ---- (r) a complete round 2: report header run: <run>, acceptance on round-2 files, wrapup under r2/ --
case_mark "(r) a complete round 2: report header ru"
report "$RD/r2/qa-report-1.md" "$C2"; rec2 qa "$C2" "$C2" 8371
greset alfa-lead alfa-qa; run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: gate acceptance qa-1-1.json" "(r) round-2 qa at the gate"
[ "$(cat "$TD/acked")" = r2/qa-1-1.json ] || fail "(r) acked is not round 2's: $(cat "$TD/acked")"
echo "- export button" > "$RD/blind-check.md"; brief
V acceptance accept --for qa-1-1.json --message ok; expect 8 "runs/$RUN_ID/r2/blind-check.md missing" "(r) round 1's files do not count"
run "$CLONE" bash .claude/lib/team-lead.sh diff alfa; expect 0 "r2/acceptance-diff.patch" "(r) diff into r2/"
cp "$RD/blind-check.md" "$RD/r2/blind-check.md"; cp "$RD/acceptance-brief.md" "$RD/r2/acceptance-brief.md"
touch -r "$RD/r2/blind-check.md" "$RD/r2/acceptance-brief.md"   # equal mtimes: the brief is not older
V acceptance accept --for qa-1-1.json --message ok; expect 0 "teamlead-acceptance-2.json" "(r) round-2 accept"
jq -e '.for == "r2/qa-1-1.json"' "$RD/teamlead-acceptance-2.json" >/dev/null || fail "(r) verdict for"
greset alfa-lead alfa-qa; on_event "launched: wrapup attempt 1"
run "$MAIN" $TR alfa; expect 6 "launched: wrapup attempt 1" "(r) wrapup launched"; cancelled_by_event "(r) wrapup launched"
[ -e "$RD/r2/qa-1-1.json.accepted" ] || fail "(r) round-2 qa not accepted"
# The lead's notes are per run: the round-2 wrapup reads them at the run root.
has ".agents/team/runs/$RUN_ID/teamlead-notes.md" "$RD/r2/wrapup-1.prompt.md" \
  && ! has "runs/$RUN_ID/r2/teamlead-notes.md" "$RD/r2/wrapup-1.prompt.md" || fail "(r) wrapup reads the wrong notes path"
# With a lead the wrapup asks nothing: a proposals stop only when it has items, the tracker script,
# the file tools (#104).
for rule in "no memory hand-off → no proposals file and no stop" \
  "team-record.sh --verdict blocked --proposals .agents/team/runs/$RUN_ID/r2/wrapup_proposals-1_<k>.json" \
  'you ask nothing in this window (no `AskUserQuestion`)' 'never `gh` directly' \
  "Never run inline interpreter code" '`selected_by: "teamlead"`' "Never edit a proposals file after its stop" \
  '"handoff":' "No question — the groups only label the proposals items" \
  "With a per-run TeamLead ask no question"; do
  has "$rule" "$RD/r2/wrapup-1.prompt.md" || fail "(r) the lead-run wrapup prompt lacks: $rule"
done
# Every tracker's step 7 menu has the lead exception, and the lead has no wrapup menu to answer.
for t in github jira none; do
  has "With a per-run TeamLead ask no question" "$MAIN/.claude/team/tracker/$t-wrapup.md" \
    || fail "(r) $t-wrapup.md step 7 lacks the lead exception"
done
has "**Planner or wrapup menu:**" "$MAIN/.claude/team/prompts/teamlead.md" && fail "(r) the lead still answers a wrapup menu"
# A product-fit hit always reaches the Operator: the lead opens a decision, a drop or a non-goal
# change records `out of product scope`, never `too big for quick`.
has "product-fit hit" "$SRC/.claude/team/prompts/teamlead.md" || fail "(r) the lead prompt does not route a product-fit hit"
has "out of product scope" "$SRC/.claude/team/prompts/planner.md" || fail "(r) planner.md lacks the out-of-product-scope rule"
has "change the PRD's non-goals first" "$SRC/.claude/team/prompts/planner-quick.md" || fail "(r) planner-quick.md lacks the non-goal change"
grep -n 'too big for quick' "$SRC/.claude/commands/quick-change.md" | grep 'Product fit' | grep -qv 'out of product scope' \
  && fail "(r) quick-change.md routes a product-fit hit to too big for quick"
has "at least one trace id" "$SRC/.claude/commands/brainstorm.md" || fail "(r) brainstorm.md lacks the Traces predicate"
# Round 1 has no accepted qa: "wrapup not done" means merge-check read round 2's records.
mv "$TD/session.json" "$WORK/sj"
run "$MAIN" bash .claude/lib/team-merge-check.sh alfa; expect 3 "wrapup not done" "(r) merge-check reads round 2"
mv "$WORK/sj" "$TD/session.json"
. "$MAIN/.claude/lib/team-integrate-lib.sh"; D0="$(team_records_digest "$TD" "$RUN_ID")"
rec2 wrapup "$C2" "$C2" 8371; printf 'target_rev: %s\n\n## What matters for you\nPR 8371.\n' "$BASE" > "$RD/r2/wrapup-1.md"
[ "$(team_records_digest "$TD" "$RUN_ID")" != "$D0" ] || fail "(r) the digest ignores a round-2 record"
greset alfa-lead; run "$MAIN" $TR alfa; expect 0 "ready: bash .claude/lib/team-merge-check.sh alfa" "(r) ready after round 2"
grep -l '^event: accepted' "$SUP"/* | xargs grep -l "run: $RUN_ID" | xargs grep -q "^ref: runs/$RUN_ID/r2/acceptance-brief.md" \
  || fail "(r) accepted event does not name round 2's brief"
echo "team-smoke-23: (r) complete round 2 OK"

# ---- (m) budget: a third rework in brainstorm (budget 2) → 9; (n) an Operator continue adds one -----
case_mark "(m) budget: a third rework in brainstorm"
rework_ready alfa-20261115-160000
for i in 1 2; do
  V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-2.md --message "round $i"
  expect 0 "teamlead-acceptance-$i.json" "(m) rework $i"
done
V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-2.md --message x
expect 9 "rework budget 2 reached (teams.teamlead.rework_budget.brainstorm) — write abandon-recommended with --notify abandon_decision" "(m) third rework"
[ ! -e "$RD/teamlead-acceptance-3.json" ] || fail "(m) a refused rework wrote a verdict"
ldec open alfa --source qa-1-1.json --question "Budget spent — one more round?" --notify abandon_decision --recommend close
expect 0 "[d-1]" "(n) abandon decision"
V acceptance abandon-recommended --for qa-1-1.json --decision d-1 --message "budget spent"; expect 0 "teamlead-acceptance-3.json" "(n) abandon-recommended"
# The two rework rounds happened; the runner acts only on what comes after them.
printf 'teamlead-acceptance-1.json\nteamlead-acceptance-2.json\n' >> "$TD/verdict-acked"
# count kept: (n) expects no line — the abandon_decision event it reads afterwards needs the polls
greset alfa-lead alfa-qa; export CANCEL_AT=12; run "$MAIN" $TR alfa; expect 6 "" "(n) runner notifies"
[ "$(nab)" = 1 ] || fail "(n) not exactly one abandon_decision event"
jq -cn --arg ts "$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ)" \
  '{type: "user", uuid: "u-op-n", timestamp: $ts, message: {role: "user", content: "d-1 continue, one more"}}' >> "$LTX"
ldec answer alfa d-1 --text "continue, one more" --outcome continue; expect 0 "answered: d-1 (continue)" "(n) Operator continue"
V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-2.md --message x; expect 9 "rework budget" "(n) an answered, unspent grant adds nothing"
V decision continue --for qa-1-1.json --decision d-1 --message "Operator: one more"; expect 0 "teamlead-decision-" "(n) decision continue"
: > "$TD/send-lead.log"; greset alfa-lead alfa-qa; run "$MAIN" $TR alfa; expect 6 "" "(n) runner on continue"
grep -qsF "continue granted" "$STUB_LOG" "$TD/send-lead.log" || fail "(n) the lead was not told to order the round"
[ "$(nab)" = 1 ] || fail "(n) a second abandon event"
V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-2.md --message granted; expect 0 "teamlead-acceptance-4.json" "(n) the granted round"
V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-2.md --message x; expect 9 "rework budget" "(n) one grant = one round"
echo "team-smoke-23: (m) budget + (n) one grant OK"

# ---- (o) quick: the first rework states continue; budget 1 -------------------------------------------
case_mark "(o) quick: the first rework states conti"
rework_ready alfa-20261115-170000; jq '.mode = "quick"' "$TD/team.json" > "$WORK/tj" && mv "$WORK/tj" "$TD/team.json"
V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-2.md --message x
expect 4 "quick: --quick-call continue, or abandon-recommended to stop" "(o) quick without continue"
V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-2.md --quick-call later --message x
expect 4 "quick: --quick-call continue" "(o) quick, another value"
V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-2.md --quick-call continue --message x
expect 0 "teamlead-acceptance-1.json" "(o) quick continue"
V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-2.md --quick-call continue --message x
expect 9 "rework budget 1 reached (teams.teamlead.rework_budget.quick)" "(o) second quick rework"
jq '.mode = "brainstorm"' "$TD/team.json" > "$WORK/tj" && mv "$WORK/tj" "$TD/team.json"
echo "team-smoke-23: (o) quick OK"

# ---- (s) a runner killed after the intent (3), the mkdir (4) or the round file (4a) resumes into the
case_mark "(s) a runner killed after the intent (3)"
#      round-2 coder; (p) killed after the round, before the launch, too ------------------------------
for p in 3:180003 4:180004 4a:180005; do
  at="${p%%:*}"; rework_ready "alfa-20261115-${p#*:}"
  V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-2.md --message x; expect 0 "" "(s) rework $at"
  greset alfa-lead alfa-qa; export CANCEL_AT=40
  TEAM_ROUND_CRASH="$at" run "$MAIN" $TR alfa
  [ "$RC" = 137 ] || fail "(s) crash at $at: exit $RC"
  ! has "launched: coder" "$WORK/out" || fail "(s) crash at $at launched the coder"
  # A crash at 3 left the qa session alive (the resume ends it); at 4/4a it was already ended.
  if [ "$at" = 3 ]; then greset alfa-lead alfa-qa; else greset alfa-lead; fi; on_event "launched: coder attempt 1"
  run "$MAIN" $TR alfa; expect 6 "launched: coder attempt 1" "(s) resume after a crash at $at"
  cancelled_by_event "(s) resume after a crash at $at"
  [ ! -e "$TD/round-transition" ] && jq -e '.round == 2' "$TD/round" >/dev/null && [ -s "$RD/r2/coder-1.session" ] \
    || fail "(s) crash at $at not completed"
  jq -e '.round == 2 and .role == "coder"' "$TD/session.json" >/dev/null || fail "(s) crash at $at: session.json"
done
rework_ready alfa-20261115-190000
V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-2.md --message x; expect 0 "" "(p) rework"
# The runner dies at its first look at the coder session after round 2 is durable.
printf '%s\n' "if [ \"\$3\" = =smk-alfa-coder ] && jq -e '.run == \"$RUN_ID\" and .round == 2' \"$TD/round\" >/dev/null 2>&1; then kill -9 \$PPID; fi" \
  ". '$WORK/hs2.sh'" > "$WORK/hs3.sh"
greset alfa-lead alfa-qa; export CANCEL_AT=40
STUB_ON_HAS_SESSION=". '$WORK/hs3.sh'" run "$MAIN" $TR alfa
[ "$RC" = 137 ] && ! has "launched: coder" "$WORK/out" || fail "(p) not killed before the launch (exit $RC)"
greset alfa-lead; on_event "launched: coder attempt 1"
run "$MAIN" $TR alfa; expect 6 "launched: coder attempt 1" "(p) resume into the round-2 coder"
cancelled_by_event "(p) resume into the round-2 coder"
jq -e '.round == 2 and .role == "coder"' "$TD/session.json" >/dev/null || fail "(p) session.json"
echo "team-smoke-23: (s) crash at 3/4/4a + (p) killed before the launch OK"

# ---- (q) qa blocked before publishing → rework → the round-2 coder on the still-draft PR → qa publishes
case_mark "(q) qa blocked before publishing → rew"
rework_ready alfa-20261115-200000; rm -f "$TD/acked"
jq '.verdict = "blocked" | .message = "the CSV import breaks the order"' "$RD/qa-1-1.json" > "$WORK/r" && mv "$WORK/r" "$RD/qa-1-1.json"
pr_set --arg s "$Q1" '.isDraft = true | .lastMergeSourceCommit.commitId = $s'
greset alfa-lead alfa-qa; on_event "waiting for TeamLead: qa-1-1.json"
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: qa-1-1.json" "(q) qa blocked → the lead"
cancelled_by_event "(q) qa blocked → the lead"
V acceptance accept --for qa-1-1.json --message x; expect 4 "is blocked, the acceptance gate needs done" "(q) accept on a blocked record"
V acceptance rework --for qa-1-1.json --ref .agents/team/runs/$RUN_ID/rework-2.md --message "fix the blocker"; expect 0 "" "(q) rework on blocked"
greset alfa-lead alfa-qa; on_event "launched: coder attempt 1"
run "$MAIN" $TR alfa; expect 6 "launched: coder attempt 1" "(q) round 2"; cancelled_by_event "(q) round 2"
jq -e '.pr_published == false' "$TD/round" >/dev/null || fail "(q) draft not carried: $(cat "$TD/round")"
commit_file src/export.txt "export button, blocker fixed"
C3="$(git -C "$CLONE" rev-parse HEAD)"; git -C "$CLONE" push --quiet origin "$BR"
pr_set --arg s "$C3" '.lastMergeSourceCommit.commitId = $s'; rec2 coder "$Q1" "$C3" 8371
snap "(q) the snapshot sees round 2" 'coder.record.message == "fix"'
greset alfa-lead; run "$MAIN" $TR alfa; expect 6 "accepted: coder-1-1.json" "(q) round-2 coder on the draft PR"
report "$RD/r2/qa-report-1.md" "$C3"; rec2 qa "$C3" "$C3" 8371; rm -f "$TD/cancel"
run "$MAIN" $TR alfa check "$RD/r2/qa-1-1.json"; expect 4 "isDraft is not false" "(q) an unpublished round-2 qa is rejected"
pr_set '.isDraft = false'
greset alfa-lead alfa-qa; run "$MAIN" $TR alfa; expect 6 "gate acceptance qa-1-1.json" "(q) round-2 qa published"
echo "team-smoke-23: (q) blocked → draft rework → publish OK"
unset STUB_ON_HAS_SESSION CANCEL_AT

# ---- (u) a launched lead gets its notes file with the six headings ----------------------------------
case_mark "(u) a launched lead gets its notes file"
export STUB_ON_HAS_SESSION=". '$WORK/hs2.sh'"
setup_run alfa-20261115-210000; echo qa-1-1.json > "$TD/acked"
greset alfa-qa; on_event "launched: TeamLead"
run "$MAIN" $TR alfa; expect 6 "launched: TeamLead" "(u) lead launched"; cancelled_by_event "(u) lead launched"
NOTES="$RD/teamlead-notes.md"
[ "$(grep -c '^## ' "$NOTES" 2>/dev/null)" = 6 ] || fail "(u) notes: $(cat "$NOTES" 2>/dev/null)"
for h in "## Order ambiguities" "## No-rule questions" "## Gate misses" "## Operator cases" "## Wrapup decisions" "## Late answers"; do
  grep -qxF "$h" "$NOTES" || fail "(u) notes lack $h"
done
echo "team-smoke-23: (u) notes created at launch OK"

# ---- (v) every Operator case is in the notes with the tuning question; a late answer too -----------
case_mark "(v) every Operator case is in the notes"
setup_run alfa-20261115-220000; NOTES="$RD/teamlead-notes.md"; echo qa-1-1.json > "$TD/acked"
said() { jq -cn --arg t "$1" --arg u "$2" --arg ts "$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ)" \
  '{type: "user", uuid: $u, timestamp: $ts, message: {role: "user", content: $t}}' >> "$LTX"; }
section() { awk -v h="$1" '$0 == h { f = 1; next } /^## / { f = 0 } f' "$NOTES"; }
ldec open alfa --source qa-1-1.json --question "Ship without the CSV import?"; expect 0 "[d-1]" "(v) open"
section "## Operator cases" | grep -qxF -- "- d-1 Ship without the CSV import? — tuning: pending" || fail "(v) no Operator case line: $(cat "$NOTES")"
said "d-1 yes ship it" u-op-v1
run "$CLONE" env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-lead.sh decision answer alfa d-1 --text "yes ship it"
expect 2 "--tuning rule|TeamLead|none" "(v) the lead answers the tuning question"
run "$CLONE" env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-lead.sh decision answer alfa d-1 --text "yes ship it" \
  --tuning rule --why "the order's Not ordered list already says it"
expect 0 "answered: d-1" "(v) answer with the tuning"
section "## Operator cases" | grep -qxF -- "- d-1 Ship without the CSV import? — tuning: rule — the order's Not ordered list already says it" \
  || fail "(v) tuning not completed: $(cat "$NOTES")"
ldec open alfa --source qa-1-1.json --question "Rename the button?"; expect 0 "[d-2]" "(v) open d-2"
ldec withdraw alfa d-2 --why "the qa settled it"; expect 0 "withdrawn: d-2" "(v) withdraw"
said "d-2 no keep it" u-op-v2
ldec answer alfa d-2 --text "no keep it"; expect 4 "d-2 is withdrawn, not pending" "(v) late answer refused"
section "## Late answers" | grep -q -- "^- d-2 (withdrawn .*): no keep it$" || fail "(v) no late answer line: $(cat "$NOTES")"
echo "team-smoke-23: (v) Operator cases + tuning + late answer OK"

# ---- (w) close_run appends the notes once; a resume of the closed run appends nothing ---------------
case_mark "(w) close_run appends the notes once; a"
LOG="$MAIN/.agents/team/teamlead-log.md"
blocks() { grep -c "^### .* alfa AB-1600 $1 — " "$LOG" 2>/dev/null || true; }
ldec open alfa --source qa-1-1.json --question "Close it?"; expect 0 "[d-3]" "(w) open"
said "d-3 close" u-op-w; ldec answer alfa d-3 --text "close" --outcome close; expect 0 "" "(w) answer"
V decision close --for qa-1-1.json --decision d-3 --message "Operator: close"; expect 0 "" "(w) decision close"
greset alfa-lead alfa-qa; run "$MAIN" $TR alfa; expect 8 "closed: abandon" "(w) closed"
[ "$(blocks "$RUN_ID")" = 1 ] && grep -q "^### .* alfa AB-1600 $RUN_ID — closed$" "$LOG" \
  && grep -qF -- "- d-1 Ship without the CSV import? — tuning: rule" "$LOG" && [ -s "$RD/log-appended" ] \
  || fail "(w) log block: $(cat "$LOG" 2>/dev/null)"
greset alfa-lead; run "$MAIN" $TR alfa; expect 1 "run closed" "(w) resume refused"
run "$MAIN" bash .claude/lib/team-lead.sh log-append alfa closed; expect 0 "already appended" "(w) a second append"
[ "$(blocks "$RUN_ID")" = 1 ] || fail "(w) appended twice"
echo "team-smoke-23: (w) close appends once OK"

# ---- (x) the log lock: a held lock times out without appending; two clones at once both land ---------
case_mark "(x) the log lock: a held lock times out"
setup_run alfa-20261115-230000; echo "- alfa-marker" >> "$RD/teamlead-notes.md"
mkdir "$MAIN/.agents/team/teamlead-log.lock"
TEAM_LOG_LOCK_SECS=1 run "$MAIN" bash .claude/lib/team-lead.sh log-append alfa merged; expect 1 "held for 1s" "(x) lock timeout"
[ ! -e "$RD/log-appended" ] && [ "$(blocks "$RUN_ID")" = 0 ] || fail "(x) appended under a held lock"
BTD="$WORK/main-beta/.agents/team"; rm -rf "$WORK/main-beta"; cp -R "$CLONE" "$WORK/main-beta"
jq '.team = "beta"' "$BTD/team.json" > "$WORK/tj" && mv "$WORK/tj" "$BTD/team.json"
echo beta-20261115-230000 > "$BTD/run"; mkdir -p "$BTD/runs/beta-20261115-230000"
jq '.team = "beta" | .run = "beta-20261115-230000"' "$BTD/teamlead.json" > "$WORK/tj" && mv "$WORK/tj" "$BTD/teamlead.json"
printf '## Gate misses\n- beta-marker\n' > "$BTD/runs/beta-20261115-230000/teamlead-notes.md"
# A mkdir spy proves both writers tried the held lock before it is released (no fixed sleep): a
# failed mkdir of the lock logs its caller, the writer's team-lead.sh shell.
mkdir_spy '*teamlead-log.lock'
( cd "$MAIN" && PATH="$WORK/spy:$PATH" bash .claude/lib/team-lead.sh log-append alfa merged > "$WORK/la1" 2>&1 ) &
( cd "$MAIN" && PATH="$WORK/spy:$PATH" bash .claude/lib/team-lead.sh log-append beta merged > "$WORK/la2" 2>&1 ) &
for _ in $(seq 1 100); do [ "$(cut -d' ' -f1 "$WORK/spy.log" | sort -u | wc -l)" -ge 2 ] && break; sleep 0.1; done
[ "$(cut -d' ' -f1 "$WORK/spy.log" | sort -u | wc -l)" -ge 2 ] || { rmdir "$MAIN/.agents/team/teamlead-log.lock"; wait; fail "(x) writers never contended"; }
rmdir "$MAIN/.agents/team/teamlead-log.lock"; wait
grep -q "appended" "$WORK/la1" && grep -q "appended" "$WORK/la2" || fail "(x) $(cat "$WORK/la1" "$WORK/la2")"
[ "$(blocks "$RUN_ID")" = 1 ] && [ "$(grep -c '^### .* beta .* beta-20261115-230000 — merged$' "$LOG")" = 1 ] || fail "(x) not both blocks"
awk -v a="alfa AB-1600 $RUN_ID" '/^### / { cur = index($0, a) ? "alfa" : (index($0, "beta-20261115-230000") ? "beta" : "") }
  /alfa-marker/ && cur != "alfa" { bad = 1 } /beta-marker/ && cur != "beta" { bad = 1 } END { exit bad }' "$LOG" \
  || fail "(x) interleaved blocks"
rm -rf "$WORK/main-beta"
echo "team-smoke-23: (x) log lock OK"

# ---- (y) owns: the global TeamLead's policy log skips runs with their own lead ----------------------
case_mark "(y) owns: the global TeamLead's policy l"
run "$MAIN" bash .claude/lib/team-lead.sh owns alfa; expect 0 "" "(y) a run with its own lead"
jq '.run = "alfa-older"' "$TD/teamlead.json" > "$WORK/tj" && mv "$WORK/tj" "$TD/teamlead.json"
run "$MAIN" bash .claude/lib/team-lead.sh owns alfa; expect 1 "" "(y) a run without one"
run "$MAIN" bash .claude/lib/team-lead.sh log-append alfa merged; expect 0 "no TeamLead in run" "(y) no lead, no block"
echo "team-smoke-23: (y) owns OK"

# ---- (z) the lead writes its notes, never memory --------------------------------------------------
case_mark "(z) the lead writes its notes, never mem"
setup_run alfa-20261115-235900; HOOK="$CLONE/.claude/hooks/guard-teamlead-write.sh"
gp() { jq -cn --arg f "$1" '{session_id: "sid-lead", tool_name: "Write", tool_input: {file_path: $f}}'; }
TEAM_SESSION_ROLE=TeamLead hook "$CLONE" "$(gp "$CLONE/.agents/memory/decisions.md")"; expect 2 "" "(z) memory write refused"
TEAM_SESSION_ROLE=TeamLead hook "$CLONE" "$(gp "$RD/teamlead-notes.md")"; expect 0 "" "(z) notes write allowed"
echo "team-smoke-23: (z) notes yes, memory no OK"
unset STUB_ON_HAS_SESSION CANCEL_AT

echo "team-smoke-23: OK"
