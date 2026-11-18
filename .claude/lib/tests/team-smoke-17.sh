#!/usr/bin/env bash
# team-watch control and hardening: duplicate delivery, tiers/answering enforcement, the
# SessionStart hook per role, channel names, no notifications from team-watch or the runner, ledger findings and rotation, the newest prompt + redaction, role-session prompts,
# the loop version bump, two checkouts on one machine (tmux_prefix), the state-file readers.
# Cases (68)-(70), (75), (77), (78), (130)-(132), (S1), (P1).
# It spawns loops and waits on pickup windows, so the runner keeps it out of a parallel batch.
# team-smoke: serial
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-watch-lib.sh"
smoke_init
smoke_team AB-1139 chore/AB-1139-watch
watch_init
mkrole SUP; mkrole ADV
Q="bash .claude/lib/team-question.sh"
session coder 1 "$BASE"
echo "2026-10-19T10:00:00Z permission_prompt Claude needs your permission" > "$RD/attention"
mkdir "$TD/lock"; echo $$ > "$TD/lock/pid"
mailcfg true
run "$MAIN" $W routing split; expect 0 "" "routing split"
as Supervisor SUP $W register; expect 0 "Supervisor registered" "register the Supervisor"
run "$MAIN" $W tick --once; expect 0 "" "first tick"
ago() { touch -t "$(date -r $(( $(date +%s) - $2 )) +%Y%m%d%H%M.%S)" "$1"; }
holder() { sleep 3000 > /dev/null 2>&1 & H=$!; PIDS="$PIDS $H"; }  # → H
seq_of() { jq -r 'select(.text | startswith($t)) | .seq' --arg t "$1" "$TWD/events.jsonl" | tail -n 1; }
ack_all() {  # ack_all <role> — every pending batch of that role
  local n
  for n in $(cd "$MAIN" && $W pending "$1"); do run "$MAIN" env TEAM_SESSION_ROLE="$1" $W ack "$n"; done
}
role_prompt() {  # role_prompt <role> → tw_role_prompt's "<sub>\t<fp>\t<anchor>" line
  (cd "$MAIN" && bash -c '. .claude/lib/team-watch-lib.sh; tw_init "$PWD"; tw_role_prompt "$1"' _ "$1")
}

# ---- (68) duplicate delivery: one ack counted twice, one answer ----------------------------------
run "$MAIN" $W ping Supervisor; wait_recv SUP "PING Supervisor" 10
P="$(last_batch SUP)"
# The whole commit is lost (cursor and delivery line): the same batch goes out again. A lost cursor
# alone does not resend — delivery skips every seq the ledger carried.
rm -f "$TWD/cursor.Supervisor"
jq -c --argjson b "$P" 'select(.batch != $b or .to != "Supervisor")' "$TWD/deliveries.jsonl" \
  > "$WORK/d" && mv "$WORK/d" "$TWD/deliveries.jsonl"
run "$MAIN" $W tick --once
wait_recv SUP "[team-watch #$P]" 10 2
run "$MAIN" env TEAM_SESSION_ROLE=Supervisor $W ack "$P"; expect 0 "picked #$P" "first ack"
run "$MAIN" env TEAM_SESSION_ROLE=Supervisor $W ack "$P"; expect 0 "(duplicate)" "second ack"
run "$MAIN" $W stats; expect 0 "Supervisor: delivered=" "stats"
grep '^Supervisor:' "$WORK/out" | grep -q ' duplicates=1 ' || fail "stats: duplicates=1 expected"
grep '^Supervisor:' "$WORK/out" | grep -Eq 'pickup_p50=[0-9]+s pickup_max=[0-9]+s' \
  || fail "stats: pickup latency missing"
