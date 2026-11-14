#!/usr/bin/env bash
# The runner's per-run TeamLead: launch, reuse, relaunch, stop ring, poll, events, status.
# Sourced by team-run.sh from the MAIN checkout after its own setup, never executed: every function
# runs in the runner's shell and uses its globals (TEAM, RUN, MODE, TD, CLONE, root, die, rec,
# sess_name, codex_home, auto_blocker). Every caller is guarded by team_lead_on, so with the
# switch off (or mode cli) none of this runs. Bash 3.2. Contract: .agents/reference/team-lead.md

team_lead_on() { [ "${TEAM_LEAD_ENABLED:-false}" = true ] && [ "$MODE" != cli ]; }

# Seconds since the epoch; a fixture clock only under the smoke marker.
team_now() {
  if [ "${TEAM_SMOKE:-}" = 1 ] && [ -n "${TEAM_NOW_CMD:-}" ]; then eval "$TEAM_NOW_CMD"
  else date +%s; fi
}

# The clone files a per-run lead needs; an older base lacks them. Later steps extend the list.
team_lead_base_ok() {
  local f
  for f in .claude/team/prompts/teamlead.md .claude/hooks/guard-teamlead-write.sh \
    .claude/lib/team-lead.sh .claude/lib/team-lead-lib.sh .claude/lib/team-verdict.sh; do
    [ -f "$CLONE/$f" ] || { echo "no $f"; return 1; }
  done
  grep -q 'review)' "$CLONE/.claude/lib/team-record.sh" || { echo "no review verdict in team-record.sh"; return 1; }
  grep -q 'teamlead.json' "$CLONE/.claude/team/prompts/planner.md" || { echo "no TeamLead branch in planner.md"; return 1; }
}

# The prompt comes from the main checkout: a clone on an older base must not run an old lead.
render_lead_prompt() {
  local p
  p="$(cat "$root/.claude/team/prompts/teamlead.md")" || die 4 "no TeamLead prompt in $root"
  put() { local k="{{$1}}"; p="${p//"$k"/$2}"; }
  put TEAM "$TEAM"; put TICKET "$(team_json ticket)"; put BRANCH "$BRANCH"; put LINE "$LINE"
  put BASE_SHA "$(team_json base_sha)"; put RUN "$RUN"; put MODE "$MODE"
  put ORDER_BRIEF ".agents/team/runs/$RUN/order-brief.md"
  printf '%s\n' "$p" > "$1"
}

launch_lead() {
  local name pf sid n perm=auto why ch ck costs=()
  team_cancelled && cancel_exit
  name="$(sess_name lead)"
  (cd "$root" && bash .claude/lib/team-brief.sh check "$TEAM") >/dev/null \
    || die 4 "no order brief — /start-team $TEAM writes it"
  mkdir -p "$TD/runs/$RUN"
  [ -f "$TD/runs/$RUN/order-brief.md" ] || cp "$TD/order-brief.md" "$TD/runs/$RUN/order-brief.md"
  (cd "$root" && bash .claude/lib/team-lead.sh materialize "$TEAM") >/dev/null \
    || die 4 "TeamLead profile not materialised — bash .claude/lib/team-lead.sh materialize $TEAM"
  if why="$(auto_blocker)"; then echo "warn: TeamLead launches in manual mode — $why"; perm=manual; fi
  ch="$(codex_home)" || die 1 "$ch"
  sid="$(uuidgen | tr 'A-Z' 'a-z')"
  [[ "$sid" =~ ^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]] || die 1 "error: uuidgen gave no UUID"
  # pipefail: no earlier session makes ls fail, which must not end the runner.
  n="$(ls "$TD/runs/$RUN"/lead-*.session 2>/dev/null | wc -l | tr -d ' ' || true)"; n=$((n + 1))
  pf="$TD/runs/$RUN/lead-$n.prompt.md"
  ck="$(team_json cost_key)"; [ -n "$ck" ] || ck="$(team_json ticket)"
  # A relaunch must not ring the dead session's socket.
  rm -f "$TD/teamlead.reg.json"
  jq -n --arg team "$TEAM" --arg run "$RUN" --arg sid "$sid" --arg at "$(team_utc)" \
    --arg model "$TEAM_LEAD_MODEL" --arg effort "$TEAM_LEAD_EFFORT" --arg perm "$perm" \
    --arg main "$root" --argjson n "$n" \
    '{team: $team, run: $run, session_id: $sid, launched_at: $at, launch: $n, model: $model,
      effort: $effort, permission_mode: $perm, main_root: $main}' > "$TD/teamlead.json.tmp"
  mv "$TD/teamlead.json.tmp" "$TD/teamlead.json"
  # The .session/.prompt.md pair is how cost.py bind --team-run finds every lead session.
  printf '%s\n' "$sid" > "$TD/runs/$RUN/lead-$n.session"
  render_lead_prompt "$pf"
  [ -z "${AGENT_COSTS_HOME:-}" ] || costs=(-e "AGENT_COSTS_HOME=$AGENT_COSTS_HOME")
  # Per-session env as in launch(); TEAM_SESSION_ROLE also reaches the hooks before settings load.
  tmux new-session -d -s "$name" -c "$CLONE" -e "TEAM_RUN_TEAM=$TEAM" -e "TEAM_RUN_ROLE=lead" \
    -e "TEAM_RUN_ID=$RUN" -e "TEAM_SESSION_ROLE=TeamLead" -e "CODEX_HOME=$ch" \
    ${CLAUDE_CONFIG_DIR:+-e "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"} ${costs[@]+"${costs[@]}"} \
    "claude --session-id $sid -n $name --settings '$TD/teamlead.settings.json' --model '$TEAM_LEAD_MODEL' --effort '$TEAM_LEAD_EFFORT' --permission-mode '$perm' --disallowedTools AskUserQuestion -- \"\$(cat '$pf')\""
  bash "$root/.claude/lib/costs/runtime-mark.sh" session --provider claude --session "$sid" \
    --source team-run --name "$name" --ticket "$ck" --team "$TEAM" \
    --role lead --run "$RUN" --attempt "$n" --cwd "$CLONE" 2>/dev/null \
    || echo "warn: token-usage registration skipped"
  rm -f "$TD/lead-dead"
  echo "launched: TeamLead ($TEAM_LEAD_MODEL/$TEAM_LEAD_EFFORT) — tmux attach -t $name"
}

