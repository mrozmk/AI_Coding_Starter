#!/usr/bin/env bash
# The Operator's single sender (notify.sh, #38) and the Supervisor's record script
# (operator-record.sh): the closed event vocabulary, write-once dedup, delivery state with crash
# recovery (published / dispatching), the switch file's validation, the iMessage channel (#40: the
# sender against an osascript stub, quiet hours, the held batch, retries, the flush-job kit with a
# launchctl stub), the Herdr channel (#39: the spool entry, the registry record, the mod's logic under
# node, the installer in a fixture app home), prune at every call (a held entry survives), the flush lock, the
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
# The iMessage sender's osascript: a stub that never logs the recipient (it checks it and writes a
# token), with a scripted rc / stderr / delay. A real osascript or launchctl is never reached.
OSL="$WORK/osa.log"
cat > "$WORK/osa" <<EOF
#!/usr/bin/env bash
case "\$3" in "$RCP") r=RCPT ;; *) r=WRONG-RECIPIENT ;; esac
printf '%s|%s|%s\n' "\$1" "\$(printf '%s' "\$2" | head -1)" "\$r" >> "$OSL"
printf '%s' "\$4" > "$WORK/osa.last"; printf '%s\n' "\$4" >> "$WORK/osa.texts"
[ ! -f "$WORK/osa.sleep" ] || sleep "\$(cat "$WORK/osa.sleep")"
[ ! -f "$WORK/osa.err" ] || cat "$WORK/osa.err" >&2
exit "\$(cat "$WORK/osa.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$WORK/osa"
export NOTIFY_OSASCRIPT_BIN="$WORK/osa" NOTIFY_SYSTEM_TZ=Europe/Warsaw
at() { TZ=Europe/Warsaw date -j -f '%Y-%m-%d %H:%M:%S' "$1:00" +%s 2>/dev/null || TZ=Europe/Warsaw date -d "$1" +%s; }
NOON="$(at '2026-11-15 12:00')"; export NOTIFY_NOW="$NOON"   # outside quiet hours unless a case says so
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
nt --check; expect 0 "imessage on, recipient set — quiet 22:00–07:00 Europe/Warsaw (not quiet), 0 held, flush job: missing" "(d) both on"
has "herdr on — mod not seen (no layout shows the harness-notify strip?)" "$WORK/out" || fail "(d) herdr on"
LONG="$(printf 'Line one\tand a tab\nline two '; printf 'x%.0s' $(seq 300))"
dec d-2 "$LONG"; expect 0 "written acme:alfa:r1:d-2" "(d) event with the switches on"
E2="$OB/events/acme_alfa_r1_d-2.json"
jq -e --arg r "$WORK/d.md" '(.summary | length) == 200 and (.summary | test("[\\n\\t]") | not)
  and (.summary | startswith("Line one and a tab line two")) and .ref == $r' "$E2" >/dev/null || fail "(d) summary not one 200-char line"
[ "$(st acme_alfa_r1_d-2 herdr)" = "skipped-tmux -" ] && [ "$(st acme_alfa_r1_d-2 imessage)" = "submitted -" ] \
  || fail "(d) herdr skips a session with no herdr record; imessage is sent on any backend"
echo "team-smoke-notify: (d) switch file OK"

# ---- (e) crash after publishing: the next call delivers ----------------------------------------------
NOTIFY_CRASH_AT=published dec d-3; expect 137 "" "(e) crash after publishing"
[ -f "$OB/events/acme_alfa_r1_d-3.json" ] && [ ! -e "$OB/state/acme_alfa_r1_d-3.herdr" ] || fail "(e) state after the crash"
rm -rf "$OB/.flush.lock"   # a killed process may leave it; a dead pid is reclaimed anyway (h)
nt flush; expect 0 "" "(e) flush"
[ "$(st acme_alfa_r1_d-3 herdr)" = "skipped-tmux -" ] || fail "(e) not delivered by the next call"
dec d-3; expect 0 "duplicate acme:alfa:r1:d-3" "(e) retry is a duplicate"
echo "team-smoke-notify: (e) crash after publish OK"

# ---- (f) crash while dispatching: outcome_unknown, never re-sent -------------------------------------
# iMessage alone, so the crash hits a send that is not idempotent (a Herdr spool write is: (k)).
BOTH="$(cat "$CONF")"
conf "{\"version\": 1, \"imessage\": {\"enabled\": true, \"recipient\": \"$RCP\", $Q}}"
NOTIFY_CRASH_AT=dispatching dec d-4; expect 137 "written acme:alfa:r1:d-4" "(f) crash in dispatching"
[ "$(st acme_alfa_r1_d-4 imessage)" = "dispatching -" ] || fail "(f) not dispatching"
nt flush; expect 0 "" "(f) recovery"
[ "$(st acme_alfa_r1_d-4 imessage)" = "outcome_unknown interrupted" ] || fail "(f) not outcome_unknown"
[ "$(st acme_alfa_r1_d-4 herdr)" = "off switch-off" ] || fail "(f) the other channel was not delivered"
nt flush; [ "$(st acme_alfa_r1_d-4 imessage)" = "outcome_unknown interrupted" ] || fail "(f) re-sent"
conf "$BOTH"
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
  and .source == "operator-record" and .answer.address == "Supervisor" and .answer.hint == "tmux attach -t smk-supervisor"' \
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
# No session host for the hint (a record the driver refuses): a true line, never a guessed tmux name.
RG="$MAIN/.agents/team/registry"; mkdir -p "$RG"; [ ! -f "$RG/Supervisor.json" ] || mv "$RG/Supervisor.json" "$WORK/sup.json"
echo '{"backend": "bogus"}' > "$RG/Supervisor.json"
orr failure --summary "the hint has no host"; expect 0 "recorded " "(i) no session host"
ID2="$(sed -n 's/^recorded //p' "$WORK/out")"; EV="$(ls "$OB/events" | grep "_failure_$ID2\.json$")" || fail "(i) no event without a host"
jq -e '.answer.hint == "no Supervisor session found — bash .claude/lib/roles.sh status"' "$OB/events/$EV" >/dev/null \
  || { cp "$OB/events/$EV" "$WORK/out"; fail "(i) the no-host hint"; }
