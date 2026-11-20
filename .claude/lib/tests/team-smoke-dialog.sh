#!/usr/bin/env bash
# The runner's startup-dialog watch (team-run-dialog.sh): a stage held at Claude's folder trust dialog
# → one warn: line, a status line, one human_decision event, no attempt spent and no stall while it
# is open; a resumed runner sends nothing twice; once the dialog is gone the event is resolved and
# the clock counts again. The same for the TeamLead. No alarm for a session that is simply starting,
# nor for one past its start whose screen shows the dialog's words. Herdr: the program's status and
# its screen, the team's tab in the hint.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

smoke_team AB-1500 feature/AB-1500-x
RUN_ID=alfa-20261116-020000; RD="$TD/runs/$RUN_ID"
REG="$(cd "$MAIN" && pwd -P)/.agents/team/registry"; OB="$HOME/.agent-comms/outbox"
export WORK TD REG
prof() { jq "$1" "$MAIN/.claude/project-profile.json" > "$WORK/p" && mv "$WORK/p" "$MAIN/.claude/project-profile.json"; }

# has-session from files: $WORK/alive lists live addresses; a killed session is dead.
cat > "$WORK/hs.sh" <<'HS'
s="${3#=}"; s="${s#smk-}"
! grep -q -- "kill-session -t =smk-$s\$" "$STUB_LOG" || exit 1
grep -qx -- "$s" "$WORK/alive" 2>/dev/null && exit 0
exit 1
HS
export STUB_ON_HAS_SESSION=". '$WORK/hs.sh'"
# Each address has its own screen: $WORK/pane.<address>.
export STUB_ON_CAPTURE='a="$*"; a="${a##*=smk-}"; STUB_PANE="$WORK/pane.${a%%:*}"; [ -f "$STUB_PANE" ] || : > "$STUB_PANE"'
# The fixture clock (+5000 s a call); past $GONE_AT the session reports a status (the dialog was
# accepted: its hooks run), past $CANCEL_AT the runner is stopped.
echo 1000000 > "$WORK/clock"
export TEAM_NOW_CMD='n=$(cat "$WORK/clock"); echo $((n + 5000)) > "$WORK/clock"
  [ -z "${GONE_AT:-}" ] || [ "$n" -lt "$GONE_AT" ] || [ -z "${GONE_WHO:-}" ] \
    || { mkdir -p "$REG/state"; jq -n --arg s "sid-$GONE_WHO" "{state: \"working\", session_id: \$s}" > "$REG/state/$GONE_WHO.json"
         [ "${GONE_HC:-}" != 1 ] || echo working > "$WORK/hc.status"; }
  [ -z "${CANCEL_AT:-}" ] || [ "$n" -lt "$CANCEL_AT" ] || touch "$TD/cancel"
  echo "$n"'

cat > "$WORK/trust" <<'EOF'
 Accessing workspace:

 /fixture/main-alfa

 Quick safety check: Is this a project you created or one you trust?

 Claude Code'll be able to read, edit, and execute files here.

 ❯ 1. No, exit
   2. Yes, I trust this folder

 Enter to confirm · Esc to cancel
EOF
printf ' ✻ Welcome to Claude Code!\n\n   /help for help, /status for your current setup\n' > "$WORK/welcome"

record() {  # record <address> <backend> [handle] — the driver's record of a started session
  mkdir -p "$REG"
  jq -n --arg a "$1" --arg b "$2" --arg h "${3:-}" '{address: $a, kind: "team", backend: $b, name: ("smk-" + $a),
    cli: "claude", session_id: ("sid-" + $a)} + (if $h != "" then {handle: $h} else {} end)' > "$REG/$1.json"
}
reset() {  # reset — a fresh run state and outbox between runner invocations
  rm -rf "$TD/lock" "$TD/cancel" "$TD/acked" "$TD/runs" "$TD/session.json" "$TD/teamlead.json" "$OB" \
    "$REG/state" "$WORK"/pane.* "$WORK/hc.status"
  : > "$STUB_LOG"; : > "$WORK/alive"; echo 1000000 > "$WORK/clock"
  unset CANCEL_AT GONE_AT GONE_WHO GONE_HC
  echo "$RUN_ID" > "$TD/run"; mkdir -p "$RD"
}
nev() { ls "$OB/events" 2>/dev/null | grep -c "_alfa_${RUN_ID}_$1\.json$" || true; }
resolved() { ls "$OB/state" 2>/dev/null | grep -q "_alfa_${RUN_ID}_$1\.resolved$"; }
WARN="warn: alfa-qa: waiting at the folder trust dialog — pick 'Yes, I trust this folder' (Enter alone exits) in tmux attach -t smk-alfa-qa"

