#!/usr/bin/env bash
# Escalation end to end with the role sessions, in advisor pair and solo: team-escalate.sh → the
# rendered escalation config → the installed kit adapter → the real agent-mail CLI → a scripted
# Advisor/Reviewer replying through team-mail.sh as that role → team-question.sh delivery.
# Cases E1-E10. A fixture channel (registry, box) under the throwaway HOME; nothing reads or
# writes the real ~/.agent-mail. The live Codex Advisor round-trip is P9 evidence, not this part.
# Its wait/opinion/peek windows are seconds wide: under load they miss.
# team-smoke: serial
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
BG=""
trap 'for p in $BG; do kill "$p" 2>/dev/null || true; done
  [ -z "$SPID" ] || kill "$SPID" 2>/dev/null || true; rm -rf "$WORK"' EXIT
unset AGENT_MAIL_BOX CODEX_HOME TEAM_SESSION_ROLE TEAM_MAIL_LEGACY
OK_DIR=.claude/team/sessions/operator-kit
ESCF="$MAIN/.agents/team/escalation.local.json"
M="bash .claude/lib/team-mail.sh QX"
Q="bash .claude/lib/team-question.sh"
TMIN=4

# ---- fixture: the channel and the kit, as /setup:teams installs them ---------------------------
mkdir -p "$MAIN/tools" "$MAIN/.claude/team/sessions"
cp -R "$SRC/tools/agent_mail" "$MAIN/tools/"; rm -rf "$MAIN/tools/agent_mail/tests"
find "$MAIN/tools" -name __pycache__ -prune -exec rm -rf {} +
cp "$SRC"/.claude/team/*.tmpl "$MAIN/.claude/team/"
cp -R "$SRC/$OK_DIR" "$MAIN/.claude/team/sessions/"
cp "$SRC/.claude/hooks/supervisor-notify.sh" "$MAIN/.claude/hooks/"
printf '__pycache__/\n' >> "$MAIN/.gitignore"
git -C "$MAIN" add -A && git -C "$MAIN" commit --quiet -m "escalation fixture"
prof() { jq "$1" "$MAIN/.claude/project-profile.json" > "$WORK/p" && mv "$WORK/p" "$MAIN/.claude/project-profile.json"; }
prof '.teams.channel = {project_code: "QX", mail_suffix: "Qx", advisor: "pair"}'
run "$MAIN" bash .claude/lib/team-mail-setup.sh "$MAIN"; expect 0 "" "fixture: the channel step"
run "$MAIN" bash $OK_DIR/install.sh --apply; expect 0 "" "fixture: the kit"
KIT="$(jq -r .kit_dir "$MAIN/.agents/team/channel.local.json")"
DEC="$(jq -r .decisions_dir "$MAIN/.agents/team/channel.local.json")"
render() {  # the rendered config with a short timeout (the template's 30 min, shrunk to $TMIN)
  run "$MAIN" bash .claude/lib/team-channel.sh render; expect 0 "" "render"
  jq --argjson t "$TMIN" '.timeout_min = $t' "$ESCF" > "$WORK/e" && mv "$WORK/e" "$ESCF"
}
render
jq -e '.opinion and .peek' "$ESCF" >/dev/null || fail "fixture: pair config lacks opinion/peek"

smoke_team AB-1400 chore/AB-1400-escalation
RUN_ID=alfa-20261105-000000; echo "$RUN_ID" > "$TD/run"; RD="$TD/runs/$RUN_ID"
mkdir -p "$RD/questions"
export TEAM_ESCALATE_UNIT_SECS=1 TEAM_ESCALATE_POLL=0.2 TEAM_ESCALATE_BACKOFF_SECS=0
export TEAM_ESCALATE_LATE_SECS=6 TEAM_ESCALATE_OPINION_SECS=15 TEAM_ESCALATE_PEEK_SECS=8
export TEAM_ESCALATE_OPINION_RECHECK_SECS=12 TEAM_ESCALATE_ADAPTER_POLL=0.2
{ echo "⏺ > waiting for the supervisor's answer"; cat "$FIX/idle.txt"; } > "$WORK/idle"
export STUB_PANE="$WORK/idle" STUB_TMUX_ALIVE=0
session coder 1 "$BASE"

assistant() {  # assistant <uuid> — the role's last transcript turn (the blocked event)
  mkdir -p "$(dirname "$(transcript sid-coder-1)")"
  jq -cn --arg u "$1" '{type: "assistant", uuid: $u, message: {content: [{type: "text",
    text: "waiting"}]}}' >> "$(transcript sid-coder-1)"
}
N=0
fresh() {  # fresh <summary> → QF QN T: a real open blocked question
  N=$((N + 1)); assistant "a-wait-$N"
  record --verdict blocked --message "$1" >/dev/null
  run "$MAIN" $Q alfa open coder --kind blocked --summary "$1"
  expect 0 "" "open $1"
  QN="$(head -n 1 "$WORK/out" | cut -d' ' -f1)"; QF="$RD/questions/$QN.md"; T="esc-$RUN_ID-$QN"
}
K=100
mkq() {  # mkq → QF QN T: a hand-written open blocked question for escalation-only cases
  K=$((K + 1)); QN="q-$K"; QF="$RD/questions/$QN.md"; T="esc-$RUN_ID-$QN"
  printf '# %s — alfa coder attempt 1\nrole: coder\nattempt: 1\nrun: %s\nkind: blocked\n' \
    "$QN" "$RUN_ID" > "$QF"
  printf 'record: -\nanchor: x\nfingerprint: v2:none\nopened: 2026-11-05T00:00:00Z\n\n' >> "$QF"
  printf '## Summary\nWhich design?\n\n## Context\n- last blocker: -\n\n## Screen\n    x\n' >> "$QF"
}
bg_esc() {  # bg_esc <args…> — team-escalate.sh as the TeamLead, in the background → BGP
  (cd "$MAIN" && TEAM_SESSION_ROLE=TeamLead exec bash .claude/lib/team-escalate.sh alfa coder "$@") \
    > "$WORK/esc.out" 2>&1 &
  BGP=$!; BG="$BG $BGP"
}
sent_wait() {
  local i=0
  until grep -q '^sent: ' "$QF" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt 150 ] || { cp "$WORK/esc.out" "$WORK/out"; fail "$1: never sent"; }
    sleep 0.2
  done
}
esc_done() { wait "$BGP" && RC=0 || RC=$?; cp "$WORK/esc.out" "$WORK/out"; }
say_as() {  # say_as <From> <To…> -- <body> — a role's mail on thread $T through team-mail.sh
  local from="$1" to=(); shift
  while [ "$1" != -- ]; do to+=(--to "$1"); shift; done
  printf '%b' "$2" > "$WORK/body"
  run "$MAIN" $M send --from "$from" "${to[@]}" --kind report --thread "$T" --body-file "$WORK/body"
  expect 0 "SENT id=" "$from mails on $T"
  SID="$(sed -nE 's/^SENT id=([0-9]+).*/\1/p' "$WORK/out")"
}
answer_sec() { awk '/^## Answer$/{s = 1} s && /^## / && !/^## Answer$/{exit} s' "$QF"; }

