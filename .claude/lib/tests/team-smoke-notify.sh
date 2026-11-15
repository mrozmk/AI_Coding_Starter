#!/usr/bin/env bash
# The Operator's single sender (notify.sh, #38) and the Supervisor's record script
# (operator-record.sh): the closed event vocabulary, write-once dedup, delivery state with crash
# recovery (published / dispatching), the switch file's validation (no channel is built yet, so
# every channel records off), prune at every call (a held entry survives), the flush lock, the
# record script's coalescing and 200-character cut, the role-profile deny. Fixture HOME only:
# nothing reaches a person — no osascript / notify-send call, no file under the real
# ~/.agent-comms, the recipient in no output or outbox file.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
T0="$WORK/t0"; touch "$T0"
N="bash $SRC/.claude/lib/notify.sh"; OR="bash $SRC/.claude/lib/operator-record.sh"
OB="$HOME/.agent-comms/outbox"; CONF="$HOME/.agent-comms/notify.json"; RCP="+48 600 RCPTOKEN"
for b in osascript notify-send terminal-notifier; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/sinks.log"\n' "$b" "$WORK" > "$WORK/bin/$b"; chmod +x "$WORK/bin/$b"
done
nt() { run "$WORK" $N "$@"; }
dec() {  # dec <decision> [summary] — a human_decision of team alfa, run r1
  nt human_decision --project acme --team alfa --ticket AB-1 --run r1 --decision "$1" \
    --summary "${2:-Allow the coder to restart the app?}" --answer acme-alfa-lead \
    --hint "tmux attach -t acme-alfa-lead" --ref "$WORK/d.md"
}
st() { cut -d' ' -f1-2 "$OB/state/$1.$2"; }
conf() { mkdir -p "$HOME/.agent-comms"; printf '%s\n' "$1" > "$CONF"; chmod 600 "$CONF"; }
perm() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

# ---- (a) the vocabulary is closed --------------------------------------------------------------------
nt released --project acme --summary x --answer Supervisor; expect 2 "unknown event 'released'" "(a) unknown event"
nt human_decision --project acme --summary x --answer a; expect 2 "--team '' must be" "(a) decision without team/run/decision"
nt release --project acme --summary x --answer Supervisor; expect 2 "--key '' must be" "(a) release without --key"
nt release --project acme --key k --answer Supervisor; expect 2 "needs --project, --summary and --answer" "(a) no summary"
nt human_decision --project 'ac me' --team alfa --run r1 --decision d-1 --summary x --answer a; expect 2 "--project 'ac me'" "(a) bad id part"
[ ! -d "$OB/events" ] || [ -z "$(ls "$OB/events")" ] || fail "(a) a refused call wrote an event"
echo "team-smoke-notify: (a) vocabulary OK"

# ---- (b) no switch file: written, nothing stored, both channels off ---------------------------------
dec d-1; expect 0 "written acme:alfa:r1:d-1" "(b) first event"
E="$OB/events/acme_alfa_r1_d-1.json"
jq -e '.event == "human_decision" and .team == "alfa" and .ticket == "AB-1" and .decision == "d-1"
  and .summary == null and .ref == null and .answer.hint == "tmux attach -t acme-alfa-lead"
  and .answer.address == "acme-alfa-lead" and .source == "runner"' "$E" >/dev/null || fail "(b) event file"
[ "$(st acme_alfa_r1_d-1 herdr)" = "off switch-off" ] && [ "$(st acme_alfa_r1_d-1 imessage)" = "off switch-off" ] \
  || fail "(b) channel states"
[ "$(perm "$OB")" = 700 ] && [ "$(perm "$OB/events")" = 700 ] && [ "$(perm "$E")" = 600 ] \
  && [ "$(perm "$OB/state/acme_alfa_r1_d-1.herdr")" = 600 ] || fail "(b) outbox 0700 / files 0600"
nt --check; expect 0 "imessage off" "(b) --check"
has "config: missing" "$WORK/out" && has "herdr off" "$WORK/out" && has "outbox: 1 events" "$WORK/out" || fail "(b) --check lines"
nt list; expect 0 "acme:alfa:r1:d-1 human_decision herdr=off imessage=off" "(b) list"
echo "team-smoke-notify: (b) no switch file OK"

# ---- (c) dedup: the same id is a duplicate, no channel past pending is touched -----------------------
before="$(cat "$OB/state/acme_alfa_r1_d-1.herdr")"; sleep 1
dec d-1 "a different text"; expect 0 "duplicate acme:alfa:r1:d-1" "(c) duplicate"
[ "$(ls "$OB/events" | wc -l | tr -d ' ')" = 1 ] && [ "$(cat "$OB/state/acme_alfa_r1_d-1.herdr")" = "$before" ] \
  || fail "(c) a second record or a re-delivered channel"