# Before the first stage of a run, and on every resume: reuse this run's live lead, else launch.
lead_start() {
  local why
  team_lead_on || return 0
  why="$(team_lead_base_ok)" \
    || die 4 "clone base lacks the per-run TeamLead ($why) — team-next onto a current line"
  if [ "$(team_lead_json run)" = "$RUN" ] && team_tmux_alive "$(sess_name lead)"; then
    echo "TeamLead reused: $(sess_name lead)"; return 0
  fi
  launch_lead
}

lead_event() {  # lead_event <event> <ref> [<body line>] — one Supervisor event; the file is the truth
  bash "$root/.claude/lib/team-inbox.sh" --main "$root" write Supervisor "$1" --from "$TEAM" \
    --ticket "$(team_json ticket)" --run "$RUN" --ref "$2" ${3:+--message "$3"} >/dev/null \
    || echo "warn: Supervisor event $1 not written" >&2
}

lead_stop() {  # lead_stop <record> — a stage's blocked/failed record: ack it once, ring the lead
  basename "$1" > "$TD/acked"
  team_session_doorbell "$TD" lead "stop $(rec "$1" role) $(rec "$1" attempt): ${1#"$CLONE"/} — $(rec "$1" message)"
}

# lead_waiting <role> <attempt> — true while this attempt's acked stop has no <record>.answered
# marker (team-answer.sh writes it). Derived from files, so a resumed runner sees it too.
lead_waiting() {
  local a r
  a="$(cat "$TD/acked" 2>/dev/null)" || return 1
  case "$a" in "$1-$2-"*) ;; *) return 1 ;; esac
  r="$TD/runs/$RUN/$a"
  [ -f "$r" ] && [ ! -e "$r.answered" ] || return 1
  case "$(rec "$r" verdict)" in blocked|failed) return 0 ;; *) return 1 ;; esac
}