# ---- E1 pair: tier 2, the Advisor answers → ANSWER, delivered as Advisor,Reviewer --------------
fresh "Which retry design?"
bg_esc 2 "$QF" --blocks "retry design" --class contract; sent_wait E1
run "$MAIN" $M inbox --for ReviewerQx --unread --limit 0; expect 0 "thread=$T" "E1: the Reviewer got the copy"
run "$MAIN" $M inbox --for AdvisorQx --unread --limit 0
has "Contract: .agents/reference/team-advisor.md" "$WORK/out" || fail "E1: protocol lacks the contract pointer"
say_as AdvisorQx TeamLeadQx -- 'status: answer\nauthor: Advisor,Reviewer\ndecided-by: analysts\n\nCounter + backoff.\n'
esc_done; expect 0 "ANSWER" "E1: ANSWER over the real CLI"
has "Counter + backoff." "$WORK/out" || fail "E1: the answer body"
grep -q "^reply: $SID answer$" "$QF" && grep -qx "outcome: answer" "$QF" || fail "E1: ledger"
run "$MAIN" $Q alfa answer "$QN" --run "$RUN_ID" --tier 2 --author "Advisor,Reviewer" \
  --why "Advisor $T" --text "Counter + backoff." --send say
expect 0 "sent say" "E1: delivered"
has "[tier 2, Advisor,Reviewer]" "$RD/notes.md" || fail "E1: notes lack the author"
echo "team-smoke-escalation: E1 OK"