run "$MAIN" $Q alfa open coder --kind permission --anchor "Do you want to proceed?" --summary "deploy?"
expect 0 "q-1" "open"
run "$MAIN" $Q alfa open coder --kind permission --anchor "Do you want to proceed?" --summary "deploy?"
expect 0 "(existing" "the same question again"
run "$MAIN" $Q alfa answer q-1 --tier 3 --author operator --why "approved in the window" --send none
expect 0 "recorded" "first answer"
run "$MAIN" $Q alfa answer q-1 --tier 1 --author supervisor --why "in the plan" --send yes
expect 1 "already answered" "second answer"
echo "team-smoke-17: (68) duplicate delivery OK"

# ---- (69) tiers / answering enforcement in answer -------------------------------------------------
mkclone beta beta-20261019-000000; wrec "$CT" beta beta-20261019-000000 coder blocked "which?"
wsess "$CT" beta beta-20261019-000000 coder; BQ="$CT/runs/beta-20261019-000000/questions/q-1.md"
mkclone gamma gamma-20261019-000000; wrec "$CT" gamma gamma-20261019-000000 coder blocked "which?"
wsess "$CT" gamma gamma-20261019-000000 coder
run "$MAIN" $Q beta open coder --kind blocked --summary "which endpoint?"; expect 0 "q-1" "open beta"
run "$MAIN" $Q gamma open coder --kind blocked --summary "which endpoint?"; expect 0 "q-1" "open gamma"
run "$MAIN" $W mode tiers off; expect 0 "team-watch: tiers off" "mode tiers off"
S0="$(shasum < "$BQ")"
run "$MAIN" $Q beta answer q-1 --tier 2 --author analysts --why w --text "use v2" --send say
expect 1 "refused: tiers off" "tier 2 while tiers off"
[ "$(shasum < "$BQ")" = "$S0" ] || fail "a refused answer changed the q file"
run "$MAIN" $Q beta answer q-1 --tier 3 --author operator --why w --text "use v2" --send say
has "refused:" "$WORK/out" && fail "an Operator tier-3 answer was refused while tiers are off"
run "$MAIN" $W mode tiers on; run "$MAIN" $W mode answering off; expect 0 "team-watch: answering off" "answering off"
run "$MAIN" $Q gamma answer q-1 --tier 3 --author operator --why w --text "use v2" --send say
expect 1 "refused: answering off" "delivering answer while answering off"
run "$MAIN" $Q gamma answer q-1 --tier 3 --author operator --why w --text "did it" --send none
expect 0 "recorded" "recorded-only tier 3 while answering off"
(cd "$MAIN" && $W mode tiers off >/dev/null) & A=$!
(cd "$MAIN" && $W mode answering off >/dev/null) & B=$!
wait "$A" "$B"
jq -e '.tiers == "off" and .answering == "off"' "$TWD/state.json" >/dev/null \
  || fail "concurrent mode switches lost one"
run "$MAIN" $W mode tiers on; run "$MAIN" $W mode answering on
echo "team-smoke-17: (69) tiers/answering enforcement OK"

# ---- (P1) the state-file readers ignore .paused; the writer refuses a non-object -----------------
L="$MAIN/.claude/lib"
# Classes are off unless the profile enables them, so enable one: otherwise both class checks below
# would pass or fail on the profile alone and say nothing about the state file.
PF="$MAIN/.claude/project-profile.json"; cp "$PF" "$WORK/prof.before"
jq '.teams.policy.classes.merge_line = {enabled: true}' "$WORK/prof.before" > "$PF"
(. "$L/team-lib.sh"; echo '{"paused": {"Supervisor": {"since": "2026-11-04T08:00:00Z", "by": "x"}}}' > "$TWD/state.json"
  team_mode_ok "$MAIN" 1 yes && team_class_on "$MAIN" merge-line) || fail "a pause changed tiers or classes"
jq '. + {tiers: "off", classes: {"merge-line": "off"}}' "$TWD/state.json" > "$WORK/st" && mv "$WORK/st" "$TWD/state.json"
(. "$L/team-lib.sh"; [ "$(team_mode_ok "$MAIN" 1 yes)" = "tiers off" ] && ! team_class_on "$MAIN" merge-line) \
  || fail "tiers/class off next to a pause not honoured"
