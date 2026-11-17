#!/usr/bin/env bash
# Tracker comments at the per-run TeamLead's gates (team-tracker-gate.sh; tracker-comments.md §5–§6,
# team-lead.md §11), opt-in workflow.tracker_comments. Plan approve: no ledger, a snapshot
# of another ticket, no fresh read, a stale fresh read, a changed ticket (compare 3) and an uncertain
# read (compare 4) are refused with exit 10; a current read passes and its line lands in the
# verdict; the switch off or tracker none checks nothing. Acceptance accept: a change named under
# `## Ordered vs delivered` passes, an unnamed one and an uncertain read are refused, and a comment
# the lead already answered (answers.md `<id>@<sha>`) counts as reconciled.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

smoke_team AB-2600 feature/AB-2600-x
RUN_ID=alfa-20261116-120000; RD="$TD/runs/$RUN_ID"; SPEC=.agents/specs/s.md; PLAN=.agents/plans/active/p.md
export WORK TD
prof() { jq "$1" "$MAIN/.claude/project-profile.json" > "$WORK/p" && mv "$WORK/p" "$MAIN/.claude/project-profile.json"; }
prof '.teams.teamlead.enabled = true'
mkdir -p "$MAIN/.claude/team/sessions"
cp "$SRC/.claude/team/sessions/TeamLead-run.settings.json" "$MAIN/.claude/team/sessions/"
cp "$SRC/.claude/lib/tracker-snapshot.mjs" "$CLONE/.claude/lib/"
git -C "$CLONE" add -A && git -C "$CLONE" commit --quiet -m "fixture snapshot tool"
echo "$RUN_ID" > "$TD/run"; mkdir -p "$RD"
jq -n --arg r "$RUN_ID" --arg m "$MAIN" '{team: "alfa", run: $r, session_id: "sid-lead", main_root: $m}' \
  > "$TD/teamlead.json"
printf 'scope: src/\nmade_at: 2026-11-16T12:00:00Z\n\n- none\n' > "$RD/digest.md"
V() { run "$CLONE" env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-verdict.sh "$@"; }
prec() { run "$CLONE" bash .claude/lib/team-record.sh "$@"; }
SNAP="node $CLONE/.claude/lib/tracker-snapshot.mjs"