# Every wait_loop poll with the lead on: a dead lead is reported once, a requested relaunch
# happens, a new file in the team's inbox rings the lead once.
lead_poll() {
  local f m
  if [ -f "$TD/relaunch-lead" ]; then
    rm -f "$TD/relaunch-lead" "$TD/lead-dead"
    launch_lead
    team_session_doorbell "$TD" lead "relaunched: reconcile from files"
  elif ! team_tmux_alive "$(sess_name lead)" && [ ! -e "$TD/lead-dead" ]; then
    lead_event session_dead .agents/team/teamlead.json
    touch "$TD/lead-dead"
    echo "TeamLead died — /start-team $TEAM relaunches it"
  fi
  for f in "$root/.agents/team/inbox/$TEAM/new"/*; do
    [ -f "$f" ] || continue
    m="$TD/inbox-rung/$(basename "$f")"
    [ ! -e "$m" ] || continue
    mkdir -p "$TD/inbox-rung" && touch "$m"
    team_session_doorbell "$TD" lead "inbox: $(basename "$f")"
  done
}

lead_status() {  # → alive|dead|none — session <sid> — pending <n>
  local s=none sid=none n
  if [ -n "${RUN:-}" ] && [ "$(team_lead_json run)" = "$RUN" ]; then
    sid="$(team_lead_json session_id)"; s=dead
    ! team_tmux_alive "$(sess_name lead)" || s=alive
  fi
  n="$( (cd "$root" && bash .claude/lib/team-lead.sh pending "$TEAM") 2>/dev/null | grep -c . || true)"
  echo "$s — session $sid — pending ${n:-0}"
}

# ---- gates (spec, plan) -----------------------------------------------------------------------

lead_gate_ring() {  # lead_gate_ring <gate> <record> — ack the gate's input record, ring the lead
  basename "$2" > "$TD/acked"
  team_session_doorbell "$TD" lead "gate $1: ${2#"$CLONE"/}"
  echo "waiting for TeamLead: gate $1 $(basename "$2")"
}

# lead_say <one line> → 0 delivered to the planner, 1 skipped (the doorbell logged why). A skipped
# message leaves its verdict unacted, so the next poll retries it.
lead_say() {
  local log="$TD/send-planner.log" n=0 m=0
  [ ! -f "$log" ] || n="$(wc -l < "$log" | tr -d ' ')"
  team_session_doorbell "$TD" planner "$1"
  [ ! -f "$log" ] || m="$(wc -l < "$log" | tr -d ' ')"
  [ "$m" = "$n" ]
}

# lead_gate <role> <attempt> — act once on each TeamLead verdict for the acked gate record, in seq
# order; $TD/verdict-acked lists the verdicts already acted on. → 0 when a plan approve accepted
# the planner record; 1 keep waiting (escalate, revise, a message to retry, no verdict yet).
lead_gate() {
  local a f v rel
  a="$(cat "$TD/acked" 2>/dev/null)" || return 1
  case "$a" in "$1-$2-"*) ;; *) return 1 ;; esac
  for f in $(ls "$TD/runs/$RUN" | grep -E '^teamlead-(spec|plan)-[0-9]+\.json$' | sort -t- -k3,3n || true); do
    [ "$(rec "$TD/runs/$RUN/$f" for)" = "$a" ] || continue
    ! grep -qxF "$f" "$TD/verdict-acked" 2>/dev/null || continue
    rel=".agents/team/runs/$RUN/$f"; v="$(rec "$TD/runs/$RUN/$f" gate) $(rec "$TD/runs/$RUN/$f" verdict)"
    case "$v" in
      "spec approve") lead_say "[team-run] TeamLead approved the spec ($rel). Set **Status:** Approved (TeamLead, $(date +%Y-%m-%d)), commit, and continue with /plan-feature." || return 1 ;;
      "spec revise") lead_say "[team-run] TeamLead: revise the spec — findings in $(rec "$TD/runs/$RUN/$f" ref). Commit, then record review again." || return 1 ;;
      "plan revise") lead_say "[team-run] TeamLead: amend the plan — findings in $(rec "$TD/runs/$RUN/$f" ref). Commit, then record done again." || return 1 ;;
      "plan remode") echo "$f" >> "$TD/verdict-acked"; close_run remode "$rel" ;;
      # Acked only once accepted: a rejected record dies unacked, so a re-run validates it again.
      "plan approve")
        validate_record "$TD/runs/$RUN/$a" \
          || die 4 "record $a rejected — session left alive: tmux attach -t $(sess_name "$ROLE")"
        accept "$TD/runs/$RUN/$a"; echo "$f" >> "$TD/verdict-acked"; return 0 ;;
    esac
    echo "$f" >> "$TD/verdict-acked"
  done
  return 1
}

# close_run <reason> <ref> — end the run without a merge. closed.json goes first, so a resume
# refuses the run even when a later step fails; then the Supervisor event, the lead, the stage.
close_run() {
  local r pr="" next
  r="$(accepted_record coder)"; [ -z "$r" ] || pr="$(rec "$r" pr_id)"
  jq -n --arg reason "$1" --arg ref "$2" --arg at "$(team_utc)" --arg pr "$pr" \
    '{reason: $reason, ref: $ref, closed_at: $at,
      pr_id: (if $pr == "" then null else ($pr | tonumber) end)}' > "$TD/runs/$RUN/closed.json"
  if [ -n "$pr" ]; then next="PR $pr to abandon before team-next"; else next="clone free"; fi
  lead_event closed "$2" "reason: $1 — $next"
  (cd "$root" && bash .claude/lib/team-lead.sh end "$TEAM") >/dev/null \
    || echo "warn: TeamLead of $TEAM did not end" >&2
  end_session "$ROLE"
  rm -f "$TD/session.json"
  echo "closed: $1 — $next"
  exit 8
}
