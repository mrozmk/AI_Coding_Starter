#!/usr/bin/env bash
# Stage runner for a team clone: planner → coder → qa → wrapup, each a fresh Claude session in tmux.
#
# Usage: bash .claude/lib/team-run.sh <team> [status|stop|unlock]
#   e.g. tmux new-session -d -s alfa-runner "bash .claude/lib/team-run.sh alfa; read"
#   internal: bash .claude/lib/team-run.sh <team> check <record>   (validate one record)
#   bash .claude/lib/team-run.sh <team> roles <role>=[<model>][/<effort>][/<perm>]… | --clear
#   bash .claude/lib/team-run.sh <team> summary   (post-run summary sources, read-only)
#   modes (team.json .mode): lead (the TeamLead chooses) · brainstorm · quick · cli
#
# Env: TEAM_ATTACH=all|planner (default all) — Herdr: every stage, or only the attended planner and
# wrapup, gets a pane in its team's tab while it runs. tmux: no effect (no window is opened; planner
# and wrapup print an `attach:` line).
# Exit: 0 ready/advanced · 1 failed record · 2 blocked · 3 stalled · 4 validation failed
#       5 partial work after a dead session · 6 cancelled · 7 orphan role session
#       8 closed without merge (a TeamLead close or remode, also before the mode choice; runs/<run>/closed.json)
set -euo pipefail

if [ $# -lt 1 ] || { [ $# -gt 3 ] && [ "${2:-}" != roles ]; }; then
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
TEAM="$1"; CMD="${2:-advance}"

root="$(git rev-parse --show-toplevel)"; ORIG_PWD="$PWD"; export HARNESS_MAIN="$root"
# Before the runner lock, session.json and any tmux session: the profile decides what 2a can run.
. "$root/.claude/lib/team-profile.sh"
team_profile_load "$root"
team_profile_require_supported
CLONE="$(team_clone_dir "$TEAM" "$root")"
case "$CLONE" in *"'"*) echo "error: clone path contains a quote: $CLONE" >&2; exit 1 ;; esac
[ -f "$CLONE/.agents/team/team.json" ] || { echo "error: no team clone at $CLONE" >&2; exit 1; }
cd "$CLONE"
# The anchor writer runs in this shell; a role-writable library must not.
. "$root/.claude/lib/team-lib.sh"
[ "$CMD" != advance ] || ! t="$(team_tab_clash "$TEAM" "$root")" || { echo "error: team name $TEAM is the roles' Herdr tab $t — pick another team name" >&2; exit 1; }
# Override keys still follow the clone's runnable roles (team-mode.md §3), read as data only.
TEAM_ROLES="$(sed -n 's/^TEAM_ROLES="\([a-z ]*\)"$/\1/p' "$CLONE/.claude/lib/team-lib.sh" \
  2>/dev/null | head -n 1)" || true; TEAM_ROLES="${TEAM_ROLES:-planner coder qa wrapup}"
# From the main checkout, like roles.json: a clone on an older base lacks this file.
. "$root/.claude/lib/team-roles.sh"
. "$root/.claude/lib/team-send-lock.sh"
. "$root/.claude/lib/team-modes.sh"
. "$root/.claude/lib/team-validate.sh"
. "$root/.claude/lib/team-tracker-render.sh"
. "$root/.claude/lib/team-pr-render.sh"
. "$root/.claude/lib/team-anchor.sh"
. "$root/.claude/lib/team-channel.sh"
. "$root/.claude/lib/team-lead-lib.sh"
. "$root/.claude/lib/team-run-lead.sh"
. "$root/.claude/lib/team-ask.sh"
. "$root/.claude/lib/team-run-asks.sh"
. "$root/.claude/lib/team-run-dialog.sh"
. "$root/.claude/lib/team-run-stop.sh"
. "$root/.claude/lib/team-run-mode.sh"