rm "$RG/Supervisor.json"; [ ! -f "$WORK/sup.json" ] || mv "$WORK/sup.json" "$RG/Supervisor.json"
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

# ---- (k) the Herdr channel (#39): spool entry from the registry record, the mod's logic, the installer -
conf '{"version": 1, "herdr": {"enabled": true}}'
MH="$WORK/hmain"; mkdir -p "$MH/.agents/team/registry"; git -C "$MH" init -q
reg() { printf '%s\n' "$2" > "$MH/.agents/team/registry/$1.json"; }
reg acme-alfa-lead '{"backend": "herdr", "handle": "t3k9", "name": "acme-alfa-lead"}'
reg acme-beta-lead '{"backend": "tmux", "handle": "acme-beta-lead"}'
reg acme-gamma-lead '{"backend": "herdr", "handle": "t1; touch /tmp/x"}'
reg Supervisor '{"backend": "herdr", "handle": "vps/t7"}'
hdec() {  # hdec <decision> <answer> — no --hint: the registry record decides it
  nt human_decision --project acme --team alfa --ticket AB-1 --run r2 --decision "$1" \
    --summary "Restart the app?" --answer "$2" --main "$MH"
}
HN="$OB/herdr/new"
hdec h-1 acme-alfa-lead; expect 0 "written acme:alfa:r2:h-1" "(k) a herdr answer"
[ "$(st acme_alfa_r2_h-1 herdr)" = "spooled -" ] || fail "(k) herdr not spooled"
jq -e '.answer == {address: "acme-alfa-lead", backend: "herdr", handle: "t3k9",
  hint: "hc attach t3k9 · herdr: acme-alfa-lead (in the agent list once placed)"}' "$OB/events/acme_alfa_r2_h-1.json" >/dev/null \
  || fail "(k) the event's answer is not the registry's"
jq -e '(keys == ["action","body","created_at","id","title"]) and .id == "acme_alfa_r2_h-1"
  and .title == "[acme] decision"
  and .body == "alfa AB-1 h-1 — Restart the app? — answer: hc attach t3k9 · herdr: acme-alfa-lead (in the agent list once placed)"
  and .action == {name: "agent.focus", args: {terminal: "t3k9"}}' "$HN/acme_alfa_r2_h-1.json" >/dev/null \
  || { cp "$HN/acme_alfa_r2_h-1.json" "$WORK/out"; fail "(k) the spool entry"; }
[ "$(perm "$HN/acme_alfa_r2_h-1.json")" = 600 ] || fail "(k) spool entry mode"
hdec h-1 acme-alfa-lead; expect 0 "duplicate acme:alfa:r2:h-1" "(k) a duplicate"
[ "$(ls "$HN" | grep -c .)" = 1 ] || fail "(k) a duplicate wrote a second entry"
mv "$HN/acme_alfa_r2_h-1.json" "$OB/herdr/done/"   # what the mod does after the toast
NOTIFY_CRASH_AT=dispatching hdec h-2 acme-alfa-lead; expect 137 "" "(k) crash while spooling"
rm -rf "$OB/.flush.lock"; nt flush
[ "$(st acme_alfa_r2_h-2 herdr)" = "spooled -" ] && [ -f "$HN/acme_alfa_r2_h-2.json" ] || fail "(k) an interrupted spool is not redone"
nt flush; [ ! -e "$HN/acme_alfa_r2_h-1.json" ] || fail "(k) an entry the mod moved was spooled again"
hdec h-3 acme-beta-lead; [ "$(st acme_alfa_r2_h-3 herdr)" = "skipped-tmux -" ] && [ ! -e "$HN/acme_alfa_r2_h-3.json" ] \
  || fail "(k) a tmux record was spooled"
jq -e '.answer.hint == "tmux attach -t acme-beta-lead" and .answer.backend == "tmux"' "$OB/events/acme_alfa_r2_h-3.json" >/dev/null \
  || fail "(k) the tmux hint"
hdec h-4 acme-gamma-lead; [ "$(st acme_alfa_r2_h-4 herdr)" = "skipped-tmux -" ] || fail "(k) a malformed handle was spooled"
nt human_decision --project acme --team alfa --run r2 --decision h-7 --summary "Q?" --answer acme-alfa-lead \
  --hint "tmux attach -t acme-alfa-lead" --main "$MH"   # the callers' tmux fallback hint
jq -e '.answer.hint | startswith("hc attach t3k9 · herdr: acme-alfa-lead")' "$OB/events/acme_alfa_r2_h-7.json" >/dev/null \
  || fail "(k) a caller's tmux hint replaced the herdr hint"