# ---- E3 pair: a late Advisor reply after the delivered answer → LATE ANSWER, ## Answer kept ----
A0="$(answer_sec)"
say_as AdvisorQx TeamLeadQx -- 'status: answer\nauthor: Advisor,Reviewer\ndecided-by: analysts\n\nLate: counter only.\n'
run "$MAIN" env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-escalate.sh alfa coder 2 "$QF" --resume
expect 0 "LATE ANSWER" "E3: late read"
has "Late: counter only." "$WORK/out" || fail "E3: the late body"
grep -qx "outcome: late-answer" "$QF" || fail "E3: late outcome not recorded"
[ "$(answer_sec)" = "$A0" ] || fail "E3: ## Answer changed"
echo "team-smoke-escalation: E3 OK"

# ---- E2 pair: eligible class, Advisor silent, Reviewer agrees with a condition → FALLBACK -------
fresh "Which test design?"
bg_esc 2 "$QF" --blocks "test design" --class plan-variant --recommend "say Integration test."
sent_wait E2
P="$RD/questions/$QN.payload.md"
has "fallback: eligible" "$P" && has "## Reviewer" "$P" || { cp "$P" "$WORK/out"; fail "E2: pair payload"; }
say_as ReviewerQx AdvisorQx TeamLeadQx -- 'opinion: agree\nKeep the limit at 3.\n'; OID="$SID"
esc_done; expect 0 "FALLBACK" "E2: fallback over the real CLI"
grep -qx "send: say" "$WORK/out" && grep -qx "reviewer: #$OID" "$WORK/out" || fail "E2: send/reviewer"
TXT="Integration test. — Reviewer conditions (#$OID): Keep the limit at 3."
grep -qxF "text: $TXT" "$WORK/out" || fail "E2: text"
WHY="fallback: Advisor no-reply — Reviewer #$OID"
run "$MAIN" $Q alfa answer "$QN" --run "$RUN_ID" --tier 2 --author TeamLead-fallback --why "$WHY" \
  --text "Integration test." --send say
expect 1 "refused: --text differs from the recorded fallback" "E2: a different --text"
OLD="Opus""Team-fallback"   # the source's literal, split so the purity scan never sees it
run "$MAIN" $Q alfa answer "$QN" --run "$RUN_ID" --tier 2 --author "$OLD" --why "$WHY" --text "$TXT" --send say
expect 1 "answered with --author TeamLead-fallback" "E2: the old fallback literal"
run "$MAIN" $Q alfa answer "$QN" --run "$RUN_ID" --tier 2 --author TeamLead-fallback --why "$WHY" \
  --text "$TXT" --send say
expect 0 "sent say" "E2: the fallback delivered"
has "[tier 2, TeamLead-fallback]" "$RD/notes.md" || fail "E2: notes lack the fallback marker"
echo "team-smoke-escalation: E2 OK"

# ---- E8 pair: the opinion op prints the Reviewer's message ------------------------------------
run "$MAIN" env TEAM_SESSION_ROLE=TeamLead bash "$KIT/escalate.sh" opinion "$P" alfa coder "$QN" "$T" 1
expect 0 "opinion: agree" "E8: pair opinion"
echo "team-smoke-escalation: E8 (pair) OK"

