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
    .claude/lib/team-lead.sh .claude/lib/team-lead-lib.sh; do
    [ -f "$CLONE/$f" ] || { echo "no $f"; return 1; }
  done
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

lead_event() {  # lead_event <event> <ref> — one Supervisor event; the file is the truth
  bash "$root/.claude/lib/team-inbox.sh" --main "$root" write Supervisor "$1" --from "$TEAM" \
    --ticket "$(team_json ticket)" --run "$RUN" --ref "$2" >/dev/null \
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