hdec h-5 acme-delta-lead; [ "$(st acme_alfa_r2_h-5 herdr)" = "skipped-tmux -" ] || fail "(k) no record was spooled"
nt release --project acme --summary "Approve the release?" --answer Supervisor --key rel-1 --main "$MH"
jq -e '.title == "[acme] release" and (.body | startswith("Approve the release? — answer: hc attach vps/t7 · herdr: Supervisor"))
  and .action.args.terminal == "vps/t7"' "$HN/acme_release_rel-1.json" >/dev/null || fail "(k) a Supervisor entry (no team words, a remote handle)"
nt --check; expect 0 "herdr on — mod not seen (no layout" "(k) no heartbeat"
touch "$OB/herdr/.mod-alive"; nt --check; expect 0 "herdr on — mod seen " "(k) a fresh heartbeat"
touch -t "$(date -v-10M +%Y%m%d%H%M.%S)" "$OB/herdr/.mod-alive"; nt --check; expect 0 "herdr on — mod not seen for " "(k) an old heartbeat"
conf '{"version": 1}'; hdec h-6 acme-alfa-lead
[ "$(st acme_alfa_r2_h-6 herdr)" = "off switch-off" ] && [ ! -e "$HN/acme_alfa_r2_h-6.json" ] || fail "(k) herdr off spooled"
echo "team-smoke-notify: (k) spool writer OK"

# The mod's logic (spool.js) under node, on the entries notify.sh wrote.
MOD="$SRC/.claude/team/herdr-mod/harness-notify"
if command -v node >/dev/null 2>&1; then
  cp "$HN/acme_alfa_r2_h-2.json" "$WORK/entry.json"
  printf '%s\n' '{"id":"bad","title":"t","body":"b","created_at":"2026-01-01T00:00:00Z","action":{"name":"agent.focus","args":{"terminal":"t1; rm -rf ~"}}}' > "$WORK/badact.json"
  run "$WORK" node --input-type=module -e '
    import * as s from "'"$MOD"'/spool.js"; import { readFileSync } from "fs";
    const ok = (c, m) => { if (!c) { console.log("FAIL " + m); process.exit(1); } };
    const now = Date.parse(JSON.parse(readFileSync("entry.json", "utf8")).created_at) + 1000;
    ok(s.idOf("acme_alfa_r2_h-2.json") === "acme_alfa_r2_h-2", "idOf");
    for (const n of [".tmp.1", "..json", ".x.json", "a/b.json", "x.txt", "a b.json"]) ok(s.idOf(n) === null, "idOf rejects " + n);
    const [cmd, args] = s.moveArgs("/H", "acme_alfa_r2_h-2");
    ok(cmd === "mv" && args.join(" ") === "-f /H/.agent-comms/outbox/herdr/new/acme_alfa_r2_h-2.json /H/.agent-comms/outbox/herdr/done/acme_alfa_r2_h-2.json", "moveArgs");
    for (const b of ["../x", "a/b", ".x", "a;b", ""]) { let t = false; try { s.moveArgs("/H", b); } catch { t = true; } ok(t, "moveArgs refuses " + b); }
    const r = s.parse("acme_alfa_r2_h-2", readFileSync("entry.json", "utf8"), now);
    ok(!r.error && !r.stale && r.item.action.args.terminal === "t3k9" && r.item.title === "[acme] decision", "parse");
    const t = s.toast(r.item);
    ok(t.level === "warning" && t.action.name === "agent.focus" && t.body.includes("Restart the app?"), "toast");
    ok(s.parse("acme_alfa_r2_h-2", readFileSync("entry.json", "utf8"), now + 25 * 3600e3).stale, "stale after 24 h");
    ok(s.parse("other", readFileSync("entry.json", "utf8"), now).error, "id must match the file name");
    ok(s.parse("x", "not json", now).error, "not JSON");
    const b = s.parse("bad", readFileSync("badact.json", "utf8"), Date.parse("2026-01-01T00:00:01Z"));
    ok(!b.error && b.item.action === null && !("action" in s.toast(b.item)), "a malformed terminal drops the action");
    let l = s.add([], r.item); l = s.add(l, r.item); ok(l.length === 1, "add dedups");
    ok(s.stripText(l).startsWith("1 waiting — [acme] decision — alfa AB-1"), "strip text");
    ok(s.stripText(s.ack(l, r.item.id)) === "harness: watching", "ack");
    ok(s.expire(l, now + 25 * 3600e3).length === 0 && s.expire(l, now).length === 1, "expire");
    ok(s.load("garbage").length === 0 && s.load(JSON.stringify([{ id: "../x" }, r.item])).length === 1, "load");
    console.log("spool.js OK");'
  expect 0 "spool.js OK" "(k) the mod logic under node"
  run "$WORK" node --check "$MOD/main.js"; expect 0 "" "(k) main.js parses"
  # main.js reaches files and programs only through spool.js's paths: two exec calls (touch the
  # heartbeat, the move), reads only under the spool's new/.
  [ "$(grep -c 'exec(' "$MOD/main.js")" = 2 ] && grep -q 'exec("touch", \[this.d.alive\])' "$MOD/main.js" \
    && grep -q 'spool.moveArgs(home(), id)' "$MOD/main.js" \
    && grep -q 'this.scan(cx); this.watch(cx);' "$MOD/main.js" \
    && [ "$(grep -o 'readTextFile([^)]*)\|readdir([^)]*)' "$MOD/main.js" | grep -vc 'this.d.new')" = 0 ] \
    || fail "(k) main.js reaches a path or a program outside the spool"
  echo "team-smoke-notify: (k) mod logic OK"
else
  echo "team-smoke-notify: (k) mod logic skipped — no node"
fi

