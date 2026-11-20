#!/usr/bin/env bash
# order brief (team-brief.sh): in-flight list from the anchors, validation, no silent rewrite,
# check, archived by team-next; the TeamLead's plan gate (verdicts, revise limit, digest at a
# brainstorm plan approve, no spec gate, older-base refusal, quick remode → closed).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

smoke_team AB-1400 feature/AB-1400-x
B="bash .claude/lib/team-brief.sh"
ANCH="$MAIN/.agents/team/anchors"
draft() {  # draft <file> [section to drop] — a full brief, optionally without one section
  { echo "## Ticket"; echo "Add the export button."
    [ "${2:-}" = not ] || { echo; echo "## Not ordered"; echo "none stated"; }
    echo; echo "## In-flight work"; echo "- none"; } > "$1"
}

# ---- (a) inflight -------------------------------------------------------------------------------
run "$MAIN" $B inflight alfa; expect 0 "- none" "(a) no other anchors"
jq -n --arg c "$WORK/gone-beta" '{team: "beta", ticket: "AB-1401", branch: "feature/AB-1401-y",
  role: "coder", clone: $c}' > "$ANCH/beta.json"
run "$MAIN" $B inflight alfa
expect 0 "- beta: AB-1401 on feature/AB-1401-y (?, stage coder)" "(a) beta from its anchor"
has "alfa:" "$WORK/out" && fail "(a) the team lists itself"
jq --arg c "$(cd "$CLONE" && pwd -P)" '.team = "gamma" | .clone = $c' "$ANCH/beta.json" \
  > "$ANCH/gamma.json"
run "$MAIN" $B inflight alfa; expect 0 "- gamma: AB-1401 on feature/AB-1401-y (brainstorm, stage coder)" \
  "(a) mode read from the clone"
rm -f "$ANCH/gamma.json"
echo "team-smoke-21: (a) inflight OK"

# ---- (b) write validates ------------------------------------------------------------------------
draft "$WORK/bad.md" not
run "$MAIN" $B write alfa "$WORK/bad.md"; expect 4 "missing heading: ## Not ordered" "(b) missing"
[ ! -e "$TD/order-brief.md" ] || fail "(b) an invalid draft was placed"
printf '## Ticket\nx\n\n## Not ordered\n\n## In-flight work\n- none\n' > "$WORK/empty.md"
run "$MAIN" $B write alfa "$WORK/empty.md"; expect 4 "empty section: ## Not ordered" "(b) empty"
{ cat "$WORK/empty.md"; printf '\n## Ticket\ny\n'; } > "$WORK/twice.md"
run "$MAIN" $B write alfa "$WORK/twice.md"; expect 4 "appears 2 times: ## Ticket" "(b) duplicate"
draft "$WORK/ok.md"
run "$MAIN" $B write alfa "$WORK/ok.md"; expect 0 "order-brief.md" "(b) full draft"
head -n 1 "$TD/order-brief.md" | grep -qx 'ticket: AB-1400' || fail "(b) no ticket header"
has "Add the export button." "$TD/order-brief.md" || fail "(b) ticket text not copied"
run "$CLONE" $B write alfa "$WORK/ok.md"; expect 1 "main checkout" "(b) refused in a clone"
# A ticket pasted verbatim with its own h2 headings stays one section.
printf '## Ticket
## Description
Export.
## Acceptance
- works

## Not ordered
none stated

## In-flight work
- none
' \
  > "$WORK/h2.md"
run "$MAIN" $B write alfa "$WORK/h2.md" --replace; expect 0 "order-brief.md" "(b) ticket with own h2 headings"
printf '## Ticket
## Description

## Not ordered
none

## In-flight work
- none
' > "$WORK/h2e.md"
run "$MAIN" $B write alfa "$WORK/h2e.md" --replace; expect 0 "" "(b) a ticket heading alone is body"
draft "$WORK/ok.md"; run "$MAIN" $B write alfa "$WORK/ok.md" --replace; expect 0 "" "(b) restore"
echo "team-smoke-21: (b) write OK"

# ---- (c) no silent rewrite ----------------------------------------------------------------------
printf 'changed\n' >> "$WORK/ok.md"
run "$MAIN" $B write alfa "$WORK/ok.md"; expect 4 "--replace" "(c) second write refused"
has changed "$TD/order-brief.md" && fail "(c) the refused write changed the brief"
run "$MAIN" $B write alfa "$WORK/ok.md" --replace; expect 0 "" "(c) --replace"
has changed "$TD/order-brief.md" || fail "(c) --replace did not rewrite"
echo "team-smoke-21: (c) replace OK"

# ---- (d) check ----------------------------------------------------------------------------------
run "$MAIN" $B check alfa; expect 0 "order brief ok" "(d) check passes"
sed -i.bak '/^## In-flight work/d' "$TD/order-brief.md"
run "$MAIN" $B check alfa; expect 4 "missing heading: ## In-flight work" "(d) check catches a broken brief"
mv "$TD/order-brief.md.bak" "$TD/order-brief.md"
echo "team-smoke-21: (d) check OK"