echo "team-smoke-notify: (c) dedup OK"

# ---- (d) the switch file: invalid → off with the reason; on → summary stored, cut, one line ----------
conf 'not json'; nt --check; expect 0 "config: invalid — not a JSON object" "(d) not JSON"
conf '{"version": 2, "herdr": {"enabled": true}}'; nt --check; expect 0 "invalid — version 2, expected 1" "(d) version"
has "herdr off" "$WORK/out" || fail "(d) herdr on with a bad version"
Q='"quiet": {"start": "22:00", "end": "07:00", "tz": "Europe/Warsaw"}'
conf "{\"version\": 1, \"imessage\": {\"enabled\": true, \"recipient\": \"\", $Q}}"
nt --check; expect 0 "imessage off — empty recipient" "(d) empty recipient"
conf "{\"version\": 1, \"imessage\": {\"enabled\": true, \"recipient\": \"$RCP\", \"quiet\": {\"start\": \"25:00\", \"end\": \"07:00\", \"tz\": \"Europe/Warsaw\"}}}"
nt --check; expect 0 "imessage off — quiet.start '25:00' is not HH:MM" "(d) bad clock"
conf "{\"version\": 1, \"imessage\": {\"enabled\": true, \"recipient\": \"$RCP\", \"quiet\": {\"start\": \"22:00\", \"end\": \"07:00\", \"tz\": \"Europe/DefinitelyMissing\"}}}"
nt --check; expect 0 "imessage off — unknown tz Europe/DefinitelyMissing" "(d) unknown tz"
conf "{\"version\": 1, \"herdr\": {\"enabled\": true}, \"imessage\": {\"enabled\": true, \"recipient\": \"$RCP\", $Q}}"
nt --check; expect 0 "imessage on, recipient set — not built yet (#40), records off" "(d) both on"
has "herdr on — not built yet (#39), records off" "$WORK/out" || fail "(d) herdr on"
LONG="$(printf 'Line one\tand a tab\nline two '; printf 'x%.0s' $(seq 300))"
dec d-2 "$LONG"; expect 0 "written acme:alfa:r1:d-2" "(d) event with the switches on"
E2="$OB/events/acme_alfa_r1_d-2.json"
jq -e --arg r "$WORK/d.md" '(.summary | length) == 200 and (.summary | test("[\\n\\t]") | not)
  and (.summary | startswith("Line one and a tab line two")) and .ref == $r' "$E2" >/dev/null || fail "(d) summary not one 200-char line"
[ "$(st acme_alfa_r1_d-2 herdr)" = "off not-built" ] && [ "$(st acme_alfa_r1_d-2 imessage)" = "off not-built" ] \
  || fail "(d) a channel that is on must record off (not built)"
echo "team-smoke-notify: (d) switch file OK"

# ---- (e) crash after publishing: the next call delivers ----------------------------------------------
NOTIFY_CRASH_AT=published dec d-3; expect 137 "" "(e) crash after publishing"
[ -f "$OB/events/acme_alfa_r1_d-3.json" ] && [ ! -e "$OB/state/acme_alfa_r1_d-3.herdr" ] || fail "(e) state after the crash"
rm -rf "$OB/.flush.lock"   # a killed process may leave it; a dead pid is reclaimed anyway (h)
nt flush; expect 0 "" "(e) flush"
[ "$(st acme_alfa_r1_d-3 herdr)" = "off not-built" ] || fail "(e) not delivered by the next call"
dec d-3; expect 0 "duplicate acme:alfa:r1:d-3" "(e) retry is a duplicate"
echo "team-smoke-notify: (e) crash after publish OK"

# ---- (f) crash while dispatching: outcome_unknown, never re-sent -------------------------------------
NOTIFY_CRASH_AT=dispatching dec d-4; expect 137 "written acme:alfa:r1:d-4" "(f) crash in dispatching"
[ "$(st acme_alfa_r1_d-4 herdr)" = "dispatching -" ] || fail "(f) not dispatching"
nt flush; expect 0 "" "(f) recovery"
[ "$(st acme_alfa_r1_d-4 herdr)" = "outcome_unknown interrupted" ] || fail "(f) not outcome_unknown"
[ "$(st acme_alfa_r1_d-4 imessage)" = "off not-built" ] || fail "(f) the other channel was not delivered"
nt flush; [ "$(st acme_alfa_r1_d-4 herdr)" = "outcome_unknown interrupted" ] || fail "(f) re-sent"
echo "team-smoke-notify: (f) crash in dispatching OK"

