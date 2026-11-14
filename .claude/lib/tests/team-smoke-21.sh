#!/usr/bin/env bash
# order brief (team-brief.sh): in-flight list from the anchors, validation, no silent rewrite,
# check, archived by team-next; the TeamLead's spec and plan gates (verdicts, revise limit, spec
# digest, plan approve, quick remode → closed).
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

# ==== gates (step 4): spec gate, plan gate, revise limit, digest, close ===========================
RUN_ID=alfa-20261114-110000; RD="$TD/runs/$RUN_ID"; SUP="$MAIN/.agents/team/inbox/Supervisor/new"
BASE="$(jq -r .base_sha "$TD/team.json")"; SPEC=.agents/specs/s.md; PLAN=.agents/plans/active/p.md
export WORK TD
jq '.teams.teamlead.enabled = true' "$MAIN/.claude/project-profile.json" > "$WORK/p" \
  && mv "$WORK/p" "$MAIN/.claude/project-profile.json"
mkdir -p "$MAIN/.claude/team/sessions" "$CLONE/.claude/hooks"
cp "$SRC/.claude/team/sessions/TeamLead-run.settings.json" "$MAIN/.claude/team/sessions/"
cp "$SRC/.claude/hooks/guard-teamlead-write.sh" "$CLONE/.claude/hooks/"
cp "$SRC/.claude/lib/team-watch-send.py" "$MAIN/.claude/lib/"
# The gate records are validated against a clean tree: the copied guard is committed.
git -C "$CLONE" add -A && git -C "$CLONE" commit --quiet -m "fixture guard" || true
[ -z "$(git -C "$CLONE" status --porcelain)" ] || { git -C "$CLONE" status --porcelain > "$WORK/out"; fail "gates: clone not clean"; }
# has-session from files: $WORK/alive lists live sessions, a killed one is dead, CANCEL_AT stops.
cat > "$WORK/hs.sh" <<'HS'
n=$(( $(cat "$WORK/hs.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/hs.n"
s="${3#=}"
[ -z "${CANCEL_AT:-}" ] || [ "$n" -lt "$CANCEL_AT" ] || touch "$TD/cancel"
! grep -q -- "kill-session -t =$s\$" "$STUB_LOG" || exit 1
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
spec_body Draft "Export button."

# ---- (f) review: planner only, one spec, no message ---------------------------------------------
session coder 1 "$BASE"
prec --verdict review --artifacts "$SPEC"; expect 2 "only the planner records review" "(f) coder review"
session planner 1 "$BASE"
prec --verdict review --artifacts "$SPEC,$PLAN"; expect 2 "one .agents/specs/*.md" "(f) two artifacts"
# The exact command /brainstorm Step 9 runs.
run "$CLONE" bash .claude/lib/team-record.sh --verdict review --artifacts .agents/specs/s.md
expect 0 "planner-1-1.json" "(f) the brainstorm review command"
grep -q '^- \[planner' "$RD/notes.md" 2>/dev/null && fail "(f) review appended a blocker"
echo "team-smoke-21: (f) review record OK"

# ---- (j) non-lead, (n) older --for ---------------------------------------------------------------
run "$CLONE" bash .claude/lib/team-verdict.sh spec approve --for planner-1-1.json --message x
expect 3 "only this run's TeamLead" "(j) non-lead caller"
prec --verdict review --artifacts "$SPEC"; expect 0 "planner-1-2.json" "(n) second review"
V spec approve --for planner-1-1.json --message ok; expect 4 "not the newest planner record" "(n) older --for"
V spec remode --for planner-1-2.json --message x; expect 4 "not allowed at the spec gate" "(n) bad verdict"
V acceptance accept --for planner-1-2.json --message x; expect 4 "not yet supported" "(n) reserved gate"
echo "team-smoke-21: (j) caller + (n) --for OK"

# ---- (o) the verdict guard binds the call to the hook payload's session id -----------------------
HOOK="$SRC/.claude/hooks/guard-team-verdict.sh"
vp() { jq -cn --arg s "$1" --arg c "$2" '{session_id: $s, tool_name: "Bash", tool_input: {command: $c}}'; }
FORGE="TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-verdict.sh spec approve --for planner-1-2.json --message x"
hook "$CLONE" "$(vp sid-planner-1 "$FORGE")"; expect 2 "not it (refused)" "(o) forged env from a stage"
hook "$CLONE" "$(vp sid-planner-1 "bash $CLONE/.claude/lib/team-verdict.sh spec approve")"; expect 2 "" "(o) absolute path"
hook "$CLONE" "$(vp sid-planner-1 "env TEAM_SESSION_ROLE=TeamLead sh .claude/lib/team-verdict.sh plan approve")"; expect 2 "" "(o) env + sh"
hook "$CLONE" "$(vp sid-planner-1 "bash '.claude/lib/team-verdict.sh'  'event' collision")"; expect 2 "" "(o) quoted name and gate"
# Only an invocation is checked: work on the file itself passes from a stage session.
for c in "git add .claude/lib/team-verdict.sh" "bash -n .claude/lib/team-verdict.sh" \
  "cat .claude/lib/team-verdict.sh" "grep -n revise .claude/lib/team-verdict.sh"; do
  hook "$CLONE" "$(vp sid-planner-1 "$c")"; expect 0 "" "(o) $c"
done
TEAM_SESSION_ROLE=TeamLead hook "$CLONE" "$(vp sid-planner-1 "$FORGE")"; expect 2 "" "(o) role env, wrong session"
TEAM_SESSION_ROLE=TeamLead hook "$CLONE" "$(vp "" "$FORGE")"; expect 2 "" "(o) empty session id"
TEAM_SESSION_ROLE=TeamLead hook "$CLONE" "$(vp sid-lead "bash .claude/lib/team-verdict.sh spec approve")"
expect 0 "" "(o) the lead's own session"
hook "$CLONE" "$(vp sid-planner-1 "git status")"; expect 0 "" "(o) other commands untouched"
hook "$MAIN" "$(vp sid-planner-1 "$FORGE")"; expect 0 "" "(o) no-op outside a team clone"
echo "team-smoke-21: (o) verdict guard OK"

# ---- (g) spec approve → digest stored, the runner messages the planner ---------------------------
V spec approve --for planner-1-2.json --message "covers the order"; expect 0 "teamlead-spec-1.json" "(g) approve"
[ -n "$(jq -r .spec_digest "$RD/teamlead-spec-1.json")" ] || fail "(g) no spec_digest"
greset alfa-lead alfa-planner
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: gate spec planner-1-2.json" "(g) runner"
has "send-keys -t =alfa-planner: -l -- [team-run] TeamLead approved the spec (.agents/team/runs/$RUN_ID/teamlead-spec-1.json). Set **Status:** Approved (TeamLead, " "$STUB_LOG" \
  || { cp "$STUB_LOG" "$WORK/out"; fail "(g) no approve message to the planner"; }
has "send-keys -t =alfa-lead: -l -- gate spec: .agents/team/runs/$RUN_ID/planner-1-2.json" "$STUB_LOG" \
  || { cp "$STUB_LOG" "$WORK/out"; fail "(g) the lead was not rung for the gate"; }
[ "$(grep -c 'TeamLead approved the spec' "$STUB_LOG")" = 1 ] || fail "(g) approve message not exactly once"
echo "team-smoke-21: (g) spec approve OK"

# ---- (m) escalate keeps waiting; the gate stays pending ------------------------------------------
prec --verdict review --artifacts "$SPEC"; expect 0 "planner-1-3.json" "(m) third review"
V spec escalate --for planner-1-3.json --message "human-only question"; expect 0 "" "(m) escalate"
greset alfa-lead alfa-planner
run "$MAIN" $TR alfa; expect 6 "gate spec planner-1-3.json" "(m) runner keeps waiting"
has "[team-run]" "$STUB_LOG" && { cp "$STUB_LOG" "$WORK/out"; fail "(m) escalate messaged the planner"; }
grep -qx teamlead-spec-2.json "$TD/verdict-acked" || fail "(m) escalate not marked acted"
run "$CLONE" bash .claude/lib/team-lead.sh pending alfa
expect 0 "gate .agents/team/runs/$RUN_ID/planner-1-3.json — spec gate" "(m) pending lists the open gate"
echo "team-smoke-21: (m) escalate OK"

# ---- (h) revise limit, one Operator grant --------------------------------------------------------
V spec revise --for planner-1-3.json --message x; expect 4 "revise needs --ref" "(h) revise without ref"
for i in 1 2 3; do
  V spec revise --for planner-1-3.json --ref "$RD/gate-spec-$i.md" --message "round $i"; expect 0 "" "(h) revise $i"
done
V spec revise --for planner-1-3.json --ref "$RD/gate-spec-4.md" --message "round 4"
expect 5 "revise limit 3 reached for gate spec (teams.teamlead.revise_limit) — write escalate with a pending decision, approve" "(h) fourth revise"
has "or remode" "$WORK/out" && fail "(h) remode offered in brainstorm"
mkdir -p "$RD/decisions"
printf -- '---\nid: d-1\nstatus: answered\noutcome: more-revise\ngate: spec\n---\nOne more round.\n' > "$RD/decisions/d-1.md"
V spec revise --for planner-1-3.json --ref "$RD/gate-spec-4.md" --message "granted" --decision d-1
expect 0 "" "(h) granted revise"
grep -q '^consumed: teamlead-spec-' "$RD/decisions/d-1.md" || fail "(h) grant not consumed"
V spec revise --for planner-1-3.json --ref "$RD/gate-spec-5.md" --message "again" --decision d-1
expect 4 "not an answered, unconsumed more-revise grant" "(h) a grant spent twice"
V spec revise --for planner-1-3.json --ref "$RD/gate-spec-5.md" --message "again"
expect 5 "revise limit 3" "(h) refused after the grant"
echo "team-smoke-21: (h) revise limit OK"

# ---- (i) spec body edited after approve → plan approve exit 6; a Status-only change passes --------
commit_file "$PLAN" "# Plan"
spec_body Draft "Export button and a CSV import."
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-4.json" "(i) done after a body edit"
V plan approve --for planner-1-4.json --message ok; expect 6 "spec changed after approval — re-run the spec gate" "(i) body edit"
spec_body "Approved (TeamLead, 2026-11-14)" "Export button."
prec --verdict done --artifacts "$SPEC,$PLAN"; expect 0 "planner-1-5.json" "(i) done after a Status edit"
V plan approve --for planner-1-5.json --message ok; expect 0 "teamlead-plan-1.json" "(i) Status-only change"
echo "team-smoke-21: (i) spec digest OK"

# ---- (k) plan approve → the runner accepts the planner record and launches the coder -------------
# A rejected approve stays unacted: after the cause is removed a re-run validates it again.
greset alfa-lead alfa-planner; touch "$CLONE/stray.txt"
run "$MAIN" $TR alfa; expect 4 "working tree is not clean" "(k) approve with a failing validation"
[ ! -e "$RD/planner-1-5.json.accepted" ] && ! grep -qx teamlead-plan-1.json "$TD/verdict-acked" \
  || fail "(k) a rejected approve was acted on"
has "gate plan: .agents/team/runs/$RUN_ID/planner-1-5.json" "$STUB_LOG" || fail "(k) no plan gate ring"
rm -f "$CLONE/stray.txt"
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
V spec approve --for planner-1-1.json --message x; expect 4 "quick mode has no spec gate" "(l) no spec gate in quick"
prec --verdict done --artifacts "$PLAN"; expect 0 "planner-1-1.json" "(l) quick done"
V plan remode --for planner-1-1.json --message "not quick: 3 services"; expect 0 "" "(l) remode"
greset alfa-lead alfa-planner
run "$MAIN" $TR alfa; expect 8 "closed: remode — clone free" "(l) runner closes"
jq -e --arg r ".agents/team/runs/$RUN_ID/teamlead-plan-1.json" '.reason == "remode" and .ref == $r' \
  "$RD/closed.json" >/dev/null || fail "(l) closed.json"
[ "$(grep -l '^event: closed' "$SUP"/* 2>/dev/null | wc -l | tr -d ' ')" = 1 ] || fail "(l) not exactly one closed event"
grep -q '^reason: remode — clone free' "$(grep -l '^event: closed' "$SUP"/*)" || fail "(l) closed event body"
has "kill-session -t =alfa-lead" "$STUB_LOG" || fail "(l) the lead was not ended"
[ ! -e "$TD/session.json" ] || fail "(l) session.json left"
greset alfa-lead
run "$MAIN" $TR alfa; expect 1 "run closed (remode) — team-next for the next ticket, team-remode for remode" "(l) resume refused"
run "$MAIN" $TR alfa status; expect 0 "closed: remode" "(l) status shows the closure"
echo "team-smoke-21: (l) quick remode OK"
unset STUB_ON_HAS_SESSION STUB_PANE CANCEL_AT

echo "team-smoke-21: OK"