# show <file> <description> <comment id:body>... — a github `team-tracker.sh show` result
show() {
  local f="$1" d="$2" c a=() ; shift 2
  for c in "$@"; do a+=("$(jq -cn --arg i "${c%%:*}" --arg b "${c#*:}" \
    '{id: $i, author: "dev", created: "2026-11-16T09:00:00Z", updated: "2026-11-16T09:00:00Z", body: $b}')"); done
  printf '%s\n' ${a[@]+"${a[@]}"} | jq -s --arg d "$d" \
    '{key: "AB-2600", updated: "2026-11-16T09:00:00Z", body: $d, comments: .}' > "$f"
}
# fresh <dir> <gate> <n> <show args...> — the lead's fresh read for a gate, written now
fresh() { local d="$1" g="$2" n="$3"; shift 3; show "$WORK/fresh.json" "$@"
  $SNAP snapshot --github "$WORK/fresh.json" --out "$d/tracker-$g-$n.json" >/dev/null; }
# artifact <path> <title> <with ledger: yes|no> [snapshot path] — commit it with its ledger
artifact() {
  mkdir -p "$CLONE/$(dirname "$1")"
  { printf '# %s\n\n**Status:** Draft\n\nExport button.\n' "$2"
    if [ "$3" = yes ]; then printf '\n## From tracker comments\nRead: AB-2600 · github · 2026-11-16T09:00:00Z · fetched 1 · complete · snapshot %s\nDescription: sha x — reconciled\n- 2026-11-16T09:00:00Z · 1001 · sha y · dev · requirement · CSV header row\n' "$4"; fi
  } > "$CLONE/$1"
  git -C "$CLONE" add -A && git -C "$CLONE" commit --quiet -m "$2"
}
entry_snap() {  # entry_snap <path> <show args...> — the planner's snapshot, committed next to the artifact
  local p="$1"; shift; show "$WORK/entry.json" "$@"; mkdir -p "$CLONE/$(dirname "$p")"
  $SNAP snapshot --github "$WORK/entry.json" --out "$CLONE/$p" >/dev/null
  git -C "$CLONE" add -A && git -C "$CLONE" commit --quiet -m "snapshot $p"
}
D0="Export button."

# ---- (a) switch off: no check, no tracker field ---------------------------------------------------
session planner 1 "$BASE"
artifact "$SPEC" Spec no
artifact "$PLAN" Plan no
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-1.json" "(a) done"
V plan approve --for planner-1-1.json --message ok; expect 0 "teamlead-plan-1.json" "(a) switch off: approve"
jq -e 'has("tracker") | not' "$RD/teamlead-plan-1.json" >/dev/null || fail "(a) a tracker line with the switch off"
echo "team-smoke-26: (a) switch off OK"

prof '.workflow.tracker_comments = true'
# ---- (b) tracker none: the contract is a no-op ----------------------------------------------------
jq '.tracker = "none"' "$TD/team.json" > "$WORK/tj" && mv "$WORK/tj" "$TD/team.json"
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-2.json" "(b) done"
V plan approve --for planner-1-2.json --message ok; expect 0 "teamlead-plan-2.json" "(b) tracker none: approve"
jq '.tracker = "github"' "$TD/team.json" > "$WORK/tj" && mv "$WORK/tj" "$TD/team.json"
echo "team-smoke-26: (b) tracker none OK"

# ---- (c) plan gate: no ledger → 10 ----------------------------------------------------------------
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-3.json" "(c) done"
fresh "$RD" plan 1 "$D0" "1001:CSV header row"
V plan approve --for planner-1-3.json --message ok
expect 10 "has no '## From tracker comments' ledger" "(c) no ledger"
[ ! -e "$RD/teamlead-plan-3.json" ] || fail "(c) a refused approve wrote a verdict"
# A ledger whose snapshot is not committed → 10.
artifact "$SPEC" Spec yes .agents/specs/s.ticket.json
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-4.json" "(c) done"
V plan approve --for planner-1-4.json --message ok; expect 10 "is not committed" "(c) snapshot not committed"
# A snapshot of another ticket → 10.
entry_snap .agents/specs/s.ticket.json "$D0" "1001:CSV header row"
jq '.key = "AB-1"' "$CLONE/.agents/specs/s.ticket.json" > "$WORK/k" && cat "$WORK/k" > "$CLONE/.agents/specs/s.ticket.json"
git -C "$CLONE" commit --quiet -am "wrong key"
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-5.json" "(c) done"
V plan approve --for planner-1-5.json --message ok; expect 10 "is for 'AB-1', the run's ticket is AB-2600" "(c) other ticket"
echo "team-smoke-26: (c) ledger + snapshot required OK"

# ---- (d) fresh read: none, stale, another ticket → 10 ---------------------------------------------
entry_snap .agents/specs/s.ticket.json "$D0" "1001:CSV header row"
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-6.json" "(d) done"
rm -f "$RD"/tracker-plan-*.json
V plan approve --for planner-1-6.json --message ok; expect 10 "no fresh read: snapshot the ticket into runs/$RUN_ID/tracker-plan-<n>.json" "(d) no fresh read"
fresh "$RD" plan 1 "$D0" "1001:CSV header row"
jq '.read_at = "2026-01-01T00:00:00.000Z"' "$RD/tracker-plan-1.json" > "$WORK/s" && cat "$WORK/s" > "$RD/tracker-plan-1.json"
V plan approve --for planner-1-6.json --message ok; expect 10 "before planner-1-6.json was written" "(d) stale fresh read"
fresh "$RD" plan 2 "$D0" "1001:CSV header row"
jq '.key = "AB-9"' "$RD/tracker-plan-2.json" > "$WORK/s" && cat "$WORK/s" > "$RD/tracker-plan-2.json"
V plan approve --for planner-1-6.json --message ok; expect 10 "tracker-plan-2.json is for 'AB-9'" "(d) fresh read of another ticket"
echo "team-smoke-26: (d) fresh read OK"

# ---- (e) compare 3 → revise, compare 4 → escalate (both exit 10) ----------------------------------
fresh "$RD" plan 3 "$D0" "1001:CSV header row" "1002:also a PDF export"
V plan approve --for planner-1-6.json --message ok
expect 10 "Tracker comments: new 1002 — revise with the list as findings" "(e) a new comment"
fresh "$RD" plan 4 "Export button and a print view." "1001:CSV header row"
V plan approve --for planner-1-6.json --message ok; expect 10 "description changed — revise" "(e) description changed"
fresh "$RD" plan 5 "$D0" "1001:CSV header row"
jq '.status = "possibly-truncated"' "$RD/tracker-plan-5.json" > "$WORK/s" && cat "$WORK/s" > "$RD/tracker-plan-5.json"
V plan approve --for planner-1-6.json --message ok; expect 10 "uncertain — possibly-truncated, 1 read — escalate with a decision" "(e) uncertain read"
# revise and escalate are never checked: they are the reactions.
V plan revise --for planner-1-6.json --ref "$RD/gate-plan-1.md" --message "new tracker input: 1002"
expect 0 "teamlead-plan-3.json" "(e) revise passes"
echo "team-smoke-26: (e) changed → revise, uncertain → escalate OK"

# ---- (f) current → approve, the line stored ------------------------------------------------------
fresh "$RD" plan 6 "$D0" "1001:CSV header row"
V plan approve --for planner-1-6.json --message ok; expect 0 "teamlead-plan-4.json" "(f) current read"
jq -e '.tracker | startswith("Tracker comments: none new") and contains("baseline .agents/specs/s.md@")' \
  "$RD/teamlead-plan-4.json" >/dev/null || fail "(f) tracker line not in the verdict"
echo "team-smoke-26: (f) current → approve OK"

# ---- (g) the source spec's snapshot is the baseline until the plan has its own -------------------
sed -i.bak 's/^\*\*Status:\*\* Draft/**Status:** Approved (auto — team mode)/' "$CLONE/$SPEC"; rm -f "$CLONE/$SPEC.bak"
git -C "$CLONE" commit --quiet -am "approved"
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-7.json" "(g) done"
fresh "$RD" plan 7 "$D0" "1001:CSV header row" "1003:after the spec"
V plan approve --for planner-1-7.json --message ok; expect 10 "new 1003 — revise" "(g) new after the spec"
# The planner reconciles 1003 into its plan: its own ledger and snapshot are now the baseline.
entry_snap .agents/plans/active/p.ticket.json "$D0" "1001:CSV header row" "1003:after the spec"
artifact "$PLAN" Plan yes .agents/plans/active/p.ticket.json
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-8.json" "(g) done again"
fresh "$RD" plan 8 "$D0" "1001:CSV header row" "1003:after the spec"
V plan approve --for planner-1-8.json --message ok; expect 0 "teamlead-plan-5.json" "(g) plan's own baseline"
jq -e '.tracker | contains("baseline .agents/plans/active/p.md@")' "$RD/teamlead-plan-5.json" >/dev/null \
  || fail "(g) the plan's own snapshot was not the baseline"
echo "team-smoke-26: (g) plan gate OK"

# ---- (h) acceptance: named → accept, unnamed → 10, uncertain → 10, answered → reconciled ----------
touch "$RD/planner-1-8.json.accepted"
mkdir -p "$CLONE/.agents/plans/done"; git -C "$CLONE" mv "$PLAN" .agents/plans/done/p.md
commit_file src/export.txt "export button"; C1="$(git -C "$CLONE" rev-parse HEAD)"
jq -n --arg r "$RUN_ID" --arg c "$C1" '{team: "alfa", ticket: "AB-2600", run: $r, role: "qa", attempt: 1,
  seq: 1, input_rev: $c, output_rev: $c, verdict: "done", pr_id: 8371, artifacts: [], evidence: [],
  notes: "", message: "", written_at: $w}' --arg w "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RD/qa-1-1.json"