# The installer, in a fixture Herdr app home: only its own folder, never a foreign one.
APPH="$WORK/herdr-app"; mkdir -p "$APPH/mods/toast" "$APPH/layouts"
echo '{"sounds": {"enabled": false}}' > "$APPH/settings.json"; echo 'export default 1;' > "$APPH/mods/toast/main.js"
echo '{}' > "$APPH/layouts/main.json"
snap() { (cd "$APPH" && find . -path ./mods/harness-notify -prune -o -type f -print | sort | xargs shasum); }
snap > "$WORK/apph.before"
INST="bash $SRC/.claude/team/herdr-mod/install.sh"
IH="$WORK/ihome"; mkdir -p "$IH"   # a HOME with no spool yet: the mod's first start
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
HOME="$IH" HERDR_APP_HOME="$APPH" run "$WORK" $INST --dry-run; expect 0 "would install $APPH/mods/harness-notify" "(k) dry run"
grep -qF "would create $IH/.agent-comms/outbox/herdr/new and" "$WORK/out" || fail "(k) the dry run does not name the spool"
[ ! -e "$APPH/mods/harness-notify" ] && [ ! -e "$IH/.agent-comms" ] || fail "(k) the dry run wrote"
HOME="$IH" HERDR_APP_HOME="$APPH" run "$WORK" $INST; expect 0 "installed $APPH/mods/harness-notify" "(k) install"
for d in "" /outbox /outbox/herdr /outbox/herdr/new /outbox/herdr/done; do
  [ "$(mode "$IH/.agent-comms$d")" = 700 ] || fail "(k) the installer did not create $d with mode 700"; done
[ -z "$(find "$IH" -type f)" ] || fail "(k) the installer wrote a file into the spool"
for f in main.js spool.js mod.json README.md; do cmp -s "$MOD/$f" "$APPH/mods/harness-notify/$f" || fail "(k) $f not copied"; done
[ -f "$APPH/mods/harness-notify/.installed-by-harness" ] || fail "(k) no ownership marker"
HERDR_APP_HOME="$APPH" run "$WORK" $INST; expect 0 "updated $APPH/mods/harness-notify" "(k) update"
snap > "$WORK/apph.after"; cmp -s "$WORK/apph.before" "$WORK/apph.after" || fail "(k) the installer touched another file of the app home"
touch "$APPH/mods/harness-notify/notes.txt" "$APPH/mods/harness-notify/jsconfig.json" "$APPH/mods/harness-notify/gpui-kit.d.ts"
HERDR_APP_HOME="$APPH" run "$WORK" $INST --rollback; expect 3 "holds files the harness did not install" "(k) rollback keeps a foreign file"
[ -f "$APPH/mods/harness-notify/jsconfig.json" ] && [ -f "$APPH/mods/harness-notify/main.js" ] || fail "(k) a refused rollback removed something"
rm "$APPH/mods/harness-notify/notes.txt"
HOME="$IH" HERDR_APP_HOME="$APPH" run "$WORK" $INST --rollback; expect 0 "removed $APPH/mods/harness-notify" "(k) rollback"
[ ! -e "$APPH/mods/harness-notify" ] || fail "(k) rollback left the folder (or Herdr's own jsconfig.json / .d.ts)"
[ -d "$IH/.agent-comms/outbox/herdr/new" ] && [ -d "$IH/.agent-comms/outbox/herdr/done" ] || fail "(k) rollback removed the spool"
mkdir "$APPH/mods/harness-notify"; echo mine > "$APPH/mods/harness-notify/main.js"
HERDR_APP_HOME="$APPH" run "$WORK" $INST; expect 3 "was not installed by the harness" "(k) a foreign folder"
HERDR_APP_HOME="$APPH" run "$WORK" $INST --rollback; expect 3 "was not installed by the harness" "(k) rollback of a foreign folder"
[ "$(cat "$APPH/mods/harness-notify/main.js")" = mine ] || fail "(k) a foreign folder was touched"
snap > "$WORK/apph.after"; cmp -s "$WORK/apph.before" "$WORK/apph.after" || fail "(k) another file of the app home changed"
HERDR_APP_HOME="$WORK/no-app" run "$WORK" $INST; expect 3 "no Herdr app home" "(k) no app home"
HERDR_APP_HOME="$APPH" run "$WORK" $INST --bogus; expect 2 "Usage:" "(k) usage"
echo "team-smoke-notify: (k) installer OK"

# ---- (l) iMessage (#40): the sender, quiet hours, the held batch, retries, the flush-job kit -----------
conf "{\"version\": 1, \"imessage\": {\"enabled\": true, \"recipient\": \"$RCP\", $Q}}"
rm -f "$OSL" "$WORK/osa.texts" "$WORK/osa.rc" "$WORK/osa.err" "$WORK/osa.sleep"
calls() { [ -f "$OSL" ] && wc -l < "$OSL" | tr -d ' ' || echo 0; }
rel() { nt release --project acme --key "$1" --summary "${2:-step $1 waits}" --answer Supervisor ${3:+--now "$3"}; }
NIGHT="$(at '2026-11-15 23:00')"; LATE="$(at '2026-11-16 03:00')"; END="$(at '2026-11-16 07:00')"
# A send outside quiet hours: the fixed script, the recipient (checked by the stub), the text as argv.
dec d-7 "Allow the coder to restart the app?"; expect 0 "written acme:alfa:r1:d-7" "(l) decision"
[ "$(st acme_alfa_r1_d-7 imessage)" = "submitted -" ] || fail "(l) not submitted"
[ "$(tail -1 "$OSL")" = "-e|on run argv|RCPT" ] || fail "(l) osascript argv: $(tail -1 "$OSL")"
[ "$(cat "$WORK/osa.last")" = "[acme] decision: alfa AB-1 d-7 — Allow the coder to restart the app? — answer: tmux attach -t acme-alfa-lead" ] \
  || fail "(l) message text: $(cat "$WORK/osa.last")"