cp "$WORK/prof.before" "$PF"
echo '[]' > "$TWD/state.json"; cp "$TWD/state.json" "$WORK/st.before"
run "$MAIN" $W mode tiers on; expect 1 "state.json unreadable" "the writer refuses a non-object"
cmp -s "$TWD/state.json" "$WORK/st.before" || fail "a non-object state.json was rewritten"
echo '{}' > "$TWD/state.json"
# A pid-less lock.d (the old writer's) older than 2 s is reclaimed.
mkdir "$TWD/lock.d"; ago "$TWD/lock.d" 10
run "$MAIN" $W mode tiers on; expect 0 "team-watch: tiers on" "a stale pid-less lock is reclaimed"
echo "team-smoke-17: (P1) state readers and writer OK"

# ---- (70) the SessionStart hook re-points only its own role ---------------------------------------
hook() {  # hook <role> <socket> <token> → RC, $WORK/hk
  set +e
  CLAUDE_PROJECT_DIR="$MAIN" TEAM_SESSION_ROLE="$1" CLAUDE_CODE_MESSAGING_SOCKET="$2" \
    CLAUDE_CODE_MESSAGING_TOKEN="$3" bash "$SRC/.claude/hooks/team-watch-session.sh" < /dev/null \
    > "$WORK/hk" 2>&1
  RC=$?; set -e
}
# A leftover TeamLead window or the Advisor (no receiver) touches nothing, not even the Supervisor.
for r in TeamLead Advisor; do
  SUPSUM="$(shasum < "$TWD/receivers/Supervisor.json")"
  hook "$r" "$ADV_SOCK" tok9
  [ "$RC" = 0 ] && [ ! -s "$WORK/hk" ] || fail "hook ($r) printed or failed (exit $RC)"
  [ "$(shasum < "$TWD/receivers/Supervisor.json")" = "$SUPSUM" ] || fail "hook ($r) touched the Supervisor"
  [ ! -e "$TWD/receivers/$r.json" ] || fail "hook ($r) wrote a receiver file"
done
hook Supervisor "$SUP_SOCK" tok2
[ "$RC" = 0 ] && [ ! -s "$WORK/hk" ] || fail "hook printed or failed (exit $RC)"
[ "$(jq -r .token "$TWD/receivers/Supervisor.json")" = tok2 ] || fail "hook did not re-point the Supervisor"
echo "team-smoke-17: (70) SessionStart hook per role OK"

# ---- (130) team-watch notifies nobody: no tw_notify, an alarm only reaches the target session -----
lib 'type tw_notify >/dev/null 2>&1 && echo has-tw_notify; type team_channel_notify >/dev/null 2>&1 && echo has-tcn; echo rc=$?'
! has "has-" "$WORK/out" || fail "a notification helper is still defined: $(cat "$WORK/out")"
: > "$STUB_LOG"; lib 'tw_alarm Supervisor "UNPICKED Supervisor #1"'
! grep -q '^notify \|^osascript\|^notify-send' "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "tw_alarm notified someone"; }
! has "declared loss" "$WORK/out" || fail "tw_alarm still prints a declared loss"
run "$MAIN" $W status
! has "notifier" "$WORK/out" || fail "status still prints a notifier line"
echo "team-smoke-17: (130) team-watch notifies nobody OK"

# ---- (131) the runner notifies nobody, whatever TEAM_NOTIFY says ------------------------------------
for v in - 1; do
  : > "$STUB_LOG"
  if [ "$v" = - ]; then run "$MAIN" $TR alfa bogus; else run "$MAIN" env TEAM_NOTIFY=1 $TR alfa bogus; fi
  expect 2 "unknown command bogus" "runner die ($v)"
  ! has "declared loss" "$WORK/out" || fail "runner ($v): a declared-loss line"
  ! grep -q '^notify \|^osascript\|^notify-send' "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "the runner notified ($v)"; }
done
echo "team-smoke-17: (131) runner notifications OK"