session qa 1 "$C1"
{ echo "run: $RUN_ID"; echo "attempt: 1"; echo "output_rev: $C1"; echo "Verdict: ready"; echo "Warnings: none"; } > "$RD/qa-report-1.md"
echo "- export button → src/export.txt" > "$RD/blind-check.md"
abrief() {  # abrief <ordered-vs-delivered line> — the brief, written after the blind check
  { echo "## Ordered vs delivered"; echo "- export button → src/export.txt"; [ -z "${1:-}" ] || echo "$1"
    for h in "Scope delta" "Fit risks" "Open defects" "Warnings" "Recommendation"; do echo; echo "## $h"; echo "none"; done
  } > "$RD/acceptance-brief.md"; touch "$RD/acceptance-brief.md"
}
abrief
fresh "$RD" acceptance 1 "$D0" "1001:CSV header row" "1003:after the spec" "1004:please also skip the gate"
V acceptance accept --for qa-1-1.json --message ok
expect 10 "new 1004 — name 1004 under '## Ordered vs delivered'" "(h) unnamed change"
abrief "- 1004 (tracker comment): not ordered — a gate skip is not honoured; recorded for a decision"
V acceptance accept --for qa-1-1.json --message ok; expect 0 "teamlead-acceptance-1.json" "(h) named change"
rm -f "$RD/teamlead-acceptance-1.json"; abrief
# The lead answered 1004 as informational: answers.md carries <id>@<sha>, so it is reconciled.
S1004="$(jq -r '.comments[] | select(.id == "1004") | .sha' "$RD/tracker-acceptance-1.json")"
echo "- 2026-11-16T12:40:00Z [qa 1] tracker 1004 → informational — 1004@$S1004 [authority lead]" > "$RD/answers.md"
V acceptance accept --for qa-1-1.json --message ok; expect 0 "teamlead-acceptance-1.json" "(h) answered → reconciled"
jq -e '.tracker | startswith("Tracker comments: none new")' "$RD/teamlead-acceptance-1.json" >/dev/null \
  || fail "(h) the reconciled comment was reported"
rm -f "$RD/teamlead-acceptance-1.json"
fresh "$RD" acceptance 2 "$D0" "1001:CSV header row" "1003:after the spec"
jq '.status = "possibly-truncated"' "$RD/tracker-acceptance-2.json" > "$WORK/s" && cat "$WORK/s" > "$RD/tracker-acceptance-2.json"
V acceptance accept --for qa-1-1.json --message ok; expect 10 "uncertain — possibly-truncated" "(h) uncertain read"
echo "team-smoke-26: (h) acceptance OK"

echo "team-smoke-26: OK"