! grep -qF "$WORK/d.md" "$WORK/osa.texts" || fail "(l) the ref path left the machine"
rel r1; [ "$(cat "$WORK/osa.last")" = "[acme] release — step r1 waits — answer: tmux attach -t Supervisor" ] \
  || fail "(l) a Supervisor event's text: $(cat "$WORK/osa.last")"
# A pre-send failure (its stderr echoes the recipient): failed, retried at the next calls, 3 attempts.
echo "execution error: Messages got an error: Can't send to $RCP. (-1743)" > "$WORK/osa.err"; echo 1 > "$WORK/osa.rc"
c0="$(calls)"; rel r2; expect 0 "written acme:release:r2" "(l) failed send"
[ "$(cat "$OB/state/acme_release_r2.imessage" | cut -d' ' -f1,2,4)" = "failed -1743 1" ] || fail "(l) failed, attempt 1"
nt flush; nt flush; nt flush
[ "$(cut -d' ' -f1,2,4 "$OB/state/acme_release_r2.imessage")" = "failed -1743 3" ] && [ "$(calls)" = $((c0 + 3)) ] \
  || fail "(l) failed: not exactly 3 attempts ($(calls) calls)"
# Anything else is final: outcome_unknown, never retried; a hang is cut at the timeout.
echo "execution error: something else (-1712)" > "$WORK/osa.err"
c0="$(calls)"; rel r3; nt flush
[ "$(st acme_release_r3 imessage)" = "outcome_unknown -1712" ] && [ "$(calls)" = $((c0 + 1)) ] || fail "(l) -1712 retried or not outcome_unknown"
rm -f "$WORK/osa.err" "$WORK/osa.rc"; echo 5 > "$WORK/osa.sleep"
NOTIFY_SEND_TIMEOUT=1 rel r4; [ "$(st acme_release_r4 imessage)" = "outcome_unknown timeout" ] || fail "(l) a hang is not outcome_unknown timeout"
rm -f "$WORK/osa.sleep"
echo "team-smoke-notify: (l) sender OK"

# Quiet hours (22:00–07:00 Warsaw, across midnight): held, nothing sent; the first flush at quiet.end
# (the end is exclusive) sends them as one message, oldest first.
c0="$(calls)"
rel q1 "first at night" "$NIGHT"; sleep 1; rel q2 "second after midnight" "$LATE"; sleep 1
nt human_decision --project acme --team beta --ticket AB-2 --run r1 --decision d-1 --summary "third" \
  --answer acme-beta-lead --hint "tmux attach -t acme-beta-lead" --now "$LATE"
[ "$(st acme_release_q1 imessage)" = "held -" ] && [ "$(st acme_release_q2 imessage)" = "held -" ] \
  && [ "$(st acme_beta_r1_d-1 imessage)" = "held -" ] && [ "$(calls)" = "$c0" ] || fail "(l) quiet hours: not held"
NOTIFY_NOW="$LATE" nt --check; expect 0 "(quiet now), 3 held" "(l) --check in quiet hours"
nt flush --now "$((END - 60))"; [ "$(calls)" = "$c0" ] || fail "(l) a flush at 06:59 sent"
nt flush --now "$END"; [ "$(calls)" = $((c0 + 1)) ] || fail "(l) the flush at quiet.end did not send once"
printf '%s\n' "[harness] 3 held overnight" "[acme] release — first at night — answer: tmux attach -t Supervisor" \
  "[acme] release — second after midnight — answer: tmux attach -t Supervisor" \
  "[acme] decision: beta AB-2 d-1 — third — answer: tmux attach -t acme-beta-lead" | cmp -s - <(cat "$WORK/osa.last"; echo) \
  || fail "(l) the batch text: $(cat "$WORK/osa.last")"
for i in q1 q2; do [ "$(st acme_release_$i imessage)" = "submitted -" ] || fail "(l) $i not submitted"; done
nt flush --now "$END"; [ "$(calls)" = $((c0 + 1)) ] || fail "(l) the batch went twice"
# One held event still gets the batch form; a long night is cut to 1,000 characters.
rel q3 "alone" "$NIGHT"; nt flush --now "$END"
head -1 "$WORK/osa.last" | grep -qx "\[harness\] 1 held overnight" || fail "(l) one held event without the batch header"
# A held event without created_at is still batched and settled (not an empty "1 held" message every flush).
printf '{"id":"acme:x:7","event":"release","project":"acme","summary":"no stamp","answer":{"hint":"h"}}\n' > "$OB/events/acme_x_7.json"
echo "held - -" > "$OB/state/acme_x_7.imessage"; nt flush --now "$END"
[ "$(st acme_x_7 imessage)" = "submitted -" ] && grep -qF "no stamp" "$WORK/osa.last" || fail "(l) a held event without created_at"
for i in 1 2 3 4 5 6 7 8; do rel "w$i" "$(printf 'w%.0s' $(seq 190))" "$NIGHT"; done
nt flush --now "$END"
[ "$(wc -m < "$WORK/osa.last" | tr -d ' ')" -le 1000 ] && tail -1 "$WORK/osa.last" | grep -qE '^… and [0-9]+ more$' \
  && head -1 "$WORK/osa.last" | grep -qx "\[harness\] 8 held overnight" || fail "(l) the long batch is not cut"