TD="$CLONE/.agents/team"
# Read from the main checkout so a local edit applies at the next launch, without a PR.
ROLES="$root/.claude/team/roles.json"; [ -f "$ROLES" ] || ROLES="$CLONE/.claude/team/roles.json"
ROLES_OVERRIDE="$TD/roles.override.json"
POLL="${TEAM_POLL_SECS:-30}"
ADO_WAIT="${TEAM_ADO_WAIT_SECS:-300}"
ADO_POLL="${TEAM_ADO_POLL_SECS:-20}"
EXIT_WAIT="${TEAM_EXIT_WAIT_SECS:-60}"
STOP_WAIT="${TEAM_STOP_WAIT_SECS:-90}"
ATTACH="${TEAM_ATTACH:-all}"
case "$ATTACH" in all|planner) ;; *) echo "error: TEAM_ATTACH must be all or planner, got $ATTACH" >&2; exit 2 ;; esac
BRANCH="$(team_json branch)"; LINE="$(team_json line)"
RUN=""; ROLE=""; OWN_LOCK=0
MODE="$(team_mode "$TD/team.json")" || { echo "error: cannot read the mode of $TD/team.json" >&2; exit 1; }

# The runner's stops, waits and "ready" are its output and the run's files. Only steps the Operator
# alone can take reach the Operator, through notify.sh: the lead's verdicts (lead_notify), a session
# held at a startup dialog (dialog_watch, team-run-dialog.sh), a stall and a rejected record nobody
# in the team can fix (team-run-stop.sh).
die() { echo "$2" >&2; exit "$1"; }
rec() { jq -r --arg f "$2" '.[$f] // empty | if type == "array" then join(",") else . end' "$1"; }
sess_name() { team_tmux_name "$TEAM" "$1"; }
# In a run without a per-run TeamLead the planner and the wrapup are attended: the developer
# answers them in their window. With a lead every stage asks through the ask channel.
attended() { case "$1" in planner|wrapup) ;; *) return 1 ;; esac; }
artifact() { jq -r --arg p "$2" '[.artifacts[] | select(startswith($p))][0] // empty' "$1"; }

# /exit only on an idle input, under the send lock (team_end_session, team-lead-lib.sh).
end_session() {
  team_end_session "$TD" "$(sess_name "$1")" "$1" "$EXIT_WAIT" \
    || die 1 "error: session $(sess_name "$1") did not end"
}

cancel_exit() {
  [ -z "$ROLE" ] || end_session "$ROLE"
  die 6 "cancelled by stop — session.json kept for the next run"
}

last_blocker() {
  awk '/^## Blockers/{b=1; next} /^## /{b=0} b && /^- /{l=$0} END{print l}' "$TD/runs/$(run_ref)/notes.md" 2>/dev/null || true
}

# ---- stages -----------------------------------------------------------------------------------

accept() {
  local r="$1"
  end_session "$ROLE"
  team_cancelled && cancel_exit
  touch "$r.accepted"; stop_resolve
  team_anchor_planner "$root" "$TEAM" "$r" || echo "warn: anchor not written" >&2
  rm -f "$TD/session.json"
  echo "accepted: $(basename "$r")"
}

handle_record() {
  local r="$1"
  case "$(rec "$r" verdict)" in
    done) # With the lead on, the planner's done waits for the plan gate; validation follows approve.
          if team_lead_on && [ "$ROLE" = planner ]; then lead_gate_ring plan "$r"; return 2; fi
          # The qa done is checked first (published PR, report), then the lead's acceptance gate.
          if team_lead_on && [ "$ROLE" = qa ]; then
            validate_record "$r" || { reject_record "$r" || return $?; }
            lead_gate_ring acceptance "$r"; return 2
          fi
          validate_record "$r" || { reject_record "$r" || return $?; }
          accept "$r" ;;
    review)
      die 4 "record $(basename "$r") is a review: there is no spec gate — the planner approves its spec itself and records done after /plan-feature" ;;
    blocked|failed)
      if team_lead_on; then lead_stop "$r"; echo "waiting for TeamLead: $(basename "$r")"; return 2; fi
      ack_name "$r" > "$TD/acked"
      echo "$(rec "$r" verdict): $(last_blocker)"
      echo "answer in: $(sh_hint "$(sess_name "$ROLE")")"
      [ "$(rec "$r" verdict)" = blocked ] && exit 2 || exit 1 ;;
    *) die 4 "record $(basename "$r") has an unknown verdict" ;;
  esac
}

input_rev_for() {
  case "$1" in
    planner|cli) team_json base_sha ;;
    coder) if [ "$(cur_round)" = 1 ]; then rec "$(accepted_record planner)" output_rev; else round_input_rev; fi ;;
    qa) rec "$(accepted_record coder)" output_rev ;;
    wrapup) rec "$(accepted_record qa)" output_rev ;;
  esac
}