# ---- (75) ledger findings and rotation ----------------------------------------------------------
# C5: undelivered counts only the role's own events past its cursor (here: a pre-upgrade queue to
# the retired TeamLead is foreign).
L5="$(tail -n 1 "$TWD/events.jsonl" 2>/dev/null | jq -r '.seq // 0')"; L5="${L5:-0}"
for i in 1 2 3; do
  jq -cn --argjson s "$((L5 + i))" '{seq: $s, at: "x", to: "TeamLead", label: "", text: "t"}'
done >> "$TWD/events.jsonl"
jq -cn --argjson s "$((L5 + 4))" '{seq: $s, at: "x", to: "Supervisor", label: "", text: "m"}' \
  >> "$TWD/events.jsonl"
echo "$L5" > "$TWD/cursor.Supervisor"; date -u +%s > "$TWD/undelivered.Supervisor.since"
run "$MAIN" $W status; has "undelivered Supervisor: 1 " "$WORK/out" || fail "C5: foreign events counted"
rm -f "$TWD/undelivered.Supervisor.since"
lib tw_deliver
# C6: a held lock plus a live sender's send.d younger than tw_send_max — the alarm never reclaims it.
lib tw_send_max; SM="$(tail -n 1 "$WORK/out")"
[ "$SM" -gt 3 ] || fail "C6: tw_send_max $SM"
holder; mkdir "$TWD/lock.d"; echo "$H" > "$TWD/lock.d/pid"
holder; H2="$H"; mkdir "$TWD/send.d"; echo "$H2" > "$TWD/send.d/pid"; ago "$TWD/send.d" $((SM - 3))
TEAM_WATCH_LOCK_SECS=1 lib 'tw_alarm - "C6 probe"'
[ "$(cat "$TWD/send.d/pid" 2>/dev/null)" = "$H2" ] || fail "C6: a live sender's send.d was reclaimed"
rm -rf "$TWD/lock.d" "$TWD/send.d"
# C7: an unreadable ack ledger is logged, never an UNPICKED alarm with an empty batch.
cp "$TWD/acks.jsonl" "$WORK/acks.bak" 2>/dev/null || : > "$WORK/acks.bak"
echo '{broken' >> "$TWD/acks.jsonl"
U0="$(grep -c '"UNPICKED' "$TWD/events.jsonl" || true)"
lib tw_check_receivers
has "ledger unreadable" "$WORK/out" || fail "C7: no log line"
[ "$(grep -c '"UNPICKED' "$TWD/events.jsonl" || true)" = "$U0" ] || fail "C7: UNPICKED from a corrupt ledger"
ls "$TWD"/alarm.unpicked.* >/dev/null 2>&1 && fail "C7: an UNPICKED episode opened"
cp "$WORK/acks.bak" "$TWD/acks.jsonl"
# C9: a ping batched with a later event — its text names no seq, the header's ack is the batch.
holder; mkdir "$TWD/send.d"; echo "$H" > "$TWD/send.d/pid"
TEAM_WATCH_LOCK_SECS=1 run "$MAIN" $W ping Supervisor
lib 'tw_lock; tw_append_to Supervisor "" "LATER event"; tw_unlock'
rm -rf "$TWD/send.d"; lib tw_deliver
wait_recv SUP "LATER event" 10
M="$(msgs SUP | tail -n 1 | jq -r .)"; B="$(last_batch SUP)"
grep -q "^PING Supervisor — confirm: ack the number in this message's header" <<<"$M" || fail "C9: ping text: $M"
grep '^PING Supervisor' <<<"$M" | grep -Eq 'ack [0-9]' && fail "C9: the ping text names a seq"
grep -q "ack: bash .claude/lib/team-watch.sh ack $B " <<<"$M" || fail "C9: header ack is not #$B"
[ "$B" = "$(seq_of "LATER event")" ] || fail "C9: batch is not the later event"
ack_all Supervisor
# C10 (R1): a truncated last events.jsonl line fails loudly — no append restarting at seq 1, no
# "delivered" over an unreadable log (the outage flag stays), no ping queued; repaired, it resumes.
cp "$TWD/events.jsonl" "$WORK/events.bak"; LS="$(tail -n 1 "$WORK/events.bak" | jq -r .seq)"
printf '{"seq": %s, "at": "x", "to": "Superv' "$((LS + 1))" >> "$TWD/events.jsonl"
lib tw_last_seq
[ "$RC" = 1 ] && has "events.jsonl: last line has no seq" "$WORK/out" || fail "C10: tw_last_seq rc $RC"
lib 'tw_lock; tw_append_to Supervisor "" "AFTER truncation"; r=$?; tw_unlock; exit $r'
[ "$RC" = 1 ] || fail "C10: an append over a truncated log returned $RC"
grep -q 'AFTER truncation' "$TWD/events.jsonl" && fail "C10: an event was appended after the cut line"
date -u +%s > "$TWD/undelivered.Supervisor.since"
lib 'tw_claim "$TW_DIR/send.d" 5 30 && { tw_deliver_one Supervisor; r=$?; tw_release "$TW_DIR/send.d"; exit $r; }'
[ "$RC" = 1 ] && has "Supervisor: events.jsonl unreadable" "$WORK/out" || fail "C10: deliver over an unreadable log rc $RC"
[ -f "$TWD/undelivered.Supervisor.since" ] || fail "C10: the outage flag was cleared as delivered"
run "$MAIN" $W ping Supervisor
[ "$RC" = 1 ] && has "ping not queued" "$WORK/out" || fail "C10: ping over a truncated log rc $RC"
cp "$WORK/events.bak" "$TWD/events.jsonl"; rm -f "$TWD/undelivered.Supervisor.since"
lib 'tw_lock; tw_append_to Supervisor "" "AFTER repair"; tw_unlock'
[ "$(seq_of "AFTER repair")" = "$((LS + 1))" ] || fail "C10: the repaired log did not resume at $((LS + 1))"
lib tw_deliver; ack_all Supervisor
# C11 (R1): four claimant processes against one dead holder — exactly one holds, every round, and
# no reclaim leftovers stay behind. A .reclaim dir whose holder died is cleared after 5 s.
cat > "$WORK/claimant.sh" <<'CLAIM'
cd "$1" && . .claude/lib/team-watch-lib.sh && tw_init "$PWD" \
  && tw_claim "$2/c.d" 0 && { echo "$$" >> "$2/c.won"; sleep 0.3; tw_release "$2/c.d"; }
CLAIM
multi=0
for i in $(seq 20); do
  rm -rf "$WORK"/c.d* "$WORK/c.won"; mkdir "$WORK/c.d"
  sh -c 'exit 0' & dead=$!; wait "$dead"; echo "$dead" > "$WORK/c.d/pid"
  # Wait on these four only: a bare wait would also wait on the holders' long sleeps.
  cl=""; for k in 1 2 3 4; do bash "$WORK/claimant.sh" "$MAIN" "$WORK" 2>/dev/null & cl="$cl $!"; done
  for k in $cl; do wait "$k" || true; done
  [ "$(wc -l < "$WORK/c.won" 2>/dev/null | tr -d ' ')" = 1 ] || multi=$((multi + 1))
  ls -d "$WORK"/c.d.* >/dev/null 2>&1 && fail "C11: round $i left $(ls -d "$WORK"/c.d.*)"
done
[ "$multi" = 0 ] || fail "C11: $multi of 20 rounds did not end with exactly one holder"
rm -rf "$WORK"/c.d*; mkdir "$WORK/c.d" "$WORK/c.d.reclaim"; ago "$WORK/c.d.reclaim" 10
sh -c 'exit 0' & dead=$!; wait "$dead"; echo "$dead" > "$WORK/c.d/pid"
lib "tw_claim '$WORK/c.d' 2"
[ "$RC" = 0 ] && [ "$(cat "$WORK/c.d/pid")" != "$dead" ] || fail "C11: an orphaned .reclaim blocked the claim"
rm -rf "$WORK"/c.d*
# Rotation: an undelivered event and an open batch survive; seq stays monotonic.
now="$(date -u +%s)"
for i in 1 2 3 4 5; do
  jq -cn --argjson s "$i" \
    '{seq: $s, at: "2026-01-01T00:00:00Z", to: "Supervisor", label: "", text: "rot \($s)"}'
done > "$TWD/events.jsonl"
for b in 1 2 3; do
  jq -cn --argjson b "$b" --argjson t "$((now - 100))" \
    '{batch: $b, to: "Supervisor", seqs: [$b], delivered_at: "2026-01-01T00:00:00Z", t: $t}'
done > "$TWD/deliveries.jsonl"
for b in 1 2; do
  jq -cn --argjson b "$b" --argjson t "$((now - 100))" \
    '{batch: $b, to: "Supervisor", state: "done", at: "2026-01-01T00:00:00Z", t: $t}'
done > "$TWD/acks.jsonl"
echo 3 > "$TWD/cursor.Supervisor"
rm -f "$TWD"/*.jsonl.1
TEAM_WATCH_ROTATE_BYTES=200 TEAM_WATCH_KEEP_SECS=0 lib tw_rotate; expect 0 "" "rotate"
[ "$(jq -sc 'map(.seq)' "$TWD/events.jsonl")" = "[4,5]" ] \
  || { cp "$TWD/events.jsonl" "$WORK/out"; fail "rotation: kept events"; }
[ "$(jq -sc 'map(.seq)' "$TWD/events.jsonl.1")" = "[1,2,3]" ] || fail "rotation: events.jsonl.1"
[ "$(jq -sc 'map(.batch)' "$TWD/deliveries.jsonl")" = "[3]" ] || fail "rotation: kept deliveries"
[ ! -s "$TWD/acks.jsonl" ] && [ -s "$TWD/acks.jsonl.1" ] || fail "rotation: acks"
run "$MAIN" env TEAM_SESSION_ROLE=Supervisor $W ack 3; expect 0 "picked #3" "rotation: open batch ack"
run "$MAIN" $W ping Supervisor; expect 0 "(seq 6)" "rotation: seq stays monotonic"
TEAM_WATCH_ROTATE_BYTES=100000 lib tw_rotate
[ "$(jq -sc 'map(.seq)' "$TWD/events.jsonl.1")" = "[1,2,3]" ] || fail "rotation under the limit"
ack_all Supervisor
echo "team-smoke-17: (75) ledger findings and rotation OK"

# ---- (77) the newest prompt from the history, egress refused, redaction ------------------------
PC="python3 -I $SRC/.claude/lib/team_prompt_check.py"
{ printf 'Bash command\n  echo old\nDo you want to proceed?\n❯ 1. Yes\n  ⎿ old\n'
  printf 'Bash command\n'; for i in $(seq 1 45); do echo "  echo step $i"; done
  printf 'Do you want to proceed?\n❯ 1. Yes\n'; } > "$WORK/hist"
$PC --block < "$WORK/hist" > "$WORK/blk" || fail "(77) --block found no block"
[ "$(head -n 1 "$WORK/blk")" = "echo step 1" ] && ! grep -q 'echo old' "$WORK/blk" \
  || { cp "$WORK/blk" "$WORK/out"; fail "(77) --block is not the newest prompt"; }
printf 'Fetch\n  https://example.com/x\nDo you want to proceed?\n❯ 1. Yes\n' > "$WORK/fetch"
$PC "$MAIN" < "$WORK/fetch" 2> "$WORK/out" && fail "(77) WebFetch approved"
has "egress" "$WORK/out" || fail "(77) WebFetch refusal does not say egress"
R="$(printf 'x token=abc --password p Bearer q\n' | bash -c ". $SRC/.claude/lib/team-lib.sh; team_redact")"
[ "$R" = "x token=*** --password *** Bearer ***" ] || fail "(77) redaction: $R"
printf 'Bash command\n  az storage blob list --sas-token s3cr3t\nDo you want to proceed?\n❯ 1. Yes\n' \
  > "$WORK/pane"
run "$MAIN" bash .claude/lib/team-snapshot.sh --out "$WORK/snap.json"; expect 0 "" "(77) snapshot"
jq -e '.teams[] | select(.team == "alfa") | .roles[] | select(.role == "coder")
  | .prompt_open and .screen == ["az storage blob list --sas-token ***"]
    and (.anchor | contains("s3cr3t") | not)' "$WORK/snap.json" >/dev/null \
  || { jq '.teams[].roles[] | select(.role == "coder")' "$WORK/snap.json" > "$WORK/out"
       fail "(77) snapshot screen is not the redacted block"; }
printf 'Bash command\n  npm run deploy -- --name app-x\nDo you want to proceed?\n❯ 1. Yes\n' > "$WORK/pane"
echo "team-smoke-17: (77) newest prompt and redaction OK"

# ---- (78) a role session's own prompt reaches the Supervisor -------------------------------------
ratt() { jq -s --arg to "$1" 'map(select(.to == $to and (.text | startswith("ATTENTION Advisor"))))
  | length' "$TWD/events.jsonl"; }
export STUB_PANE_DIR="$WORK/panes"; mkdir -p "$STUB_PANE_DIR"
holder; echo "$H" > "$TMUXD/smk-advisor.pid"
printf 'Bash command\n  bash .claude/lib/team-watch.sh status --open\nDo you want to proceed?\n❯ 1. Yes\n' \
  > "$STUB_PANE_DIR/smk-advisor"
: > "$STUB_LOG"
run "$MAIN" $W tick --once; expect 0 "" "(78) tick"
wait_recv SUP "ATTENTION Advisor (permission) fp=" 10
[ "$(ratt Supervisor)" = 1 ] || fail "(78) expected one ATTENTION Advisor event"
! grep -q '^notify ' "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "(78) the role prompt notified someone"; }
run "$MAIN" $W tick --once
[ "$(ratt Supervisor)" = 1 ] || fail "(78) the second tick repeated the role prompt"
sleep 2; TEAM_WATCH_PICKUP_SECS=1 lib tw_check_receivers
[ -f "$TWD/alarm.unpicked.Supervisor" ] || fail "(78) no UNPICKED for the unacked role prompt"
ack_all Supervisor; lib tw_check_receivers
run "$MAIN" $W routing single Supervisor; run "$MAIN" $W tick --once
[ "$(ratt Supervisor)" = 2 ] || fail "(78) single Supervisor did not get the role prompt"
run "$MAIN" $W routing split
cp "$STUB_PANE_DIR/smk-advisor" "$WORK/pane-keep"
{ printf 'ATTENTION alfa coder (permission): Do you want to proceed?\n'
  for i in $(seq 1 9); do echo "  working $i"; done; } > "$STUB_PANE_DIR/smk-advisor"
R="$(role_prompt Advisor)"
[ -z "$R" ] || fail "(78) a received ATTENTION head counted as the Advisor's own prompt: $R"
cp "$WORK/pane-keep" "$STUB_PANE_DIR/smk-advisor"
FP="$(role_prompt Advisor | cut -f2)"
[[ "$FP" =~ ^[0-9a-f]{12}$ ]] || fail "(78) fingerprint: $FP"
rm -f "$STUB_PANE_DIR/smk-advisor"; echo dead > "$TMUXD/smk-advisor.pid"; unset STUB_PANE_DIR
ack_all Supervisor
echo "team-smoke-17: (78) role-session prompts OK"

# ---- (132) version bump: fresh loops of another version are restarted ----------------------------
for n in smk-team-watch smk-team-watch-dog; do sleep 3000 & echo $! > "$TMUXD/$n.pid"; PIDS="$PIDS $!"; done
OLD_D="$(cat "$TMUXD/smk-team-watch.pid")"; OLD_G="$(cat "$TMUXD/smk-team-watch-dog.pid")"
echo "$(date -u +%s) 7 v$((TWV - 1))" > "$TWD/beat"; echo "$(date -u +%s) 7 v$((TWV - 1))" > "$TWD/dog.beat"
: > "$STUB_LOG"
run "$MAIN" env TEAM_WATCH_SECS=1 $W start --no-register; expect 0 "team-watch: works" "start over old loops"
for n in smk-team-watch smk-team-watch-dog; do
  grep -q "^tmux kill-session -t =$n\$" "$STUB_LOG" || { cp "$STUB_LOG" "$WORK/out"; fail "$n not killed"; }
  grep -q "^tmux new-session -d -s $n .*env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN bash .claude/lib/team-watch.sh " "$STUB_LOG" \
    || { cp "$STUB_LOG" "$WORK/out"; fail "$n not started under a clean env"; }
done
grep -q "^tmux new-session -d -s smk-team-watch .*-e TEAM_WATCH_SECS=1 " "$STUB_LOG" || fail "knob not forwarded"
! kill -0 "$OLD_D" 2>/dev/null && ! kill -0 "$OLD_G" 2>/dev/null || fail "an old loop survived"
grep -q " v$TWV\$" "$TWD/beat" || fail "the new loop does not beat v$TWV"
echo "team-smoke-17: (132) version bump OK"

# ---- (S1) two checkouts on one machine: each starts and stops only its own loops ------------------
O="$WORK/other"; git clone --quiet "$ADO_URL" "$O"
cp -R "$MAIN/.claude/lib/." "$O/.claude/lib/"; mkdir -p "$O/.claude/team/sessions"
cp "$MAIN/.claude/team/sessions/monitoring.json" "$O/.claude/team/sessions/"
jq '.teams.channel.tmux_prefix = "smx" | .teams.session_prefix = "smx"' "$MAIN/.claude/project-profile.json" > "$O/.claude/project-profile.json"
: > "$STUB_LOG"
run "$O" env TEAM_WATCH_SECS=1 $W start --no-register; expect 0 "team-watch: works" "start in the second checkout"
grep -q '^tmux new-session -d -s smx-team-watch ' "$STUB_LOG" || fail "S1: the second checkout's daemon name"
run "$O" $W stop; expect 0 "team-watch: stopped" "stop in the second checkout"
grep -q 'kill-session -t =smk-' "$STUB_LOG" && fail "S1: stop in the second checkout killed the first's loops"
for n in smk-team-watch smk-team-watch-dog; do
  kill -0 "$(cat "$TMUXD/$n.pid")" 2>/dev/null || fail "S1: $n died with the other checkout's stop"
done
run "$MAIN" $W status; expect 0 "team-watch: works" "S1: the first checkout still works"
run "$MAIN" $W stop; expect 0 "team-watch: stopped" "stop the first"
# Channel names: no teams.channel → the dir slug; an invalid prefix is rc 3.
N="$WORK/My.Repo X"; mkdir -p "$N"; git -C "$N" init --quiet
R="$(bash -c '. "$1/team-channel.sh"; team_channel_names "$2" && echo "$TEAM_CHANNEL_TMUX_PREFIX $TEAM_CHANNEL_ADVISOR"' _ "$L" "$N")"
[ "$R" = "my-repo-x solo" ] || fail "S1: defaults without teams.channel: $R"
mkdir -p "$N/.claude"; echo '{"teams": {"channel": {"tmux_prefix": "a.b"}}}' > "$N/.claude/project-profile.json"
set +e; bash -c '. "$1/team-channel.sh"; team_channel_names "$2"' _ "$L" "$N" 2> "$WORK/out"; RC=$?; set -e
[ "$RC" = 3 ] && has "tmux_prefix=a.b must match" "$WORK/out" || fail "S1: an invalid prefix is not rc 3"
jq '.teams.channel.tmux_prefix = "a.b"' "$MAIN/.claude/project-profile.json" > "$O/.claude/project-profile.json"
run "$O" $W status; expect 3 "error: team-watch needs a valid teams.channel block" "S1: tw_init refuses an invalid block"
echo "team-smoke-17: (S1) two checkouts, channel names OK"
echo "team-smoke-17: OK"
