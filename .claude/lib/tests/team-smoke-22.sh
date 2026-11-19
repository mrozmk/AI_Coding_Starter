#!/usr/bin/env bash
# per-run TeamLead lifecycle in the runner: launch before the planner, reuse, wait in place on a
# stop, doorbell (socket and logged skip), dead lead → session_dead once → relaunch, inbox rings,
# execution-time limit paused while waiting, old base, cli, end/finalize, team-watch filter, and
# the run-scoped root files archived by team-next; the TeamLead's answers on an authority
# (human-only first, production asks, never-waived refusals, answers.md, the .answered marker).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

smoke_team AB-1500 feature/AB-1500-x
L="$SRC/.claude/lib"
RUN_ID=alfa-20261114-100000; RD="$TD/runs/$RUN_ID"
SUP="$MAIN/.agents/team/inbox/Supervisor/new"
export WORK TD
prof() { jq "$1" "$MAIN/.claude/project-profile.json" > "$WORK/p" && mv "$WORK/p" "$MAIN/.claude/project-profile.json"; }
mkdir -p "$MAIN/.claude/team/sessions" "$CLONE/.claude/hooks"
cp "$SRC/.claude/team/sessions/TeamLead-run.settings.json" "$MAIN/.claude/team/sessions/"
cp "$SRC/.claude/hooks/guard-teamlead-write.sh" "$SRC/.claude/hooks/guard-teamlead-bash.sh" "$CLONE/.claude/hooks/"
# The doorbell's socket sender, from the main checkout (the seed carries only team-*.sh).
cp "$SRC/.claude/lib/team-watch-send.py" "$MAIN/.claude/lib/"
printf '## Ticket\nExport.\n\n## Not ordered\nnone stated\n\n## In-flight work\n- none\n' > "$WORK/brief.md"
run "$MAIN" bash .claude/lib/team-brief.sh write alfa "$WORK/brief.md"; expect 0 "" "fixture brief"

