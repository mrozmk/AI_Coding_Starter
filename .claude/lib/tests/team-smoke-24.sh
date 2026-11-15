#!/usr/bin/env bash
# End to end with the per-run TeamLead: the real runner in the background (TEAM_POLL_SECS=1) and
# every session played by writing the files a real session writes, through the record, verdict,
# decision and sender scripts. Waits are on a file or a log line with a 60 s deadline, never a fixed
# sleep as the pass condition. Scenarios (the owner's flow lanes):
#   alfa  — brainstorm, clean: spec gate, plan gate, coder, qa, acceptance, wrapup → ready, accepted
#   beta  — quick: plan gate, a human-only coder prompt → decision, one notification, operator relay
#   gamma — brainstorm: spec revise + collision, two reworks, the third refused, abandon → closed
#   trk   — brainstorm with workflow.tracker_comments on (github-shaped reads; the fixture's tracker
#           stays jira, whose wrapup needs no tracker target): the planner's ledger + snapshot,
#           the lead's fresh reads; a comment after the spec refuses the plan approve (exit 10) until
#           the planner reconciles it into the plan; acceptance on a current read → ready
#   off   — the switch off: no lead, the pre-TeamLead flow, a blocked coder ends the runner (exit 2)
# Each scenario asserts the exact set of Supervisor events and Operator notifications.
#
# Spec acceptance criteria → asserting cases (parts 20–24):
#   lead per run, reuse, end; none in cli            22 b, e, f, h; 24 alfa
#   order brief required                             21 b; 22 c
#   no plan before spec approve; Approved (TeamLead) 21 g; 24 alfa
#   no coder before plan approve; quick remode       21 k, l; 24 alfa, beta
#   blocked does not end the runner                  22 d; 24 off (it does with the switch off)
#   classes first; human-only → one notification     22 i–m; 24 beta
#   non-blocking decisions, matching                 22 m–o; 24 beta
#   revise limit                                     21 h; 24 gamma (revise)
#   answers.md, notes Operator cases                 22 p; 23 v; 24 beta
#   rework budget, abandon decision                  23 m–o; 24 gamma
#   ready only after blind accept                    23 b, d; 24 alfa
#   four events only                                 23 d, f; 24 alfa, beta, gamma, off
#   lead cannot commit/push/edit/record              20 d, e; 23 z
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
T0="$WORK/t0"; touch "$T0"

smoke_team AB-2400 feature/AB-2400-x
BR=feature/AB-2400-x; SUP="$MAIN/.agents/team/inbox/Supervisor/new"; NLOG="$WORK/notify.log"
export WORK TD
prof() { jq "$1" "$MAIN/.claude/project-profile.json" > "$WORK/p" && mv "$WORK/p" "$MAIN/.claude/project-profile.json"; }
mkdir -p "$MAIN/.claude/team/sessions/operator-kit" "$CLONE/.claude/hooks"
cp "$SRC/.claude/team/sessions/TeamLead-run.settings.json" "$MAIN/.claude/team/sessions/"
cp "$SRC/.claude/hooks/guard-teamlead-write.sh" "$CLONE/.claude/hooks/"
cp "$SRC/.claude/lib/team-watch-send.py" "$MAIN/.claude/lib/"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "$NLOG" > "$MAIN/.claude/team/sessions/operator-kit/notify.sh"
# A project-added ask rule (human-only for the lead) for beta's coder prompt; committed, so every
# stage validates on a clean tree.
jq '.permissions.ask = ["Bash(az webapp restart*)"]' "$CLONE/.claude/settings.json" > "$WORK/s" \
  && mv "$WORK/s" "$CLONE/.claude/settings.json"
git -C "$CLONE" add .claude && git -C "$CLONE" commit --quiet -m "fixture guard and ask rule"
printf '## Ticket\nExport button.\n\n## Not ordered\nCSV import\n\n## In-flight work\n- none\n' > "$WORK/brief.md"
run "$MAIN" bash .claude/lib/team-brief.sh write alfa "$WORK/brief.md"; expect 0 "" "fixture brief"