# ---- (1) a stage at the trust dialog: warn, status, one event, no attempt spent, no stall -------------
reset; record alfa-qa tmux; echo alfa-qa > "$WORK/alive"; session qa 1 "$BASE"; cp "$WORK/trust" "$WORK/pane.alfa-qa"
export CANCEL_AT=1200000   # ~20 polls past the qa limit (10800 s), all at the dialog
run "$MAIN" $TR alfa; expect 6 "cancelled by stop" "(1) runner at the dialog"
[ "$(grep -cF -- "$WARN" "$WORK/out")" = 1 ] || fail "(1) not exactly one warn line"
! has "stalled" "$WORK/out" || fail "(1) the dialog counted as a stall"
! has "dead attempt" "$WORK/out" && ! has "-s smk-alfa-qa" "$STUB_LOG" || fail "(1) an attempt was spent"
[ "$(jq -r .attempt "$TD/session.json")" = 1 ] || fail "(1) session.json attempt moved"
[ "$(nev dialog-qa-1)" = 1 ] || { ls -la "$OB/events" > "$WORK/out" 2>&1 || true; fail "(1) not exactly one event"; }
jq -e '.event == "human_decision" and .team == "alfa" and .decision == "dialog-qa-1" and .source == "runner"
  and .answer.address == "alfa-qa" and .answer.hint == "tmux attach -t smk-alfa-qa"' \
  "$OB/events/"*"_alfa_${RUN_ID}_dialog-qa-1.json" >/dev/null || fail "(1) event file"
[ "$(cat "$RD/dialog-qa")" = dialog-qa-1 ] || fail "(1) no dialog marker"
: > "$STUB_LOG"   # the cancel ended the session; the status case reads it alive again
run "$MAIN" $TR alfa status; expect 0 "tmux: alfa-qa waiting at the folder trust dialog — pick 'Yes, I trust this folder'" "(1) status line"
! has "alfa-qa alive" "$WORK/out" || fail "(1) status still says alive"
echo "team-smoke-dialog: (1) stage at the trust dialog OK"

# ---- (2) a resumed runner: no second event; the dialog goes → resolved, the clock counts again -------
rm -f "$TD/cancel" "$TD/lock"; : > "$STUB_LOG"; unset CANCEL_AT
export GONE_WHO=alfa-qa GONE_AT=1100000 CANCEL_AT=1400000   # the net: a dialog that never goes fails, never hangs
run "$MAIN" $TR alfa; expect 3 "stalled" "(2) the limit counts after the dialog"
[ "$(nev dialog-qa-1)" = 1 ] || fail "(2) a resumed runner sent a second event"
has "startup dialog gone: alfa-qa" "$WORK/out" || fail "(2) no gone line"
resolved dialog-qa-1 || { ls -la "$OB/state" > "$WORK/out" 2>&1 || true; fail "(2) the event was not resolved"; }
[ ! -e "$RD/dialog-qa" ] || fail "(2) dialog marker left"
[ "$(cat "$WORK/clock")" -gt 1110000 ] || fail "(2) stalled before the dialog was gone"
[ "$(grep -n 'startup dialog gone' "$WORK/out" | cut -d: -f1)" -lt "$(grep -n stalled "$WORK/out" | cut -d: -f1)" ] \
  || fail "(2) stalled before the gone line"
: > "$STUB_LOG"; run "$MAIN" $TR alfa status; expect 0 "tmux: alfa-qa alive" "(2) status after the dialog"
echo "team-smoke-dialog: (2) resume + dialog gone OK"

# ---- (3) no false alarm: a session simply starting, and one past its start ----------------------------
reset; record alfa-qa tmux; echo alfa-qa > "$WORK/alive"; session qa 1 "$BASE"; cp "$WORK/welcome" "$WORK/pane.alfa-qa"
run "$MAIN" $TR alfa; expect 3 "stalled" "(3) a starting session is no dialog"
! has "warn: alfa-qa" "$WORK/out" && [ "$(nev dialog-qa-1)" = 0 ] && [ ! -e "$RD/dialog-qa" ] || fail "(3) alarm for a starting session"
reset; record alfa-qa tmux; echo alfa-qa > "$WORK/alive"; session qa 1 "$BASE"; cp "$WORK/trust" "$WORK/pane.alfa-qa"
mkdir -p "$REG/state"; echo '{"state": "working", "session_id": "sid-alfa-qa"}' > "$REG/state/alfa-qa.json"
run "$MAIN" $TR alfa; expect 3 "stalled" "(3) a session past its start"
! has "warn: alfa-qa" "$WORK/out" && [ "$(nev dialog-qa-1)" = 0 ] || fail "(3) the dialog's words on a working screen alarmed"
echo "team-smoke-dialog: (3) no false alarm OK"