render_prompt() {
  local role="$1" attempt="$2" out="$3" p planner c1 qa plan="" spec="" pr="" report=""
  local kind host
  planner="$(accepted_record planner)"; qa="$(accepted_record qa)"
  if [ -n "$planner" ]; then
    spec="$(artifact "$planner" .agents/specs/)"; plan="$(artifact "$planner" .agents/plans/active/)"
  fi
  # Round 1's coder holds the PR and the done plan of every round (a rework coder pushes to that PR).
  c1="$(team_accepted_record "$RUN" coder)"
  if [ "$role" != planner ] && [ -n "$c1" ]; then plan="$(artifact "$c1" .agents/plans/done/)"; pr="$(rec "$c1" pr_id)"; fi
  [ -z "$qa" ] || report=".agents/team/runs/$(run_ref)/qa-report-$(rec "$qa" attempt).md"
  # ADO keeps `team_ado_coords`; github resolves owner/repo through the PR layer (Amendment 4).
  case "$TEAM_PR_PROVIDER" in
    github)
      ADO_ORG_URL=""; kind="GitHub repo"
      host="https://github.com/$(bash "$root/.claude/lib/team-pr.sh" coords)" \
        || die 4 "cannot resolve the github repo of $CLONE" ;;
    *) team_ado_coords; kind="Azure DevOps org"; host="$ADO_ORG_URL" ;;
  esac
  if [ "$MODE" = quick ] && [ -z "$spec" ]; then spec="none (quick mode)"; fi
  p="$(cat "$CLONE/.claude/team/prompts/$(team_prompt_name "$MODE" "$role")")"
  # Before `put TEAM`: the tracker blocks carry {{TICKET}}/{{RUN}} of their own. An empty tracker
  # field (a team.json written before 2b) renders as jira.
  p="$(team_tracker_render "$(team_json tracker || true)" "$CLONE/.claude/team/tracker" "$p")" \
    || die 4 "cannot render the tracker blocks of the $role prompt"
  # After the tracker blocks and before `put`: a tracker wrapup block carries {{PR_BODY_SET}}, and
  # the PR blocks themselves carry {{LINE}}/{{PR}}/{{RUN}}/{{BRANCH}}/{{ORG_URL}} of their own.
  p="$(team_pr_render "$TEAM_PR_PROVIDER" "$CLONE/.claude/team/pr" "$kind" "$host" \
    "$TEAM_GATES" "$p")" || die 4 "cannot render the PR blocks of the $role prompt"
  put() { local LC_ALL=C k="{{$1}}"; p="${p//"$k"/$2}"; }  # C: see render_lead_prompt
  put TEAM "$TEAM"; put TICKET "$(team_json ticket)"; put BRANCH "$BRANCH"; put LINE "$LINE"
  local o; o="$(team_json origin_ticket)"; put ORIGIN_TICKET "${o:-$(team_json ticket)}"  # pre-#86 clone: own origin
  put BASE_SHA "$(team_json base_sha)"; put RUN "$RUN"; put ATTEMPT "$attempt"; put MODE "$MODE"
  put RUN_DIR ".agents/team/runs/$(run_ref)"; put ROUND "$(cur_round)"; put REWORK "$(round_rework)"
  put PLAN "$plan"; put SPEC "$spec"; put PR "$pr"; put ORG_URL "$ADO_ORG_URL"; put QA_REPORT "$report"
  # Project gates come from the profile; TEST_GATE is a ready sentence, never a raw path.
  put BUILD_CHECK "$TEAM_BUILD_CHECK"; put TEST_GATE "$(team_gate_sentence)"
  printf '%s\n' "$p" > "$out"
}