echo "team-smoke-notify: (l) quiet hours and the batch OK"

# A crash inside the batch: all of it outcome_unknown, nothing sent twice.
rel x1 "" "$NIGHT"; rel x2 "" "$NIGHT"; c0="$(calls)"
NOTIFY_CRASH_AT=batch nt flush --now "$END"; expect 137 "" "(l) crash in the batch"
rm -rf "$OB/.flush.lock"
[ "$(st acme_release_x1 imessage)" = "dispatching -" ] && [ "$(st acme_release_x2 imessage)" = "dispatching -" ] || fail "(l) batch not dispatching"
nt flush --now "$END"
[ "$(st acme_release_x1 imessage)" = "outcome_unknown interrupted" ] && [ "$(st acme_release_x2 imessage)" = "outcome_unknown interrupted" ] \
  && [ "$(calls)" = "$c0" ] || fail "(l) a crashed batch was re-sent"
# A failed batch goes back to held with its attempt count; the third failure is final.
rel y1 "" "$NIGHT"; echo "x (-600)" > "$WORK/osa.err"; echo 1 > "$WORK/osa.rc"; c0="$(calls)"
nt flush --now "$END"; [ "$(cut -d' ' -f1,2,4 "$OB/state/acme_release_y1.imessage")" = "held -600 1" ] || fail "(l) failed batch not held again"
nt flush --now "$END"; nt flush --now "$END"; nt flush --now "$END"
[ "$(cut -d' ' -f1,2,4 "$OB/state/acme_release_y1.imessage")" = "failed -600 3" ] && [ "$(calls)" = $((c0 + 3)) ] \
  || fail "(l) failed batch: not 3 attempts"
rm -f "$WORK/osa.err" "$WORK/osa.rc"
# Switched off while held → off at the next flush; no osascript → the channel is off.
rel z1 "" "$NIGHT"; conf '{"version": 1}'; nt flush --now "$END"
[ "$(st acme_release_z1 imessage)" = "off switch-off" ] || fail "(l) a held event of a switched-off channel"
conf "{\"version\": 1, \"imessage\": {\"enabled\": true, \"recipient\": \"$RCP\", $Q}}"
NOTIFY_OSASCRIPT_BIN="$WORK/no-osascript" nt --check; expect 0 "imessage off — no osascript (macOS only)" "(l) no osascript"
# Prune keeps a failed event with attempts left, and drops a final one.
for i in 5 6; do printf '{"id":"acme:x:%s","event":"release"}\n' "$i" > "$OB/events/acme_x_$i.json"; echo "off - -" > "$OB/state/acme_x_$i.herdr"; done
echo "failed -600 - 1" > "$OB/state/acme_x_5.imessage"; echo "failed -600 - 3" > "$OB/state/acme_x_6.imessage"
old "$OB"/events/acme_x_[56].json "$OB"/state/acme_x_[56].*
nt list   # list prunes and never delivers, so the switch stays on here
[ -f "$OB/events/acme_x_5.json" ] && [ ! -e "$OB/events/acme_x_6.json" ] || fail "(l) prune of failed events"
# Switched off, a failed channel is never retried, so its attempts left do not hold the event.
CONF_KEEP="$(cat "$CONF")"; rm -f "$CONF"; nt list; conf "$CONF_KEEP"
[ ! -e "$OB/events/acme_x_5.json" ] || fail "(l) a failed event of a switched-off channel survived prune"
rm -f "$OB"/events/acme_x_5.json "$OB"/state/acme_x_5.*
echo "team-smoke-notify: (l) batch crash, retries, switch-off, prune OK"

# A busy lock never loses an event: written without it, delivery deferred, sent once by the next flush.
# The holder is killed on any exit; the fixture's own EXIT trap body is kept and restored after.
KEEP_TRAP="$(trap -p EXIT | sed "s/^trap -- '//; s/' EXIT\$//")"; sleep 300 & HOLDER=$!
trap "kill $HOLDER 2>/dev/null || true; $KEEP_TRAP" EXIT
mkdir "$OB/.flush.lock"; echo "$HOLDER" > "$OB/.flush.lock/pid"; c0="$(calls)"
NOTIFY_LOCK_WAIT=1 rel b1 "busy one"; expect 0 "written acme:release:b1 (delivery deferred: outbox busy)" "(l) event while the lock is held"
[ -f "$OB/events/acme_release_b1.json" ] && [ "$(st acme_release_b1 imessage)" = "pending -" ] \
  && [ "$(st acme_release_b1 herdr)" = "pending -" ] && [ "$(calls)" = "$c0" ] || fail "(l) a deferred event: file, pending states, no send"