# ---- (e) team-next archives the brief -----------------------------------------------------------
run "$MAIN" perl -e 'alarm 30; exec @ARGV' \
  bash .claude/lib/team-next.sh alfa AB-1402 feature/AB-1402-z origin/develop
expect 0 "was AB-1400" "(e) team-next"
[ ! -e "$TD/order-brief.md" ] || fail "(e) the brief stayed with the new ticket"
ls "$TD"/archive/AB-1400-*/order-brief.md >/dev/null 2>&1 || fail "(e) the brief was not archived"
run "$MAIN" $B check alfa; expect 4 "no order brief" "(e) the new ticket has no brief yet"
echo "team-smoke-21: (e) archive OK"

# ==== gates (step 4): plan gate, revise limit, digest, no spec gate, close =======================
RUN_ID=alfa-20261114-110000; RD="$TD/runs/$RUN_ID"; SUP="$MAIN/.agents/team/inbox/Supervisor/new"
BASE="$(jq -r .base_sha "$TD/team.json")"; SPEC=.agents/specs/s.md; PLAN=.agents/plans/active/p.md
export WORK TD
unset TEAM_SMOKE_NO_LEAD
mkdir -p "$MAIN/.claude/team/sessions" "$CLONE/.claude/hooks"
cp "$SRC/.claude/team/sessions/TeamLead.settings.json" "$MAIN/.claude/team/sessions/"
cp "$SRC/.claude/hooks/guard-teamlead-write.sh" "$SRC/.claude/hooks/guard-teamlead-bash.sh" "$CLONE/.claude/hooks/"
cp "$SRC/.claude/lib/team-watch-send.py" "$MAIN/.claude/lib/"
# The gate records are validated against a clean tree: the copied guard is committed.
git -C "$CLONE" add -A && git -C "$CLONE" commit --quiet -m "fixture guard" || true
[ -z "$(git -C "$CLONE" status --porcelain)" ] || { git -C "$CLONE" status --porcelain > "$WORK/out"; fail "gates: clone not clean"; }
# has-session from files: $WORK/alive lists live sessions, a killed one is dead, CANCEL_AT stops.
cat > "$WORK/hs.sh" <<'HS'
n=$(( $(cat "$WORK/hs.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/hs.n"
s="${3#=}"; s="${s#smk-}"   # alive lists and cases name addresses; tmux names carry smk-
[ -z "${CANCEL_AT:-}" ] || [ "$n" -lt "$CANCEL_AT" ] || touch "$TD/cancel"
! grep -q -- "kill-session -t =smk-$s\$" "$STUB_LOG" || exit 1
grep -qx -- "$s" "$WORK/alive" 2>/dev/null && exit 0
exit 1
HS
export STUB_ON_HAS_SESSION=". '$WORK/hs.sh'" STUB_PANE="$FIX/idle.txt"
greset() {  # greset <alive sessions...> — a runner start on this run; records and verdicts stay
  rm -rf "$TD/lock" "$TD/cancel" "$WORK/hs.n"; : > "$STUB_LOG"; printf '%s\n' "$@" > "$WORK/alive"
  export CANCEL_AT=12
}
V() { run "$CLONE" env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-verdict.sh "$@"; }
prec() { run "$CLONE" bash .claude/lib/team-record.sh "$@"; }
spec_body() { mkdir -p "$CLONE/.agents/specs"; printf '# Spec\n\n**Status:** %s\n\n%s\n' "$1" "$2" > "$CLONE/$SPEC"
  git -C "$CLONE" add "$SPEC" && git -C "$CLONE" commit --quiet -m spec; }
rm -rf "$TD/runs" "$TD/acked" "$TD/verdict-acked"; echo "$RUN_ID" > "$TD/run"; mkdir -p "$RD"
jq -n --arg r "$RUN_ID" --arg m "$MAIN" '{team: "alfa", run: $r, session_id: "sid-lead", main_root: $m}' \
  > "$TD/teamlead.json"
# The planner approves its own spec (/brainstorm Step 9 in team mode): no spec gate.
spec_body "Approved (auto — team mode)" "Export button."
commit_file "$PLAN" "# Plan"

# ---- (f) no review record; the planner's done goes to the plan gate ------------------------------
session planner 1 "$BASE"
prec --verdict review --artifacts "$SPEC"; expect 2 "there is no spec gate" "(f) review refused"
[ -z "$(ls "$RD"/planner-*.json 2>/dev/null)" ] || fail "(f) a refused review wrote a record"
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-1.json" "(f) the planner's done"
echo "team-smoke-21: (f) no review record OK"

# ---- (j) non-lead, (n) older --for, no spec gate -------------------------------------------------
run "$CLONE" bash .claude/lib/team-verdict.sh plan approve --for planner-1-1.json --message x
expect 3 "only this run's TeamLead" "(j) non-lead caller"
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-2.json" "(n) second done"
V plan approve --for planner-1-1.json --message ok; expect 4 "not the newest planner record" "(n) older --for"
V spec approve --for planner-1-2.json --message ok; expect 4 "no spec gate: the first gate is the plan gate" "(n) spec gate refused"
V plan accept --for planner-1-2.json --message x; expect 4 "not allowed at the plan gate" "(n) bad verdict"
V acceptance accept --for planner-1-2.json --message x; expect 4 "the acceptance gate is the qa's" "(n) acceptance on a planner record"
[ -z "$(ls "$RD"/teamlead-*.json 2>/dev/null)" ] || fail "(n) a refused verdict was written"
echo "team-smoke-21: (j) caller + (n) --for OK"

# ---- (o) the verdict guard binds the call to the hook payload's session id -----------------------
HOOK="$SRC/.claude/hooks/guard-team-verdict.sh"
vp() { jq -cn --arg s "$1" --arg c "$2" '{session_id: $s, tool_name: "Bash", tool_input: {command: $c}}'; }
FORGE="TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-verdict.sh plan approve --for planner-1-2.json --message x"
hook "$CLONE" "$(vp sid-planner-1 "$FORGE")"; expect 2 "not it (refused)" "(o) forged env from a stage"
# A forged spec call is still refused by the hook, before the script's own refusal.
hook "$CLONE" "$(vp sid-planner-1 "TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-verdict.sh spec approve --for planner-1-2.json --message x")"
expect 2 "not it (refused)" "(o) forged spec call"
hook "$CLONE" "$(vp sid-planner-1 "bash $CLONE/.claude/lib/team-verdict.sh plan approve")"; expect 2 "" "(o) absolute path"
hook "$CLONE" "$(vp sid-planner-1 "env TEAM_SESSION_ROLE=TeamLead sh .claude/lib/team-verdict.sh plan approve")"; expect 2 "" "(o) env + sh"
hook "$CLONE" "$(vp sid-planner-1 "bash '.claude/lib/team-verdict.sh'  'event' collision")"; expect 2 "" "(o) quoted name and gate"
hook "$CLONE" "$(vp sid-wrapup-1 "TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-verdict.sh wrapup decide --for wrapup_proposals-1_1.json --ref x --message x")"
expect 2 "not it (refused)" "(o) forged env: the wrapup deciding its own proposals"
# Only an invocation is checked: work on the file itself passes from a stage session.
for c in "git add .claude/lib/team-verdict.sh" "bash -n .claude/lib/team-verdict.sh" \
  "cat .claude/lib/team-verdict.sh" "grep -n revise .claude/lib/team-verdict.sh"; do
  hook "$CLONE" "$(vp sid-planner-1 "$c")"; expect 0 "" "(o) $c"
done
TEAM_SESSION_ROLE=TeamLead hook "$CLONE" "$(vp sid-planner-1 "$FORGE")"; expect 2 "" "(o) role env, wrong session"
TEAM_SESSION_ROLE=TeamLead hook "$CLONE" "$(vp "" "$FORGE")"; expect 2 "" "(o) empty session id"
TEAM_SESSION_ROLE=TeamLead hook "$CLONE" "$(vp sid-lead "bash .claude/lib/team-verdict.sh plan approve")"
expect 0 "" "(o) the lead's own session"
hook "$CLONE" "$(vp sid-planner-1 "git status")"; expect 0 "" "(o) other commands untouched"
hook "$MAIN" "$(vp sid-planner-1 "$FORGE")"; expect 0 "" "(o) no-op outside a team clone"
echo "team-smoke-21: (o) verdict guard OK"

# ---- (p) a brainstorm plan approve needs the constraint digest -----------------------------------
V plan approve --for planner-1-2.json --message "covers the order"
expect 7 "constraint digest missing — see the Digest section of the TeamLead prompt" "(p) no digest.md"
printf 'made_at: x\n\nnone\n' > "$RD/digest.md"
V plan approve --for planner-1-2.json --message "covers the order"; expect 7 "constraint digest missing" "(p) no scope header"
[ ! -e "$RD/teamlead-plan-1.json" ] || fail "(p) a refused approve wrote a verdict"
# ---- (q) with the digest it passes (below) --------------------------------------------------------
printf 'scope: %s\nmade_at: 2026-11-14T11:00:00Z\n\n- none\n' "$PLAN" > "$RD/digest.md"
echo "team-smoke-21: (p) digest required + (q) digest present OK"

# ---- (m) escalate keeps waiting; the gate stays pending ------------------------------------------
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-3.json" "(m) third done"
V plan escalate --for planner-1-3.json --message "human-only question"; expect 0 "teamlead-plan-1.json" "(m) escalate"
[ "$(jq -r 'has("spec_digest")' "$RD/teamlead-plan-1.json")" = false ] || fail "(m) the verdict carries spec_digest"
greset alfa-lead alfa-planner
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: gate plan planner-1-3.json" "(m) runner keeps waiting"
has "send-keys -t =smk-alfa-lead: -l -- gate plan: .agents/team/runs/$RUN_ID/planner-1-3.json" "$STUB_LOG" \
  || { cp "$STUB_LOG" "$WORK/out"; fail "(m) the lead was not rung for the plan gate"; }
has "gate spec" "$STUB_LOG" && { cp "$STUB_LOG" "$WORK/out"; fail "(m) a spec gate was rung"; }
has "[team-run]" "$STUB_LOG" && { cp "$STUB_LOG" "$WORK/out"; fail "(m) escalate messaged the planner"; }
grep -qx teamlead-plan-1.json "$TD/verdict-acked" || fail "(m) escalate not marked acted"
run "$CLONE" bash .claude/lib/team-lead.sh pending alfa
expect 0 "gate .agents/team/runs/$RUN_ID/planner-1-3.json — plan gate" "(m) pending lists the open gate"
echo "team-smoke-21: (m) escalate OK"

# ---- (h) revise limit on the plan gate, one Operator grant ---------------------------------------
V plan revise --for planner-1-3.json --message x; expect 4 "revise needs --ref" "(h) revise without ref"
for i in 1 2 3; do
  V plan revise --for planner-1-3.json --ref "$RD/gate-plan-$i.md" --message "round $i"; expect 0 "" "(h) revise $i"
done
V plan revise --for planner-1-3.json --ref "$RD/gate-plan-4.md" --message "round 4"
expect 5 "revise limit 3 reached for gate plan (teams.teamlead.revise_limit) — write escalate with a pending decision, approve" "(h) fourth revise"
has "or remode" "$WORK/out" && fail "(h) remode offered in brainstorm"
mkdir -p "$RD/decisions"
printf -- '---\nid: d-1\nstatus: answered\nanswer_outcome: more-revise\ngate: plan\n---\nOne more round.\n' > "$RD/decisions/d-1.md"
V plan revise --for planner-1-3.json --ref "$RD/gate-plan-4.md" --message "granted" --decision d-1
expect 0 "teamlead-plan-5.json" "(h) granted revise"
grep -q '^status: consumed' "$RD/decisions/d-1.md" && grep -q '^consumed_by: teamlead-plan-5.json' "$RD/decisions/d-1.md" \
  || fail "(h) grant not consumed"
V plan revise --for planner-1-3.json --ref "$RD/gate-plan-5.md" --message "again" --decision d-1
expect 4 "not an answered, unconsumed more-revise grant" "(h) a grant spent twice"
V plan revise --for planner-1-3.json --ref "$RD/gate-plan-5.md" --message "again"
expect 5 "revise limit 3" "(h) refused after the grant"
echo "team-smoke-21: (h) revise limit OK"

# ---- (i) a spec body edited after the planner's own approve does not block a plan approve --------
spec_body "Approved (auto — team mode)" "Export button and a CSV import."
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-4.json" "(i) done after a spec edit"
V plan approve --for planner-1-4.json --message ok; expect 0 "teamlead-plan-6.json" "(i) plan approve"
echo "team-smoke-21: (i) no spec digest OK"

# ---- (w) the wrapup's proposals under the lead: the record mark, the decision, notes, audit (#104) --
session wrapup 1 "$BASE"; CL="$CLONE/.claude/lib"
P=".agents/team/runs/$RUN_ID/wrapup_proposals-1_1.json"; WD="$RD/wrapup-decision-1.md"
prec --verdict blocked --proposals "$P"; expect 2 "not readable JSON" "(w) no proposals file"
echo '{"run": "x", "attempt": 1, "items": []}' > "$CLONE/$P"
prec --verdict blocked --proposals "$P"; expect 2 "no items" "(w) nothing to propose is no stop"
# An id with a trailing newline is no id (fullmatch, not `$`).
jq -n '{items: [{id: "create-1\n", kind: "ticket", title: "t", body: "b"}]}' > "$CLONE/$P"
prec --verdict blocked --proposals "$P"; expect 2 "an item id must be" "(w) an id with a trailing newline"
jq -n '{items: [{id: "memory-1", kind: "memory", group: "A", target: "errors.md", text: "t", czytelnik: "c"}]}' > "$CLONE/$P"
prec --verdict blocked --proposals "$P"; expect 2 "target must be a file under .agents/memory/" "(w) a bare memory target"
# memory-2 says group A, but decisions.md is group B by its target.
jq -n '{run: "x", attempt: 1, items: [
  {id: "create-1", kind: "ticket", title: "Fix the CSV header", body: "b1"},
  {id: "create-2", kind: "ticket", title: "Tidy the export module", body: "b2"},
  {id: "memory-1", kind: "memory", group: "A", target: ".agents/memory/errors.md", text: "t1", czytelnik: "c"},
  {id: "memory-2", kind: "memory", group: "A", target: ".agents/memory/decisions.md", text: "t2", czytelnik: "c"}]}' \
  > "$CLONE/$P"
prec --verdict blocked --proposals "/tmp/wrapup_proposals-1_1.json"; expect 2 "must be .agents/team/runs/" "(w) proposals outside the run dir"
prec --verdict blocked --proposals ".agents/team/runs/$RUN_ID/wrapup_proposals-1.json"; expect 2 "wrapup_proposals-1_<k>.json" "(w) a name without its sequence"
mv "$TD/teamlead.json" "$WORK/tl.json"
prec --verdict blocked --proposals "$P"; expect 2 "needs this run's TeamLead" "(w) no lead"
mv "$WORK/tl.json" "$TD/teamlead.json"
session coder 1 "$BASE"; prec --verdict blocked --proposals "$P"; expect 2 "is the wrapup's" "(w) a coder"
session wrapup 1 "$BASE"
prec --verdict blocked --proposals "$P"; expect 0 "wrapup-1-1.json" "(w) the proposals stop"
jq -e --arg p "$P" '.verdict == "blocked" and .proposals == $p and .message == "wrapup proposals: " + $p' \
  "$RD/wrapup-1-1.json" >/dev/null || fail "(w) record lacks the proposals mark"
grep -q '^- \[wrapup' "$RD/notes.md" 2>/dev/null && fail "(w) the proposals stop appended a blocker line"
run "$CLONE" bash .claude/lib/team-lead.sh pending alfa
expect 0 "stop .agents/team/runs/$RUN_ID/wrapup-1-1.json — wrapup proposals: $P" "(w) pending lists the stop"
# The audit does not count it as a block (run, stage), the run stays in progress, and the wait for
# the lead is not stage time.
python3 -I - "$CL" "$RD" "$WORK" > "$WORK/out" 2>&1 <<'PY' || fail "(w) audit counts the proposals stop: $(cat "$WORK/out")"
import json, os, sys
sys.path.insert(0, sys.argv[1])
import team_audit as a
recs = a.load_records(sys.argv[2], ["wrapup"])
c = a.run_counts(sys.argv[2], recs)
assert c["records"] == {"proposals": 1}, c["records"]
assert a.run_state([], recs) == "in-progress", a.run_state([], recs)
assert a.stage(sys.argv[2], "wrapup", recs, {})["verdicts"] == {"proposals": 1}
d = os.path.join(sys.argv[3], "lw"); os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "teamlead-wrapup-1.json"), "w") as f:
    json.dump({"for": "wrapup_proposals-1_1.json", "written_at": "2026-11-16T10:20:00Z"}, f)