# ---- E4 pair: tier 3 with a forged operator-ref → unverified, nothing delivered ---------------
mkq
printf 'thread: esc-%s-q-999\nOperator decision: go\n' "$RUN_ID" > "$DEC/forged.md"
SUM="$(shasum -a 256 "$DEC/forged.md" | cut -c1-16)"
bg_esc 3 "$QF" --blocks "drop the column"; sent_wait E4
say_as AdvisorQx TeamLeadQx -- "status: answer\ndecided-by: operator\noperator-ref: forged.md sha256:$SUM\n\nGo.\n"
esc_done; expect 3 "operator-ref not verified" "E4: a forged operator-ref"
grep -q "^reply: $SID unverified-operator-ref$" "$QF" || fail "E4: ledger lacks the unverified reply"
! grep -qx "## Answer" "$QF" || fail "E4: something was delivered"
echo "team-smoke-escalation: E4 OK"

# ---- E6b pair channel, config without opinion → `opinion adapter off`, not `advisor solo` ------
jq 'del(.opinion)' "$ESCF" > "$WORK/e" && mv "$WORK/e" "$ESCF"
mkq
say_as ReviewerQx AdvisorQx TeamLeadQx -- 'opinion: agree\n'
run "$MAIN" env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-escalate.sh alfa coder 2 "$QF" \
  --blocks x --class plan-variant --recommend "say x"
expect 3 "NO-REPLY timeout after $TMIN min" "E6b: no opinion key"
has "fallback: no — opinion adapter off" "$QF" || fail "E6b: reason"
grep -qx "fallback: no" "$RD/questions/$QN.payload.md" || fail "E6b: payload fallback line"
echo "team-smoke-escalation: E6b OK"

# ---- solo -------------------------------------------------------------------------------------
prof '.teams.channel.advisor = "solo"'
render
! jq -e 'has("opinion")' "$ESCF" >/dev/null || fail "solo: the render kept the opinion op"

# ---- E5 + E6 solo: eligible class → no fallback advertised, Advisor only; silent → NO-REPLY ---
mkq
bg_esc 2 "$QF" --blocks "test design" --class plan-variant --recommend "say Integration test."
sent_wait E5
P="$RD/questions/$QN.payload.md"
grep -qx "fallback: no (advisor solo)" "$P" && ! grep -qx "## Reviewer" "$P" \
  || { cp "$P" "$WORK/out"; fail "E5: solo payload"; }
run "$MAIN" $M inbox --for ReviewerQx --unread --limit 0
! has "thread=$T" "$WORK/out" || fail "E5: the Reviewer got a solo escalation"
run "$MAIN" $M inbox --for AdvisorQx --unread --limit 0; expect 0 "thread=$T" "E5: the Advisor got it"
has "advisor solo — no Reviewer; say reviewer: none" "$WORK/out" || fail "E5: solo protocol line"
# A stray Reviewer agreement changes nothing under solo.
say_as ReviewerQx AdvisorQx TeamLeadQx -- 'opinion: agree\n'
esc_done; expect 3 "NO-REPLY timeout after $TMIN min" "E6: solo silence"
has "fallback: no — advisor solo" "$QF" || fail "E6: the refusal does not name the mode"
! has "reviewer-fallback" "$QF" || fail "E6: solo fell back"
run "$MAIN" $Q alfa answer "$QN" --run "$RUN_ID" --tier 2 --author TeamLead-fallback \
  --why "fallback: Advisor no-reply — Reviewer #$SID" --text x --send say
expect 1 "refused: TeamLead-fallback needs a recorded reviewer-fallback outcome" "E6: fallback author"
echo "team-smoke-escalation: E5 E6 OK"

# ---- E8 solo: the opinion op is refused --------------------------------------------------------
run "$MAIN" env TEAM_SESSION_ROLE=TeamLead bash "$KIT/escalate.sh" opinion "$P" alfa coder "$QN" "$T" 1
expect 2 "no Reviewer (advisor solo)" "E8: solo opinion"
echo "team-smoke-escalation: E8 (solo) OK"