launch() {
  local role="$1" attempt="$2" name pf sid start ch cc ck extra="" perm why costs=()
  team_cancelled && cancel_exit
  name="$(sess_name "$role")"; pf="$TD/runs/$(run_ref)/$role-$attempt.prompt.md"
  [ -n "$(input_rev_for "$role")" ] || die 4 "no input revision for $role — previous stage not accepted"
  # Before session.json: a rejected config must not record an attempt (dead_attempt stops at 2).
  extra="$(role_flags "$role")"
  perm="$(role_permission "$role")"
  if [ "$perm" = auto ] && why="$(auto_blocker)"; then
    echo "warn: $role launches in manual mode — $why"; perm=manual
  fi
  [ -z "$perm" ] || extra="$extra--permission-mode '$perm' "
  ch="$(codex_home)" || die 1 "$ch"
  cc="$(team_claude_home "$root")" || die 1 "$cc"
  mkdir -p "$TD/runs/$(run_ref)"
  # A known session id makes token-usage bindings explicit; transcripts are lower-case.
  sid="$(new_uuid)" || die 1 "error: new_uuid gave no UUID"
  # A lead-chosen cli resumes the choosing lead's session id (team-run-mode.sh).
  start="$(session_start_flag "$role")"
  if [ "$start" = --resume ]; then sid="$(cli_resume_sid "$cc")" || exit "$?"
  elif [ "$role" = cli ] && ! team_cli_prompt_ok "$CLONE"; then
    echo "warn: clone base has the pre-#296 cli prompt — this run keeps the old cli contract (no /codex-review)" >&2
  fi
  # A team.json written before 2b has no cost_key; jq's `//` would keep the empty string.
  ck="$(team_json cost_key)"; [ -n "$ck" ] || ck="$(team_json ticket)"
  jq -n --arg team "$TEAM" --arg role "$role" --arg run "$RUN" --argjson attempt "$attempt" \
    --arg ticket "$(team_json ticket)" --arg input_rev "$(input_rev_for "$role")" \
    --arg launched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg mode "$MODE" \
    --arg session_id "$sid" --arg cost_key "$ck" --arg permission_mode "${perm:-default}" \
    --arg claude_config_dir "$cc" \
    --argjson round "$(cur_round)" \
    '{team: $team, role: $role, run: $run, round: $round, attempt: $attempt, ticket: $ticket, mode: $mode,
      cost_key: $cost_key, claude_config_dir: $claude_config_dir,
      input_rev: $input_rev, launched_at: $launched_at, session_id: $session_id,
      permission_mode: $permission_mode}' \
    > "$TD/session.json"
  team_anchor_launch "$root" "$TEAM" "$CLONE" "$RUN" "$role" "$attempt" "$sid" \
    || echo "warn: anchor not written" >&2
  printf '%s\n' "$sid" > "$TD/runs/$(run_ref)/$role-$attempt.session"; stop_resolve
  render_prompt "$role" "$attempt" "$pf"
  if team_lead_on; then
    # The ask channel: every stage may ask, the run's TeamLead answers (team-lead.md §6).
    stage_hooks_materialise || die 4 "stage hooks not materialised from $root/.claude/team/stage-hooks.json"
    extra="$extra--settings '$TD/stage-hooks.settings.json' "
  else
    attended "$role" || extra="$extra--disallowedTools AskUserQuestion "
  fi
  # `--` is required: --disallowedTools is variadic and would swallow the prompt as a tool name.
  # CODEX_HOME per session, never `-g`: that would move other projects onto this licence.
  # CLAUDE_CONFIG_DIR the same way (team_claude_home: .claude/claude-profile, else this process's
  # own value): the tmux server may have been started from ANOTHER project's shell, and a new
  # session inherits that server's global environment — another project's Claude licence.
  # AGENT_COSTS_HOME likewise: a tmux session gets the server's environment, not the caller's.
  [ -z "${AGENT_COSTS_HOME:-}" ] || costs=(--env "AGENT_COSTS_HOME=$AGENT_COSTS_HOME")
  sh_start "$name" --kind team --cwd "$CLONE" --cli claude --no-probe --env "TEAM_RUN_TEAM=$TEAM" --env "TEAM_RUN_ROLE=$role" \
    --env "TEAM_RUN_ID=$RUN" --env "TEAM_RUN_ATTEMPT=$attempt" --env "CODEX_HOME=$ch" \
    ${cc:+--env "CLAUDE_CONFIG_DIR=$cc"} \
    ${costs[@]+"${costs[@]}"} \
    -- "claude $start $sid -n $name ${extra}-- \"\$(cat '$pf')\"" >/dev/null
  # Main checkout: a clone on an older base has no helper; a missing one only warns.
  bash "$root/.claude/lib/costs/runtime-mark.sh" session --provider claude --session "$sid" \
    --source team-run --name "$name" --ticket "$ck" --team "$TEAM" \
    --role "$role" --run "$RUN" --attempt "$attempt" --cwd "$CLONE" 2>/dev/null \
    || echo "warn: token-usage registration skipped"
  echo "launched: $role attempt $attempt"
  ! attended "$role" || echo "attach: $(sh_hint "$name")"
  if { [ "$ATTACH" = all ] || attended "$role"; } && [ "$(sh_record_get "$root" "$name" backend)" = herdr ]; then
    # Herdr: the stage's own terminal into its team's tab (label adoption, no focus change); its pane
    # closes when the stage's program exits. The main checkout's roles.sh, never the clone's.
    (cd "$root" && bash .claude/lib/roles.sh place "$name") 2>&1 | grep '^warn: ' || true
  fi
}