r = [{"proposals": ".agents/team/runs/x-1/wrapup_proposals-1_1.json", "written_at": "2026-11-16T10:00:00Z"}]
w = a.lead_wait(d, r, a.parse_utc("2026-11-16T10:30:00Z"))
assert w == 20.0, w
PY
run "$CLONE" bash .claude/lib/team-lead.sh notes-init alfa
WV() { V wrapup decide --for wrapup_proposals-1_1.json --ref "$WD" --message "decided"; }
dec() { printf '%s\n' "$@" > "$WD"; }
A1="- create-1 accept — needed because users hit the broken header"
D2="- create-2 decline — cannot judge: a tidy-up from the implementation"
M1="- memory-1 accept — needed because the next coder repeats it"
M2="- memory-2 accept — needed because it fixes a wrong decision, opinion-1.md — over cap because two different mistakes"
dec "$A1" "$D2" "$M1"; WV; expect 4 "not decided: memory-2" "(w) an item left out"
dec "- create-1 accept — users hit it" "$D2" "$M1" "$M2"; WV; expect 4 "neither" "(w) accept without needed because"
dec "- create-1 accept — needed because   " "$D2" "$M1" "$M2"; WV; expect 4 "non-empty reason" "(w) an empty needed-because"
dec "$A1" "- create-2 decline —   " "$M1" "$M2"; WV; expect 4 "non-empty reason" "(w) an empty decline reason"
dec "$A1" "$D2" "$M1" "- memory-2 accept — needed because x, opinion-1.md — over cap because  "; WV
expect 4 "non-empty reason" "(w) an empty over-cap reason"
dec "$A1" "- create-2 accept — needed because x" "$M1" "$M2"; WV; expect 4 "more than 1 ticket" "(w) the ticket cap"
dec "$A1" "$D2" "$M1" "- memory-2 accept — needed because x, opinion-1.md"; WV; expect 4 "more than 1 memory entry" "(w) the memory cap counts A and B"
dec "$A1" "  correction: one" "  correction: two" "$D2" "$M1" "$M2"; WV; expect 4 "one correction line per item" "(w) a second correction"
dec "$A1" "$D2" "  correction: x" "$M1" "$M2"; WV; expect 4 "belongs under an accept" "(w) a correction under a decline"
dec "$A1" "$A1" "$D2" "$M1" "$M2"; WV; expect 4 "decided twice" "(w) an item twice"
dec "$A1" "$D2" "$M1" "$M2" "- create-9 decline — x"; WV; expect 4 "not a proposed item" "(w) an unknown item"
dec "$A1" "$D2" "$M1" "$M2"; WV; expect 4 "group B accept names its Codex opinion" "(w) group B by target, no opinion file"
echo opinion > "$RD/opinion-1.md"
dec "$A1" "$D2" "$M1" "- memory-2 accept — needed because see notopinion-1.md — over cap because y"; WV
expect 4 "group B accept names its Codex opinion" "(w) an opinion name inside another word"
dec "$A1" "  correction: the header is 'id', not 'key'" "$D2" "$M1" "$M2"
V wrapup decide --for wrapup_proposals-1_2.json --ref "$WD" --message x; expect 4 "is not wrapup_proposals-1_1.json" "(w) another proposals file"
V wrapup decide --for wrapup_proposals-1_1.json --ref "$RD/gate-plan-1.md" --message x; expect 4 "wrapup-decision-<n>.md" "(w) not a decision file"
WV; expect 0 "teamlead-wrapup-1.json" "(w) decide"
jq -e --arg sha "$(shasum -a 256 "$CLONE/$P" | cut -d' ' -f1)" '[.items[] | [.id, .decision]] == [["create-1","accept"],["create-2","decline"],["memory-1","accept"],["memory-2","accept"]]
  and .items[0].correction == "the header is '"'"'id'"'"', not '"'"'key'"'"'" and (.items[3].over_cap | length > 0)
  and .items[3].group == "B" and .items[2].target == ".agents/memory/errors.md" and .proposals_sha256 == $sha' \
  "$RD/teamlead-wrapup-1.json" >/dev/null || fail "(w) verdict items: $(cat "$RD/teamlead-wrapup-1.json")"
