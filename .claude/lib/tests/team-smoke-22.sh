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
cp "$SRC/.claude/hooks/guard-teamlead-write.sh" "$CLONE/.claude/hooks/"
# The doorbell's socket sender, from the main checkout (the seed carries only team-*.sh).
cp "$SRC/.claude/lib/team-watch-send.py" "$MAIN/.claude/lib/"
printf '## Ticket\nExport.\n\n## Not ordered\nnone stated\n\n## In-flight work\n- none\n' > "$WORK/brief.md"
run "$MAIN" bash .claude/lib/team-brief.sh write alfa "$WORK/brief.md"; expect 0 "" "fixture brief"

# has-session is answered from files: $WORK/alive lists live sessions, a killed one is dead,
# $WORK/hs.case adds per-case behaviour, CANCEL_AT stops the runner after that many calls.
cat > "$WORK/hs.sh" <<'HS'
n=$(( $(cat "$WORK/hs.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WORK/hs.n"
s="${3#=}"
[ -z "${CANCEL_AT:-}" ] || [ "$n" -lt "$CANCEL_AT" ] || touch "$TD/cancel"
[ ! -f "$WORK/hs.case" ] || . "$WORK/hs.case"
! grep -q -- "kill-session -t =$s\$" "$STUB_LOG" || exit 1
grep -qx -- "$s" "$WORK/alive" 2>/dev/null && exit 0
exit 1
HS
export STUB_ON_HAS_SESSION=". '$WORK/hs.sh'"
reset() {  # reset — a fresh run state between runner invocations
  rm -rf "$TD/lock" "$TD/cancel" "$TD/acked" "$TD/runs" "$TD/session.json" "$TD/teamlead.json" \
    "$TD/teamlead.reg.json" "$TD/lead-dead" "$TD/relaunch-lead" "$TD/inbox-rung" "$TD/send-lead.log" \
    "$MAIN/.agents/team/inbox" "$WORK/hs.n" "$WORK/hs.case" "$WORK/lead.n" "$WORK/relaunched"
  : > "$STUB_LOG"; : > "$WORK/alive"; unset CANCEL_AT
  echo "$RUN_ID" > "$TD/run"; mkdir -p "$RD"
}
lead_json() { jq -n --arg r "$RUN_ID" --arg m "$MAIN" \
  '{team: "alfa", run: $r, session_id: "sid-lead", main_root: $m}' > "$TD/teamlead.json"; }
line_of() { grep -n -- "$1" "$STUB_LOG" | head -n 1 | cut -d: -f1; }
TR="bash .claude/lib/team-run.sh"

# ---- (a) switch off: no lead, unchanged launch order ---------------------------------------------
reset
run "$MAIN" $TR alfa; expect 5 "dead attempt" "(a) runner, switch off"
has "-s alfa-lead" "$STUB_LOG" && fail "(a) a lead launched with the switch off"
has "-s alfa-planner" "$STUB_LOG" || fail "(a) the planner did not launch"
[ ! -e "$TD/teamlead.json" ] && [ ! -d "$SUP" ] || fail "(a) lead state or events with the switch off"
echo "team-smoke-22: (a) switch off OK"

prof '.teams.teamlead.enabled = true'

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

# ---- (b) switch on, brainstorm: the lead launches first, with its profile ------------------------
reset
run "$MAIN" $TR alfa; expect 5 "launched: TeamLead (fable/high)" "(b) runner, switch on"
[ -n "$(line_of '-s alfa-lead')" ] && [ -n "$(line_of '-s alfa-planner')" ] \
  && [ "$(line_of '-s alfa-lead')" -lt "$(line_of '-s alfa-planner')" ] || fail "(b) lead not before the planner"
for x in "/main-alfa/.agents/team/teamlead.settings.json' " "--model 'fable' --effort 'high'" \
  "--disallowedTools AskUserQuestion -- " "-e TEAM_SESSION_ROLE=TeamLead"; do
  grep -- "-s alfa-lead" "$STUB_LOG" | grep -qF -- "$x" || fail "(b) lead launch lacks: $x"
done
jq -e --arg r "$RUN_ID" '.run == $r and .model == "fable" and (.main_root | length > 0)' \
  "$TD/teamlead.json" >/dev/null || fail "(b) teamlead.json"
[ -s "$RD/lead-1.session" ] && [ -f "$RD/lead-1.prompt.md" ] && [ -f "$RD/order-brief.md" ] \
  || fail "(b) lead-1 session/prompt or frozen brief missing"
has "$RUN_ID" "$RD/lead-1.prompt.md" && ! grep -q '{{' "$RD/lead-1.prompt.md" || fail "(b) prompt not rendered"
[ "$(ls "$SUP" | wc -l | tr -d ' ')" = 1 ] && grep -q '^event: session_dead' "$SUP"/* \
  && grep -q "^ref: runs/$RUN_ID/planner-" "$SUP"/* || fail "(b) dead planner: no single session_dead"
echo "team-smoke-22: (b) launch OK"

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
jq -n --arg s "$SD/l.sock" '{socket: $s, token: "t", pid: null}' > "$TD/teamlead.reg.json"
session planner 1 "$BASE"; mkrec planner "$BASE" blocked
jq '.message = "which endpoint?"' "$RD/planner-1-1.json" > "$WORK/r" && mv "$WORK/r" "$RD/planner-1-1.json"
mkdir -p "$MAIN/.agents/team/inbox/alfa/new"; echo x > "$MAIN/.agents/team/inbox/alfa/new/20261114T100500Z-Supervisor-collision-answer.md"
export CANCEL_AT=15
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead: planner-1-1.json" "(d) runner on a stop"
has "TeamLead reused: alfa-lead" "$WORK/out" || fail "(d) the live lead of this run was not reused"
has "-s alfa-lead" "$STUB_LOG" && fail "(d) a live lead was launched again"
[ "$(cat "$TD/acked")" = planner-1-1.json ] || fail "(d) record not acked"
for _ in $(seq 1 30); do grep -q 'collision-answer' "$WORK/recv" 2>/dev/null && break; sleep 0.1; done
touch "$WORK/recv"
[ "$(grep -o 'stop planner 1: [^"]*which endpoint' "$WORK/recv" | wc -l | tr -d ' ')" = 1 ] \
  || { { cat "$WORK/recv"; cat "$TD/send-lead.log" 2>/dev/null; } >> "$WORK/out"; fail "(d) not exactly one stop doorbell"; }
# ---- (j) a new file in the team's inbox rings the lead once, over many polls ----
[ "$(grep -o 'inbox: 20261114T100500Z-Supervisor-collision-answer.md' "$WORK/recv" | wc -l | tr -d ' ')" = 1 ] \
  || { cp "$WORK/recv" "$WORK/out"; fail "(j) inbox file not rung exactly once"; }
run "$MAIN" bash .claude/lib/team-lead.sh pending alfa
expect 0 "stop .agents/team/runs/$RUN_ID/planner-1-1.json — which endpoint?" "(d) pending lists the stop"
grep -q '^inbox .*/main/.agents/team/inbox/alfa/new/20261114T100500Z' "$WORK/out" || fail "(d) pending lacks the inbox file"
kill "$SRV" 2>/dev/null || true; SPID=""
# Without a registration the doorbell is skipped and logged (pane not idle).
reset; lead_json; printf 'alfa-lead\nalfa-planner\n' > "$WORK/alive"
session planner 1 "$BASE"; mkrec planner "$BASE" failed; export CANCEL_AT=8
run "$MAIN" $TR alfa; expect 6 "waiting for TeamLead" "(d) failed record, no socket"
[ "$(grep -c 'doorbell-skipped .*stop planner 1' "$TD/send-lead.log")" = 1 ] || fail "(d) skipped doorbell not logged once"
echo "team-smoke-22: (d) wait in place + (j) inbox ring OK"

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
[ "$(grep -c -- '-s alfa-lead' "$STUB_LOG")" = 1 ] && [ -s "$RD/lead-1.session" ] || fail "(e) not relaunched once"
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
has "-s alfa-lead" "$STUB_LOG" && fail "(f) a lead launched in mode cli"
has "-s alfa-cli" "$STUB_LOG" || fail "(f) the cli session did not launch"
jq '.mode = "brainstorm"' "$TD/team.json" > "$WORK/t" && cp "$WORK/t" "$TD/team.json"
echo "team-smoke-22: (f) cli OK"

# ---- (h) end / finalize; team-integrate calls finalize on both success exits ----------------------
reset; lead_json; echo alfa-lead > "$WORK/alive"; echo '{}' > "$TD/teamlead.reg.json"
run "$MAIN" bash .claude/lib/team-lead.sh finalize alfa merged; expect 0 "finalized: alfa $RUN_ID merged" "(h) finalize"
has "kill-session -t =alfa-lead" "$STUB_LOG" || fail "(h) the lead was not ended"
[ -f "$RD/finalized" ] && [ ! -e "$TD/teamlead.reg.json" ] || fail "(h) finalized marker / registration"
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
reset; lead_json; H="$SRC/.claude/hooks/teamlead-register.sh"
reg_hook() {  # reg_hook <sid> [role] — the hook as a session of the clone
  set +e; CLAUDE_PROJECT_DIR="$CLONE" TEAM_SESSION_ROLE="${2-TeamLead}" \
    CLAUDE_CODE_MESSAGING_SOCKET=/tmp/x.sock CLAUDE_CODE_MESSAGING_TOKEN=tok \
    bash "$H" <<<"{\"session_id\": \"$1\"}" > "$WORK/out" 2>&1; RC=$?; set -e
}
reg_hook sid-lead coder; expect 0 "" "(reg) another role"
[ ! -s "$WORK/out" ] && [ ! -e "$TD/teamlead.reg.json" ] || fail "(reg) a non-lead session registered"
reg_hook sid-lead; expect 0 "Pending (oldest first" "(reg) the lead"
[ "$(ls -l "$TD/teamlead.reg.json" | cut -c1-10)" = "-rw-------" ] \
  && jq -e '.socket == "/tmp/x.sock" and .token == "tok" and .session_id == "sid-lead"' \
    "$TD/teamlead.reg.json" >/dev/null || fail "(reg) registration file"
# The registered pid is not an ancestor of this hook: a foreign process (the suite itself may run
# under a claude, so the first registration's pid is not usable here).
jq '.pid = 999999' "$TD/teamlead.reg.json" > "$WORK/r" && mv "$WORK/r" "$TD/teamlead.reg.json"
reg_hook sid-other; expect 0 "" "(reg) a foreign process with another id"
[ "$(jq -r .session_id "$TD/teamlead.json")" = sid-lead ] || fail "(reg) a foreign process moved the id"
jq --argjson p $$ '.pid = $p' "$TD/teamlead.reg.json" > "$WORK/r" && mv "$WORK/r" "$TD/teamlead.reg.json"
reg_hook sid-after-clear; expect 0 "Pending" "(reg) /clear in the lead's own process"
[ "$(jq -r .session_id "$TD/teamlead.json")" = sid-after-clear ] || fail "(reg) /clear did not refresh the id"
echo "team-smoke-22: SessionStart registration OK"

# ---- (i) team-watch: a run with its own lead is filtered, a legacy run is not ---------------------
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
jq -e 'map(select(.kind == "runner") | .team) == ["beta"]' "$WORK/sig.json" >/dev/null \
  || { cp "$WORK/sig.json" "$WORK/out"; fail "(i) signal filter"; }
echo "team-smoke-22: (i) team-watch filter OK"

# ---- (k) team-next archives the run-scoped root files; the next ticket takes the no-lead branch ---
reset; lead_json
for f in teamlead.settings.json round verdict-acked lead-dead relaunch-lead; do echo x > "$TD/$f"; done
mkdir -p "$TD/inbox-rung"; rm -f "$CLONE/.claude/hooks/guard-teamlead-write.sh"
run "$MAIN" perl -e 'alarm 30; exec @ARGV' bash .claude/lib/team-next.sh alfa AB-1501 feature/AB-1501-y origin/develop
expect 0 "was AB-1500" "(k) team-next"
for f in teamlead.json teamlead.settings.json round verdict-acked lead-dead relaunch-lead inbox-rung; do
  [ ! -e "$TD/$f" ] || fail "(k) $f left at the team-dir root"
done
ls "$TD"/archive/AB-1500-*/teamlead.json >/dev/null 2>&1 || fail "(k) teamlead.json not archived"
prof '.teams.teamlead.enabled = false'
: > "$STUB_LOG"; rm -f "$WORK/hs.case"; : > "$WORK/alive"
run "$MAIN" $TR alfa
has "-s alfa-planner" "$STUB_LOG" && ! has "-s alfa-lead" "$STUB_LOG" || fail "(k) next ticket not on the no-lead branch"
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
chk operator; expect 0 "policy-authority: operator" "(j) settings edit, operator"
mkdir -p "$CLONE/.claude/team/sessions"; echo '{"permissions": {"allow": []}}' > "$CLONE/.claude/team/sessions/TeamLead.settings.json"
editp "$CREAL/.claude/team/sessions/TeamLead.settings.json" .claude/team/sessions/TeamLead.settings.json \
  '"allow": []' '"allow": ["Bash(*)"]'
chk teamlead; expect 1 "human-only: settings edit" "(j) guard profile edit"
bashp "cp /tmp/s .claude/settings.json"; chk teamlead; expect 1 "human-only: settings edit" "(j) settings via Bash"
echo "team-smoke-22: (j) settings edit human-only OK"
# ---- (k) a project-added ask is human-only; a baseline ask is the lead's --------------------------
bashp "az webapp restart --name x"; chk teamlead
expect 1 "human-only: production ask: Bash(az webapp restart*)" "(k) project-added ask, teamlead"
chk operator; expect 0 "policy-authority: operator" "(k) project-added ask, operator"
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
chk operator; expect 0 "policy-authority: operator" "(k) rm outside, operator"
for c in "rm -rf .git/objects" "rm -rf .git/refs/heads/x"; do
  bashp "$c"
  for a in teamlead class; do chk "$a"; expect 1 "human-only: irreversible delete inside the git dir" "(k) $c, $a"; done
  chk operator; expect 0 "policy-authority: operator" "(k) $c, operator"
done
for c in "rm -rf ." "rm -rf .git" "rm -rf $CREAL" "rm -rf $CREAL/.git/"; do
  bashp "$c"; chk operator; expect 1 "clone root or its .git — never" "(k) rm of the clone root: $c"
done
bashp "git remote add x https://example.invalid/r.git"
for a in teamlead class; do chk "$a"; expect 1 "human-only: egress: git remote add" "(k) git remote add, $a"; done
chk operator; expect 0 "policy-authority: operator" "(k) git remote add, operator"
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
chk operator; expect 0 "policy-authority: operator" "(egress) operator"
echo "team-smoke-22: authority never-waived + egress OK"

# ---- sender: legacy refusal, caller rules, decision, answers.md, the .answered marker -------------
ANS="bash .claude/lib/team-answer.sh"
lead() { run "$MAIN" env TEAM_SESSION_ROLE=TeamLead TEAM_RUN_TEAM="${LT:-alfa}" $ANS "$@"; }
bashp "git rm old.txt"
run "$MAIN" $ANS alfa coder yes --tier 1; expect 8 "run is owned by its TeamLead — use --authority" "(legacy) --tier in a lead-owned run"
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
expect 0 "sent yes" "(l) operator with an answered decision"
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

echo "team-smoke-22: OK"