dead_attempt() {
  local role="$1" attempt="$2" input tip
  input="$(session_json input_rev)"
  tip="$(git ls-remote origin "refs/heads/$BRANCH" | cut -f1)"
  if [ "$(git rev-parse HEAD)" = "$input" ] && [ -z "$(git status --porcelain)" ] \
    && { [ -z "$tip" ] || [ "$tip" = "$input" ]; } && [ "$attempt" -lt 2 ]; then
    echo "dead attempt $attempt of $role left no trace — retrying"
    launch "$role" $((attempt + 1))
    return 0
  fi
  ! team_lead_on || lead_event session_dead "runs/$(run_ref)/$role-$attempt.session"
  die 5 "dead attempt $attempt of $role: partial work or retry limit — supervisor"
}

# A record the lead must resolve (rc 2) keeps the loop waiting; time spent waiting on the lead is
# not execution time, so the stage limit pauses (start moves with the clock while waiting=1) until
# the stop's <record>.answered marker appears (lead_waiting, re-read every poll and on resume).
wait_loop() {
  local role="$1" attempt name r start limit seen=0 n rc waiting=0 t last
  attempt="$(session_json attempt)"; name="$(sess_name "$role")"; start="$(team_now)"; last="$start"
  case "$role" in coder|cli) limit=14400 ;; qa) limit=10800 ;; *) limit=0 ;; esac
  while :; do
    team_cancelled && cancel_exit
    t="$(team_now)"; [ "$waiting" = 0 ] || start=$((start + t - last)); last="$t"
    waiting=0; ! team_lead_on || ! lead_waiting "$role" "$attempt" || waiting=1
    ! dialog_watch "$role" "$attempt" || waiting=1   # a startup dialog: the Operator's, not a stall
    r="$(new_record "$role" "$attempt")"
    if [ -n "$r" ]; then rc=0; handle_record "$r" || rc=$?; [ "$rc" = 2 ] || return 0; waiting=1; continue; fi
    ! team_lead_on || ! lead_gate "$role" "$attempt" || return 0
    n=0; [ ! -f "$TD/runs/$RUN/attention" ] || n="$(wc -l < "$TD/runs/$RUN/attention" | tr -d ' ')"
    if [ "$n" -gt "$seen" ]; then
      seen="$n"; echo "needs attention: $(sh_hint "$name")"
      ! team_lead_on || lead_attention "$role" "$n"
    fi
    if ! team_tmux_alive "$name"; then
      r="$(new_record "$role" "$attempt")"
      if [ -n "$r" ]; then rc=0; handle_record "$r" || rc=$?; [ "$rc" = 2 ] || return 0; waiting=1; continue; fi
      ! lead_close_hold "$role" "$attempt" || { sleep "$POLL"; continue; }
      dead_attempt "$role" "$attempt"
      attempt="$(session_json attempt)"; start="$(team_now)"; last="$start"; continue
    fi
    ! team_lead_on || lead_poll
    if [ "$limit" -gt 0 ] && [ $(( $(team_now) - start )) -ge "$limit" ]; then
      stall_stop "$role" "$attempt"; die 3 "stalled — attach: $(sh_hint "$name")"
    fi
    sleep "$POLL"
  done
}

# Recovery: a session.json means its role is the current stage, whatever else is accepted.
resume_stage() {
  local role attempt r rc=1
  role="$(session_json role)"; attempt="$(session_json attempt)"; ROLE="$role"
  [ "$(session_json run)" = "$RUN" ] || die 1 "error: session.json run differs from $TD/run"
  if ls "$TD/runs/$(run_ref)/$role-$attempt-"*.json.accepted >/dev/null 2>&1; then
    end_session "$role"; rm -f "$TD/session.json"; return 0
  fi
  if ! team_tmux_alive "$(sess_name "$role")"; then
    r="$(new_record "$role" "$attempt")"
    [ -z "$r" ] || { rc=0; handle_record "$r" || rc=$?; }
    [ "$rc" != 0 ] || return 0
    [ "$rc" = 2 ] || dead_attempt "$role" "$attempt"
  fi
  wait_loop "$role"
}