awk '/^## Wrapup decisions$/ { f = 1; next } /^## / { f = 0 } f && NF' "$RD/teamlead-notes.md" > "$WORK/wd"
[ "$(wc -l < "$WORK/wd" | tr -d ' ')" = 4 ] && grep -qF -- "- create-2 decline — cannot judge: a tidy-up" "$WORK/wd" \
  && grep -qF -- "(correction: the header is 'id', not 'key')" "$WORK/wd" \
  || fail "(w) notes section: $(cat "$RD/teamlead-notes.md")"
grep '^## ' "$RD/teamlead-notes.md" | tail -n 1 | grep -q 'Late answers' || fail "(w) the notes headings moved"
WV; expect 4 "already decided" "(w) decided once"
run "$CLONE" bash .claude/lib/team-verdict.sh wrapup decide --for wrapup_proposals-1_1.json --ref "$WD" --message x
expect 3 "only this run's TeamLead" "(w) the wrapup itself"
# A decided file is never a second stop; a resume writes the next <k>.
prec --verdict blocked --proposals "$P"; expect 2 "already decided (teamlead-wrapup-1.json)" "(w) a decided file restopped"
# The cap counts the run: one ticket and two memory entries are already accepted. A hand-off uses no cap.
P2=".agents/team/runs/$RUN_ID/wrapup_proposals-1_2.json"
jq -n '{run: "x", attempt: 1, items: [
  {id: "create-3", kind: "ticket", title: "Fix the CSV footer", body: "b3"},
  {id: "memory-3", kind: "memory", group: "A", target: ".agents/memory/errors.md", text: "t3", czytelnik: "c", handoff: "q-2 accepted"}]}' \
  > "$CLONE/$P2"