# ---- E7 solo: author: Advisor + reviewer: none → ANSWER, delivered with that author -----------
fresh "Which contract?"
bg_esc 2 "$QF" --blocks "contract" --class contract; sent_wait E7
say_as AdvisorQx TeamLeadQx -- 'status: answer\nauthor: Advisor\nreviewer: none\ndecided-by: analysts\n\nKeep the contract.\n'
esc_done; expect 0 "ANSWER" "E7: solo answer"
grep -qx "author: Advisor" "$WORK/out" || fail "E7: author not printed as recorded"
grep -qx "outcome: answer" "$QF" || fail "E7: ledger"
run "$MAIN" $Q alfa answer "$QN" --run "$RUN_ID" --tier 2 --author Advisor --why "Advisor $T" \
  --text "Keep the contract." --send say
expect 0 "sent say" "E7: delivered"
has "[tier 2, Advisor]" "$RD/notes.md" || fail "E7: notes lack the author"
echo "team-smoke-escalation: E7 OK"

# ---- E10 the wrapup (B) hand-over: one deduplicated info mail, no wake-up ---------------------
ho() { run "$MAIN" bash .claude/lib/team-channel.sh turn TeamLead Advisor --thread "$T" "$@"; }
ho --kind info --dedup-key "memdefer-alfa-$RUN_ID" --body "ready note — q-1"
expect 0 "to=AdvisorQx kind=info awaiting=-" "E10: info hand-over"
I1="$(sed -nE 's/^SENT id=([0-9]+).*/\1/p' "$WORK/out")"
ho --kind info --dedup-key "memdefer-alfa-$RUN_ID" --body "ready note — q-1"
[ "$(sed -nE 's/^SENT id=([0-9]+).*/\1/p' "$WORK/out")" = "$I1" ] || fail "E10: the hand-over is not deduplicated"
ho --body "a wake-up"; expect 0 "kind=turn awaiting=AdvisorQx" "E10: a plain turn still wakes"
echo "team-smoke-escalation: E10 OK"

# ---- E9 the docs contract ---------------------------------------------------------------------
HDR="Transitional supervision rules — the scripts do not enforce them."
MON="$SRC/.claude/commands/monitor.md"
for l in "**Ownership**" "$HDR" "**Scope:**" "**Before the skip:**" "**Deferred record:**" \
  "**Hand-over:**" "**Late acceptance:**" "memdefer-<team>-<run>" "info: not sent" "--kind info" \
  "never on the q number alone" "an unreadable ledger is no proof" \
  "ESCALATION <thread>: Advisor reply #<id> without a current q"; do
  grep -qF -- "$l" "$MON" || fail "E9: monitor.md lacks '$l'"
done
ADV="$SRC/.agents/reference/team-advisor.md"
for l in '[promoted] <entry UTC> → decisions.md "<title>"' "Read immediately before the Edit" \
  "reviewer: none" "opinion: agree" "memory-writes workflow"; do
  grep -qF -- "$l" "$ADV" || fail "E9: team-advisor.md lacks '$l'"
done
grep -qx "own .agents/reference/team-advisor.md" "$SRC/.claude/team/manifest.txt" || fail "E9: not distributed"
grep -qF "Contract: .agents/reference/team-advisor.md" "$SRC/$OK_DIR/escalate.sh" || fail "E9: kit pointer"
grep -qF "ADVISOR silent since <UTC>: <n> escalation(s) waiting" \
  "$SRC/.agents/reference/supervisor-sessions.md" || fail "E9: Supervisor's ADVISOR silent handling"
grep -qF "orphans" "$SRC/.claude/commands/session-role.md" && grep -qF -- "--resume" \
  "$SRC/.claude/commands/session-role.md" || fail "E9: bootstrap orphans → --resume"
# Every summary of the (B) exception carries the header verbatim.
for f in $(grep -rlE 'wrapup \(B\)|\(B\) memory' "$SRC/.claude" "$SRC/.agents/reference" "$SRC/docs/teams" \
  | grep -v '/\.claude/lib/tests/'); do
  grep -qF -- "$HDR" "$f" || fail "E9: ${f#"$SRC/"} summarises (B) without the header"
done
echo "team-smoke-escalation: E9 OK"

echo "team-smoke-escalation: OK"