# ---- (4) the TeamLead at the trust dialog: warn, status, one event, resolved when gone ---------------
unset TEAM_SMOKE_NO_LEAD
mkdir -p "$CLONE/.claude/hooks" "$MAIN/.claude/team/sessions"
cp "$SRC/.claude/team/sessions/TeamLead.settings.json" "$MAIN/.claude/team/sessions/"
cp "$SRC/.claude/hooks/guard-teamlead-write.sh" "$SRC/.claude/hooks/guard-teamlead-bash.sh" "$CLONE/.claude/hooks/"
printf '## Ticket\nExport.\n\n## Not ordered\nnone stated\n\n## In-flight work\n- none\n' > "$WORK/brief.md"
run "$MAIN" bash .claude/lib/team-brief.sh write alfa "$WORK/brief.md"; expect 0 "" "(4) fixture brief"
reset; record alfa-lead tmux; record alfa-planner tmux; printf 'alfa-lead\nalfa-planner\n' > "$WORK/alive"
jq -n --arg r "$RUN_ID" --arg m "$MAIN" '{team: "alfa", run: $r, session_id: "sid-alfa-lead", launch: 1, main_root: $m}' > "$TD/teamlead.json"
session planner 1 "$BASE"; cp "$WORK/trust" "$WORK/pane.alfa-lead"; cp "$WORK/welcome" "$WORK/pane.alfa-planner"
export CANCEL_AT=1100000
run "$MAIN" $TR alfa; expect 6 "TeamLead reused: alfa-lead" "(4) runner, lead at the dialog"
[ "$(grep -c "warn: alfa-lead: waiting at the folder trust dialog" "$WORK/out")" = 1 ] || fail "(4) not exactly one lead warn"
! has "warn: alfa-planner" "$WORK/out" || fail "(4) the starting planner alarmed"
[ "$(nev dialog-lead-1)" = 1 ] && [ "$(nev dialog-planner-1)" = 0 ] || fail "(4) not exactly one lead event"
: > "$STUB_LOG"; run "$MAIN" $TR alfa status
expect 0 "teamlead: waiting at the folder trust dialog — pick 'Yes, I trust this folder' (Enter alone exits) in tmux attach -t smk-alfa-lead — session sid-alfa-lead" "(4) lead status line"
rm -f "$TD/cancel" "$TD/lock"; : > "$STUB_LOG"; echo 1000000 > "$WORK/clock"
export GONE_WHO=alfa-lead GONE_AT=1040000 CANCEL_AT=1100000
run "$MAIN" $TR alfa; expect 6 "startup dialog gone: alfa-lead" "(4) lead dialog gone"
[ "$(nev dialog-lead-1)" = 1 ] && resolved dialog-lead-1 && [ ! -e "$RD/dialog-lead" ] || fail "(4) the lead event not resolved once"
echo "team-smoke-dialog: (4) TeamLead at the trust dialog OK"
export TEAM_SMOKE_NO_LEAD=1

# ---- (5) Herdr: no program status + the dialog on screen; the tab in the hint; status wording --------
reset; record alfa-qa herdr t7q; session qa 1 "$BASE"; echo null > "$WORK/hc.status"
export STUB_HC_ADDR=t7q STUB_HC_STATUS_FILE="$WORK/hc.status" STUB_HC_SCREEN="$WORK/trust"
run "$MAIN" $TR alfa status
expect 0 "herdr: alfa-qa waiting at the folder trust dialog — pick 'Yes, I trust this folder' (Enter alone exits) in hc attach t7q · herdr: smk-alfa-qa (in the agent list once placed), tab alfa" "(5) herdr status"
export GONE_WHO=alfa-qa GONE_AT=1100000 GONE_HC=1 CANCEL_AT=1400000
run "$MAIN" $TR alfa; expect 3 "stalled" "(5) herdr runner: the limit counts after the dialog"
has "warn: alfa-qa: waiting at the folder trust dialog" "$WORK/out" && has "startup dialog gone: alfa-qa" "$WORK/out" \
  && [ "$(cat "$WORK/clock")" -gt 1110000 ] || fail "(5) herdr warn, gone line or an early stall"
[ "$(nev dialog-qa-1)" = 1 ] && resolved dialog-qa-1 || fail "(5) herdr event not resolved once"
jq -e '.answer.backend == "herdr" and .answer.handle == "t7q"' "$OB/events/"*"_alfa_${RUN_ID}_dialog-qa-1.json" >/dev/null || fail "(5) event backend"
rm -f "$TD/cancel" "$TD/lock"; run "$MAIN" $TR alfa status; expect 0 "herdr: alfa-qa alive" "(5) herdr status alive"
! has "tmux: alfa-qa" "$WORK/out" || fail "(5) a herdr session labelled tmux"
unset STUB_HC_ADDR STUB_HC_STATUS_FILE STUB_HC_SCREEN
echo "team-smoke-dialog: (5) herdr OK"
echo "team-smoke-dialog: OK"