prec --verdict blocked --proposals "$P2"; expect 0 "wrapup-1-2.json" "(w) a second proposals stop"
WV2() { V wrapup decide --for wrapup_proposals-1_2.json --ref "$WD" --message "decided"; }
dec "- create-3 accept — needed because the footer is broken too" "- memory-3 accept — needed because q-2 accepted it"
WV2; expect 4 "more than 1 ticket accepted in this run" "(w) the cap counts earlier proposals files"
dec "- create-3 decline — the footer defect is create-1's" "- memory-3 accept — needed because q-2 accepted it"
WV2; expect 0 "teamlead-wrapup-2.json" "(w) a hand-off uses no cap"
jq -e '.items[1].handoff == true' "$RD/teamlead-wrapup-2.json" >/dev/null || fail "(w) hand-off not marked: $(cat "$RD/teamlead-wrapup-2.json")"
# The runner's done check: drafts and create intents against the ticket accepts, memory files against
# the accepted targets, the decided proposals files against their sha256.
G="$WORK/wg"; mkdir -p "$G"; git -C "$G" init --quiet
gc() { git -C "$G" add -A; git -C "$G" -c user.name=t -c user.email=t@example.invalid commit --quiet --allow-empty -m "$1"; git -C "$G" rev-parse HEAD; }
G0="$(gc a)"; mkdir -p "$G/.agents/memory"; echo x > "$G/.agents/memory/errors.md"; echo y > "$G/.agents/memory/decisions.md"
G1="$(gc mem)"; echo z > "$G/.agents/memory/patterns.md"; G2="$(gc pat)"
cwl() {  # cwl <state json> <from> <to> → RC of check_wrapup_lead
  printf '%s' "$1" > "$RD/wrapup-state.json"
  set +e; (cd "$G" && . "$CL/team-lib.sh" && . "$CL/team-validate.sh" && TD="$TD" && RUN="$RUN_ID" \
    && run_ref() { echo "$RUN_ID"; } && check_wrapup_lead "$2" "$3") > "$WORK/out" 2>&1; RC=$?; set -e
}
OK1='{"drafts": {"create-1": {"accepted": true}}, "intents": {"create-1": {"op": "create", "draft_id": "create-1", "state": "done"}}}'
cwl "$OK1" "$G0" "$G1"; expect 0 "" "(w) an accepted create-<n> draft + accepted memory files"
cwl '{"drafts": {"1": {"accepted": true}}}' "$G0" "$G0"; expect 0 "" "(w) a bare draft key reads as create-<n>"
cwl '{"drafts": {"create-1": {"accepted": true}, "create-2": {"accepted": true}}}' "$G0" "$G0"
expect 1 "did not accept: create-2" "(w) a draft the lead declined"
cwl '{"drafts": {"create-1": {"accepted": true}, "create-2": {"accepted": false}}, "intents": {"create-2": {"op": "create", "draft_id": "create-2", "state": "done"}}}' "$G0" "$G0"
expect 1 "did not accept: create-2" "(w) a declined ticket created anyway"
cwl '{"intents": {"create-3": {"state": "pending", "draft_id": "create-3"}}}' "$G0" "$G0"
expect 1 "did not accept: create-3" "(w) a jira-style create intent without op"
cwl "$OK1" "$G0" "$G2"; expect 1 "changed .agents/memory/patterns.md without a TeamLead memory accept" "(w) a memory file no accept names"
cp "$CLONE/$P" "$WORK/p1"; echo ' ' >> "$CLONE/$P"
cwl "$OK1" "$G0" "$G1"; expect 1 "wrapup_proposals-1_1.json changed after the TeamLead decided it" "(w) a decided file rewritten"
cp "$WORK/p1" "$CLONE/$P"
mv "$TD/teamlead.json" "$WORK/tl.json"; cwl '{"drafts": {"create-2": {"accepted": true}}}' "$G0" "$G2"
expect 0 "" "(w) no lead: unchanged"; mv "$WORK/tl.json" "$TD/teamlead.json"
rm -f "$RD"/wrapup-* "$RD"/teamlead-wrapup-* "$RD/opinion-1.md" "$CLONE/$P" "$CLONE/$P2"
session planner 1 "$BASE"
echo "team-smoke-21: (w) wrapup proposals OK"