# has-session is answered from files: $WORK/alive lists live sessions, a killed one is dead,
# $WORK/hs.case adds per-case behaviour, CANCEL_AT stops the runner after that many calls.
cat > "$WORK/hs.sh" <<'HS'
n=$(( $(cat "$WORK/hs.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/hs.n"
s="${3#=}"; s="${s#smk-}"   # alive lists and cases name addresses; tmux names carry smk-
[ -z "${CANCEL_AT:-}" ] || [ "$n" -lt "$CANCEL_AT" ] || touch "$TD/cancel"
[ ! -f "$WORK/hs.case" ] || . "$WORK/hs.case"
! grep -q -- "kill-session -t =smk-$s\$" "$STUB_LOG" || exit 1
grep -qx -- "$s" "$WORK/alive" 2>/dev/null && exit 0
exit 1
HS
export STUB_ON_HAS_SESSION=". '$WORK/hs.sh'"
LREG="$MAIN/.agents/team/registry/alfa-lead.reg.json"   # the lead's doorbell registration (main registry)
reset() {  # reset — a fresh run state between runner invocations
  rm -rf "$TD/lock" "$TD/cancel" "$TD/acked" "$TD/runs" "$TD/session.json" "$TD/teamlead.json" \
    "$LREG" "$MAIN/.agents/team/registry/state/alfa-lead.json" "$TD/lead-dead" "$TD/relaunch-lead" "$TD/send-lead.log" \
    "$MAIN/.agents/team/inbox" "$WORK/hs.n" "$WORK/hs.case" "$WORK/lead.n" "$WORK/relaunched"
  : > "$STUB_LOG"; : > "$WORK/alive"; unset CANCEL_AT
  echo "$RUN_ID" > "$TD/run"; mkdir -p "$RD"
}
lead_json() { jq -n --arg r "$RUN_ID" --arg m "$MAIN" \
  '{team: "alfa", run: $r, session_id: "sid-lead", main_root: $m}' > "$TD/teamlead.json"; }
line_of() { grep -n -- "$1" "$STUB_LOG" | head -n 1 | cut -d: -f1; }
TR="bash .claude/lib/team-run.sh"

# ---- (a) fixture seam: no lead, unchanged launch order -------------------------------------------
reset
run "$MAIN" $TR alfa; expect 5 "dead attempt" "(a) runner, no-lead seam"
has "-s smk-alfa-lead" "$STUB_LOG" && fail "(a) a lead launched under the no-lead seam"
has "-s smk-alfa-planner" "$STUB_LOG" || fail "(a) the planner did not launch"
[ ! -e "$TD/teamlead.json" ] && [ ! -d "$SUP" ] || fail "(a) lead state or events under the seam"
# The seam is honoured only under the smoke marker: without it a brainstorm run has its lead.
( unset TEAM_SMOKE; export TEAM_SMOKE_NO_LEAD=1 MODE=brainstorm
  . "$SRC/.claude/lib/team-run-lead.sh"; team_lead_on ) \
  || fail "(a) TEAM_SMOKE_NO_LEAD without TEAM_SMOKE switched the lead off"
( export MODE=cli; unset TEAM_SMOKE_NO_LEAD; . "$SRC/.claude/lib/team-run-lead.sh"; team_lead_on ) \
  && fail "(a) mode cli has a lead"
echo "team-smoke-22: (a) no-lead seam OK"

unset TEAM_SMOKE_NO_LEAD

# ---- (c) no brief → exit 4, no lead --------------------------------------------------------------
reset; mv "$TD/order-brief.md" "$WORK/placed-brief.md"
run "$MAIN" $TR alfa; expect 4 "no order brief" "(c) no brief"
has "-s alfa-" "$STUB_LOG" && fail "(c) a session launched without a brief"
[ ! -e "$TD/teamlead.json" ] || fail "(c) teamlead.json without a brief"
mv "$WORK/placed-brief.md" "$TD/order-brief.md"
echo "team-smoke-22: (c) brief required OK"

# ---- (g) old base (no teamlead.md in the clone) → exit 4 -----------------------------------------
reset; mv "$CLONE/.claude/team/prompts/teamlead.md" "$WORK/tl.md"
run "$MAIN" $TR alfa; expect 4 "team-next onto a current line" "(g) old base"
has "-s alfa-" "$STUB_LOG" && fail "(g) a session launched on an old base"
mv "$WORK/tl.md" "$CLONE/.claude/team/prompts/teamlead.md"
echo "team-smoke-22: (g) old base OK"

# ---- (b) brainstorm: the lead launches first, with its profile -----------------------------------
reset
run "$MAIN" $TR alfa; expect 5 "launched: TeamLead (fable/high)" "(b) runner, brainstorm"
[ -n "$(line_of '-s smk-alfa-lead')" ] && [ -n "$(line_of '-s smk-alfa-planner')" ] \
  && [ "$(line_of '-s smk-alfa-lead')" -lt "$(line_of '-s smk-alfa-planner')" ] || fail "(b) lead not before the planner"
for x in "/main-alfa/.agents/team/teamlead.settings.json' " "--model 'fable' --effort 'high'" \
  "--disallowedTools AskUserQuestion -- " "-e TEAM_SESSION_ROLE=TeamLead"; do
  grep -- "-s smk-alfa-lead" "$STUB_LOG" | grep -qF -- "$x" || fail "(b) lead launch lacks: $x"
done
jq -e --arg r "$RUN_ID" '.run == $r and .model == "fable" and (.main_root | length > 0)' \
  "$TD/teamlead.json" >/dev/null || fail "(b) teamlead.json"
[ -s "$RD/lead-1.session" ] && [ -f "$RD/lead-1.prompt.md" ] && [ -f "$RD/order-brief.md" ] \
  || fail "(b) lead-1 session/prompt or frozen brief missing"
has "$RUN_ID" "$RD/lead-1.prompt.md" && ! grep -q '{{' "$RD/lead-1.prompt.md" || fail "(b) prompt not rendered"
[ "$(ls "$SUP" | wc -l | tr -d ' ')" = 1 ] && grep -q '^event: session_dead' "$SUP"/* \
  && grep -q "^ref: runs/$RUN_ID/planner-" "$SUP"/* || fail "(b) dead planner: no single session_dead"
echo "team-smoke-22: (b) launch OK"

# ---- (b2) Herdr: the lead's terminal into its team's tab through the main checkout's roles.sh place
reset; RB="$MAIN/.claude/lib/roles.sh"; rm -f "$WORK/roles.main"; [ ! -f "$RB" ] || cp "$RB" "$WORK/roles.main"
printf '#!/usr/bin/env bash\necho "PLACE $*" >> "$STUB_LOG"\n' > "$RB"
RGD="$(cd "$MAIN" && pwd -P)/.agents/team/registry"; rm -rf "$WORK/reg.keep"; mkdir -p "$RGD"; cp -R "$RGD" "$WORK/reg.keep"
TEAM_SESSION_HOST=herdr STUB_HC_NONAME=1 STUB_HC_STATE=finished run "$MAIN" $TR alfa
grep -qx 'PLACE place alfa-lead' "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(b2) the lead was not placed"; }
if [ -f "$WORK/roles.main" ]; then cp "$WORK/roles.main" "$RB"; else rm -f "$RB"; fi
rm -rf "$RGD"; cp -R "$WORK/reg.keep" "$RGD"   # the herdr records of this case go
echo "team-smoke-22: (b2) herdr lead placement OK"

# ---- (d) a blocked record keeps the runner waiting; the lead is rung over its socket -------------
cat > "$WORK/srv.py" <<'PY'
import os, socket, sys
path, out = sys.argv[1:3]
if os.path.exists(path):
    os.unlink(path)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(path); os.chmod(path, 0o600); s.listen(16)
while True:
    c, _ = s.accept(); c.settimeout(5); data = b""
    try:
        while True:
            b = c.recv(65536)
            if not b:
                break
            data += b
    except OSError:
        pass
    c.close()
    with open(out, "ab") as f:
        f.write(data)
PY
SD="$(mktemp -d /tmp/tl.XXXXXX)"   # macOS caps a unix socket path at 104 bytes
trap '[ -z "$SPID" ] || kill "$SPID" 2>/dev/null || true; rm -rf "$WORK" "$SD"' EXIT
python3 -I "$WORK/srv.py" "$SD/l.sock" "$WORK/recv" & SRV=$!; SPID="$SRV"
for _ in $(seq 1 50); do [ -S "$SD/l.sock" ] && break; sleep 0.1; done
[ -S "$SD/l.sock" ] || fail "(d) stub socket did not bind"
reset; lead_json; printf 'alfa-lead\nalfa-planner\n' > "$WORK/alive"
mkdir -p "$(dirname "$LREG")"; jq -n --arg s "$SD/l.sock" '{socket: $s, token: "t", pid: null}' > "$LREG"
session planner 1 "$BASE"; mkrec planner "$BASE" blocked
jq '.message = "which endpoint?"' "$RD/planner-1-1.json" > "$WORK/r" && mv "$WORK/r" "$RD/planner-1-1.json"
mkdir -p "$MAIN/.agents/team/inbox/alfa/new"; echo x > "$MAIN/.agents/team/inbox/alfa/new/20261114T100500Z-Supervisor-collision-answer.md"
export CANCEL_AT=15
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: planner-1-1.json" "(d) runner on a stop"
has "TeamLead reused: alfa-lead" "$WORK/out" || fail "(d) the live lead of this run was not reused"
has "-s smk-alfa-lead" "$STUB_LOG" && fail "(d) a live lead was launched again"
[ "$(cat "$TD/acked")" = planner-1-1.json ] || fail "(d) record not acked"
for _ in $(seq 1 30); do grep -q 'stop planner 1' "$WORK/recv" 2>/dev/null && break; sleep 0.1; done
touch "$WORK/recv"
[ "$(grep -o 'stop planner 1: [^"]*which endpoint' "$WORK/recv" | wc -l | tr -d ' ')" = 1 ] \
  || { { cat "$WORK/recv"; cat "$TD/send-lead.log" 2>/dev/null; } >> "$WORK/out"; fail "(d) not exactly one stop doorbell"; }
# ---- (j) the runner no longer rings inbox files; team-inbox.sh write rings the lead once ----------
grep -q 'inbox: 20261114T100500Z' "$WORK/recv" && { cp "$WORK/recv" "$WORK/out"; fail "(j) the runner rang an inbox file"; }
[ ! -e "$TD/inbox-rung" ] || fail "(j) the runner wrote inbox-rung"
run "$MAIN" bash .claude/lib/team-inbox.sh write alfa collision-answer --from Supervisor --ticket AB-1500 --run "$RUN_ID"
expect 0 "ring: 0" "(j) a write to the team"
for _ in $(seq 1 30); do grep -q 'inbox: collision-answer Supervisor' "$WORK/recv" 2>/dev/null && break; sleep 0.1; done
[ "$(grep -o 'inbox: collision-answer Supervisor AB-1500' "$WORK/recv" | wc -l | tr -d ' ')" = 1 ] \
  || { cp "$WORK/recv" "$WORK/out"; fail "(j) the write did not ring the lead exactly once"; }
# A blocked lead: the ring is refused (9), the file stays in new/, write exits 0.
LRS="$(jq -r '.session_id // empty' "$MAIN/.agents/team/registry/alfa-lead.json" 2>/dev/null)"
mkdir -p "$MAIN/.agents/team/registry/state"
jq -n --arg s "$LRS" '{state: "blocked", kind: "permission", session_id: $s}' > "$MAIN/.agents/team/registry/state/alfa-lead.json"
run "$MAIN" bash .claude/lib/team-inbox.sh write alfa message --from Supervisor --ticket AB-1500 --run "$RUN_ID"
expect 0 "ring: 9" "(j) a blocked lead"
[ -f "$(head -n 1 "$WORK/out")" ] || fail "(j) a refused ring lost the file"
rm -f "$MAIN/.agents/team/registry/state/alfa-lead.json"
# Sender rules to the Supervisor; a role or team address takes any event.
TI="bash .claude/lib/team-inbox.sh"
run "$MAIN" $TI write Supervisor message --from Fable --message hi; expect 0 "" "(j) a role sends a message"
run "$MAIN" $TI write Supervisor advice --from adhoc-dev-1; expect 0 "" "(j) an ad-hoc session sends advice"
run "$MAIN" $TI write Supervisor message --from alfa; expect 2 "from a team, not message" "(j) a team sends a message"
run "$MAIN" $TI write Supervisor collision --from zzz; expect 2 "is no team, declared role or adhoc-*" "(j) an unknown sender"
run "$MAIN" $TI write Supervisor collision --from alfa; expect 0 "" "(j) a team sends a collision"
run "$MAIN" $TI write alfa collision --from Supervisor; expect 0 "" "(j) the Supervisor writes to a team"
run "$MAIN" bash .claude/lib/team-lead.sh pending alfa
expect 0 "stop .agents/team/runs/$RUN_ID/planner-1-1.json — which endpoint?" "(d) pending lists the stop"
grep -q '^inbox .*/main/.agents/team/inbox/alfa/new/20261114T100500Z' "$WORK/out" || fail "(d) pending lacks the inbox file"
# (d2) pending lists this run's and run-less messages only; a done message is gone from it.
grep -q "^inbox .*-Supervisor-collision-answer.md — collision-answer" "$WORK/out" || fail "(d2) this run's message missing"
run "$MAIN" $TI write alfa message --from Supervisor --run alfa-20000101-000000; OLD="$(head -n 1 "$WORK/out")"
run "$MAIN" $TI done alfa 20261114T100500Z-Supervisor-collision-answer.md; expect 0 "/inbox/alfa/done/" "(d2) done"
run "$MAIN" bash .claude/lib/team-lead.sh pending alfa
grep -q '20261114T100500Z' "$WORK/out" && fail "(d2) pending still lists a done message"
grep -qF "$(basename "$OLD")" "$WORK/out" && fail "(d2) pending lists another run's message"
grep -q "^inbox .*-Supervisor-collision-answer.md — collision-answer" "$WORK/out" || fail "(d2) this run's message lost"
kill "$SRV" 2>/dev/null || true; SPID=""
# Without a registration the doorbell is skipped and logged (pane not idle).
reset; lead_json; printf 'alfa-lead\nalfa-planner\n' > "$WORK/alive"
session planner 1 "$BASE"; mkrec planner "$BASE" failed; export CANCEL_AT=8
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead" "(d) failed record, no socket"
[ "$(grep -c 'doorbell-skipped .*stop planner 1' "$TD/send-lead.log")" = 1 ] || fail "(d) skipped doorbell not logged once"
echo "team-smoke-22: (d) wait in place + (j) inbox write ring OK"

# ---- (e) a dead lead: one session_dead, then relaunch-lead relaunches it --------------------------
reset; lead_json; printf 'alfa-lead\nalfa-planner\n' > "$WORK/alive"; session planner 1 "$BASE"
export CANCEL_AT=400   # a safety net: the case script cancels long before
cat > "$WORK/hs.case" <<'HS'
if [ "$s" = alfa-lead ]; then
  c=$(( $(cat "$WORK/lead.n" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$WORK/lead.n"
  [ ! -e "$WORK/relaunched" ] || exit 0
  [ "$c" -ge 2 ] || exit 0
  [ ! -e "$TD/lead-dead" ] || touch "$WORK/relaunched" "$TD/relaunch-lead"
  exit 1
fi
[ ! -f "$TD/runs/$(cat "$TD/run")/lead-1.session" ] || touch "$TD/cancel"
HS
run "$MAIN" $TR alfa; expect 6 "TeamLead died — /start-team alfa relaunches it" "(e) dead lead"
[ "$(grep -l '^event: session_dead' "$SUP"/* | wc -l | tr -d ' ')" = 1 ] || fail "(e) not exactly one session_dead"
grep -q '^ref: .agents/team/teamlead.json' "$SUP"/* || fail "(e) session_dead ref"
[ "$(grep -c -- '-s smk-alfa-lead' "$STUB_LOG")" = 1 ] && [ -s "$RD/lead-1.session" ] || fail "(e) not relaunched once"
[ ! -e "$TD/lead-dead" ] && [ ! -e "$TD/relaunch-lead" ] || fail "(e) relaunch markers left"
run "$MAIN" bash .claude/lib/team-lead.sh relaunch alfa; expect 0 "relaunch requested" "(e) relaunch command"
[ -e "$TD/relaunch-lead" ] || fail "(e) relaunch command wrote no request"
run "$MAIN" $TR alfa status
expect 0 "teamlead: alive — session $(jq -r .session_id "$TD/teamlead.json") — pending 0" "(e) status line"
[ "$(jq -r .session_id "$TD/teamlead.json")" = "$(cat "$RD/lead-1.session")" ] || fail "(e) relaunch kept the old sid"
echo "team-smoke-22: (e) dead lead + relaunch OK"

# ---- execution-time limit pauses while waiting on the lead (fixture clock) ------------------------
echo 1000000 > "$WORK/clock"
export TEAM_NOW_CMD='n=$(cat "$WORK/clock"); echo $((n + 5000)) > "$WORK/clock"; echo "$n"'
reset; lead_json; printf 'alfa-lead\nalfa-qa\n' > "$WORK/alive"; session qa 1 "$BASE"
run "$MAIN" $TR alfa; expect 3 "stalled" "(clock) the qa limit still applies without a wait"
reset; lead_json; printf 'alfa-lead\nalfa-qa\n' > "$WORK/alive"; session qa 1 "$BASE"
mkrec qa "$BASE" blocked; export CANCEL_AT=20
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: qa-1-1.json" "(clock) a held decision is not a stall"
# The answer marker ends the pause: polls well past the limit while waiting, then the clock counts.
reset; lead_json; printf 'alfa-lead\nalfa-qa\n' > "$WORK/alive"; session qa 1 "$BASE"
mkrec qa "$BASE" blocked; export CANCEL_AT=60
echo '[ "$n" -lt 12 ] || touch "$TD/runs/$(cat "$TD/run")/qa-1-1.json.answered"' > "$WORK/hs.case"
run "$MAIN" $TR alfa; expect 3 "stalled" "(clock) the limit counts again after the answer marker"
[ "$(cat "$WORK/hs.n")" -ge 12 ] || fail "(clock) stalled before the answer marker"
# A resumed runner whose acked stop has no marker still holds the clock.
reset; lead_json; printf 'alfa-lead\nalfa-qa\n' > "$WORK/alive"; session qa 1 "$BASE"
mkrec qa "$BASE" blocked; echo qa-1-1.json > "$TD/acked"; export CANCEL_AT=20
run "$MAIN" $TR alfa; expect 6 "" "(clock) a resumed wait is not a stall"
unset TEAM_NOW_CMD
echo "team-smoke-22: execution-time limit OK"

# ---- (f) mode cli → no lead -----------------------------------------------------------------------
reset; jq '.mode = "cli"' "$TD/team.json" > "$WORK/t" && cp "$WORK/t" "$TD/team.json"
run "$MAIN" $TR alfa
has "-s smk-alfa-lead" "$STUB_LOG" && fail "(f) a lead launched in mode cli"
has "-s smk-alfa-cli" "$STUB_LOG" || fail "(f) the cli session did not launch"
jq '.mode = "brainstorm"' "$TD/team.json" > "$WORK/t" && cp "$WORK/t" "$TD/team.json"
echo "team-smoke-22: (f) cli OK"

# ---- (h) end / finalize; team-integrate calls finalize on both success exits ----------------------
reset; lead_json; echo alfa-lead > "$WORK/alive"; mkdir -p "$(dirname "$LREG")"; echo '{}' > "$LREG"
# The run's own inbox messages leave new/ when it ends; another run's stay (team-inbox.sh close-run).
IBA="$MAIN/.agents/team/inbox/alfa"; mkdir -p "$IBA/new"
for m in "1:$RUN_ID" "2:$RUN_ID" "3:alfa-20990101-000000"; do
  printf -- '---\nid: m%s\nrun: %s\n---\nx\n' "${m%%:*}" "${m#*:}" > "$IBA/new/20261115T00000${m%%:*}Z-Supervisor-message.md"
done
# The run's notifications are resolved when it ends; another run's are not (notify.sh resolve --all).
for r in "$RUN_ID" alfa-20990101-000000; do
  run "$MAIN" bash .claude/lib/notify.sh human_decision --project smk --team alfa --ticket AB-1 --run "$r" \
    --decision x-1 --summary s --answer alfa-lead --main "$MAIN"; expect 0 "written" "(h) seed a notification"
done
run "$MAIN" bash .claude/lib/team-lead.sh finalize alfa merged; expect 0 "finalized: alfa $RUN_ID merged" "(h) finalize"
NST="$HOME/.agent-comms/outbox/state"
[ -f "$NST/smk_alfa_${RUN_ID}_x-1.resolved" ] && [ ! -e "$NST/smk_alfa_alfa-20990101-000000_x-1.resolved" ] \
  || { ls "$NST" > "$WORK/out" 2>&1; fail "(h) finalize did not resolve exactly the run's notifications"; }
[ -f "$IBA/done/20261115T000001Z-Supervisor-message.md" ] && [ -f "$IBA/done/20261115T000002Z-Supervisor-message.md" ] \
  && [ -f "$IBA/new/20261115T000003Z-Supervisor-message.md" ] && [ ! -e "$IBA/new/20261115T000001Z-Supervisor-message.md" ] \
  || { ls -R "$IBA" > "$WORK/out"; fail "(h) finalize did not move exactly the run's inbox messages to done/"; }
run "$MAIN" bash .claude/lib/team-inbox.sh close-run alfa "$RUN_ID"; expect 0 "closed: 0 message(s) of run $RUN_ID" "(h) close-run again"
run "$MAIN" bash .claude/lib/team-inbox.sh close-run alfa 'x y'; expect 2 "" "(h) close-run with a bad run id"
rm -f "$IBA/new/20261115T000003Z-Supervisor-message.md" "$IBA/done/20261115T00000"[12]"Z-Supervisor-message.md"
# The runner's other exit (close_run: abandon, remode) closes the run's inbox too.
awk '/^close_run\(\) \{/,/^}/' "$SRC/.claude/lib/team-run-lead.sh" | grep -q 'team-inbox.sh" --main "$root" close-run "$TEAM" "$RUN"' \
  || fail "(h) close_run does not close the run's inbox"
has "kill-session -t =smk-alfa-lead" "$STUB_LOG" || fail "(h) the lead was not ended"
[ -f "$RD/finalized" ] && [ ! -e "$LREG" ] || fail "(h) finalized marker / registration"
cp "$RD/finalized" "$WORK/fin1"
run "$MAIN" bash .claude/lib/team-lead.sh finalize alfa merged; expect 0 "finalized:" "(h) finalize again"
cmp -s "$RD/finalized" "$WORK/fin1" || fail "(h) finalize is not idempotent"
run "$MAIN" bash .claude/lib/team-lead.sh end alfa; expect 0 "TeamLead ended" "(h) end with no session"
[ "$(grep -c 'finalize_lead$' "$SRC/.claude/lib/team-integrate.sh")" = 2 ] \
  && grep -B1 'finalize_lead$' "$SRC/.claude/lib/team-integrate.sh" | grep -q 'already integrated' \
  && grep -B1 'finalize_lead$' "$SRC/.claude/lib/team-integrate.sh" | grep -q '"integrated: ' \
  || fail "(h) team-integrate does not finalize after both integrated exits"
echo "team-smoke-22: (h) end/finalize OK"

# ---- SessionStart hook: registration, /clear identity refresh, silent for others -----------------
reset; lead_json; H="$SRC/.claude/hooks/session-registry.sh"
LR="$MAIN/.agents/team/registry/alfa-lead.json"; mkdir -p "$(dirname "$LR")"
[ -f "$LR" ] || echo '{"address": "alfa-lead", "kind": "team"}' > "$LR"
reg_hook() {  # reg_hook <sid> [role] — the hook as a session of the clone
  set +e; CLAUDE_PROJECT_DIR="$CLONE" TEAM_SESSION_ROLE="${2-TeamLead}" \
    CLAUDE_CODE_MESSAGING_SOCKET=/tmp/x.sock CLAUDE_CODE_MESSAGING_TOKEN=tok \
    bash "$H" <<<"{\"session_id\": \"$1\"}" > "$WORK/out" 2>&1; RC=$?; set -e
}
reg_hook sid-lead coder; expect 0 "" "(reg) another role"
[ ! -s "$WORK/out" ] && [ ! -e "$LREG" ] || fail "(reg) a non-lead session registered"
reg_hook sid-lead; expect 0 "Pending (oldest first" "(reg) the lead"
[ "$(ls -l "$LREG" | cut -c1-10)" = "-rw-------" ] && [ ! -e "$TD/teamlead.reg.json" ] \
  && jq -e '.socket == "/tmp/x.sock" and .token == "tok" and .session_id == "sid-lead"' \
    "$LREG" >/dev/null || fail "(reg) registration file"
# The registered pid is not an ancestor of this hook: a foreign process (the suite itself may run
# under a claude, so the first registration's pid is not usable here).
jq '.pid = 999999' "$LREG" > "$WORK/r" && mv "$WORK/r" "$LREG"
reg_hook sid-other; expect 0 "" "(reg) a foreign process with another id"
[ "$(jq -r .session_id "$TD/teamlead.json")" = sid-lead ] || fail "(reg) a foreign process moved the id"
jq --argjson p $$ '.pid = $p' "$LREG" > "$WORK/r" && mv "$WORK/r" "$LREG"
reg_hook sid-after-clear; expect 0 "Pending" "(reg) /clear in the lead's own process"
[ "$(jq -r .session_id "$TD/teamlead.json")" = sid-after-clear ] || fail "(reg) /clear did not refresh the id"
jq -e '.session_id == "sid-after-clear" and .reg == "alfa-lead.reg.json"' "$LR" >/dev/null \
  || { cp "$LR" "$WORK/out"; fail "(reg) the registry record did not follow the lead"; }
echo "team-smoke-22: SessionStart registration OK"

# ---- (i) team-watch: no team signal for a run with or without its own lead -----------------------
reset; lead_json
run "$MAIN" bash .claude/lib/team-snapshot.sh --out "$WORK/snap.json"; expect 0 "" "(i) snapshot"
jq -e '.teams[] | select(.team == "alfa") | .lead == true' "$WORK/snap.json" >/dev/null || fail "(i) snapshot lead flag"
echo alfa-old > "$TD/run"
run "$MAIN" bash .claude/lib/team-snapshot.sh --out "$WORK/snap.json"; expect 0 "" "(i) snapshot, stale lead"
jq -e '.teams[] | select(.team == "alfa") | .lead == false' "$WORK/snap.json" >/dev/null || fail "(i) a stale teamlead.json counts as lead"
jq -n '{routing: {mode: "split", receiver: "Supervisor", live: {}}, snapshot: {teams: [
  {team: "alfa", run: "a1", lead: true, runner: "stale", finished: false, roles: []},
  {team: "beta", run: "b1", runner: "stale", finished: false, roles: []}]}}' \
  | jq -f "$L/team-watch-signals.jq" > "$WORK/sig.json"
jq -e '[.[] | select(.kind | IN("attention","record","runner","ready","escalation"))] | length == 0' \
  "$WORK/sig.json" >/dev/null \
  || { cp "$WORK/sig.json" "$WORK/out"; fail "(i) signal filter produced a team signal"; }
echo "team-smoke-22: (i) team-watch filter OK"

# ---- (k) team-next archives the run-scoped root files; the next ticket takes the no-lead branch ---
reset; lead_json
for f in teamlead.settings.json round verdict-acked lead-dead relaunch-lead; do echo x > "$TD/$f"; done
rm -f "$CLONE/.claude/hooks/guard-teamlead-write.sh" "$CLONE/.claude/hooks/guard-teamlead-bash.sh"
mkdir -p "$MAIN/.agents/team/registry"; echo '{}' > "$MAIN/.agents/team/registry/alfa-coder.json"; echo '{}' > "$LREG"
# The archived run's notifications are resolved, another run's are not; x-k: (h)'s x-1 is resolved.
for r in "$RUN_ID" alfa-20990102-000000; do
  run "$MAIN" bash .claude/lib/notify.sh human_decision --project smk --team alfa --ticket AB-1 --run "$r" \
    --decision x-k --summary s --answer alfa-lead --main "$MAIN"; expect 0 "written" "(k) seed a notification"
done
NST="$HOME/.agent-comms/outbox/state"
# A failed switch leaves the run in place, so its notifications stay open.
STUB_GIT_FAIL_DIR="$CLONE" STUB_GIT_FAIL_CMD=switch \
  run "$MAIN" perl -e 'alarm 30; exec @ARGV' bash .claude/lib/team-next.sh alfa AB-1501 feature/AB-1501-y origin/develop
expect 128 "forced switch failure" "(k) team-next with a failing switch"
[ ! -e "$NST/smk_alfa_${RUN_ID}_x-k.resolved" ] || fail "(k) a failed switch resolved the still-live run's notifications"
run "$MAIN" perl -e 'alarm 30; exec @ARGV' bash .claude/lib/team-next.sh alfa AB-1501 feature/AB-1501-y origin/develop
expect 0 "was AB-1500" "(k) team-next"
[ -f "$NST/smk_alfa_${RUN_ID}_x-k.resolved" ] && [ ! -e "$NST/smk_alfa_alfa-20990102-000000_x-k.resolved" ] \
  || { ls "$NST" > "$WORK/out" 2>&1; fail "(k) team-next did not resolve exactly the archived run's notifications"; }
for f in teamlead.json teamlead.settings.json round verdict-acked lead-dead relaunch-lead; do
  [ ! -e "$TD/$f" ] || fail "(k) $f left at the team-dir root"
done
[ ! -e "$MAIN/.agents/team/registry/alfa-coder.json" ] && [ ! -e "$LREG" ] || fail "(k) the ended run's registry files stayed"
ls "$TD"/archive/AB-1500-*/teamlead.json >/dev/null 2>&1 || fail "(k) teamlead.json not archived"
export TEAM_SMOKE_NO_LEAD=1
: > "$STUB_LOG"; rm -f "$WORK/hs.case"; : > "$WORK/alive"
run "$MAIN" $TR alfa
has "-s smk-alfa-planner" "$STUB_LOG" && ! has "-s smk-alfa-lead" "$STUB_LOG" || fail "(k) next ticket not on the no-lead branch"
echo "team-smoke-22: (k) team-next OK"

# ==== authority: the per-run TeamLead's answers (checker, sender, hook) ===========================
RUN_ID=alfa-20261114-120000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
lead_json; rm -f "$WORK/hs.case"; unset STUB_ON_HAS_SESSION CANCEL_AT
export STUB_TMUX_ALIVE=0 STUB_PANE="$WORK/pane" TEAM_CONFIRM_SECS=1
CREAL="$(cd "$CLONE" && pwd -P)"; SET="$CREAL/.claude/settings.json"
SID=sid-auth-1; session coder 1 "$BASE" "$SID"; T="$(transcript "$SID")"; mkdir -p "$(dirname "$T")"
(. "$MAIN/.claude/lib/team-anchor.sh"; team_anchor_launch "$MAIN" alfa "$CLONE" "$RUN_ID" coder 1 "$SID")
jq -cn '{type: "assistant", uuid: "a-w", message: {content: [{type: "text", text: "wait"}]}}' > "$T"
# Project settings: a baseline ask (git rm), a project-added ask (az webapp restart), a deny.
jq -n '{permissions: {allow: ["Bash(bash -n:*)"], ask: ["Bash(git rm*)", "Bash(az webapp restart*)",
  "Edit(**/.env.*)", "Edit(infra/**)", "Bash(rm -rf:*)", "Bash(git remote add:*)"],
  deny: ["Bash(git rebase*)"]}, hooks: {}}' > "$SET"
prof '.teams.policy.classes = {allow_offline: {enabled: true}}'
printf '%s\n' '**Integration:** `develop`' '**Protected:** `develop`' > "$MAIN/CLAUDE.md"  # the classes' Branch model
mkdir -p "$CLONE/.claude/lib"; printf 'echo hi\n' > "$CLONE/.claude/lib/x.sh"
RULE="$(printf '─%.0s' $(seq 120))"; DASH="$(printf '╌%.0s' $(seq 120))"; LAST=""; N=0
PCM="python3 -I $MAIN/.claude/lib/team_prompt_check.py"
pend() {  # pend <tool> <json input> — the role's single pending call
  [ -z "$LAST" ] || tool_done "$SID" "$LAST"
  N=$((N + 1)); LAST="t$N"; pending_tool "$SID" "$LAST" "$1" "$2" "$CREAL"
}
bashp() {  # bashp <one-line command> — pending Bash call + its permission prompt
  pend Bash "$(jq -cn --arg c "$1" '{command: $c, description: "Run it"}')"
  { echo "$RULE"; echo " Bash command"; echo " Run it"; echo "$DASH"; echo " │ $1"; echo "$DASH"
    echo " This command requires approval"; echo " Do you want to proceed?"
    echo " ❯ 1. Yes"; echo "   2. No"; echo " Esc to cancel · Tab to amend"; } > "$WORK/pane"
}
editp() {  # editp <file_path> <shown> <old> <new> — pending Edit + its prompt (one-line change)
  local f="$1" o="$3" n="$4" t a
  pend Edit "$(jq -cn --arg f "$f" --arg o "$o" --arg n "$n" '{file_path: $f, old_string: $o, new_string: $n}')"
  t="$(cat "$f" 2>/dev/null || echo "$o")"; a="$(grep -F -- "$o" <<<"$t" | head -n 1)"
  { echo "$RULE"; echo " Edit file"; echo " $2"; echo "$DASH"
    echo "  1 -$a"; echo "  1 +${a/"$o"/$n}"; echo "$DASH"
    echo " Do you want to make this edit to $(basename "$f")?"
    echo " ❯ 1. Yes"; echo "   2. No"; echo " Esc to cancel"; } > "$WORK/pane"
}
chk() {  # chk <authority|--classes> → RC, $WORK/out
  local a=(--authority "$1"); [ "$1" != --classes ] || a=(--classes)
  set +e; $PCM "$CLONE" --strict --transcript "$T" "${a[@]}" --main "$MAIN" < "$WORK/pane" \
    > "$WORK/out" 2>&1; RC=$?; set -e
}
A0='"Bash(bash -n:*)"'
# ---- (j) a settings edit is human-only for class and teamlead, even with allow-offline on ---------
editp "$SET" .claude/settings.json "$A0" "$A0, \"Bash(bash -n .claude/lib/x.sh)\""
chk --classes; expect 0 "policy-class: allow-offline" "(j) legacy --classes keeps its class waiver"
for a in class teamlead; do
  chk "$a"; expect 1 "human-only: settings edit" "(j) settings edit, authority $a"
done
chk operator; expect 1 "human-only: settings edit" "(j) settings edit, operator (the Operator answers in the window)"
mkdir -p "$CLONE/.claude/team/sessions"; echo '{"permissions": {"allow": []}}' > "$CLONE/.claude/team/sessions/TeamLead.settings.json"
editp "$CREAL/.claude/team/sessions/TeamLead.settings.json" .claude/team/sessions/TeamLead.settings.json \
  '"allow": []' '"allow": ["Bash(*)"]'
chk teamlead; expect 1 "human-only: settings edit" "(j) guard profile edit"
bashp "cp /tmp/s .claude/settings.json"; chk teamlead; expect 1 "human-only: settings edit" "(j) settings via Bash"
echo "team-smoke-22: (j) settings edit human-only OK"
# ---- (k) a project-added ask is human-only; a baseline ask is the lead's --------------------------
bashp "az webapp restart --name x"; chk teamlead
expect 1 "human-only: production ask: Bash(az webapp restart*)" "(k) project-added ask, teamlead"
chk operator; expect 1 "human-only: production ask: Bash(az webapp restart*)" "(k) project-added ask, operator"
bashp "git rm old.txt"; chk teamlead; expect 0 "policy-authority: teamlead" "(k) baseline ask, teamlead"
chk class; expect 1 "class:" "(k) baseline ask, class without a matching class"
mv "$MAIN/.claude/team/baseline-ask.json" "$WORK/baseline.json"
chk teamlead; expect 1 "human-only: production ask: Bash(git rm*)" "(k) missing baseline: every ask"
mv "$WORK/baseline.json" "$MAIN/.claude/team/baseline-ask.json"
# Edit/Write ask rules match the edited path: a project rule is human-only, a baseline rule the lead's.
mkdir -p "$CLONE/infra"; echo 'size = 1' > "$CLONE/infra/main.tf"; echo 'A=1' > "$CLONE/.env.local"
editp "$CREAL/infra/main.tf" infra/main.tf 'size = 1' 'size = 2'; chk teamlead
expect 1 "human-only: production ask: Edit(infra/**)" "(k) project-added Edit rule"
editp "$CREAL/.env.local" .env.local 'A=1' 'A=2'; chk teamlead; expect 0 "policy-authority: teamlead" "(k) baseline Edit rule"
chk class; expect 1 "class:" "(k) baseline Edit rule, class"
chk operator; expect 0 "policy-authority: operator" "(k) baseline Edit rule, operator relay"
jq -e 'index("Edit(**/.env.*)")' "$MAIN/.claude/team/baseline-ask.json" >/dev/null \
  || fail "(k) Edit(**/.env.*) left the baseline: it would become human-only (owner: the lead approves it)"
# .env itself is a deny rule of the starter: Claude Code shows no prompt for it, so no authority can.
jq -e '.permissions.deny | index("Edit(**/.env)")' "$SRC/.claude/settings.json" >/dev/null \
  || fail "(k) the starter no longer denies Edit(**/.env)"
# A recursive rm is the lead's only inside the clone or a temp root; git remote add is egress.
# The fixture lives under the system temp dir: a separate TMPDIR keeps the clone outside "temp".
OLD_TMPDIR="$TMPDIR"; export TMPDIR="$WORK/tz"; mkdir -p "$TMPDIR" "$CLONE/sub"
for c in "rm -rf build/" "rm -fr $TMPDIR/x" "rm -r -f sub/y"; do
  bashp "$c"; chk teamlead; expect 0 "" "(k) rm inside: $c"
done
for c in "rm -rf ~/x" "rm -rf /usr/local/x" "rm -rf ../x" "rm -rf \$HOME/x" "sudo rm -r -f ~/x" \
  "cd sub && rm -rf y" "rm -rf nothing-*"; do
  bashp "$c"; chk teamlead; expect 1 "human-only: irreversible delete outside the clone" "(k) rm outside: $c"
done
bashp "rm -rf ~/x"; chk class; expect 1 "human-only: irreversible delete" "(k) rm outside, class"
chk operator; expect 1 "human-only: irreversible delete" "(k) rm outside, operator"
for c in "rm -rf .git/objects" "rm -rf .git/refs/heads/x"; do
  bashp "$c"
  for a in teamlead class; do chk "$a"; expect 1 "human-only: irreversible delete inside the git dir" "(k) $c, $a"; done
  chk operator; expect 1 "human-only: irreversible delete inside the git dir" "(k) $c, operator"
done
bashp "rm -rf .GIT/objects"; chk teamlead; expect 1 "inside the git dir" "(k) case-folded git dir path"
for c in "rm -rf ." "rm -rf .git" "rm -rf $CREAL" "rm -rf $CREAL/.git/" "rm -rf .Git" "rm -rf .GIT/" "rm -rf /"; do
  bashp "$c"; chk operator; expect 1 "clone root or its .git — never" "(k) rm of the clone root: $c"
done
# With the clone under a temp root its ancestors are strictly "inside temp": still never.
export TMPDIR="$(dirname "$WORK")"
for c in "rm -rf .." "rm -rf $(dirname "$CREAL")"; do
  bashp "$c"
  for a in teamlead operator; do chk "$a"; expect 1 "clone root or its .git — never" "(k) ancestor under temp: $c, $a"; done
done
export TMPDIR="$WORK/tz"
bashp "git remote add x https://example.invalid/r.git"
for a in teamlead class; do chk "$a"; expect 1 "human-only: egress: git remote add" "(k) git remote add, $a"; done
chk operator; expect 1 "human-only: egress: git remote add" "(k) git remote add, operator"
bashp "rm -rf build/"; chk teamlead; expect 0 "policy-authority: teamlead" "(k) baseline rm -rf inside, waived"
export TMPDIR="$OLD_TMPDIR"
bashp "git status"; chk teamlead; expect 0 "" "(k) no match, nothing to waive"
has "policy-" "$WORK/out" && fail "(k) a waiver printed for a clean prompt"
echo "team-smoke-22: (k) production asks OK"
# ---- never waived: deny, SQL, unreadable, no transcript; egress needs the Operator -----------------
for a in teamlead operator; do
  bashp "git rebase -i HEAD~2"; chk "$a"; expect 1 "deny-tier" "(never) deny, $a"
  bashp "sqlcmd -Q 'DROP TABLE x'"; chk "$a"; expect 1 "refuse (" "(never) SQL, $a"
  has "human-only" "$WORK/out" && fail "(never) SQL offered to the Operator"
  bashp 'echo "unbalanced'; chk "$a"; expect 1 "cannot be parsed" "(never) unreadable, $a"
done
set +e; $PCM "$CLONE" --strict --authority operator < "$WORK/pane" > "$WORK/out" 2>&1; RC=$?; set -e
expect 1 "no transcript" "(never) no transcript"
bashp "curl https://example.invalid/x"; chk teamlead; expect 1 "human-only: egress: curl" "(egress) teamlead"
chk operator; expect 1 "human-only: egress: curl" "(egress) operator"
echo "team-smoke-22: authority never-waived + egress OK"

# ---- sender: a TeamLead's bare call, caller rules, decision, answers.md, the .answered marker ------
ANS="bash .claude/lib/team-answer.sh"
lead() { run "$MAIN" env TEAM_SESSION_ROLE=TeamLead TEAM_RUN_TEAM="${LT:-alfa}" $ANS "$@"; }
bashp "git rm old.txt"
# A pending human-only request on the open prompt: a bare TeamLead call would skip that check.
mkdir -p "$RD/decisions"; echo '{"binding": {"event": "toolu_human"}}' > "$RD/decisions/req-1.json"
n0="$(grep -c '^tmux send-keys' "$STUB_LOG" || true)"
lead alfa coder no; expect 7 "a TeamLead answers only with --authority" "(bare) TeamLead call without --authority"
[ "$(grep -c '^tmux send-keys' "$STUB_LOG" || true)" = "$n0" ] || fail "(bare) keys sent on a refused TeamLead call"
! grep -q 'operator-window' "$RD/answers.md" 2>/dev/null || fail "(bare) a refused call logged an answer"
# Outside a TeamLead session the same bare call is not refused by that rule: the Escape goes out
# (this stub pane stays on the prompt, so it may end as exit 4, which still proves delivery).
run "$MAIN" $ANS alfa coder no
! has "a TeamLead answers only" "$WORK/out" || fail "(bare) a non-TeamLead call was refused as a TeamLead"
[ "$(grep -c '^tmux send-keys' "$STUB_LOG" || true)" -gt "$n0" ] || fail "(bare) a non-TeamLead bare call sent nothing"
rm -f "$RD/decisions/req-1.json"; bashp "git rm old.txt"; : > "$STUB_LOG"
run "$MAIN" $ANS alfa coder yes --authority teamlead --why w; expect 7 "is the run's TeamLead's" "(caller) not the lead"
lead alfa coder yes --authority teamlead; expect 2 "needs --why" "(caller) no --why"
LT=beta lead alfa coder yes --authority teamlead --why w; expect 7 "only its own team" "(caller) another team"
lead alfa coder yes --authority operator --why w; expect 7 "needs --decision" "(l) operator without a decision"
mkdir -p "$RD/decisions"; printf -- '---\nid: d-1\nstatus: pending\n---\nq\n' > "$RD/decisions/d-1.md"
lead alfa coder yes --authority operator --why w --decision "$RD/decisions/d-1.md"
expect 7 "needs --decision" "(l) operator with a pending decision"
bashp "rm -rf ~/x"
lead alfa coder yes --authority teamlead --why "clean up"
expect 9 "irreversible delete outside the clone" "(k) sender: rm outside the clone is exit 9"
[ "$(grep -c '^tmux send-keys' "$STUB_LOG")" = 0 ] || fail "(k) keys sent on an rm outside the clone"
editp "$SET" .claude/settings.json "$A0" "$A0, \"Bash(bash -n .claude/lib/x.sh)\""
lead alfa coder yes --authority teamlead --why "allow a syntax check"
expect 9 "human-only: settings edit" "(j) sender maps human-only to exit 9"
[ "$(grep -c '^tmux send-keys' "$STUB_LOG")" = 0 ] || fail "(j) keys sent on a human-only refusal"
sed -i.bak 's/^status: pending/status: answered/' "$RD/decisions/d-1.md"
: > "$STUB_LOG"
lead alfa coder yes --authority operator --why "Operator approved" --decision "$RD/decisions/d-1.md"
expect 9 "human-only: settings edit" "(l) an operator relay never answers a human-only prompt"
[ "$(grep -c '^tmux send-keys' "$STUB_LOG")" = 0 ] || fail "(l) keys sent on a human-only relay"
grep -q '^status: answered' "$RD/decisions/d-1.md" || fail "(l) a refused relay spent the decision"
bashp "git rm old.txt"
lead alfa coder yes --authority operator --why "Operator approved" --decision "$RD/decisions/d-1.md"
expect 0 "sent yes" "(l) operator relay of a baseline ask"
grep -q "\[coder 1\] .* → yes — Operator approved \[authority operator\] \[decision d-1\]$" "$RD/answers.md" \
  || { cp "$RD/answers.md" "$WORK/out"; fail "(p) operator answer not in answers.md"; }
# A blocked coder: a say on the lead's authority writes the stop's marker; a refused one does not.
mkrec coder "$BASE" blocked; jq '.attempt = 1 | .message = "which endpoint?"' "$RD/coder-1-1.json" \
  > "$WORK/r" && mv "$WORK/r" "$RD/coder-1-1.json"; echo coder-1-1.json > "$TD/acked"
bashp "git status"
lead alfa coder say "Use the existing endpoint." --authority teamlead --why "order line 2"
expect 6 "a menu or permission prompt is open" "(marker) refused say"
[ ! -e "$RD/coder-1-1.json.answered" ] || fail "(marker) a refused say wrote the marker"
tool_done "$SID" "$LAST"; LAST=""; cp "$FIX/idle.txt" "$WORK/pane"
lead alfa coder say "Use the existing endpoint." --authority teamlead --why "order line 2"
expect 0 "sent say" "(marker) say on the lead's authority"
[ -e "$RD/coder-1-1.json.answered" ] || fail "(marker) no .answered after the say"
grep -q "\[coder 1\] which endpoint? → say: Use the existing endpoint. — order line 2 \[authority teamlead\]$" \
  "$RD/answers.md" || { cp "$RD/answers.md" "$WORK/out"; fail "(p) say not in answers.md"; }
[ "$(grep -c '^- ' "$RD/answers.md")" = 2 ] || fail "(p) answers.md is not one line per send"
grep -q 'q=authority:teamlead' "$TD/send-coder.log" || fail "(p) dispatch not journalled on the authority"
echo "team-smoke-22: sender authority + answers.md + marker OK"

# ---- the hook binds team-answer.sh --authority to the lead's session id ---------------------------
HOOK="$SRC/.claude/hooks/guard-team-verdict.sh"
vp() { jq -cn --arg s "$1" --arg c "$2" '{session_id: $s, tool_name: "Bash", tool_input: {command: $c}}'; }
FORGE="TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-answer.sh alfa coder yes --authority teamlead --why w"
hook "$CLONE" "$(vp sid-coder-1 "$FORGE")"; expect 2 "not it (refused)" "(hook) forged authority call"
TEAM_SESSION_ROLE=TeamLead hook "$CLONE" "$(vp sid-lead "bash .claude/lib/team-answer.sh alfa coder yes --authority teamlead --why w")"
expect 0 "" "(hook) the lead's own session"
hook "$CLONE" "$(vp sid-coder-1 "bash .claude/lib/team-answer.sh alfa coder say hi")"; expect 0 "" "(hook) plain sender use"
echo "team-smoke-22: authority hook OK"

# ==== pending decisions, the runner's class-first answering and the Operator notification =========
DLD="$RD/decisions"; LTX="$(transcript sid-lead)"; mkdir -p "$(dirname "$LTX")"; : > "$LTX"
unset TEAM_SMOKE_NO_LEAD  # (k) above ran the next ticket without a lead
DEC="bash .claude/lib/team-lead.sh decision"
# The lead records every answer with the tuning question (team-lead.md §10); `ldec0` omits it.
ldec() { if [ "$1" = answer ]; then set -- "$@" --tuning none --why fixture; fi; run "$CLONE" env TEAM_SESSION_ROLE=TeamLead $DEC "$@"; }
ldec0() { run "$CLONE" env TEAM_SESSION_ROLE=TeamLead $DEC "$@"; }
SAID=0
said_in_lead() {  # said_in_lead <text> — the Operator typed it into the lead window, now
  SAID=$((SAID + 1))
  jq -cn --arg t "$1" --arg ts "$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ)" --arg u "u-$SAID" \
    '{type: "user", uuid: $u, timestamp: $ts, message: {role: "user", content: $t}}' >> "$LTX"
}
# ---- (m) open: a pending file, the escalate verdict with notify, one notification -----------------
OB="$HOME/.agent-comms/outbox"
nev() { ls "$OB/events" 2>/dev/null | grep -c "_alfa_${RUN_ID}_$1\.json$" || true; }
run "$CLONE" $DEC open alfa --source coder-1-1.json --question "Edit the settings?"
expect 3 "only this run's TeamLead opens decisions" "(m) open by a non-lead"
ldec open alfa --source coder-1-1.json --question "Allow the coder to edit .claude/settings.json?" \
  --options "yes|no" --recommend "no — not ordered"
expect 0 "[d-2] Allow the coder to edit .claude/settings.json?" "(m) open"
[ "$(sed -n 's/^status: //p' "$DLD/d-2.md")" = pending ] && grep -q '^## Recommendation' "$DLD/d-2.md" \
  || fail "(m) d-2.md not pending"
V1="$(ls "$RD"/teamlead-decision-*.json | tail -n 1)"
jq -e '.gate == "decision" and .verdict == "escalate" and .notify == "human_decision"
  and (.ref | endswith("/decisions/d-2.md")) and .for == "coder-1-1.json"' "$V1" >/dev/null || fail "(m) escalate verdict"
ldec open alfa --source nothere.json --question q; expect 1 "verdict was refused" "(m) a source outside the run"
rm -f "$DLD/d-3.md"
cp "$SRC/.claude/hooks/guard-teamlead-write.sh" "$SRC/.claude/hooks/guard-teamlead-bash.sh" "$CLONE/.claude/hooks/"
printf 'alfa-lead\nalfa-coder\n' > "$WORK/alive"; rm -f "$WORK/hs.n" "$TD/cancel" "$TD/lock"
STUB_ON_HAS_SESSION=". '$WORK/hs.sh'" CANCEL_AT=14 run "$MAIN" $TR alfa; expect 6 "" "(m) runner polls"
[ "$(nev d-2)" = 1 ] || { ls -la "$OB/events" > "$WORK/out" 2>&1 || true; fail "(m) not exactly one human_decision event"; }
# A failing notify.sh (exit 1) is retried on the next ticks, three tries per verdict, then one warn:
# naming the window. Nothing else reaches the Operator; the decision stays pending.
cp "$MAIN/.claude/lib/notify.sh" "$WORK/notify.sh.keep"
cp "$STUB_LOG" "$WORK/stub.keep"; : > "$STUB_LOG"  # the first runner ended the coder on cancel
printf '#!/usr/bin/env bash\necho x >> "%s/nfail.log"; exit 1\n' "$WORK" > "$MAIN/.claude/lib/notify.sh"
printf 'alfa-lead\nalfa-coder\n' > "$WORK/alive"; rm -f "$WORK/hs.n" "$TD/cancel" "$TD/lock" "$WORK/nfail.log"
STUB_ON_HAS_SESSION=". '$WORK/hs.sh'" CANCEL_AT=14 run "$MAIN" $TR alfa
expect 6 "warn: notify.sh failed 3× for teamlead-decision-" "(m) a failing notify.sh warns after three tries"
has "the decision waits in alfa-lead" "$WORK/out" || fail "(m) the warn does not name the window"
[ "$(grep -c . "$WORK/nfail.log")" = 3 ] || fail "(m) notify.sh tried $(grep -c . "$WORK/nfail.log") times, want 3"
[ "$(grep -c 'warn: notify.sh failed' "$WORK/out")" = 1 ] || fail "(m) more than one warn"
[ "$(sed -n 's/^status: //p' "$DLD/d-2.md")" = pending ] || fail "(m) a failing sender changed the decision"
cp "$WORK/notify.sh.keep" "$MAIN/.claude/lib/notify.sh"
# The lead on herdr (step 6): its record's handle is probed through the fake hc and the hint passed
# to notify.sh names the Herdr terminal; the runner lives on. (A driver that cannot give a hint at
# all now means a broken record, which also fails the lead's liveness probe.)
LR="$MAIN/.agents/team/registry/alfa-lead.json"; mkdir -p "$(dirname "$LR")"; rm -f "$WORK/lr.keep"
[ ! -f "$LR" ] || cp "$LR" "$WORK/lr.keep"
jq -n --slurpfile r <(cat "$WORK/lr.keep" 2>/dev/null || echo '{}') '($r[0] // {}) + {address: "alfa-lead", backend: "herdr", handle: "t5l", name: "smk-alfa-lead"}' > "$LR"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/nargs.log"\n' "$WORK" > "$MAIN/.claude/lib/notify.sh"; : > "$STUB_LOG"  # the last runner ended the coder
printf 'alfa-lead\nalfa-coder\n' > "$WORK/alive"; rm -f "$WORK/hs.n" "$TD/cancel" "$TD/lock" "$WORK/nargs.log"
STUB_HC_ADDR=t5l STUB_ON_HAS_SESSION=". '$WORK/hs.sh'" CANCEL_AT=14 run "$MAIN" $TR alfa; expect 6 "" "(m) herdr hint: the runner lives"
cp "$WORK/notify.sh.keep" "$MAIN/.claude/lib/notify.sh"
if [ -f "$WORK/lr.keep" ]; then cp "$WORK/lr.keep" "$LR"; else rm -f "$LR"; fi
grep -A1 -x -- "--hint" "$WORK/nargs.log" 2>/dev/null | grep -q "^hc attach t5l · herdr: smk-alfa-lead" \
  || { cp "$WORK/nargs.log" "$WORK/out" 2>/dev/null || true; fail "(m) herdr hint: notify.sh did not get the herdr hint"; }
cp "$WORK/stub.keep" "$STUB_LOG"
rm -f "$WORK/hs.n" "$TD/cancel"
STUB_ON_HAS_SESSION=". '$WORK/hs.sh'" CANCEL_AT=8 run "$MAIN" $TR alfa
! has "warn: notify.sh" "$WORK/out" || fail "(m) a restarted runner: the duplicate event warned"
# notify.sh (#38): one write-once event in the fixture HOME's outbox, no .notified; channels off.
[ "$(nev d-2)" = 1 ] || { ls -la "$OB/events" > "$WORK/out" 2>&1 || true; fail "(m) a restarted runner wrote a second event"; }
jq -e '.event == "human_decision" and .team == "alfa" and .decision == "d-2" and .summary == null
  and .answer.hint == "tmux attach -t smk-alfa-lead" and .answer.address == "alfa-lead"' "$OB/events/"*"_alfa_${RUN_ID}_d-2.json" >/dev/null \
  || fail "(m) event file"
[ ! -e "$TD/runs/$RUN_ID/.notified" ] || fail "(m) .notified still written"
run "$CLONE" bash .claude/lib/team-lead.sh pending alfa
head -n 1 "$WORK/out" | grep -q "^decision .agents/team/runs/$RUN_ID/decisions/d-2.md — Allow the coder" \
  || fail "(m) pending does not list the open decision first"
echo "team-smoke-22: (m) open + one notification OK"

# ---- (n) two pending: answered by id, bound to the Operator's own words; a second answer → 4 ------
ldec open alfa --source coder-1-1.json --question "Which endpoint?" --options "old|new"; expect 0 "[d-3]" "(n) open d-3"
ldec answer d-3 --text "use the old one"; expect 1 "not team d-3" "(n) answer without a team"
ldec answer alfa d-3 --text "use the old one"; expect 7 "no Operator message" "(n) no Operator input yet"
said_in_lead "prompt coder: use the old one"
ldec answer alfa d-3 --text "use the old one"; expect 7 "no Operator message" "(n) a doorbell is not the Operator"
said_in_lead "d-3 use the old one"
ldec answer alfa d-3 --text "use the old one" --outcome continue; expect 0 "answered: d-3 (continue) via teamlead-window" "(n) answer by id"
grep -q '^answered_via: teamlead-window u-' "$DLD/d-3.md" && [ "$(sed -n 's/^status: //p' "$DLD/d-2.md")" = pending ] \
  || fail "(n) wrong decision answered"
ldec answer alfa d-3 --text "use the old one"; expect 4 "d-3 is answered, not pending" "(n) second answer"
# The decision gate: a control verdict spends the answered decision once.
VD="env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-verdict.sh"
run "$CLONE" $VD decision close --for coder-1-1.json --decision d-3 --message x; expect 4 "outcome continue, not close" "(n) wrong outcome"
run "$CLONE" $VD decision continue --for coder-1-1.json --decision d-3 --message "Operator: old endpoint"
expect 0 "teamlead-decision-" "(n) continue on the answered decision"
grep -q '^status: consumed' "$DLD/d-3.md" || fail "(n) decision not consumed"
run "$CLONE" $VD decision continue --for coder-1-1.json --decision d-3 --message again; expect 4 "consumed, not answered" "(n) a decision spent twice"
run "$CLONE" $VD decision escalate --for attention:x --ref "$DLD/d-2.md" --message x; expect 4 "attention:<line number>" "(n) bad attention ref"
echo "team-smoke-22: (n) answer by id + decision gate OK"

# ---- (o) withdraw, then a late answer is refused ---------------------------------------------------
ldec withdraw alfa d-2 --why "the coder found another way"; expect 0 "withdrawn: d-2" "(o) withdraw"
ls "$OB/state" 2>/dev/null | grep -q "_alfa_${RUN_ID}_d-2[.]resolved$" || fail "(o) the withdrawn decision's notification is not resolved"
said_in_lead "d-2 yes"
ldec answer alfa d-2 --text "yes"; expect 4 "d-2 is withdrawn, not pending" "(o) answer after withdraw"
run "$CLONE" bash .claude/lib/team-lead.sh decision list alfa --pending; expect 0 "" "(o) list"
[ ! -s "$WORK/out" ] || fail "(o) a pending decision is left: $(cat "$WORK/out")"
echo "team-smoke-22: (o) withdraw OK"

# ---- the Operator's relay is bound to the prompt instance and dispatched once ---------------------
bashp "git rm old.txt"; : > "$STUB_LOG"
ldec open alfa --source coder-1-1.json --question "Remove old.txt?"; expect 0 "[d-4]" "(bind) open"
printf '%s\n' "bind_session_id: sid-someone-else" > "$WORK/bind"
awk -v b="$(cat "$WORK/bind")" '/^---$/ && ++n == 2 { print b } { print }' "$DLD/d-4.md" > "$WORK/d4" && mv "$WORK/d4" "$DLD/d-4.md"
said_in_lead "d-4 yes remove it"; ldec answer alfa d-4 --text "yes remove it"; expect 0 "answered: d-4" "(bind) answer"
lead alfa coder yes --authority operator --why "Operator: remove" --decision "$DLD/d-4.md"
expect 6 "session changed" "(bind) a decision bound to another session instance"
ldec open alfa --source coder-1-1.json --question "Remove old.txt now?"; expect 0 "[d-5]" "(once) open"
said_in_lead "d-5 yes"; ldec answer alfa d-5 --text "yes"; expect 0 "" "(once) answer"
lead alfa coder yes --authority operator --why "Operator: remove" --decision "$DLD/d-5.md"; expect 0 "sent yes" "(once) relay"
grep -q '^status: dispatched' "$DLD/d-5.md" && grep -q '^dispatched_at: ' "$DLD/d-5.md" || fail "(once) not journalled"
lead alfa coder yes --authority operator --why "again" --decision "$DLD/d-5.md"; expect 7 "needs --decision" "(once) second relay"
hook "$CLONE" "$(vp sid-coder-1 "bash .claude/lib/team-lead.sh decision answer alfa d-5 --text yes")"
expect 2 "not it (refused)" "(hook) a stage answering a decision"
hook "$CLONE" "$(vp sid-coder-1 "bash .claude/lib/team-lead.sh decision list alfa")"; expect 0 "" "(hook) list is free"
echo "team-smoke-22: decision binding + dispatch once + hook OK"

# ---- (i) the runner answers at authority class first; human-only → a request; else the lead's ------
runner_attention() {  # runner_attention <label> [<line>] — one attention line, a runner start, stopped
  echo "${2:-2026-11-14T12:00:00Z permission_prompt Claude needs your permission}" > "$RD/attention"
  rm -f "$WORK/hs.n" "$TD/cancel" "$TD/lock" "$TD/send-lead.log"; : > "$STUB_LOG"
  STUB_ON_HAS_SESSION=". '$WORK/hs.sh'" CANCEL_AT=10 run "$MAIN" $TR alfa
  cp "$WORK/out" "$WORK/runner.out"
}
bashp "git status"; runner_attention "(i) clean prompt"
has "answered at authority class: coder prompt" "$WORK/runner.out" || { cp "$WORK/runner.out" "$WORK/out"; fail "(i) the runner did not answer at class"; }
grep -q 'send-keys -t %1 Enter' "$STUB_LOG" || fail "(i) no Enter sent to the stage"
! grep -q 'prompt coder' "$TD/send-lead.log" 2>/dev/null && ! grep -q 'send-keys -t =smk-alfa-lead: -l -- prompt' "$STUB_LOG" \
  || fail "(i) the lead was rung for a class-answered prompt"
grep -q "\[authority class\]" "$RD/answers.md" || fail "(i) class answer not in answers.md"
editp "$SET" .claude/settings.json "$A0" "$A0, \"Bash(bash -n .claude/lib/x.sh)\""; runner_attention "(i) human-only"
[ -f "$DLD/req-1.json" ] && jq -e '.role == "coder" and .tool == "Edit file" and .binding.session_id == "sid-auth-1"
  and (.binding.event | length > 0) and .source == "attention:1"' "$DLD/req-1.json" >/dev/null \
  || fail "(i) no request for a human-only prompt"
grep -q 'human-only coder: Edit file .* — open a decision for req-1' "$TD/send-lead.log" "$STUB_LOG" 2>/dev/null \
  || fail "(i) the lead was not rung for the request"
ldec open alfa --request req-1; expect 0 "[d-6] coder: Edit file" "(i) open from the request"
grep -q '^bind_session_id: sid-auth-1' "$DLD/d-6.md" && grep -q '^source: decisions/req-1.json' "$DLD/d-6.md" \
  || fail "(i) binding not copied from the request"
bashp "git rm old.txt"; prof '.teams.policy.classes = {}'; runner_attention "(i) no class"
grep -q 'prompt coder: Bash command git rm old.txt — team-answer.sh alfa coder yes|no --authority teamlead' \
  "$TD/send-lead.log" "$STUB_LOG" 2>/dev/null || { { cat "$TD/send-lead.log"; grep alfa-lead "$STUB_LOG"; } > "$WORK/out" 2>&1; fail "(i) the lead was not rung with the command"; }
echo "team-smoke-22: (i) runner class-first OK"

# ---- (idle) an idle stage rings the lead once per line, but is no item the lead owes ---------------
IDLE="2099-01-01T00:00:01Z idle_prompt Claude is waiting for your input"
printf '%s\n' "$IDLE" > "$RD/attention"
run "$CLONE" bash .claude/lib/team-lead.sh pending alfa
grep -q '^attention ' "$WORK/out" && fail "(idle) pending lists an idle_prompt line"
{ echo "$IDLE"; echo "2099-01-01T00:00:02Z permission_prompt Claude needs your permission"
  echo "2099-01-01T00:00:03Z elicitation_dialog server asks"; echo "2099-01-01T00:00:04Z agent_needs_input x"
  echo "2099-01-01T00:00:05Z some_new_kind y"; } > "$RD/attention"
run "$CLONE" bash .claude/lib/team-lead.sh pending alfa
[ "$(grep -c '^attention ' "$WORK/out")" = 4 ] || fail "(idle) pending does not list the four other kinds"
for k in permission_prompt elicitation_dialog agent_needs_input some_new_kind; do
  grep -q "attention .* — coder: $k " "$WORK/out" || fail "(idle) pending lacks the $k line"
done
grep -q idle_prompt "$WORK/out" && fail "(idle) pending lists the idle line among others"
runner_attention "(idle) ring" "$IDLE"
grep -q 'prompt coder: idle — look at the screen; nothing is owed unless it is stuck — Claude is waiting' \
  "$TD/send-lead.log" "$STUB_LOG" 2>/dev/null || { cp "$WORK/runner.out" "$WORK/out"; fail "(idle) the lead was not rung for an idle stage"; }
has "answered at authority class" "$WORK/runner.out" && fail "(idle) the runner tried to answer an idle stage"
echo "team-smoke-22: (idle) idle stage OK"

# ---- one typed message answers one decision, unless it names the others' ids -----------------------
ldec open alfa --source coder-1-1.json --question "Keep the old endpoint?"; expect 0 "[d-7]" "(once-ev) open d-7"
ldec open alfa --source coder-1-1.json --question "Keep the old table?"; expect 0 "[d-8]" "(once-ev) open d-8"
said_in_lead "yes"
ldec answer alfa d-7 --text yes; expect 0 "answered: d-7" "(once-ev) the first answer"
ldec answer alfa d-8 --text yes; expect 7 "no Operator message" "(once-ev) the same message twice"
ldec open alfa --source coder-1-1.json --question "Ship today?"; expect 0 "[d-9]" "(once-ev) open d-9"
said_in_lead "d-8 yes, d-9 no"
ldec answer alfa d-8 --text yes; expect 0 "answered: d-8" "(once-ev) a message naming d-8"
ldec answer alfa d-9 --text no; expect 0 "answered: d-9" "(once-ev) the same message names d-9"
echo "team-smoke-22: single-use evidence OK"

# ---- (w) a human-only prompt is the Operator's, in the stage window; only the runner closes it -----
# d-6 (opened from req-1 in (i)) was already resolved by the runner of a later section: the stage's
# own transcript got the result of that call. The cases below use fresh copies of it.
grep -q '^answer_in: coder$' "$DLD/d-6.md" || fail "(w) answer_in not written from the request"
grep -q '^answered_via: stage-window ' "$DLD/d-6.md" || fail "(w) the live runner did not resolve d-6"
win() {  # win <fn> [args…] → one runner function in the runner's shell; doorbells to $WORK/bells
  set +e; (cd "$CREAL" && TEAM=alfa RUN="$RUN_ID" CLONE="$CREAL" root="$MAIN" MODE=normal
    . "$MAIN/.claude/lib/team-lib.sh"; TD="$(team_dir)"; . "$MAIN/.claude/lib/team-run-lead.sh"
    team_session_doorbell() { echo "$3" >> "$WORK/bells"; }
    "$@") > "$WORK/out" 2>&1; RC=$?; set -e
}
# No session host for the decision's window (step 10): the hint passed to notify.sh says so and names
# the status command, never a guessed tmux name; the runner goes on.
nohost_notify() {
  rec() { jq -r --arg f "$2" '.[$f] // empty | if type == "array" then join(",") else . end' "$1"; }
  sess_name() { team_tmux_name "$TEAM" "$1"; }
  sh_hint() { return 1; }
  LEAD_NOTIFIED=" "; lead_notify
}
cp "$MAIN/.claude/lib/notify.sh" "$WORK/notify.sh.nohost"; rm -f "$WORK/nargs.log"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/nargs.log"\n' "$WORK" > "$MAIN/.claude/lib/notify.sh"
win nohost_notify; cp "$WORK/notify.sh.nohost" "$MAIN/.claude/lib/notify.sh"
[ "$RC" = 0 ] || fail "(m) no host: lead_notify failed"
grep -A1 -x -- "--hint" "$WORK/nargs.log" 2>/dev/null | tail -n 1 \
  | grep -qx "no alfa-lead session found — bash .claude/lib/session-host.sh status alfa-lead" \
  || { cp "$WORK/nargs.log" "$WORK/out" 2>/dev/null || true; fail "(m) no host: the fallback hint"; }
st() { sed -n 's/^status: //p' "$DLD/$1.md"; }
res() {  # res <tool_use id> <entry fields> — the stage's own answer to its prompt, in its transcript
  jq -cn --arg id "$1" --argjson x "$2" '{type: "user", uuid: ("u-" + $id),
    message: {content: [{type: "tool_result", tool_use_id: $id, content: "ok"}]}} * $x' >> "$T"
}
mkd() {  # mkd <n> <tool_use id> [no-call] → d-<n>: a pending copy of d-6 bound to another call
  sed -e "s/^id: d-6$/id: d-$1/" -e "s/^bind_event: .*/bind_event: $2/" -e '/^## Answer/,$d' \
    -e "s/^status: .*/status: pending/" -e '/^answered_at: /d' -e '/^answered_via: /d' -e '/^answer_outcome: /d' "$DLD/d-6.md" > "$DLD/d-$1.md"
  [ -n "${3:-}" ] || jq -cn --arg id "$2" '{type: "assistant", uuid: ("a-" + $id),
    message: {content: [{type: "tool_use", id: $id, name: "Bash", input: {command: "curl x"}}]}}' >> "$T"
}
mkd 30 tu-30; : > "$WORK/bells"
said_in_lead "d-30 yes"
ldec answer alfa d-30 --text yes; expect 7 "answers it in the coder window" "(w) decision answer refused"
[ "$(st d-30)" = pending ] && ! grep -q '^## Answer' "$DLD/d-30.md" || fail "(w) a refused answer changed d-30"
ldec withdraw alfa d-30 --why "not needed"; expect 7 "answers it in the coder window" "(w) withdraw refused"
lead alfa coder yes --authority operator --why w --decision "$DLD/d-30.md"; expect 7 "answers it in the coder window" "(w) relay refused"
win lead_window; [ "$(st d-30)" = pending ] || fail "(w) resolved with no answer in the window"
win lead_waiting coder 1; [ "$RC" = 0 ] || fail "(w) the stage clock runs while the Operator is asked"
mkd 20 tu-20; mkd 21 tu-21; mkd 22 tu-22; mkd 23 tu-23 no-call
res tu-30 '{"permissionDecision": {"decision": "accept", "source": "user_temporary"}}'
res tu-20 '{"permissionDecision": {"decision": "accept", "source": "user_permanent"}}'
res tu-21 '{"toolDenialKind": "user-rejected", "message": {"content": [{"type": "tool_result", "tool_use_id": "tu-21", "is_error": true, "content": "The user doesn'"'"'t want to proceed with this tool use. The tool use was rejected"}]}}'
win lead_window
for x in "d-30 approved" "d-20 approved (rule added)" "d-21 rejected"; do
  d="${x%% *}"; o="${x#* }"
  [ "$(st "$d")" = resolved ] && grep -qxF "answer_outcome: $o" "$DLD/$d.md" \
    && grep -q '^answered_via: stage-window tu-' "$DLD/$d.md" || fail "(w) $d not resolved as $o: $(cat "$DLD/$d.md")"
  grep -qF "→ $o — Operator in the stage window [authority operator-window] [decision $d]" "$RD/answers.md" \
    || fail "(w) $d: no answers.md line"
  grep -qxF "human-only coder: $d answered in the stage window — $o" "$WORK/bells" || fail "(w) $d: the lead was not rung"
done
[ "$(st d-22)" = pending ] || fail "(w) an open prompt was closed"
[ "$(st d-23)" = withdrawn ] && grep -q '^prompt gone (the runner)$' "$DLD/d-23.md" || fail "(w) a call never made was not withdrawn"
cp "$TD/session.json" "$WORK/sj1"; jq '.attempt = 2' "$WORK/sj1" > "$TD/session.json"
win lead_window; cp "$WORK/sj1" "$TD/session.json"
[ "$(st d-22)" = withdrawn ] || fail "(w) a prompt of a replaced attempt was not withdrawn"
grep -qxF "human-only coder: d-22 withdrawn — prompt gone" "$WORK/bells" || fail "(w) no doorbell for prompt gone"
win lead_waiting coder 1; [ "$RC" = 1 ] || fail "(w) the stage clock still stopped after the runner closed the decisions"
[ "$(python3 -I "$MAIN/.claude/lib/team_prompt.py" outcome "$WORK/none.jsonl" tu-1)" = unknown ] || fail "(w) outcome of an unreadable transcript"
# The Operator is pointed at the stage window, not the lead's.
mkd 31 tu-31
jq -n --arg r "$DLD/d-31.md" '{gate: "decision", verdict: "escalate", notify: "human_decision", ref: $r,
  message: "d-31: coder: Bash curl x"}' > "$RD/teamlead-decision-99.json"
win eval ". '$MAIN/.claude/lib/team-channel.sh'; sess_name() { team_tmux_name alfa \"\$1\"; }
  rec() { jq -r --arg f \"\$2\" '.[\$f] // empty' \"\$1\"; }; lead_notify"
jq -e '.event == "human_decision" and (.answer | tostring | test("alfa-coder"))' "$OB/events/"*"_alfa_${RUN_ID}_d-31.json" >/dev/null 2>&1 \
  || fail "(w) the event does not name the stage window: $(cat "$OB/events/"*"_d-31.json" 2>/dev/null) $(cat "$WORK/out")"
rm -f "$RD/teamlead-decision-99.json"
echo "team-smoke-22: (w) human-only prompts answered in the stage window OK"

echo "team-smoke-22: OK"