NOTIFY_LOCK_WAIT=1 rel b1 "busy one"; expect 0 "duplicate acme:release:b1 (delivery deferred: outbox busy)" "(l) a deferred duplicate"
nt flush; expect 1 "the outbox lock is held by pid $HOLDER" "(l) flush without the lock"
# --check is read-only on a busy outbox: no wait, exit 0, prune skipped, the holder's lock untouched.
t0=$SECONDS; nt --check; expect 0 " events (prune skipped: outbox busy)" "(l) --check while the lock is held"
[ $((SECONDS - t0)) -lt 2 ] || fail "(l) --check waited $((SECONDS - t0)) s for the lock"
has "imessage on, recipient set" "$WORK/out" || fail "(l) --check lost the switch lines on a busy outbox"
[ "$(cat "$OB/.flush.lock/pid" 2>/dev/null)" = "$HOLDER" ] || fail "(l) --check touched the held lock"
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null || true; trap "$KEEP_TRAP" EXIT
nt flush; [ "$(st acme_release_b1 imessage)" = "submitted -" ] && [ "$(calls)" = $((c0 + 1)) ] || fail "(l) the deferred event not sent once"
nt flush; [ "$(calls)" = $((c0 + 1)) ] || fail "(l) the deferred event sent twice"
# Two events racing a flush that is sending (the stub takes 2 s): each delivered exactly once.
rel s0 "slow"; echo 2 > "$WORK/osa.sleep"; rel s1 "" "$NIGHT"; c0="$(calls)"
(cd "$WORK" && $N flush --now "$END" > "$WORK/bg.out" 2>&1; echo $? > "$WORK/bg.rc") &
BG=$!; sleep 0.5
NOTIFY_LOCK_WAIT=0 rel race1 "race one"; NOTIFY_LOCK_WAIT=0 rel race2 "race two"
wait "$BG"; rm -f "$WORK/osa.sleep"; nt flush
[ "$(cat "$WORK/bg.rc")" = 0 ] || fail "(l) the racing flush failed"
for k in "race one" "race two"; do
  [ "$(grep -c -- "— $k —" "$WORK/osa.texts")" = 1 ] || fail "(l) '$k' not delivered exactly once"; done
# One failed retry per flush, however many failed events wait.
echo "x (-1743)" > "$WORK/osa.err"; echo 1 > "$WORK/osa.rc"
rel f1; rel f2; c0="$(calls)"
[ "$(st acme_release_f1 imessage)" = "failed -1743" ] && [ "$(st acme_release_f2 imessage)" = "failed -1743" ] || fail "(l) two failed events"
nt flush; [ "$(calls)" = $((c0 + 1)) ] || fail "(l) a flush retried more than one failed event"
rm -f "$WORK/osa.err" "$WORK/osa.rc"
echo "team-smoke-notify: (l) busy lock, race, one retry per flush OK"

# The flush-job kit, with a launchctl stub; the plist lands in the fixture HOME.
printf '#!/usr/bin/env bash\necho "launchctl $*" >> "%s/lctl.log"\n' "$WORK" > "$WORK/lctl"; chmod +x "$WORK/lctl"
export LAUNCHCTL_BIN="$WORK/lctl"
KIT="bash $SRC/.claude/team/notify-kit/install.sh"; PL="$HOME/Library/LaunchAgents/harness.notify-flush.plist"
DOM="gui/$(id -u)"; NS="$SRC/.claude/lib/notify.sh"
HOME="$WORK/nohome" run "$WORK" $KIT; expect 3 "no $WORK/nohome/.agent-comms/notify.json" "(l) kit without a switch file"
run "$WORK" $KIT --dry-run; expect 0 "would install $PL" "(l) kit dry run"
has "<key>Hour</key><integer>7</integer><key>Minute</key><integer>0</integer>" "$WORK/out" && has "$LAUNCHCTL_BIN bootstrap $DOM $PL" "$WORK/out" \
  || fail "(l) the dry run's plist or commands"