# ---- (k) plan approve → the runner accepts the planner record and launches the coder -------------
# A rejected approve is spent: the planner is sent the reason (team-run-stop.sh reject_record) and the
# runner waits; the planner's next done rings the plan gate again and a new approve accepts it.
greset alfa-lead alfa-planner; touch "$CLONE/stray.txt"
run "$MAIN" $TR alfa; expect 6 "sent back to planner (1 of 2)" "(k) approve with a failing validation"
[ ! -e "$RD/planner-1-4.json.accepted" ] && grep -qx teamlead-plan-6.json "$TD/verdict-acked" \
  || fail "(k) a rejected approve was accepted, or not spent"
has "gate plan: .agents/team/runs/$RUN_ID/planner-1-4.json" "$STUB_LOG" || fail "(k) no plan gate ring"
has "your done record .agents/team/runs/$RUN_ID/planner-1-4.json was rejected: " "$STUB_LOG" \
  && has "working tree is not clean" "$RD/rejected-planner-1-4" && [ -e "$RD/planner-1-4.json.answered" ] \
  || fail "(k) the planner was not told the reason"
rm -f "$CLONE/stray.txt"
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-5.json" "(k) the planner's next done"
greset alfa-lead alfa-planner
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: gate plan planner-1-5.json" "(k) the plan gate rings again"
V plan approve --for planner-1-5.json --message ok; expect 0 "teamlead-plan-7.json" "(k) a new approve"
greset alfa-lead alfa-planner; export CANCEL_AT=30
run "$MAIN" $TR alfa
[ -e "$RD/planner-1-5.json.accepted" ] || fail "(k) planner record not accepted (exit $RC)"
has "accepted: planner-1-5.json" "$WORK/out" && has "launched: coder attempt 1" "$WORK/out" \
  || fail "(k) coder not launched after the plan approve"