next_stage() {
  local role
  for role in $(team_mode_roles "$MODE" "$CLONE"); do
    [ -n "$(accepted_record "$role")" ] || { echo "$role"; return 0; }
  done
}

check_orphans() {
  local role
  for role in $(team_mode_roles "$MODE" "$CLONE"); do
    [ "$role" = "${1:-}" ] && continue
    ! team_tmux_alive "$(sess_name "$role")" || die 7 "orphan session $(sess_name "$role") — attach or stop"
  done
}

cmd_advance() {
  local stage r why=""
  mkdir "$TD/lock" 2>/dev/null || die 1 "runner lock held by pid $(cat "$TD/lock/pid" 2>/dev/null) — check: bash .claude/lib/team-run.sh $TEAM status"
  OWN_LOCK=1; echo $$ > "$TD/lock/pid"
  rm -f "$TD/cancel"
  ! command -v caffeinate >/dev/null 2>&1 || caffeinate -i -w $$ >/dev/null 2>&1 &
  [ -s "$TD/run" ] || echo "$TEAM-$(date -u +%Y%m%d-%H%M%S)" > "$TD/run"
  RUN="$(cat "$TD/run")"
  if [ -f "$TD/runs/$RUN/closed.json" ]; then
    r="$(jq -r .reason "$TD/runs/$RUN/closed.json")"
    case "$r" in abandon-before-mode) why=" — the Supervisor first releases its claim on the closed event (team-pipeline.md §5a), then /start-team $TEAM <KEY>" ;; esac
    die 1 "run closed ($r) — team-next for the next ticket, team-remode for remode$why"
  fi
  # A persisted close or mode verdict first: a close wins (nothing ran yet); a replacement judge
  # must not launch for a choice already made.
  [ "$MODE" != lead ] || mode_settle
  lead_start; round_reconcile
  # Mode lead has no stage yet (next_stage is empty): wait for the choice, never print ready.
  [ "$MODE" != lead ] || mode_wait
  cli_handover
  while :; do
    if [ -f "$TD/session.json" ]; then
      check_orphans "$(session_json role)"; resume_stage; continue
    fi
    check_orphans
    stage="$(next_stage)"
    if [ -z "$stage" ]; then
      ! team_lead_on || lead_accepted
      echo "ready: bash .claude/lib/team-merge-check.sh $TEAM"
      exit 0
    fi
    ROLE="$stage"; launch "$stage" 1; wait_loop "$stage"
  done
}

# Per-ticket override, merged over roles.json at each launch; team-next.sh archives it.
cmd_roles() {
  local e
  if [ "$MODE" = cli ] && [ "${1:-}" != --clear ]; then
    for e in "$@"; do
      case "$e" in cli=*) ;; *)
        echo 'error: in mode cli only cli=… entries apply (the other roles do not run);' \
          'use roles --clear to remove a stale override' >&2
        exit 1 ;;
      esac
    done
  fi
  team_roles_write "$TEAM" "$ROLES_OVERRIDE" "$@" || exit "$?"
}

cmd_status() {
  local role r pid
  jq -c '{team, ticket, branch, line, base_sha}' "$TD/team.json"
  mode_status
  # Durable non-fatal failures recorded by team-warn.sh.
  jq -r '(.warnings // [])[] | "warn: " + .text + " (" + .at + ")"' "$TD/team.json"
  RUN="$(cat "$TD/run" 2>/dev/null || true)"; echo "run: ${RUN:-none}$([ "$(run_ref)" = "$RUN" ] || echo " round $(cur_round)")"
  [ ! -f "$TD/runs/${RUN:-none}/closed.json" ] || echo "closed: $(jq -r .reason "$TD/runs/$RUN/closed.json")"
  [ ! -f "$TD/session.json" ] || echo "session:$(jq -c '{role, attempt, input_rev}' "$TD/session.json")"
  [ ! -f "$ROLES_OVERRIDE" ] || echo "roles override: $(team_roles_status "$ROLES_OVERRIDE")"
  for role in $(team_mode_roles "$MODE" "$CLONE"); do
    r="$(ls -1t "$TD/runs/$(run_ref)/$role"-*.json 2>/dev/null | head -n 1)" || true
    [ -z "$r" ] || echo "$role: $(basename "$r") $(rec "$r" verdict)$([ -e "$r.accepted" ] && echo ' accepted')"
    ! team_tmux_alive "$(sess_name "$role")" || dialog_label "$(sess_name "$role")"
  done
  if [ -d "$TD/lock" ]; then
    pid="$(cat "$TD/lock/pid" 2>/dev/null || true)"
    kill -0 "$pid" 2>/dev/null && echo "lock: runner $pid alive" || echo "lock: stale (pid $pid dead) — bash .claude/lib/team-run.sh $TEAM unlock"
  fi
  [ ! -f "$TD/runs/${RUN:-none}/attention" ] || echo "attention: $(tail -n 1 "$TD/runs/$RUN/attention")"
  ! team_lead_on || echo "teamlead: $(lead_status)"
}