[ ! -e "$PL" ] && [ ! -e "$WORK/lctl.log" ] || fail "(l) the dry run wrote or loaded"
run "$WORK" $KIT; expect 0 "installed $PL — flush at 07:00 system time, runs $NS" "(l) kit install"
! command -v plutil >/dev/null 2>&1 || plutil -lint "$PL" >/dev/null || fail "(l) the plist does not lint"
has "<string>$NS</string><string>flush</string>" "$PL" && has "installed-by-harness" "$PL" || fail "(l) plist content"
[ "$(cat "$WORK/lctl.log")" = "launchctl bootout $DOM/harness.notify-flush
launchctl bootstrap $DOM $PL" ] || fail "(l) launchctl calls: $(cat "$WORK/lctl.log")"
nt --check; expect 0 "flush job: installed" "(l) --check sees the job"
! has "imessage warning" "$WORK/out" || fail "(l) a tz warning with matching zones"
NOTIFY_SYSTEM_TZ=UTC nt --check; expect 0 "quiet.tz Europe/Warsaw is not the system zone UTC" "(l) --check tz warning"
NOTIFY_SYSTEM_TZ=UTC run "$WORK" $KIT; expect 0 "warning: quiet.tz Europe/Warsaw is not the system zone UTC" "(l) kit tz warning"
# A moved checkout, a changed quiet.end: --check says stale; a re-install replaces and says so.
sed -i.bak "s|<string>$NS</string>|<string>/gone/.claude/lib/notify.sh</string>|" "$PL"; rm -f "$PL.bak"
nt --check; expect 0 "flush job: stale path /gone/.claude/lib/notify.sh" "(l) stale path"
run "$WORK" $KIT; expect 0 "updated $PL" "(l) kit update"; has "replaced the path /gone/.claude/lib/notify.sh" "$WORK/out" || fail "(l) replaced path not said"
conf "{\"version\": 1, \"imessage\": {\"enabled\": true, \"recipient\": \"$RCP\", \"quiet\": {\"start\": \"22:00\", \"end\": \"06:30\", \"tz\": \"Europe/Warsaw\"}}}"
nt --check; expect 0 "flush job: stale time" "(l) stale time"
run "$WORK" $KIT; expect 0 "flush at 06:30" "(l) kit re-install"; has "<key>Hour</key><integer>6</integer><key>Minute</key><integer>30</integer>" "$PL" || fail "(l) new hour"
conf "{\"version\": 1, \"imessage\": {\"enabled\": true, \"recipient\": \"$RCP\", \"quiet\": {\"start\": \"22:00\", \"end\": \"7am\", \"tz\": \"Europe/Warsaw\"}}}"
run "$WORK" $KIT; expect 3 "imessage.quiet.end '7am' is not HH:MM" "(l) kit with a bad quiet.end"
conf "{\"version\": 1, \"imessage\": {\"enabled\": true, \"recipient\": \"$RCP\", $Q}}"
: > "$WORK/lctl.log"; run "$WORK" $KIT --rollback; expect 0 "removed $PL" "(l) kit rollback"
[ ! -e "$PL" ] && has "bootout $DOM/harness.notify-flush" "$WORK/lctl.log" || fail "(l) rollback left the plist or did not unload"
echo '<plist>mine</plist>' > "$PL"
run "$WORK" $KIT; expect 3 "was not installed by the harness" "(l) kit refuses a foreign plist"
run "$WORK" $KIT --rollback; expect 3 "was not installed by the harness" "(l) rollback of a foreign plist"
[ "$(cat "$PL")" = '<plist>mine</plist>' ] || fail "(l) a foreign plist was touched"; rm -f "$PL"
# A bootstrap that fails once right after the bootout is retried.
printf '#!/usr/bin/env bash\necho "launchctl $*" >> "%s/lctl.log"\n[ "$1" != bootstrap ] || [ -f "%s/lctl.once" ] || { touch "%s/lctl.once"; exit 5; }\n' \
  "$WORK" "$WORK" "$WORK" > "$WORK/lctl"
: > "$WORK/lctl.log"; run "$WORK" $KIT; expect 0 "installed $PL" "(l) kit retries a failed bootstrap"
[ "$(grep -c ' bootstrap ' "$WORK/lctl.log")" = 2 ] || fail "(l) bootstrap not retried once"
run "$WORK" $KIT --rollback; expect 0 "removed $PL" "(l) kit rollback after the retry"
# The job's log is kept to its last 32-64 KB by every call's prune.
head -c 70000 /dev/zero | tr '\0' x > "$OB/flush.log"; nt list
[ "$(wc -c < "$OB/flush.log" | tr -d ' ')" -le 32768 ] || fail "(l) flush.log not trimmed"
run "$WORK" $KIT --bogus; expect 2 "Usage:" "(l) kit usage"
echo "team-smoke-notify: (l) flush-job kit OK"

# ---- (m) one path to the Operator: no other sink is left in the checkout (AC9) ----------------------
OK_RE='^(\.claude/hooks/lib/guard_team_egress\.py|\.agents/reference/security-egress\.md|\.claude/lib/notify\.sh|\.claude/team/notify-kit/.*|docs/teams/upgrade-notes\.md|\.claude/lib/tests/.*)$'
left="$(cd "$SRC" && grep -rlE 'osascript|notify-send|terminal-notifier|PushNotification|TEAM_NOTIFY|team_channel_notify' \
  .claude .agents/reference docs 2>/dev/null | grep -vE "$OK_RE" || true)"
[ -z "$left" ] || fail "(m) a notification sink is left outside notify.sh: $left"
[ ! -e "$SRC/.claude/team/sessions/operator-kit/notify.sh" ] && [ ! -e "$SRC/.claude/hooks/supervisor-notify.sh" ] \
  || fail "(m) the platform notifier or the role Notification hook still ships"
! grep -qE 'supervisor-notify\.sh|operator-kit/notify\.sh' "$SRC/.claude/team/manifest.txt" || fail "(m) the manifest still lists a removed sink"
jq -e '.hooks | has("Notification") | not' "$SRC/.claude/team/sessions/operator-kit/hooks/role-hooks.settings.json.tmpl" >/dev/null \
  || fail "(m) the kit's role hooks still wire a Notification hook"
! grep -q '^notify()' "$SRC/.claude/lib/team-run.sh" || fail "(m) the runner still has notify()"
! grep -qE 'tw_notify|notifier_line|team_channel_loss_line' "$SRC"/.claude/lib/team-watch*.sh "$SRC/.claude/lib/team-channel.sh" \
  || fail "(m) team-watch or the channel still notifies"
jq -e '.teams.channel | has("notifier") | not' "$SRC/.claude/project-profile.json.example" >/dev/null || fail "(m) the profile example still sets a notifier"
echo "team-smoke-notify: (m) one path to the Operator OK"

# ---- nothing reached a person; the recipient is nowhere ----------------------------------------------
[ ! -s "$WORK/sinks.log" ] || { cp "$WORK/sinks.log" "$WORK/out"; fail "a platform notifier was called"; }
! grep -rlF "RCPTOKEN" "$OB" "$MAIN/.agents/team" "$WORK/out" "$WORK"/f1 "$WORK"/f2 "$OSL" "$WORK"/osa.texts \
    "$WORK"/lctl.log "$HOME/Library" 2>/dev/null | grep -q . \
  || fail "the recipient appears outside the switch file"
REAL="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
[ -z "$REAL" ] || [ "$HOME" != "$REAL" ] || fail "the part ran with the real HOME"
d="${REAL:-/nonexistent}/.agent-comms"
[ ! -d "$d" ] || [ -z "$(find "$d" -type f -newer "$T0" -exec grep -lF -e "$WORK" -e acme_alfa_r1 -e RCPTOKEN {} + 2>/dev/null)" ] \
  || fail "a fixture file appeared under the real ~/.agent-comms"
echo "team-smoke-notify: nothing outside the fixture OK"
echo "team-smoke-notify: OK"