echo "team-smoke-21: (k) plan approve OK"

# ---- (l) quick: plan remode → closed (exit 8), one event, the lead ended -------------------------
cmd_reset_quick() {
  rm -rf "$TD/runs" "$TD/acked" "$TD/verdict-acked"; mkdir -p "$RD"
  jq '.mode = "quick"' "$TD/team.json" > "$WORK/tj" && mv "$WORK/tj" "$TD/team.json"
}
cmd_reset_quick; session planner 1 "$BASE"
V spec approve --for planner-1-1.json --message x; expect 4 "no spec gate: the first gate is the plan gate" "(l) no spec gate in quick"
prec --verdict done --artifacts "$PLAN"; expect 0 "planner-1-1.json" "(l) quick done"
# ---- (r) quick, no routed domain: approve without a digest; (s) routed: exit 7 until it exists -----
V plan approve --for planner-1-1.json --message ok; expect 0 "teamlead-plan-1.json" "(r) quick, no routed domain"
jq -n '{rules: [{match: "^src/pay/", domain: "payments"}], fallback: "general"}' \
  > "$CLONE/.claude/memory-domains.json"
printf '# Plan\n\n### UPDATE `src/pay/charge.ts:12`\n' > "$CLONE/$PLAN"
git -C "$CLONE" add -A && git -C "$CLONE" commit --quiet -m "routed plan"
prec --verdict done --artifacts "$PLAN"; expect 0 "planner-1-2.json" "(s) routed done"
V plan approve --for planner-1-2.json --message ok; expect 7 "constraint digest missing" "(s) routed, no digest"
printf 'scope: src/pay/charge.ts\nmade_at: 2026-11-14T11:00:00Z\n\n- none\n' > "$RD/digest.md"
V plan approve --for planner-1-2.json --message ok; expect 0 "teamlead-plan-2.json" "(s) routed, with digest"
echo "team-smoke-21: (r) quick unrouted + (s) quick routed OK"
prec --verdict done --artifacts "$PLAN"; expect 0 "planner-1-3.json" "(l) quick done again"
V plan remode --for planner-1-3.json --message "not quick: 3 services"; expect 0 "" "(l) remode"
greset alfa-lead alfa-planner
run "$MAIN" $TR alfa; expect 8 "closed: remode — clone free" "(l) runner closes"
jq -e --arg r ".agents/team/runs/$RUN_ID/teamlead-plan-3.json" '.reason == "remode" and .ref == $r' \
  "$RD/closed.json" >/dev/null || fail "(l) closed.json"