# ---- (g) prune at every call; held / pending / dispatching survive -----------------------------------
old() { touch -t 202001010000 "$@"; }
for i in 1 2 3 4; do printf '{"id":"acme:x:%s","event":"release"}\n' "$i" > "$OB/events/acme_x_$i.json"; done
echo "off switch-off -" > "$OB/state/acme_x_1.herdr"; echo "off switch-off -" > "$OB/state/acme_x_1.imessage"
echo "held - -" > "$OB/state/acme_x_2.imessage"; echo "off - -" > "$OB/state/acme_x_2.herdr"
echo "dispatching - -" > "$OB/state/acme_x_3.imessage"
: # acme_x_4 has no state at all → pending
echo "off - -" > "$OB/state/acme_gone.herdr"
echo '{}' > "$OB/herdr/done/old.json"; echo '{}' > "$OB/herdr/done/new.json"
old "$OB"/events/acme_x_*.json "$OB"/state/acme_x_* "$OB/state/acme_gone.herdr" "$OB/herdr/done/old.json"
CONF_KEEP="$(cat "$CONF")"; rm -f "$CONF"   # flush with the switches off would turn held into off
nt list; expect 0 "" "(g) list prunes"
[ ! -e "$OB/events/acme_x_1.json" ] && [ ! -e "$OB/state/acme_x_1.herdr" ] || fail "(g) a settled old event survived"
[ -f "$OB/events/acme_x_2.json" ] && [ -f "$OB/events/acme_x_3.json" ] && [ -f "$OB/events/acme_x_4.json" ] \
  || fail "(g) a held / dispatching / pending event was pruned"
[ ! -e "$OB/state/acme_gone.herdr" ] && [ ! -e "$OB/herdr/done/old.json" ] && [ -f "$OB/herdr/done/new.json" ] \
  || fail "(g) orphan state or the 24 h spool"
[ -f "$E" ] || fail "(g) a fresh event was pruned"
rm -f "$OB"/events/acme_x_*.json "$OB"/state/acme_x_*; conf "$CONF_KEEP"
# A HOME with a space: prune removes the settled old event and never a path split at the space.
SH="$WORK/sp ace"; SO="$SH/.agent-comms/outbox"; mkdir -p "$SO/events" "$SO/state"; echo keep > "$WORK/sp"
printf '{"id":"acme:x:9","event":"release"}\n' > "$SO/events/acme_x_9.json"
echo "off - -" > "$SO/state/acme_x_9.herdr"; echo "off - -" > "$SO/state/acme_x_9.imessage"
old "$SO/events/acme_x_9.json" "$SO"/state/acme_x_9.*
HOME="$SH" run "$WORK" $N list; expect 0 "" "(g) list with a spaced HOME"
[ ! -e "$SO/events/acme_x_9.json" ] && [ ! -e "$SO/state/acme_x_9.herdr" ] && [ -f "$WORK/sp" ] \
  || fail "(g) prune under a HOME with a space"
echo "team-smoke-notify: (g) prune OK"

# ---- (h) the flush lock: two at once both finish; a dead holder is reclaimed --------------------------
mkdir "$OB/.flush.lock"; echo 999999 > "$OB/.flush.lock/pid"
nt flush; expect 0 "" "(h) stale lock reclaimed"
( $N flush > "$WORK/f1" 2>&1; echo $? > "$WORK/r1" ) & ( $N flush > "$WORK/f2" 2>&1; echo $? > "$WORK/r2" ) &
wait
[ "$(cat "$WORK/r1")" = 0 ] && [ "$(cat "$WORK/r2")" = 0 ] && [ ! -e "$OB/.flush.lock" ] || fail "(h) concurrent flushes"
echo "team-smoke-notify: (h) lock OK"