# A launched session is alive until it is killed (tmux stub log); each pane is idle unless the
# scenario put a prompt on it ($WORK/pane-<role>).
cat > "$WORK/hs.sh" <<'HS'
s="${3#=}"
l="$(grep -E -- "new-session -d -s $s |kill-session -t =$s\$" "$STUB_LOG" | tail -n 1)"
case "$l" in *new-session*) exit 0 ;; esac
exit 1
HS
export STUB_ON_HAS_SESSION=". '$WORK/hs.sh'" STUB_PANE="$FIX/idle.txt" TEAM_POLL_SECS=1
# has-session is answered by hs.sh; STUB_TMUX_ALIVE=0 lets display-message name the pane (prompt binding).
export STUB_TMUX_ALIVE=0
# The sender captures the stage's pane by id (display-message → %1); only a coder prompt is ever shown.
export STUB_ON_CAPTURE='case "$*" in *"=smk-alfa-coder:"*|*"-t %1"*) [ ! -s "$WORK/pane-coder" ] || STUB_PANE="$WORK/pane-coder" ;; esac'

# ---- helpers ---------------------------------------------------------------------------------------
# A deadline bounds a failure, it never paces a pass: 60 s absorbs the whole suite running in
# parallel (a reaction takes 1–3 s idle, up to ~25 s under that load).
WAIT_POLLS=$(( ${TEAM_SMOKE_WAIT_SECS:-60} * 5 ))
RPID=""
start_runner() {  # start_runner — the real runner, in the background, logs in $WORK/runner.out
  rm -rf "$TD/lock" "$TD/cancel"
  ( cd "$MAIN" && exec bash .claude/lib/team-run.sh alfa ) > "$WORK/runner.out" 2>&1 &
  RPID=$!; SPID=$RPID
}
runner_rc() {  # runner_rc <want> <label> — wait for the runner's own exit
  local i=0 rc=0
  while kill -0 "$RPID" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt "$WAIT_POLLS" ] || { cp "$WORK/runner.out" "$WORK/out"; fail "$2: the runner did not exit"; }
    sleep 0.2
  done
  wait "$RPID" || rc=$?; SPID=""
  [ "$rc" = "$1" ] || { cp "$WORK/runner.out" "$WORK/out"; fail "$2: runner exit $rc, expected $1"; }
}
wait_for() {  # wait_for <label> <condition> — poll up to the deadline; a dead runner fails at once
  local i=0
  until eval "$2"; do
    if [ -n "$RPID" ] && ! kill -0 "$RPID" 2>/dev/null; then
      eval "$2" && return 0
      cp "$WORK/runner.out" "$WORK/out"; fail "$1: the runner exited"
    fi
    i=$((i + 1)); [ "$i" -lt "$WAIT_POLLS" ] || { { tail -n 5 "$WORK/runner.out"; echo "-- send-lead.log"
      tail -n 3 "$TD/send-lead.log" 2>/dev/null || true; echo "-- keys"; grep -- "-l --" "$STUB_LOG" | tail -n 3 || true; echo "-- answers.md"; cat "$TD/runs/$RUN_ID/answers.md" 2>/dev/null || true; } > "$WORK/out"
      fail "$1: timed out"; }
    sleep 0.2
  done
}
launches() { grep -c -- "new-session -d -s smk-alfa-$1 " "$STUB_LOG" || true; }
launched() { wait_for "$1 launch $2" "[ \"\$(launches $1)\" -ge $2 ]"; }
rung() { grep -qsF -- "$1" "$STUB_LOG" "$TD/send-lead.log"; }   # a doorbell to the lead, sent or logged
said_to() { grep -qsF -- "send-keys -t =smk-alfa-$1: -l -- $2" "$STUB_LOG"; }
play() { run "$CLONE" bash .claude/lib/team-record.sh "$@"; }     # the stage session's record
V() { run "$CLONE" env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-verdict.sh "$@"; }
ldec() { run "$CLONE" env TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-lead.sh decision "$@"; }
sj() { jq -r --arg f "$1" '.[$f] // empty' "$TD/session.json" 2>/dev/null || true; }
on_stage() { wait_for "$1 session" "[ \"\$(sj role)\" = $1 ] && [ \"\$(sj round)\" = ${2:-1} ]"; }
pr_at() { pr_json "$1" "$2"; pr_set --arg b "refs/heads/$BR" '.sourceRefName = $b'; }
push() { git -C "$CLONE" push --quiet origin "$BR"; }
head_rev() { git -C "$CLONE" rev-parse HEAD; }
qa_report() {  # qa_report <file> — a ready report for the clone HEAD, attempt 1
  { echo "run: $RUN_ID"; echo "attempt: 1"; echo "output_rev: $(head_rev)"; echo "Verdict: ready"
    echo "Gate code: passed"; echo "Gate design: skipped — backend change"; echo "Gate cross-model: warn"
    echo "Gate final-build: passed"; echo "Tests: passed=3 failed=0 skipped=0 baseline=0"
    echo "Warnings: none"; echo "Rethink signals: none"; } > "$1"
}
brief() {  # brief <dir> — the blind check, then the acceptance brief written from it
  echo "- export button → src/export.txt" > "$1/blind-check.md"
  { for h in "Ordered vs delivered" "Scope delta" "Fit risks" "Open defects" "Warnings" "Recommendation"; do
      echo "## $h"; echo "none"; echo; done; } > "$1/acceptance-brief.md"
}
lead_said() {  # lead_said <text> <uuid> — the Operator typed it into the lead window
  local t; t="$(transcript "$(jq -r .session_id "$TD/teamlead.json")")"; mkdir -p "$(dirname "$t")"
  jq -cn --arg x "$1" --arg u "$2" --arg ts "$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ)" \
    '{type: "user", uuid: $u, timestamp: $ts, message: {role: "user", content: $x}}' >> "$t"
}
events() { grep -h '^event: ' "$SUP"/* 2>/dev/null | sed 's/^event: //' | sort | tr '\n' ' ' || true; }
notified() { if [ -s "$NLOG" ]; then grep -c . "$NLOG"; else echo 0; fi; }
fresh() {  # fresh <run id> <mode> — a new run, a fresh stub log, no inbox, no notifications
  RUN_ID="$1"; RD="$TD/runs/$RUN_ID"
  jq --arg m "$2" '.mode = $m' "$TD/team.json" > "$WORK/tj" && mv "$WORK/tj" "$TD/team.json"
  rm -rf "$TD/session.json" "$TD/acked" "$TD/verdict-acked" "$TD/round" "$MAIN/.agents/team/inbox" "$NLOG" \
    "$WORK"/pane-*
  echo "$RUN_ID" > "$TD/run"; : > "$STUB_LOG"; : > "$TD/send-lead.log"
}
spec() { mkdir -p "$CLONE/.agents/specs"; printf '# Spec\n\n**Status:** %s\n\n%s\n' "$1" "$2" > "$CLONE/.agents/specs/s.md"
  git -C "$CLONE" add -A && git -C "$CLONE" commit --quiet -m "spec: $1"; }
# One plan file per run: an earlier run's plan already sits in plans/done/.
plan() { PLAN="p-${RUN_ID##*-}.md"; mkdir -p "$CLONE/.agents/plans/active"
  printf '# Plan\n\n1. Add the export button.\n' > "$CLONE/.agents/plans/active/$PLAN"
  git -C "$CLONE" add -A && git -C "$CLONE" commit --quiet -m plan; }
coder_round1() {  # the coder's work: the plan to done/, the delivery, pushed, a draft PR; its record
  mkdir -p "$CLONE/.agents/plans/done"; git -C "$CLONE" mv ".agents/plans/active/$PLAN" ".agents/plans/done/$PLAN"
  commit_file "src/export-$RUN_ID.txt" "export button"; push; pr_at true "$(head_rev)"
  play --verdict done --pr 8371 --artifacts ".agents/plans/done/$PLAN"; expect 0 "coder-1-1.json" "$RUN_ID coder record"
}
qa_done() {  # qa_done <run dir> — report, the PR published, the record
  qa_report "$1/qa-report-1.md"; pr_at false "$(head_rev)"
  play --verdict done --pr 8371 --evidence "${1#"$CLONE"/}/qa-report-1.md"; expect 0 "qa-1-1.json" "$RUN_ID qa record"
}
prof '.teams.teamlead.enabled = true'

# ==== alfa: brainstorm, clean ==========================================================================
fresh alfa-20261116-100000 brainstorm
start_runner
launched planner 1
[ "$(grep -n -- 'new-session -d -s smk-alfa-lead ' "$STUB_LOG" | head -n 1 | cut -d: -f1)" -lt \
  "$(grep -n -- 'new-session -d -s smk-alfa-planner ' "$STUB_LOG" | head -n 1 | cut -d: -f1)" ] || fail "alfa: the planner launched before the lead"
on_stage planner
spec Draft "Export button."; play --verdict review --artifacts .agents/specs/s.md; expect 0 "planner-1-1.json" "alfa review"
wait_for "alfa spec gate" "rung 'gate spec: .agents/team/runs/$RUN_ID/planner-1-1.json'"
printf 'scope: src/\nmade_at: 2026-11-16T10:00:00Z\n\n- none\n' > "$RD/digest.md"
V spec approve --for planner-1-1.json --message "matches the order"; expect 0 "teamlead-spec-1.json" "alfa spec approve"
wait_for "alfa approve said" "said_to planner '[team-run] TeamLead approved the spec'"
grep -F -- "send-keys -t =smk-alfa-planner: -l -- [team-run] TeamLead approved the spec" "$STUB_LOG" \
  | grep -qF "Set **Status:** Approved (TeamLead, " || fail "alfa: no Approved (TeamLead, …) instruction"
spec "Approved (TeamLead, 2026-11-16)" "Export button."; plan
play --verdict done --artifacts ".agents/specs/s.md,.agents/plans/active/$PLAN"; expect 0 "planner-1-2.json" "alfa planner done"
wait_for "alfa plan gate" "rung 'gate plan: .agents/team/runs/$RUN_ID/planner-1-2.json'"
[ "$(launches coder)" = 0 ] || fail "alfa: the coder launched before the plan gate"
git -C "$CLONE" show HEAD~1:.agents/specs/s.md | grep -q '^\*\*Status:\*\* Approved (TeamLead, ' || fail "alfa: spec commit not Approved (TeamLead, …)"
V plan approve --for planner-1-2.json --message ok; expect 0 "teamlead-plan-1.json" "alfa plan approve"
launched coder 1; on_stage coder
[ "$(launches qa)" = 0 ] || fail "alfa: qa before the coder"
coder_round1
launched qa 1; on_stage qa; qa_done "$RD"
wait_for "alfa acceptance gate" "rung 'gate acceptance: .agents/team/runs/$RUN_ID/qa-1-1.json'"
[ "$(launches wrapup)" = 0 ] || fail "alfa: the wrapup launched before accept"
brief "$RD"; V acceptance accept --for qa-1-1.json --message "covers the order"; expect 0 "teamlead-acceptance-1.json" "alfa accept"
launched wrapup 1; on_stage wrapup
printf 'target_rev: %s\n\n## What matters for you\nPR 8371.\n' "$BASE" > "$RD/wrapup-1.md"
play --verdict done --pr 8371 --artifacts ".agents/team/runs/$RUN_ID/wrapup-1.md"; expect 0 "wrapup-1-1.json" "alfa wrapup"
runner_rc 0 "alfa"
has "ready: bash .claude/lib/team-merge-check.sh alfa" "$WORK/runner.out" || fail "alfa: not ready"
[ "$(events)" = "accepted " ] || fail "alfa: events '$(events)'"
[ "$(notified)" = 0 ] || fail "alfa: $(notified) notifications"
echo "team-smoke-24: alfa (brainstorm, clean) OK"

# ==== beta: quick, a human-only prompt → decision → operator relay ======================================
fresh alfa-20261116-110000 quick
start_runner
launched planner 1; on_stage planner
plan; play --verdict done --artifacts ".agents/plans/active/$PLAN"; expect 0 "planner-1-1.json" "beta planner done"
wait_for "beta plan gate" "rung 'gate plan: .agents/team/runs/$RUN_ID/planner-1-1.json'"
[ "$(launches coder)" = 0 ] || fail "beta: the coder launched before the plan gate"
V plan approve --for planner-1-1.json --message ok; expect 0 "teamlead-plan-1.json" "beta plan approve"
launched coder 1; on_stage coder
CSID="$(sj session_id)"; CREAL="$(cd "$CLONE" && pwd -P)"; CT="$(transcript "$CSID")"; mkdir -p "$(dirname "$CT")"
jq -cn '{type: "assistant", uuid: "a-w", message: {content: [{type: "text", text: "working"}]}}' >> "$CT"
pending_tool "$CSID" t1 Bash '{"command": "az webapp restart --name x", "description": "Restart it"}' "$CREAL"
RULE="$(printf '─%.0s' $(seq 120))"; DASH="$(printf '╌%.0s' $(seq 120))"
{ echo "$RULE"; echo " Bash command"; echo " Restart it"; echo "$DASH"; echo " │ az webapp restart --name x"
  echo "$DASH"; echo " This command requires approval"; echo " Do you want to proceed?"
  echo " ❯ 1. Yes"; echo "   2. No"; echo " Esc to cancel · Tab to amend"; } > "$WORK/pane-coder"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) permission_prompt Claude needs your permission" >> "$RD/attention"
wait_for "beta request" "[ -f '$RD/decisions/req-1.json' ]"
wait_for "beta human-only ring" "rung 'human-only coder: Bash command az webapp restart'"
! grep -q '\[authority class\]' "$RD/answers.md" 2>/dev/null || fail "beta: the class answered a human-only prompt"
ldec open alfa --request req-1; expect 0 "[d-1] coder: Bash command" "beta decision"
wait_for "beta notification" "[ \"\$(notified)\" -ge 1 ]"
lead_said "d-1 yes, restart it" u-op-beta
ldec answer alfa d-1 --text "yes, restart it" --tuning rule --why "a restart in the order's scope could be a rule"
expect 0 "answered: d-1" "beta Operator answer"
TEAM_CONFIRM_SECS=1 run "$MAIN" env TEAM_SESSION_ROLE=TeamLead TEAM_RUN_TEAM=alfa bash .claude/lib/team-answer.sh \
  alfa coder yes --authority operator --why "Operator: yes, restart it" --decision "$RD/decisions/d-1.md"
expect 0 "sent yes" "beta operator relay"
grep -q '\[coder 1\] .* → yes — Operator: yes, restart it \[authority operator\] \[decision d-1\]$' "$RD/answers.md" \
  || fail "beta: the relay is not in answers.md"
grep -qF -- "- d-1 coder: Bash command" "$RD/teamlead-notes.md" && grep -q -- "— tuning: rule — " "$RD/teamlead-notes.md" \
  || fail "beta: no Operator case in the notes"
tool_done "$CSID" t1; rm -f "$WORK/pane-coder"
coder_round1
launched qa 1; on_stage qa; qa_done "$RD"
wait_for "beta acceptance gate" "rung 'gate acceptance: .agents/team/runs/$RUN_ID/qa-1-1.json'"
brief "$RD"; V acceptance accept --for qa-1-1.json --message ok; expect 0 "" "beta accept"
launched wrapup 1; on_stage wrapup
printf 'target_rev: %s\n' "$BASE" > "$RD/wrapup-1.md"
play --verdict done --pr 8371 --artifacts ".agents/team/runs/$RUN_ID/wrapup-1.md"; expect 0 "" "beta wrapup"
runner_rc 0 "beta"
[ "$(events)" = "accepted " ] || fail "beta: events '$(events)'"
[ "$(notified)" = 1 ] && grep -q -- '--alarm team alfa: human_decision' "$NLOG" || fail "beta: notifications $(cat "$NLOG" 2>/dev/null)"
echo "team-smoke-24: beta (quick, human decision) OK"

# ==== gamma: revise + collision, two reworks, the third refused, abandon → closed ======================
fresh alfa-20261116-120000 brainstorm
start_runner
launched planner 1; on_stage planner
spec Draft "Export button. Also a CSV import."; play --verdict review --artifacts .agents/specs/s.md; expect 0 "" "gamma review"
wait_for "gamma spec gate 1" "rung 'gate spec: .agents/team/runs/$RUN_ID/planner-1-1.json'"
echo "- CSV import is beyond the order (Not ordered)" > "$RD/gate-spec-1.md"
V spec revise --for planner-1-1.json --ref ".agents/team/runs/$RUN_ID/gate-spec-1.md" --message "1 finding"; expect 0 "" "gamma revise"
V event collision --ref ".agents/team/runs/$RUN_ID/gate-spec-1.md" --message "beta's open PR touches the export"; expect 0 "" "gamma collision"
wait_for "gamma revise said" "said_to planner '[team-run] TeamLead: revise the spec'"
spec Draft "Export button."; play --verdict review --artifacts .agents/specs/s.md; expect 0 "planner-1-2.json" "gamma review 2"
wait_for "gamma spec gate 2" "rung 'gate spec: .agents/team/runs/$RUN_ID/planner-1-2.json'"
printf 'scope: src/\nmade_at: 2026-11-16T12:00:00Z\n\n- none\n' > "$RD/digest.md"
V spec approve --for planner-1-2.json --message ok; expect 0 "" "gamma spec approve"
wait_for "gamma approve said" "said_to planner '[team-run] TeamLead approved the spec'"
spec "Approved (TeamLead, 2026-11-16)" "Export button."; plan
play --verdict done --artifacts ".agents/specs/s.md,.agents/plans/active/$PLAN"; expect 0 "planner-1-3.json" "gamma planner done"
wait_for "gamma plan gate" "rung 'gate plan: .agents/team/runs/$RUN_ID/planner-1-3.json'"
V plan approve --for planner-1-3.json --message ok; expect 0 "" "gamma plan approve"
launched coder 1; on_stage coder; coder_round1
launched qa 1; on_stage qa; qa_done "$RD"
for n in 2 3; do
  p="$( [ "$n" = 2 ] && echo "" || echo "r$((n - 1))/" )"
  wait_for "gamma acceptance gate round $((n - 1))" "rung 'gate acceptance: .agents/team/runs/$RUN_ID/${p}qa-1-1.json'"
  echo "- remove the CSV stub (not ordered)" > "$RD/rework-$n.md"
  V acceptance rework --for qa-1-1.json --ref ".agents/team/runs/$RUN_ID/rework-$n.md" --message "round $n"; expect 0 "" "gamma rework $((n - 1))"
  launched coder "$n"; on_stage coder "$n"
  commit_file "src/export-$RUN_ID.txt" "export button, round $n"; push; pr_at false "$(head_rev)"
  play --verdict done --pr 8371; expect 0 "r$n/coder-1-1.json" "gamma round-$n coder"
  launched qa "$n"; on_stage qa "$n"; qa_done "$RD/r$n"
done
wait_for "gamma acceptance gate round 3" "rung 'gate acceptance: .agents/team/runs/$RUN_ID/r3/qa-1-1.json'"
echo "- one more" > "$RD/rework-4.md"
V acceptance rework --for qa-1-1.json --ref ".agents/team/runs/$RUN_ID/rework-4.md" --message x
expect 9 "rework budget 2 reached" "gamma third rework"
ldec open alfa --source qa-1-1.json --question "Two reworks spent — abandon AB-2400?" --notify abandon_decision --recommend abandon
expect 0 "[d-1]" "gamma abandon decision"
V acceptance abandon-recommended --for qa-1-1.json --decision d-1 --message "budget spent"; expect 0 "" "gamma abandon-recommended"
wait_for "gamma notification" "[ \"\$(notified)\" -ge 1 ]"
lead_said "d-1 close it" u-op-gamma
ldec answer alfa d-1 --text "close it" --outcome close --tuning TeamLead --why "the lead could have stopped at the spec gate"
expect 0 "answered: d-1 (close)" "gamma Operator answer"
V decision close --for qa-1-1.json --decision d-1 --message "Operator: close it"; expect 0 "" "gamma decision close"
runner_rc 8 "gamma"
has "closed: abandon — PR 8371 to abandon before team-next" "$WORK/runner.out" || fail "gamma: closed line"
[ "$(events)" = "closed collision " ] || fail "gamma: events '$(events)'"
[ "$(notified)" = 1 ] && grep -q -- '--alarm team alfa: abandon_decision' "$NLOG" || fail "gamma: notifications $(cat "$NLOG" 2>/dev/null)"
grep -q "^### .* alfa AB-2400 $RUN_ID — closed$" "$MAIN/.agents/team/teamlead-log.md" \
  && grep -qF -- "- d-1 Two reworks spent — abandon AB-2400? — tuning: TeamLead — " "$MAIN/.agents/team/teamlead-log.md" \
  || fail "gamma: no log block"
echo "team-smoke-24: gamma (revise, collision, rework budget, abandon) OK"

# ==== trk: brainstorm, tracker comments on (github-shaped reads) ====================================================
cp "$SRC/.claude/lib/tracker-snapshot.mjs" "$CLONE/.claude/lib/"
git -C "$CLONE" add .claude/lib && git -C "$CLONE" commit --quiet -m "fixture snapshot tool"
prof '.workflow.tracker_comments = true'
SNAP="node $CLONE/.claude/lib/tracker-snapshot.mjs"
tshow() {  # tshow <out snapshot> <comment id:body>... — snapshot a github show result of the ticket
  local o="$1" c a=(); shift
  for c in "$@"; do a+=("$(jq -cn --arg i "${c%%:*}" --arg b "${c#*:}" \
    '{id: $i, author: "dev", created: "2026-11-16T09:00:00Z", updated: "2026-11-16T09:00:00Z", body: $b}')"); done
  printf '%s\n' ${a[@]+"${a[@]}"} | jq -s '{key: "AB-2400", updated: "2026-11-16T09:00:00Z", body: "Export button.", comments: .}' \
    > "$WORK/show.json"
  $SNAP snapshot --github "$WORK/show.json" --out "$o" >/dev/null
}
ledger() {  # ledger <artifact> <snapshot> — append the entry stage's ledger
  printf '\n## From tracker comments\nRead: AB-2400 · github · 2026-11-16T09:00:00Z · fetched 1 · complete · snapshot %s\nDescription: sha x — reconciled\n- 2026-11-16T09:00:00Z · 501 · sha y · dev · requirement · CSV header row\n' "$2" >> "$CLONE/$1"
}
fresh alfa-20261116-125000 brainstorm
start_runner
launched planner 1; on_stage planner
mkdir -p "$CLONE/.agents/specs"; tshow "$CLONE/.agents/specs/s.ticket.json" "501:CSV header row"
printf '# Spec\n\n**Status:** Draft\n\nExport button with a CSV header row.\n' > "$CLONE/.agents/specs/s.md"
ledger .agents/specs/s.md .agents/specs/s.ticket.json
git -C "$CLONE" add -A && git -C "$CLONE" commit --quiet -m "spec + ticket snapshot"
play --verdict review --artifacts .agents/specs/s.md; expect 0 "planner-1-1.json" "trk review"
wait_for "trk spec gate" "rung 'gate spec: .agents/team/runs/$RUN_ID/planner-1-1.json'"
printf 'scope: src/\nmade_at: 2026-11-16T12:50:00Z\n\n- none\n' > "$RD/digest.md"
V spec approve --for planner-1-1.json --message ok; expect 10 "no fresh read" "trk spec approve without a fresh read"
tshow "$RD/tracker-spec-1.json" "501:CSV header row"
V spec approve --for planner-1-1.json --message ok; expect 0 "teamlead-spec-1.json" "trk spec approve"
wait_for "trk approve said" "said_to planner '[team-run] TeamLead approved the spec'"
sed -i.bak 's/^\*\*Status:\*\* Draft/**Status:** Approved (TeamLead, 2026-11-16)/' "$CLONE/.agents/specs/s.md"
rm -f "$CLONE/.agents/specs/s.md.bak"; git -C "$CLONE" commit --quiet -am "spec approved"; plan
play --verdict done --artifacts ".agents/specs/s.md,.agents/plans/active/$PLAN"; expect 0 "planner-1-2.json" "trk planner done"
wait_for "trk plan gate" "rung 'gate plan: .agents/team/runs/$RUN_ID/planner-1-2.json'"
# The Operator commented after the spec: the plan approve is refused, the lead sends it back.
tshow "$RD/tracker-plan-1.json" "501:CSV header row" "502:a footer line too"
V plan approve --for planner-1-2.json --message ok; expect 10 "new 502 — revise with the list as findings" "trk plan approve on a new comment"
printf -- '- 502 (tracker comment): a footer line — reconcile into the plan\n' > "$RD/gate-plan-1.md"
V plan revise --for planner-1-2.json --ref "$RD/gate-plan-1.md" --message "new tracker input: 502"; expect 0 "teamlead-plan-1.json" "trk plan revise"
wait_for "trk amend said" "said_to planner '[team-run] TeamLead: amend the plan'"
tshow "$CLONE/.agents/plans/active/${PLAN%.md}.ticket.json" "501:CSV header row" "502:a footer line too"
ledger ".agents/plans/active/$PLAN" ".agents/plans/active/${PLAN%.md}.ticket.json"
git -C "$CLONE" add -A && git -C "$CLONE" commit --quiet -m "plan reconciles 502"
play --verdict done --artifacts ".agents/specs/s.md,.agents/plans/active/$PLAN"; expect 0 "planner-1-3.json" "trk planner done again"
wait_for "trk plan gate 2" "rung 'gate plan: .agents/team/runs/$RUN_ID/planner-1-3.json'"
tshow "$RD/tracker-plan-2.json" "501:CSV header row" "502:a footer line too"
V plan approve --for planner-1-3.json --message ok; expect 0 "teamlead-plan-2.json" "trk plan approve"
launched coder 1; on_stage coder
coder_round1
launched qa 1; on_stage qa; qa_done "$RD"
wait_for "trk acceptance gate" "rung 'gate acceptance: .agents/team/runs/$RUN_ID/qa-1-1.json'"
brief "$RD"; tshow "$RD/tracker-acceptance-1.json" "501:CSV header row" "502:a footer line too"
V acceptance accept --for qa-1-1.json --message "covers the order"; expect 0 "teamlead-acceptance-1.json" "trk accept"
jq -e '.tracker | startswith("Tracker comments: none new")' "$RD/teamlead-acceptance-1.json" >/dev/null || fail "trk: no tracker line in the accept"
launched wrapup 1; on_stage wrapup
printf 'target_rev: %s\n\n## What matters for you\nPR 8371.\n' "$BASE" > "$RD/wrapup-1.md"
play --verdict done --pr 8371 --artifacts ".agents/team/runs/$RUN_ID/wrapup-1.md"; expect 0 "wrapup-1-1.json" "trk wrapup"
runner_rc 0 "trk"
has "ready: bash .claude/lib/team-merge-check.sh alfa" "$WORK/runner.out" || fail "trk: not ready"
[ "$(events)" = "accepted " ] || fail "trk: events '$(events)'"
prof '.workflow.tracker_comments = false'
echo "team-smoke-24: trk (tracker comments on) OK"

# ==== off: the switch off — no lead, Approved (auto — team mode), a blocked coder ends the runner ======
prof '.teams.teamlead.enabled = false'
fresh alfa-20261116-130000 brainstorm; rm -f "$TD/teamlead.json"
start_runner
launched planner 1; on_stage planner
grep -qF 'Approved (auto — team mode)' "$RD/planner-1.prompt.md" || fail "off: the planner prompt lost the auto approval"
spec "Approved (auto — team mode)" "Export button."; plan
play --verdict done --artifacts ".agents/specs/s.md,.agents/plans/active/$PLAN"; expect 0 "" "off planner done"
launched coder 1; on_stage coder
play --verdict blocked --message "which endpoint?"; expect 0 "" "off coder blocked"
runner_rc 2 "off"
[ "$(launches lead)" = 0 ] || fail "off: a lead launched"
[ ! -d "$MAIN/.agents/team/inbox" ] && [ "$(notified)" = 0 ] || fail "off: inbox '$(events)' or notifications"
echo "team-smoke-24: off (switch off) OK"

# ---- nothing outside the fixture ------------------------------------------------------------------
REAL="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
# Live sessions on this machine write ~/.agent-comms and ~/.agent-mail all the time: there a newer
# file only fails when it carries this fixture (its scratch path or its ticket).
for d in "$REAL/.agent-comms" "$REAL/.agent-mail"; do
  [ ! -d "$d" ] || [ -z "$(find "$d" -type f -newer "$T0" -exec grep -lF -e "$WORK" -e AB-2400 {} + 2>/dev/null)" ] \
    || fail "a fixture file appeared under $d"
done
[ ! -d "$SRC/.agents/team" ] || [ -z "$(find "$SRC/.agents/team" -newer "$T0" -print -quit 2>/dev/null)" ] \
  || fail "a file appeared under the worktree's .agents/team"
[ "$HOME" != "$REAL" ] || fail "the part ran with the real HOME"
echo "team-smoke-24: no file outside the fixture OK"
echo "team-smoke-24: OK"

