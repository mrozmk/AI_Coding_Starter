#!/usr/bin/env bash
# TeamLead mode choice (#296): team.json mode `lead` by default and its base-ref preflight; the runner
# waits for the lead's mode verdict, applies it before any stage (and before lead_start on a resume),
# watches the choosing lead (dead lead, startup dialog); a lead-chosen cli resumes the lead's own
# conversation after the judge's handover; a fixed cli on an old cli prompt; the cli permission from
# the profile; quick without a wrapup (merge check, summary, status, integration readiness), a
# pre-upgrade quick clone that keeps its wrapup; the quick acceptance refusing a follow-up warning;
# the dashboard of a chosen-cli run.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

# smoke_team without its mode argument: team-new's own default is under test here.
chmod 600 "$MAIN/.env"
run "$MAIN" $NEW alfa AB-1500 feature/AB-1500-x origin/develop; expect 0 "" "fixture team creation (no mode)"
NEWOUT="$(cat "$WORK/out")"
CLONE="$WORK/main-alfa"; TD="$CLONE/.agents/team"; BASE=$(git -C "$CLONE" rev-parse HEAD)
RUN_ID=alfa-20261124-100000; RD="$TD/runs/$RUN_ID"
SUP="$MAIN/.agents/team/inbox/Supervisor/new"
REG="$(cd "$MAIN" && pwd -P)/.agents/team/registry"; OB="$HOME/.agent-comms/outbox"
BR="$(jq -r .branch "$TD/team.json")"
TGT0="$(git -C "$CLONE" ls-remote origin refs/heads/develop | cut -f1)"
S=0f0e0d0c-0b0a-4908-8706-050403020100   # the choosing TeamLead's session id (a UUID)
MC="bash .claude/lib/team-merge-check.sh"
export WORK TD REG

# ---- (30) mode lead state ------------------------------------------------------------------------
case_mark "(30) mode lead state"
[ "$(jq -r .mode "$TD/team.json")" = lead ] || fail "(30) team-new without a mode did not write mode lead"
grep -qF "mode:     lead" <<<"$NEWOUT" || fail "(30) team-new did not print mode lead"
run "$MAIN" $TR alfa status; expect 0 "mode: lead (TeamLead choosing)" "(30) status"
( . "$SRC/.claude/lib/team-modes.sh"; [ -z "$(team_mode_roles lead)" ] ) || fail "(30) team_mode_roles lead is not empty"
old_base() {  # old_base <branch> <prompt file> [marker] — origin/<branch> off develop without the file (or the marker)
  smoke_gh_wc "$1"
  git -C "$SGW" checkout --quiet -B "$1" origin/develop
  if [ -z "${3:-}" ]; then git -C "$SGW" rm --quiet ".claude/team/prompts/$2"
  else
    grep -vF -- "$3" "$SGW/.claude/team/prompts/$2" > "$WORK/ob" && mv "$WORK/ob" "$SGW/.claude/team/prompts/$2"
    git -C "$SGW" add ".claude/team/prompts/$2"
  fi
  git -C "$SGW" commit --quiet -m "old $2" && git -C "$SGW" push --quiet origin "$1"
  rm -rf "$SGW"
}
old_base old-quick planner-quick.md
old_base old-qa qa.md 'In mode `quick` no wrapup follows you'
old_base old-cli cli.md /codex-review
git -C "$MAIN" fetch --quiet origin
n=1
for bf in old-quick:planner-quick.md old-qa:qa.md old-cli:cli.md; do
  b="${bf%%:*}"; f="${bf#*:}"
  run "$MAIN" $NEW beta "AB-150$n" "feature/AB-150$n-x" "origin/$b"
  expect 1 "base origin/$b has no $f contract for mode lead — pick a current base ref" "(30) team-new on a base without $f"
  [ ! -e "$WORK/main-beta" ] || fail "(30) a clone was created on a base without $f"
  n=$((n + 1))
done
echo "team-smoke-27: (30) mode lead state OK"