# ---- (i) operator-record.sh: vocabulary, coalescing, close → a new event, the cut, --ref -------------
orr() { run "$MAIN" $OR "$@"; }
orr shipped --summary x; expect 2 "" "(i) unknown verb"
orr human_decision --summary x; expect 2 "" "(i) cannot impersonate a TeamLead decision"
orr failure --team alfa --summary "$(printf 'alfa-lead will not restart\n%s' "$(printf 'y%.0s' $(seq 300))")"
expect 0 "recorded " "(i) failure"
ID1="$(sed -n 's/^recorded //p' "$WORK/out")"; R1="$MAIN/.agents/team/operator/$ID1.md"
[ "$(perm "$MAIN/.agents/team/operator")" = 700 ] || fail "(i) operator dir mode"
grep -qx 'status: open' "$R1" && grep -qx 'team: alfa' "$R1" || fail "(i) frontmatter"
[ "$(sed '1,/^---$/d' "$R1" | wc -l | tr -d ' ')" = 1 ] && [ "$(sed '1,/^---$/d' "$R1" | tr -d '\n' | wc -m | tr -d ' ')" = 200 ] \
  || fail "(i) summary not one 200-char line"
EV="$(ls "$OB/events" | grep "_failure_$ID1\.json$")" || fail "(i) no failure event"
jq -e --arg k "$ID1" '.event == "unrepaired_failure" and (.id | endswith(":failure:" + $k)) and .team == "alfa"
  and .source == "operator-record" and .answer.address == "Supervisor" and (.answer.hint | test("supervisor$"))' \
  "$OB/events/$EV" >/dev/null || fail "(i) event fields"
orr failure --team alfa --summary "$(printf 'alfa-lead will not restart\n%s' "$(printf 'y%.0s' $(seq 300))")"
expect 0 "open $ID1 (coalesced)" "(i) an open repeat"
[ "$(ls "$OB/events" | grep -c '_failure_')" = 1 ] || fail "(i) the repeat sent again"
orr close "$ID1"; expect 0 "closed $ID1" "(i) close"
grep -qx 'status: closed' "$R1" && grep -q '^closed_at: ' "$R1" || fail "(i) not closed"
sleep 1
orr failure --team alfa --summary "$(printf 'alfa-lead will not restart\n%s' "$(printf 'y%.0s' $(seq 300))")"
expect 0 "recorded " "(i) same text after close"
[ "$(ls "$OB/events" | grep -c '_failure_')" = 2 ] || fail "(i) after close the same text is a new event"
orr release --summary "publish waits for the Operator" --ref "$WORK/t0"; expect 2 "inside the main checkout" "(i) --ref outside"
orr release --summary "publish waits for the Operator" --ref "$MAIN/README"; expect 0 "recorded " "(i) release"
CL="$WORK/clone"; mkdir -p "$CL/.agents/team"; git -C "$CL" init --quiet; echo '{"team":"alfa"}' > "$CL/.agents/team/team.json"
run "$CL" $OR failure --summary x
expect 1 "run from the main checkout" "(i) refused in a team clone"
echo "team-smoke-notify: (i) operator-record OK"

# ---- (j) the role profiles deny notify.sh; a profile without the rule fails the check -----------------
mkdir -p "$WORK/prof"
jq '.permissions.deny -= ["Bash(*notify.sh*)"]' "$SRC/.claude/team/sessions/Supervisor.settings.json" \
  > "$WORK/prof/Supervisor.settings.json"
run "$SRC" python3 -I .claude/lib/session_profile_check.py "$SRC" --profiles "$WORK/prof" Supervisor
[ "$RC" != 0 ] && has "notify.sh flush' → prompt, expected deny" "$WORK/out" || fail "(j) a missing deny passed"
run "$SRC" python3 -I .claude/lib/session_profile_check.py "$SRC" --profiles "$SRC/.claude/team/sessions" Supervisor TeamLead
expect 0 "TeamLead OK" "(j) the shipped profiles"
echo "team-smoke-notify: (j) profile deny OK"

# ---- nothing reached a person; the recipient is nowhere ----------------------------------------------
[ ! -s "$WORK/sinks.log" ] || { cp "$WORK/sinks.log" "$WORK/out"; fail "a platform notifier was called"; }
! grep -rlF "RCPTOKEN" "$OB" "$MAIN/.agents/team" "$WORK/out" "$WORK"/f1 "$WORK"/f2 2>/dev/null | grep -q . \
  || fail "the recipient appears outside the switch file"
REAL="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
[ -z "$REAL" ] || [ "$HOME" != "$REAL" ] || fail "the part ran with the real HOME"
d="${REAL:-/nonexistent}/.agent-comms"
[ ! -d "$d" ] || [ -z "$(find "$d" -type f -newer "$T0" -exec grep -lF -e "$WORK" -e acme_alfa_r1 -e RCPTOKEN {} + 2>/dev/null)" ] \
  || fail "a fixture file appeared under the real ~/.agent-comms"
echo "team-smoke-notify: nothing outside the fixture OK"
echo "team-smoke-notify: OK"