[ "$(grep -l '^event: closed' "$SUP"/* 2>/dev/null | wc -l | tr -d ' ')" = 1 ] || fail "(l) not exactly one closed event"
grep -q '^reason: remode — clone free' "$(grep -l '^event: closed' "$SUP"/*)" || fail "(l) closed event body"
has "kill-session -t =smk-alfa-lead" "$STUB_LOG" || fail "(l) the lead was not ended"
[ ! -e "$TD/session.json" ] || fail "(l) session.json left"
greset alfa-lead
run "$MAIN" $TR alfa; expect 1 "run closed (remode) — team-next for the next ticket, team-remode for remode" "(l) resume refused"
run "$MAIN" $TR alfa status; expect 0 "closed: remode" "(l) status shows the closure"
echo "team-smoke-21: (l) quick remode OK"

# ---- (t) runner: a review record is an error; an older base refuses a brainstorm run in planning --
t_reset() {  # t_reset <mode> — a fresh run of this RUN_ID with its lead, no stage session
  rm -rf "$TD/runs" "$TD/acked" "$TD/verdict-acked" "$TD/session.json"; mkdir -p "$RD"
  jq --arg m "$1" '.mode = $m' "$TD/team.json" > "$WORK/tj" && mv "$WORK/tj" "$TD/team.json"
  jq -n --arg r "$RUN_ID" --arg m "$MAIN" '{team: "alfa", run: $r, session_id: "sid-lead", main_root: $m}' \
    > "$TD/teamlead.json"
}
t_reset brainstorm; session planner 1 "$BASE"
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-1.json" "(t) a planner done"
jq '.verdict = "review"' "$RD/planner-1-1.json" > "$WORK/r" && mv "$WORK/r" "$RD/planner-1-1.json"
greset alfa-lead
run "$MAIN" $TR alfa; expect 4 "is a review: there is no spec gate" "(t) a review record"
VF="$CLONE/.claude/lib/team-verdict.sh"; cp "$VF" "$WORK/verdict.sh"
grep -v 'the first gate is the plan gate' "$WORK/verdict.sh" > "$VF"
git -C "$CLONE" add -A && git -C "$CLONE" commit --quiet -m "older base"
t_reset brainstorm; greset alfa-lead
run "$MAIN" $TR alfa
expect 4 "clone base still has the spec gate (its team-verdict.sh predates the plan-gate-only TeamLead) — this brainstorm run cannot finish planning on the current runner: finish planning before updating the main checkout, or the Operator restarts the ticket on a fresh clone (team-new.sh)" "(t) older base, planner not accepted"
has "team-next" "$WORK/out" && fail "(t) the refusal names team-next"
t_reset brainstorm; session planner 1 "$BASE"
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-1.json" "(t) older base: a planner done"
touch "$RD/planner-1-1.json.accepted"; rm -f "$TD/session.json"; greset alfa-lead
run "$MAIN" $TR alfa
has "clone base still has the spec gate" "$WORK/out" && fail "(t) an accepted planner was refused"
has "TeamLead reused: alfa-lead" "$WORK/out" || fail "(t) older base, planner accepted: the lead was not reused"
t_reset quick; greset alfa-lead
run "$MAIN" $TR alfa
has "clone base still has the spec gate" "$WORK/out" && fail "(t) a quick run was refused"
has "TeamLead reused: alfa-lead" "$WORK/out" || fail "(t) older base, quick: the lead was not reused"
cp "$WORK/verdict.sh" "$VF"; git -C "$CLONE" add -A && git -C "$CLONE" commit --quiet -m "current base"
echo "team-smoke-21: (t) review record + older base OK"
unset STUB_ON_HAS_SESSION STUB_PANE CANCEL_AT

echo "team-smoke-21: OK"