# ---- lead fixtures (team-smoke-22.sh) ------------------------------------------------------------
mkdir -p "$MAIN/.claude/team/sessions" "$CLONE/.claude/hooks"
cp "$SRC/.claude/team/sessions/TeamLead.settings.json" "$MAIN/.claude/team/sessions/"
cp "$SRC/.claude/hooks/guard-teamlead-write.sh" "$SRC/.claude/hooks/guard-teamlead-bash.sh" "$CLONE/.claude/hooks/"
cp "$SRC/.claude/lib/team-watch-send.py" "$MAIN/.claude/lib/"
# Committed, so the merge check finds a clean clone (team-smoke-23.sh does the same).
git -C "$CLONE" add .claude/hooks && git -C "$CLONE" commit --quiet -m "fixture guard"
printf '## Ticket\nExport.\n\n## Not ordered\nnone stated\n\n## In-flight work\n- none\n' > "$WORK/brief.md"
run "$MAIN" bash .claude/lib/team-brief.sh write alfa "$WORK/brief.md"; expect 0 "" "fixture brief"

# has-session from files: $WORK/alive lists live addresses, a killed one is dead, $WORK/hs.case adds
# per-case behaviour, CANCEL_AT stops the runner after that many calls.
cat > "$WORK/hs.sh" <<'HS'
n=$(( $(cat "$WORK/hs.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/hs.n"
s="${3#=}"; s="${s#smk-}"
[ -z "${CANCEL_AT:-}" ] || [ "$n" -lt "$CANCEL_AT" ] || touch "$TD/cancel"
[ ! -f "$WORK/hs.case" ] || . "$WORK/hs.case"
! grep -q -- "kill-session -t =smk-$s\$" "$STUB_LOG" || exit 1
grep -qx -- "$s" "$WORK/alive" 2>/dev/null && exit 0
exit 1
HS
export STUB_ON_HAS_SESSION=". '$WORK/hs.sh'"
reset() {  # reset — a fresh run state between runner invocations
  rm -rf "$TD/lock" "$TD/cancel" "$TD/acked" "$TD/runs" "$TD/session.json" "$TD/teamlead.json" "$TD/round" \
    "$TD/lead-dead" "$TD/relaunch-lead" "$TD/send-lead.log" "$TD/roles.override.json" "$REG/alfa-lead.reg.json" \
    "$REG/state" "$MAIN/.agents/team/inbox" "$OB" "$WORK/hs.n" "$WORK/hs.case" "$WORK/lead.n" "$WORK"/pane.*
  : > "$STUB_LOG"; : > "$WORK/alive"; unset CANCEL_AT
  echo "$RUN_ID" > "$TD/run"; mkdir -p "$RD"
}
again() { rm -rf "$TD/lock" "$TD/cancel" "$WORK/hs.n"; : > "$STUB_LOG"; unset CANCEL_AT; }  # the next runner start
setmode() {  # setmode <mode> [mode_choice json]
  jq --arg m "$1" --argjson c "${2:-null}" '.mode = $m | if $c == null then del(.mode_choice) else .mode_choice = $c end' \
    "$TD/team.json" > "$WORK/tj" && mv "$WORK/tj" "$TD/team.json"
}
choice() { jq -cn --arg s "$S" --arg cc "${1:-}" '{by: "teamlead", reason: "one-line fix", verdict: "x",
  at: "2026-11-24T10:00:00Z", session_id: $s, claude_config_dir: $cc}'; }
lead_json() { jq -n --arg r "$RUN_ID" --arg m "$MAIN" --arg s "${1:-sid-lead}" \
  '{team: "alfa", run: $r, session_id: $s, launch: 1, main_root: $m}' > "$TD/teamlead.json"; }
line_of() { grep -n -- "$1" "$STUB_LOG" | head -n 1 | cut -d: -f1; }
cli_line() { grep -- "-s smk-alfa-cli" "$STUB_LOG" | head -n 1; }
nsd() { grep -l '^event: session_dead' "$SUP"/* 2>/dev/null | wc -l | tr -d ' '; }
V() { run "$CLONE" env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-verdict.sh "$@"; }
unset TEAM_SMOKE_NO_LEAD

# ---- (31) mode apply -----------------------------------------------------------------------------
case_mark "(31) mode apply"
reset
# The launched lead is alive (its new-session is in the log): the choice waits, no TeamLead died.
echo '[ "$s" != alfa-lead ] || ! grep -q -- "-s smk-alfa-lead" "$STUB_LOG" || exit 0' > "$WORK/hs.case"
export CANCEL_AT=8
run "$MAIN" $TR alfa; expect 6 "launched: TeamLead (fable/medium)" "(31) first start"
has "waiting for TeamLead: mode choice" "$WORK/out" || fail "(31) no mode-choice wait"
! has "TeamLead died" "$WORK/out" && ! has "-s smk-alfa-planner" "$STUB_LOG" || fail "(31) a stage launched, or the lead died"
[ "$(jq -r .mode "$TD/team.json")" = lead ] || fail "(31) the mode changed without a verdict"
LSID="$(jq -r .session_id "$TD/teamlead.json")"
V mode quick --message "small clear change"; expect 0 "teamlead-mode-1.json" "(31) the lead's mode verdict"
jq -e --arg s "$LSID" '.gate == "mode" and .verdict == "quick" and .message == "small clear change" and .session_id == $s' \
  "$RD/teamlead-mode-1.json" >/dev/null || fail "(31) verdict fields: $(cat "$RD/teamlead-mode-1.json")"
V mode cli --message "second thought"; expect 4 "mode already chosen" "(31) a second mode verdict"
again; echo alfa-lead > "$WORK/alive"
run "$MAIN" $TR alfa; expect 5 "mode: quick — TeamLead: small clear change" "(31) second start"
has "TeamLead reused: alfa-lead" "$WORK/out" && has "launched: planner attempt 1" "$WORK/out" \
  || fail "(31) the lead was not reused or the planner did not launch"
jq -e --arg s "$LSID" --arg v ".agents/team/runs/$RUN_ID/teamlead-mode-1.json" '.mode == "quick"
  and .mode_choice.by == "teamlead" and .mode_choice.reason == "small clear change"
  and .mode_choice.verdict == $v and .mode_choice.session_id == $s and (.mode_choice.at | length > 0)' \
  "$TD/team.json" >/dev/null || fail "(31) team.json: $(jq -c '{mode, mode_choice}' "$TD/team.json")"
AT="$(jq -r .mode_choice.at "$TD/team.json")"
run "$MAIN" $TR alfa status; expect 0 "mode: quick (TeamLead: small clear change)" "(31) status"
again; run "$MAIN" $TR alfa
[ "$(jq -r .mode_choice.at "$TD/team.json")" = "$AT" ] && ! has "mode: quick — TeamLead" "$WORK/out" \
  || fail "(31) a third start applied the verdict again"
# A remode keeps .mode_choice but starts a new run in a mode the Operator set: no TeamLead credit.
jq '.mode = "brainstorm"' "$TD/team.json" > "$WORK/tj" && mv "$WORK/tj" "$TD/team.json"
echo "alfa-20990101-000000" > "$TD/run"
run "$MAIN" $TR alfa status; expect 0 "mode: brainstorm (Operator)" "(31) status after a remode"
echo "team-smoke-27: (31) mode apply OK"

# ---- (31d) dead lead while choosing --------------------------------------------------------------
case_mark "(31d) dead lead while choosing"
reset; setmode lead; lead_json; echo alfa-lead > "$WORK/alive"; export CANCEL_AT=14
cat > "$WORK/hs.case" <<'HS'
if [ "$s" = alfa-lead ]; then
  c=$(( $(cat "$WORK/lead.n" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$WORK/lead.n"
  [ "$c" -ge 2 ] || exit 0
  exit 1
fi
HS
run "$MAIN" $TR alfa; expect 6 "TeamLead reused: alfa-lead" "(31d) runner"
[ "$(grep -cF "TeamLead died — /start-team alfa relaunches it" "$WORK/out" || true)" = 1 ] || fail "(31d) not exactly one died line"
[ "$(nsd)" = 1 ] && grep -q '^ref: .agents/team/teamlead.json' "$SUP"/* || fail "(31d) not exactly one session_dead"
! has "dead attempt" "$WORK/out" && ! has "-s smk-alfa-planner" "$STUB_LOG" || fail "(31d) a stage ran while choosing"
[ "$(jq -r .mode "$TD/team.json")" = lead ] || fail "(31d) the mode changed"
echo "team-smoke-27: (31d) dead lead while choosing OK"

# ---- (31x) lead at a startup dialog while choosing (team-smoke-dialog.sh) ------------------------
case_mark "(31x) lead at a startup dialog while choosing"
reset; setmode lead; lead_json; echo alfa-lead > "$WORK/alive"; export CANCEL_AT=12
mkdir -p "$REG"
jq -n '{address: "alfa-lead", kind: "team", backend: "tmux", name: "smk-alfa-lead", cli: "claude", session_id: "sid-lead"}' \
  > "$REG/alfa-lead.json"
printf ' Accessing workspace:\n\n /fixture/main-alfa\n\n Quick safety check: Is this a project you created or one you trust?\n\n Claude Code'"'"'ll be able to read, edit, and execute files here.\n\n ❯ 1. No, exit\n   2. Yes, I trust this folder\n\n Enter to confirm · Esc to cancel\n' \
  > "$WORK/pane.alfa-lead"
export STUB_ON_CAPTURE='a="$*"; a="${a##*=smk-}"; STUB_PANE="$WORK/pane.${a%%:*}"; [ -f "$STUB_PANE" ] || : > "$STUB_PANE"'
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: mode choice" "(31x) runner"
[ "$(grep -c "warn: alfa-lead: waiting at the folder trust dialog" "$WORK/out" || true)" = 1 ] || fail "(31x) not exactly one warn"
[ "$(ls "$OB/events" 2>/dev/null | grep -c "_alfa_${RUN_ID}_dialog-lead-1\.json$" || true)" = 1 ] \
  || { ls -la "$OB/events" > "$WORK/out" 2>&1 || true; fail "(31x) not exactly one human_decision"; }
jq -e '.event == "human_decision" and .decision == "dialog-lead-1"' "$OB/events/"*"_alfa_${RUN_ID}_dialog-lead-1.json" >/dev/null \
  || fail "(31x) event file"
[ "$(cat "$WORK/hs.n")" -ge 4 ] || fail "(31x) fewer than two polls: no dedup shown"
unset STUB_ON_CAPTURE; rm -f "$REG/alfa-lead.json"
echo "team-smoke-27: (31x) lead at a startup dialog while choosing OK"

# ---- (31r) restart before apply keeps the choosing conversation ----------------------------------
case_mark "(31r) restart before apply keeps the choosing conversation"
reset; setmode lead; lead_json
jq -n --arg r "$RUN_ID" --arg s "$S" '{team: "alfa", run: $r, gate: "mode", seq: 1, for: "", verdict: "cli",
  message: "one-line fix", session_id: $s, written_at: "2026-11-24T10:00:00Z"}' > "$RD/teamlead-mode-1.json"
run "$MAIN" $TR alfa; expect 5 "mode: cli — TeamLead: one-line fix" "(31r) runner"
! has "launched: TeamLead" "$WORK/out" && ! has "-s smk-alfa-lead" "$STUB_LOG" || fail "(31r) a judge launched for a choice already made"
[ "$(jq -r .mode_choice.session_id "$TD/team.json")" = "$S" ] || fail "(31r) mode_choice.session_id is not the verdict's"
grep -qF -- "claude --resume $S -n alfa-cli" <<<"$(cli_line)" || fail "(31r) the cli does not resume S: $(cli_line)"
echo "team-smoke-27: (31r) restart before apply OK"

# ---- (21r) chosen cli resumes the lead -----------------------------------------------------------
case_mark "(21r) chosen cli resumes the lead"
reset; setmode cli "$(choice)"; lead_json "$S"
run "$MAIN" $TR alfa; expect 5 "launched: cli attempt 1" "(21r) runner"
grep -qF -- "claude --resume $S -n alfa-cli --model 'fable' --effort 'medium' --permission-mode 'auto'" <<<"$(cli_line)" \
  || fail "(21r) cli launch: $(cli_line)"
! grep -qF -- "--session-id" <<<"$(cli_line)" || fail "(21r) a resumed cli also got --session-id"
[ "$(jq -r .session_id "$TD/session.json")" = "$S" ] || fail "(21r) session.json session_id is not S"
# Another Claude config dir than the choosing lead's: refused before session.json.
reset; setmode cli "$(choice "$WORK/other-config")"; lead_json "$S"
run "$MAIN" $TR alfa; expect 4 "another Claude config dir than the choosing TeamLead" "(21r) config dir mismatch"
[ ! -e "$TD/session.json" ] && ! has "-s smk-alfa-cli" "$STUB_LOG" || fail "(21r) a mismatched config dir launched"
echo "team-smoke-27: (21r) chosen cli resumes the lead OK"

# ---- (21h) handover ends the judge ---------------------------------------------------------------
case_mark "(21h) handover ends the judge"
reset; setmode cli "$(choice)"; lead_json "$S"; echo alfa-lead > "$WORK/alive"
run "$MAIN" $TR alfa; expect 5 "TeamLead judge ended" "(21h) runner"
[ -n "$(line_of 'kill-session -t =smk-alfa-lead')" ] && [ -n "$(line_of '-s smk-alfa-cli')" ] \
  && [ "$(line_of 'kill-session -t =smk-alfa-lead')" -lt "$(line_of '-s smk-alfa-cli')" ] \
  || { cp "$STUB_LOG" "$WORK/out"; fail "(21h) the judge was not ended before the cli launch"; }
echo "team-smoke-27: (21h) handover ends the judge OK"

export TEAM_SMOKE_NO_LEAD=1
# ---- (21m) fixed cli on an old cli prompt --------------------------------------------------------
case_mark "(21m) fixed cli on an old cli prompt"
reset; setmode cli
grep -vF -- /codex-review "$CLONE/.claude/team/prompts/cli.md" > "$WORK/cli.md" && cp "$WORK/cli.md" "$CLONE/.claude/team/prompts/cli.md"
run "$MAIN" $TR alfa; expect 5 "warn: clone base has the pre-#296 cli prompt" "(21m) runner"
has "launched: cli attempt 1" "$WORK/out" && grep -qF -- "--session-id" <<<"$(cli_line)" || fail "(21m) the fixed cli did not launch fresh"
git -C "$CLONE" checkout --quiet -- .claude/team/prompts/cli.md
run "$MAIN" $TR alfa status; expect 0 "mode: cli (Operator)" "(21m) status"
echo "team-smoke-27: (21m) fixed cli on an old cli prompt OK"

# ---- (21p) cli permission from the profile -------------------------------------------------------
case_mark "(21p) cli permission from the profile"
PROF="$MAIN/.claude/project-profile.json"; cp "$PROF" "$WORK/prof.keep"
jq '.teams.roles = {cli: {permission: "manual"}}' "$WORK/prof.keep" > "$PROF"
reset; setmode cli
run "$MAIN" $TR alfa; expect 5 "launched: cli attempt 1" "(21p) profile manual"
grep -qF -- "-n alfa-cli --model 'fable' --effort 'medium' --permission-mode 'manual'" <<<"$(cli_line)" || fail "(21p) $(cli_line)"
reset; run "$MAIN" $TR alfa roles cli=//auto; expect 0 '"cli":{"permission":"auto"}' "(21p) override"
: > "$STUB_LOG"; run "$MAIN" $TR alfa; expect 5 "launched: cli attempt 1" "(21p) override auto"
grep -qF -- "--permission-mode 'auto'" <<<"$(cli_line)" || fail "(21p) the override did not win: $(cli_line)"
cp "$WORK/prof.keep" "$PROF"
echo "team-smoke-27: (21p) cli permission from the profile OK"

# ---- (24q) merge check and summary in quick mode (team-smoke-3.sh (24)) --------------------------
case_mark "(24q) merge check and summary in quick mode"
reset; setmode quick
commit_file src/quick.txt quick; C1="$(git -C "$CLONE" rev-parse HEAD)"; git -C "$CLONE" push --quiet origin "$BR"
for r in planner coder qa; do mkrec "$r" "$C1"; done
printf 'Verdict: ready\nWarnings: none\nRethink signals: none\n' > "$RD/qa-report-1.md"
merge_at "$C1"
run "$MAIN" $MC alfa; expect 0 "VERDICT: ok" "(24q) merge check, no wrapup"
has "validated source=$C1" "$WORK/out" || fail "(24q) the PR source is not the qa output_rev"
commit_file late.txt late; git -C "$CLONE" push --quiet origin "$BR"
run "$MAIN" $MC alfa; expect 3 "is not the qa revision $C1" "(24q) a push past the qa"
point "$C1"
run "$MAIN" $TR alfa summary; expect 0 "--- qa" "(24q) summary"
! has "--- wrapup" "$WORK/out" || fail "(24q) a quick summary has a wrapup block"
jq '.role = "wrapup" | .verdict = "blocked"' "$RD/qa-1-1.json" > "$RD/wrapup-1-1.json"   # a stray record: never listed
run "$MAIN" $TR alfa status; expect 0 "qa: qa-1-1.json done accepted" "(24q) status"
has "planner: planner-1-1.json done accepted" "$WORK/out" && has "coder: coder-1-1.json done accepted" "$WORK/out" \
  && ! has "wrapup:" "$WORK/out" || fail "(24q) status does not list exactly planner coder qa"
rm -f "$RD/wrapup-1-1.json"
echo "team-smoke-27: (24q) merge check and summary in quick mode OK"

# ---- (24r) integration readiness in quick (unit) -------------------------------------------------
case_mark "(24r) integration readiness in quick"
ready() {  # ready <mode> → RC, $WORK/out
  set +e; (cd "$MAIN" && . .claude/lib/team-integrate-lib.sh && team_run_ready alfa "$CLONE" "$RUN_ID" "$1") > "$WORK/out" 2>&1
  RC=$?; set -e
}
ready quick; expect 0 "" "(24r) accepted done qa, no wrapup"
mv "$RD/qa-1-1.json.accepted" "$WORK/qa.acc"
ready quick; expect 3 "no accepted qa record" "(24r) no accepted qa"
mv "$WORK/qa.acc" "$RD/qa-1-1.json.accepted"; cp "$RD/qa-1-1.json" "$WORK/qa.keep"
jq '.verdict = "blocked"' "$WORK/qa.keep" > "$RD/qa-1-1.json"
ready quick; expect 3 "accepted qa record is not done" "(24r) qa blocked"
cp "$WORK/qa.keep" "$RD/qa-1-1.json"
session qa 1 "$C1"; ready quick; expect 3 "a role is still live (qa)" "(24r) a live session.json"
rm -f "$TD/session.json"
echo "team-smoke-27: (24r) integration readiness in quick OK"

# ---- (24w) a pre-upgrade quick run keeps its wrapup ----------------------------------------------
case_mark "(24w) a pre-upgrade quick run keeps its wrapup"
grep -vF -- 'In mode `quick` no wrapup follows you' "$CLONE/.claude/team/prompts/qa.md" > "$WORK/qa.md" \
  && cp "$WORK/qa.md" "$CLONE/.claude/team/prompts/qa.md"
[ "$(. "$SRC/.claude/lib/team-modes.sh"; team_mode_roles quick "$CLONE")" = "planner coder qa wrapup" ] \
  || fail "(24w) team_mode_roles quick on an old clone"
jq '.role = "wrapup" | .verdict = "blocked"' "$RD/qa-1-1.json" > "$RD/wrapup-1-1.json"
run "$MAIN" $TR alfa status; expect 0 "wrapup: wrapup-1-1.json blocked" "(24w) status lists the wrapup"
rm -f "$RD/wrapup-1-1.json"
ready quick; expect 3 "wrapup not done" "(24w) readiness needs the wrapup"
again; run "$MAIN" $TR alfa; expect 5 "launched: wrapup attempt 1" "(24w) the runner launches the wrapup"
[ "$(jq -r .role "$TD/session.json")" = wrapup ] || fail "(24w) no wrapup session.json"
again; run "$MAIN" $TR alfa; expect 5 "dead attempt 1 of wrapup" "(24w) a wrapup session.json resumes"
rm -f "$TD/session.json"; mkrec wrapup "$C1"
ready quick; expect 0 "" "(24w) readiness with the accepted wrapup"
git -C "$CLONE" checkout --quiet -- .claude/team/prompts/qa.md
echo "team-smoke-27: (24w) a pre-upgrade quick run keeps its wrapup OK"

# ---- (24f) quick acceptance refuses a follow-up disposition (team-smoke-23.sh fixture) -----------
case_mark "(24f) quick acceptance refuses a follow-up disposition"
reset; setmode quick; lead_json
mkrec planner "$C1"; mkrec coder "$C1"; mkrec qa "$C1"; rm -f "$RD/qa-1-1.json.accepted"; session qa 1 "$C1"
printf 'run: %s\nattempt: 1\noutput_rev: %s\nVerdict: ready-with-warnings\nWarnings: flaky e2e\nRethink signals: none\n' \
  "$RUN_ID" "$C1" > "$RD/qa-report-1.md"
echo "- export button → src/quick.txt" > "$RD/blind-check.md"
brief() {  # brief <warnings line> [ordered line] — the acceptance brief, written after the blind check
  { echo "## Ordered vs delivered"; printf '%s\n' "${2:-- export button → src/quick.txt}"
    echo; echo "## Scope delta"; echo "none"; echo; echo "## Fit risks"; echo "none"
    echo; echo "## Open defects"; echo "none"; echo; echo "## Warnings"; printf '%s\n' "$1"
    echo; echo "## Recommendation"; echo "accept"; } > "$RD/acceptance-brief.md"
}
brief "- flaky e2e → follow-up — tracked as a test-infra ticket"
V acceptance accept --for qa-1-1.json --message ok
expect 8 "quick has no wrapup: 'flaky e2e' needs keep or fix, not follow-up" "(24f) quick follow-up"
[ ! -e "$RD/teamlead-acceptance-1.json" ] || fail "(24f) a refused accept wrote a verdict"
# Cut ordered work routed to a ticket is refused the same way: no wrapup would create it.
brief "- flaky e2e → keep — known flake, retried green" "- export button → follow-up — cut: past the appetite"
V acceptance accept --for qa-1-1.json --message ok
expect 8 "quick has no wrapup: '- export button → follow-up — cut: past the appetite' needs keep or fix" "(24f) quick cut follow-up"
[ ! -e "$RD/teamlead-acceptance-1.json" ] || fail "(24f) a refused cut accept wrote a verdict"
brief "- flaky e2e → keep — known flake, retried green"
V acceptance accept --for qa-1-1.json --message ok; expect 0 "teamlead-acceptance-1.json" "(24f) quick keep"
rm -f "$RD/teamlead-acceptance-1.json"; setmode brainstorm
brief "- flaky e2e → follow-up — tracked as a test-infra ticket"
V acceptance accept --for qa-1-1.json --message ok; expect 0 "teamlead-acceptance-1.json" "(24f) brainstorm follow-up"
rm -f "$TD/session.json"
echo "team-smoke-27: (24f) quick acceptance refuses a follow-up disposition OK"

# ---- (34) dashboard in a chosen-cli run ----------------------------------------------------------
case_mark "(34) dashboard in a chosen-cli run"
mkdir -p "$WORK/claude"; echo '{"type":"assistant","message":{"model":"m"}}' > "$WORK/claude/s1.jsonl"
export TEAM_DASH_PROJECT_DIR="$WORK/claude" TEAM_DASH_SESSION=s1
TEAM='.teams[] | select(.team == "alfa")'
# Control: a quick run with its lead — the lead's pending list and window.
reset; setmode quick "$(choice)"; lead_json "$S"; mkrec qa "$C1" blocked
snap "(34) quick lead run" "$TEAM | .lead == true and (.roles[] | select(.role == \"qa\") | .status == \"blocked\"
  and .actions == [\"bash .claude/lib/team-lead.sh pending alfa\", \"bash .claude/lib/session-host.sh hint alfa-lead\"])"
reset; setmode cli "$(choice)"; lead_json "$S"; mkrec cli "$C1" blocked
snap "(34) chosen cli run" "$TEAM | .lead == false and (.roles[] | select(.role == \"cli\") | .status == \"blocked\"
  and .actions == [\"bash .claude/lib/session-host.sh hint alfa-cli\", \"/start-team alfa\"])"
unset TEAM_DASH_PROJECT_DIR TEAM_DASH_SESSION
echo "team-smoke-27: (34) dashboard in a chosen-cli run OK"
echo "team-smoke-27: OK"