cmd_stop() {
  local pid waited=0 role
  touch "$TD/cancel"
  # Every open ask of the run is withdrawn: the sender and the hook refuse an answer from now on.
  RUN="$(cat "$TD/run" 2>/dev/null || true)"
  [ -z "$RUN" ] || lead_withdraw_asks all "team stopped" || true
  pid="$(cat "$TD/lock/pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$STOP_WAIT" ]; do sleep 1; waited=$((waited + 1)); done
    ! kill -0 "$pid" 2>/dev/null || die 1 "runner $pid did not stop — check: $(sh_hint "$TEAM-runner")"
  fi
  # cli too: a stop also ends a cli session left behind by a mode mix-up.
  for role in $TEAM_ROLES cli; do end_session "$role"; done
  # A lead-chosen cli whose handover did not run yet still has the judge open.
  [ "$MODE" != cli ] || end_session lead
  rm -rf "$TD/lock"
  echo "stopped; session.json kept for the next run"
}

# Deliberate, supervisor-run removal of a dead runner's lock; never automatic, it would race a start.
cmd_unlock() {
  local pid age m
  refuse() { echo "$1" >&2; exit 1; }
  [ -d "$TD/lock" ] || refuse "no lock to remove"
  pid="$(cat "$TD/lock/pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || refuse "lock is not stale — no pid recorded (a runner may be starting)"
  ! kill -0 "$pid" 2>/dev/null || refuse "lock is not stale — runner $pid is alive"
  m="$(file_mtime "$TD/lock")" || refuse "lock is not stale — its age cannot be read"; age=$(( $(date +%s) - m ))
  [ "$age" -gt 10 ] || refuse "lock is not stale — created ${age}s ago"
  rm -rf "$TD/lock"
  echo "removed stale lock (pid $pid dead)"
}

# Material for later review; main checkout script, like team-roles.sh: a clone may lack it.
audit_run() {
  local final=()
  [ "$1" != 0 ] || final=(--final ready)
  [ "$1" != 8 ] || final=(--final closed)
  bash "$root/.claude/lib/team-audit.sh" "$TEAM" --runner-exit "$1" ${final[@]+"${final[@]}"} \
    || echo "warn: team audit failed (rc $?) — run outcome unchanged" >&2
}

# Only the runner whose pid is in the lock removes it — never a replacement lock of another runner.
# The lock goes first, so a slow audit never holds it.
on_exit() {
  local rc=$?
  [ "$OWN_LOCK" = 1 ] && [ "$(cat "$TD/lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$TD/lock"
  [ "$CMD" != advance ] || [ -z "$RUN" ] || audit_run "$rc" || true
  exit "$rc"
}
trap on_exit EXIT

case "$CMD" in
  advance) [ $# -le 1 ] || die 2 "error: unknown arguments"; cmd_advance ;;
  roles) shift 2; cmd_roles "$@" ;;
  status) cmd_status ;;
  summary) cmd_summary ;;
  stop) cmd_stop ;;
  unlock) cmd_unlock ;;
  check)
    [ $# -eq 3 ] || die 2 "usage: team-run.sh <team> check <record>"
    r="$3"; case "$r" in /*) ;; *) r="$ORIG_PWD/$r" ;; esac
    RUN="$(rec "$r" run)"; ROLE="$(rec "$r" role)"
    validate_record "$r" && echo "valid: $(basename "$r")" || exit 4 ;;
  *) die 2 "error: unknown command $CMD" ;;
esac
