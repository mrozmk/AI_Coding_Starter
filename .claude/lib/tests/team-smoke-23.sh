#!/usr/bin/env bash
# Acceptance against the order: the qa done waits for the lead's acceptance gate; accept needs the
# blind check and a complete brief (one decision per QA warning); ready and one `accepted` event
# only after accept and a done wrapup; abandon goes through an abandon_decision; the acceptance
# patch carries no spec or plan line. Step 8 adds its rework cases here.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

smoke_team AB-1600 feature/AB-1600-x
BR=feature/AB-1600-x; SUP="$MAIN/.agents/team/inbox/Supervisor/new"
export WORK TD
prof() { jq "$1" "$MAIN/.claude/project-profile.json" > "$WORK/p" && mv "$WORK/p" "$MAIN/.claude/project-profile.json"; }
mkdir -p "$MAIN/.claude/team/sessions" "$CLONE/.claude/hooks"
cp "$SRC/.claude/team/sessions/TeamLead-run.settings.json" "$MAIN/.claude/team/sessions/"
cp "$SRC/.claude/hooks/guard-teamlead-write.sh" "$CLONE/.claude/hooks/"
cp "$SRC/.claude/lib/team-watch-send.py" "$MAIN/.claude/lib/"
git -C "$CLONE" add .claude/hooks && git -C "$CLONE" commit --quiet -m "fixture guard"
mkdir -p "$MAIN/.claude/team/sessions/operator-kit"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/notify.log"\n' "$WORK" > "$MAIN/.claude/team/sessions/operator-kit/notify.sh"
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

cat > "$WORK/hs.sh" <<'HS'
n=$(( $(cat "$WORK/hs.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/hs.n"
s="${3#=}"
[ -z "${CANCEL_AT:-}" ] || [ "$n" -lt "$CANCEL_AT" ] || touch "$TD/cancel"
! grep -q -- "kill-session -t =$s\$" "$STUB_LOG" || exit 1
grep -qx -- "$s" "$WORK/alive" 2>/dev/null && exit 0
exit 1
HS
export STUB_ON_HAS_SESSION=". '$WORK/hs.sh'" STUB_PANE="$FIX/idle.txt"
greset() {  # greset <alive sessions...> — a runner start: lock, cancel, logs cleared
  rm -rf "$TD/lock" "$TD/cancel" "$WORK/hs.n"; : > "$STUB_LOG"; printf '%s\n' "$@" > "$WORK/alive"
  export CANCEL_AT=12
}
TR="bash .claude/lib/team-run.sh"
V() { run "$CLONE" env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-verdict.sh "$@"; }
ldec() { run "$CLONE" env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-lead.sh decision "$@"; }
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
prof '.teams.teamlead.enabled = true'
setup_run alfa-20261115-100000

# ---- (a) qa done with the lead on: validated, the acceptance gate rung, no wrapup yet -------------
greset alfa-lead alfa-qa
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: gate acceptance qa-1-1.json" "(a) runner"
! has "-s alfa-wrapup" "$STUB_LOG" || fail "(a) the wrapup launched before a verdict"
grep -qsF "gate acceptance: .agents/team/runs/$RUN_ID/qa-1-1.json" "$STUB_LOG" "$TD/send-lead.log" \
  || fail "(a) the lead was not rung for the acceptance gate"
[ "$(cat "$TD/acked")" = qa-1-1.json ] || fail "(a) qa record not acked"
echo "team-smoke-23: (a) acceptance gate OK"

# ---- (b) accept needs the blind check first, then a complete brief -------------------------------
V acceptance accept --for qa-1-1.json --message ok; expect 8 "blind-check.md missing" "(b) no blind check"
brief; sleep 1; echo "- export button → src/export.txt" > "$RD/blind-check.md"
V acceptance accept --for qa-1-1.json --message ok; expect 8 "older than blind-check.md" "(b) brief before the blind check"
brief; sed -i.bak '/^## Fit risks$/d' "$RD/acceptance-brief.md"
V acceptance accept --for qa-1-1.json --message ok; expect 8 "lacks the heading '## Fit risks'" "(b) missing heading"
V acceptance accept --for qa-1-1.json --message ok; [ ! -e "$RD/teamlead-acceptance-1.json" ] || fail "(b) a refused accept wrote a verdict"
V acceptance remode --for qa-1-1.json --message x; expect 4 "not allowed at the acceptance gate" "(b) bad verdict"
echo "team-smoke-23: (b) blind check + brief OK"

# ---- (c) ready-with-warnings: one decision line per warning ---------------------------------------
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
greset alfa-lead alfa-qa; export CANCEL_AT=40
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
greset alfa-lead
run "$MAIN" $TR alfa; expect 0 "ready:" "(e) resume after ready"
[ "$(grep -l '^event: accepted' "$SUP"/* | wc -l | tr -d ' ')" = 1 ] || fail "(e) a second accepted event"
echo "team-smoke-23: (e) single accepted OK"

# ---- (f) abandon-recommended goes through an abandon_decision; decision close closes the run -------
setup_run alfa-20261115-110000; rm -f "$WORK/notify.log"
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
[ "$(grep -c 'abandon_decision' "$WORK/notify.log")" = 1 ] || { cp "$WORK/notify.log" "$WORK/out"; fail "(f) not exactly one abandon_decision notification"; }
LTX="$(transcript sid-lead)"; mkdir -p "$(dirname "$LTX")"
jq -cn --arg ts "$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ)" \
  '{type: "user", uuid: "u-op", timestamp: $ts, message: {role: "user", content: "d-1 close it"}}' >> "$LTX"
ldec answer alfa d-1 --text "close it" --outcome close; expect 0 "answered: d-1 (close)" "(f) Operator answer"
V decision close --for qa-1-1.json --decision d-1 --message "Operator: close it"; expect 0 "" "(f) decision close"
greset alfa-lead alfa-qa; run "$MAIN" $TR alfa; expect 8 "closed: abandon — PR 8371 to abandon before team-next" "(f) the run closes"
jq -e '.reason == "abandon"' "$RD/closed.json" >/dev/null || fail "(f) closed.json"
grep -l '^event: closed' "$SUP"/* | xargs grep -l "run: $RUN_ID" >/dev/null || fail "(f) no closed event"
[ "$(grep -c 'abandon_decision' "$WORK/notify.log")" = 1 ] || fail "(f) a second abandon notification"
echo "team-smoke-23: (f) abandon through a decision OK"

# ---- (g) the switch off: ready as today, no inbox file ---------------------------------------------
prof '.teams.teamlead.enabled = false'
setup_run alfa-20261115-120000; touch "$RD/qa-1-1.json.accepted"
rec_json wrapup "$C1" "$C1" 8371 '[]'; touch "$RD/wrapup-1-1.json.accepted"; rm -f "$TD/session.json"
N0="$(ls "$SUP" | wc -l | tr -d ' ')"
greset; run "$MAIN" $TR alfa; expect 0 "ready:" "(g) ready without a lead"
[ "$(ls "$SUP" | wc -l | tr -d ' ')" = "$N0" ] && [ ! -e "$RD/accepted.sent" ] || fail "(g) an inbox file without a lead"
echo "team-smoke-23: (g) switch off OK"

# ---- (h) the acceptance patch holds no line of this run's spec or plan -----------------------------
run "$CLONE" bash .claude/lib/team-lead.sh diff alfa; expect 0 "acceptance-diff.patch" "(h) diff"
has "src/export.txt" "$RD/acceptance-diff.patch" || fail "(h) the delivery is not in the patch"
! grep -q 'Speculative\|Add the export button' "$RD/acceptance-diff.patch" || fail "(h) spec or plan lines in the patch"
! grep -q '\.agents/specs/\|\.agents/plans/' "$RD/acceptance-diff.stat" || fail "(h) spec or plan in the stat"
echo "team-smoke-23: (h) blind patch OK"

echo "team-smoke-23: OK"
