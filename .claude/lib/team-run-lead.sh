#!/usr/bin/env bash
# The runner's per-run TeamLead: launch, reuse, relaunch, stop ring, poll, events, status, and the
# rework rounds with the runner's round-aware record lookups.
# Sourced by team-run.sh from the MAIN checkout after its own setup, never executed: every function
# runs in the runner's shell and uses its globals (TEAM, RUN, MODE, TD, CLONE, root, die, rec,
# sess_name, codex_home, auto_blocker). Every lead caller is guarded by team_lead_on, so with the
# switch off (or mode cli) only the record lookups run, always in round 1. Bash 3.2.
# Contract: .agents/reference/team-lead.md

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
    .claude/lib/team-lead.sh .claude/lib/team-lead-lib.sh .claude/lib/team-verdict.sh \
    .claude/hooks/lib/memory-domain.sh .claude/lib/team-lead-decision.sh \
    .claude/hooks/guard-teamlead-bash.sh; do
    [ -f "$CLONE/$f" ] || { echo "no $f"; return 1; }
  done
  grep -q 'review)' "$CLONE/.claude/lib/team-record.sh" || { echo "no review verdict in team-record.sh"; return 1; }
  grep -q 'teamlead.json' "$CLONE/.claude/team/prompts/planner.md" || { echo "no TeamLead branch in planner.md"; return 1; }
  grep -q '{{REWORK}}' "$CLONE/.claude/team/prompts/coder.md" || { echo "no rework round in coder.md"; return 1; }
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
  local name pf sid n perm=auto why ch cc ck costs=()
  team_cancelled && cancel_exit
  name="$(sess_name lead)"
  (cd "$root" && bash .claude/lib/team-brief.sh check "$TEAM") >/dev/null \
    || die 4 "no order brief — /start-team $TEAM writes it"
  mkdir -p "$TD/runs/$RUN"
  [ -f "$TD/runs/$RUN/order-brief.md" ] || cp "$TD/order-brief.md" "$TD/runs/$RUN/order-brief.md"
  (cd "$root" && bash .claude/lib/team-lead.sh materialize "$TEAM") >/dev/null \
    || die 4 "TeamLead profile not materialised — bash .claude/lib/team-lead.sh materialize $TEAM"
  (cd "$root" && bash .claude/lib/team-lead.sh notes-init "$TEAM") >/dev/null \
    || echo "warn: TeamLead notes not created — bash .claude/lib/team-lead.sh notes-init $TEAM"
  if why="$(auto_blocker)"; then echo "warn: TeamLead launches in manual mode — $why"; perm=manual; fi
  ch="$(codex_home)" || die 1 "$ch"
  # The project's Claude profile, as launch() takes it (team_claude_home, team-profile.sh).
  cc="$(team_claude_home "$root")" || die 1 "$cc"
  sid="$(uuidgen | tr 'A-Z' 'a-z')"
  [[ "$sid" =~ ^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]] || die 1 "error: uuidgen gave no UUID"
  # pipefail: no earlier session makes ls fail, which must not end the runner.
  n="$(ls "$TD/runs/$RUN"/lead-*.session 2>/dev/null | wc -l | tr -d ' ' || true)"; n=$((n + 1))
  pf="$TD/runs/$RUN/lead-$n.prompt.md"
  ck="$(team_json cost_key)"; [ -n "$ck" ] || ck="$(team_json ticket)"
  # A relaunch must not ring the dead session's socket.
  rm -f "$(sh_reg_dir "$root")/$(sess_name lead).reg.json"
  jq -n --arg team "$TEAM" --arg run "$RUN" --arg sid "$sid" --arg at "$(team_utc)" \
    --arg model "$TEAM_LEAD_MODEL" --arg effort "$TEAM_LEAD_EFFORT" --arg perm "$perm" \
    --arg main "$root" --argjson n "$n" --arg cc "$cc" \
    '{team: $team, run: $run, session_id: $sid, launched_at: $at, launch: $n, model: $model,
      effort: $effort, permission_mode: $perm, main_root: $main, claude_config_dir: $cc}' > "$TD/teamlead.json.tmp"
  mv "$TD/teamlead.json.tmp" "$TD/teamlead.json"
  # The .session/.prompt.md pair is how cost.py bind --team-run finds every lead session.
  printf '%s\n' "$sid" > "$TD/runs/$RUN/lead-$n.session"
  render_lead_prompt "$pf"
  [ -z "${AGENT_COSTS_HOME:-}" ] || costs=(--env "AGENT_COSTS_HOME=$AGENT_COSTS_HOME")
  # Per-session env as in launch(); TEAM_SESSION_ROLE also reaches the hooks before settings load.
  sh_start "$name" --kind team --cwd "$CLONE" --cli claude --no-probe --env "TEAM_RUN_TEAM=$TEAM" --env "TEAM_RUN_ROLE=lead" \
    --env "TEAM_RUN_ID=$RUN" --env "TEAM_SESSION_ROLE=TeamLead" --env "CODEX_HOME=$ch" \
    ${cc:+--env "CLAUDE_CONFIG_DIR=$cc"} ${costs[@]+"${costs[@]}"} \
    -- "claude --session-id $sid -n $name --settings '$TD/teamlead.settings.json' --model '$TEAM_LEAD_MODEL' --effort '$TEAM_LEAD_EFFORT' --permission-mode '$perm' --disallowedTools AskUserQuestion -- \"\$(cat '$pf')\"" >/dev/null
  bash "$root/.claude/lib/costs/runtime-mark.sh" session --provider claude --session "$sid" \
    --source team-run --name "$name" --ticket "$ck" --team "$TEAM" \
    --role lead --run "$RUN" --attempt "$n" --cwd "$CLONE" 2>/dev/null \
    || echo "warn: token-usage registration skipped"
  rm -f "$TD/lead-dead"
  echo "launched: TeamLead ($TEAM_LEAD_MODEL/$TEAM_LEAD_EFFORT) — $(sh_hint "$name")"
  # Herdr: the lead's terminal into its team's tab, left (a failure only warns; tmux: nothing).
  [ "$(sh_record_get "$root" "$name" backend)" != herdr ] \
    || (cd "$root" && bash .claude/lib/roles.sh place "$name") 2>&1 | grep '^warn: ' || true
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
  ack_name "$1" > "$TD/acked"
  team_session_doorbell "$TD" lead "stop $(rec "$1" role) $(rec "$1" attempt): ${1#"$CLONE"/} — $(rec "$1" message)"
}

# lead_waiting <role> <attempt> — true while this attempt's acked stop or gate input has no
# <record>.answered marker (team-answer.sh writes it for a stop). Derived from files, so a resumed
# runner sees it too.
lead_waiting() {
  local a r
  # A human-only prompt waits on the Operator in the stage window: the clock stops until the runner
  # closes its decision (lead_window).
  ! lead_window_pending "$1" "$2" || return 0
  a="$(cat "$TD/acked" 2>/dev/null)" || return 1
  case "$a" in "$(rp)$1-$2-"*) ;; *) return 1 ;; esac
  r="$TD/runs/$RUN/$a"
  [ -f "$r" ] && [ ! -e "$r.answered" ] || return 1
  # A gate input (review, done) waits on the lead as a stop does; the gate ends with the record accepted.
  case "$(rec "$r" verdict)" in blocked|failed|review|done) return 0 ;; *) return 1 ;; esac
}

# Every wait_loop poll with the lead on: a dead lead is reported once, a requested relaunch
# happens. An inbox file rings the lead from team-inbox.sh write itself (the driver's send).
lead_poll() {
  if [ -f "$TD/relaunch-lead" ]; then
    rm -f "$TD/relaunch-lead" "$TD/lead-dead"
    launch_lead
    team_session_doorbell "$TD" lead "relaunched: reconcile from files"
  elif ! team_tmux_alive "$(sess_name lead)" && [ ! -e "$TD/lead-dead" ]; then
    lead_event session_dead .agents/team/teamlead.json
    touch "$TD/lead-dead"
    echo "TeamLead died — /start-team $TEAM relaunches it"
  fi
  lead_window
  lead_notify
}

# A verdict with notify (human_decision, abandon_decision) reaches the Operator once, through
# notify.sh, the only path to the Operator. Its write-once event file (id <project>:<team>:<run>:<d-n>)
# is the dedup, so a retry is safe: a failed call is retried on the next tick, three tries per verdict
# per runner process, then one warn:. LEAD_NOTIFIED holds the verdicts done; LEAD_NOTIFY_FAILS one
# entry per failed try. The decision stays pending either way.
LEAD_NOTIFIED=" " LEAD_NOTIFY_FAILS=" "
lead_notify() {
  local f d ev id q rc p h w k n
  for f in "$TD/runs/$RUN"/teamlead-*-*.json; do
    [ -f "$f" ] || continue
    ev="$(rec "$f" notify)"; [ -n "$ev" ] || continue
    k="$RUN/$(basename "$f")"; case "$LEAD_NOTIFIED" in *" $k "*) continue ;; esac
    d="$(rec "$f" ref)"; id=""; q=""
    if [ -f "$d" ]; then id="$(sed -n 's/^id: //p' "$d" | head -n 1)"; q="$(sed -n '/^## Question$/{n;p;q;}' "$d")"; fi
    team_channel_names "$root" 2>/dev/null || unset TEAM_CHANNEL_TMUX_PREFIX  # only for the prefix; a broken channel block → the dir slug
    w="lead"; [ ! -f "$d" ] || w="$(lfm "$d" answer_in)"; w="${w:-lead}"  # human-only: the stage window
    h="$(sh_hint "$(sess_name "$w")" 2>/dev/null)" \
      || h="no $(sess_name "$w") session found — bash .claude/lib/session-host.sh status $(sess_name "$w")"  # no host: say so, never kill the runner
    p="${TEAM_CHANNEL_TMUX_PREFIX:-$(basename "$root" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-\n' '-')}"
    rc=0; bash "$root/.claude/lib/notify.sh" "$ev" --project "$p" --team "$TEAM" \
      --ticket "$(team_json ticket)" --run "$RUN" --decision "${id:-$(basename "$f" .json)}" \
      --summary "${q:-$(rec "$f" message)}" --answer "$(sess_name "$w")" \
      --hint "$h" --ref "$d" --source runner --main "$root" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then LEAD_NOTIFIED="$LEAD_NOTIFIED$k "; continue; fi
    LEAD_NOTIFY_FAILS="$LEAD_NOTIFY_FAILS$k "
    n="$(printf '%s' "$LEAD_NOTIFY_FAILS" | tr ' ' '\n' | grep -cxF "$k")" || n=0
    [ "$n" -ge 3 ] || continue
    echo "warn: notify.sh failed 3× for $(basename "$f") (exit $rc) — the decision waits in $(sess_name "$w")"
    LEAD_NOTIFIED="$LEAD_NOTIFIED$k "
  done
}

# lead_attention <role> <line> — a new attention line with the lead on. A permission prompt is tried
# at authority class first, so a deterministic class answers without waking the lead; a human-only
# refusal (9) becomes a request runs/<run>/decisions/req-<n>.json the lead opens a decision from;
# otherwise the lead is rung with the prompt's tool and command, read from the transcript-bound
# parse (never from the screen alone; unreadable → said so).
lead_attention() {
  local role="$1" line kind name t p tool cmd rc=0 n d ev gen
  line="$(sed -n "${2}p" "$TD/runs/$RUN/attention" 2>/dev/null)"; kind="$(cut -d' ' -f2 <<<"$line")"
  name="$(sess_name "$role")"
  if [ "$kind" = idle_prompt ]; then
    team_session_doorbell "$TD" lead "prompt $role: idle — look at the screen; nothing is owed unless it is stuck — $(cut -d' ' -f3- <<<"$line")"
    return 0
  fi
  if [ "$kind" != permission_prompt ]; then
    team_session_doorbell "$TD" lead "prompt $role: ${kind:-attention} — $(cut -d' ' -f3- <<<"$line")"
    return 0
  fi
  bash "$root/.claude/lib/team-answer.sh" "$TEAM" "$role" yes --authority class \
    --why "deterministic class" --clone "$CLONE" --root "$root" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then echo "answered at authority class: $role prompt"; return 0; fi
  t="$(team_role_transcript "$CLONE" "$(session_json session_id)" "$(session_json claude_config_dir)")"
  p="$(team_pane_history "$name" 200 \
    | python3 -I "$root/.claude/lib/team_prompt.py" parse --transcript "${t:--}" 2>/dev/null)" || p='{}'
  if ! jq -e '.kind == "permission" and .complete' <<<"$p" >/dev/null 2>&1; then
    team_session_doorbell "$TD" lead "prompt $role: unreadable — $(sh_hint "$name")"; return 0
  fi
  tool="$(jq -r '.header // "?"' <<<"$p")"
  cmd="$(jq -r '.command // ""' <<<"$p" | tr '\n' ' ' | sed 's/[[:space:]]*$//' | cut -c1-200)"
  if [ "$rc" != 9 ]; then
    team_session_doorbell "$TD" lead \
      "prompt $role: $tool $cmd — team-answer.sh $TEAM $role yes|no --authority teamlead --why …"
    return 0
  fi
  d="$TD/runs/$RUN/decisions"; mkdir -p "$d"
  n="$(ls "$d" | sed -n 's/^req-\([0-9]*\)\.json$/\1/p' | sort -n | tail -n 1)"; n=$(( ${n:-0} + 1 ))
  ev="$(printf '%s' "$p" | python3 -I "$root/.claude/lib/team_prompt.py" event "$t" permission 2>/dev/null)" || ev=-
  gen="$(team_pane_gen "$name")" || gen=-
  jq -n --arg src "attention:$2" --arg role "$role" --arg tool "$tool" --arg cmd "$cmd" \
    --arg sid "$(session_json session_id)" --arg run "$RUN" --arg att "$(session_json attempt)" \
    --arg fp "$(jq -r '.fp // ""' <<<"$p")" --arg ev "$ev" --arg pane "$gen" --arg at "$(team_utc)" \
    '{source: $src, role: $role, tool: $tool, command: $cmd, written_at: $at,
      binding: {session_id: $sid, run: $run, attempt: $att, fp: $fp, event: $ev, pane: $pane}}' \
    > "$d/.req-$n.json.tmp"
  mv "$d/.req-$n.json.tmp" "$d/req-$n.json"
  team_session_doorbell "$TD" lead "human-only $role: $tool $cmd — open a decision for req-$n"
}

lfm() { sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^$2: *//p" | head -n 1; }
lfm_set() {  # lfm_set <file> <key> <value> — replace or add one frontmatter key, atomically
  awk -v k="$2" -v v="$3" '/^---$/ { n++; if (n == 2 && !done) print k ": " v; print; next }
    n == 1 && index($0, k ": ") == 1 { print k ": " v; done = 1; next } { print }' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

# lead_window_pending <role> <attempt> — a pending human-only decision (answer_in) of that attempt.
lead_window_pending() {
  local f
  for f in "$TD/runs/$RUN"/decisions/d-*.md; do
    [ -f "$f" ] && [ "$(lfm "$f" status)" = pending ] && [ "$(lfm "$f" answer_in)" = "$1" ] \
      && [ "$(lfm "$f" bind_attempt)" = "$2" ] && return 0
  done
  return 1
}

# lead_window — every poll: only the runner closes a human-only prompt's decision (answer_in), from
# the stage's own transcript. The Operator's answer in the stage window resolves it (approved,
# approved (rule added), rejected); a prompt that is no longer open, or whose stage session or
# attempt was replaced, withdraws it (prompt gone). The lead can neither answer nor withdraw it.
lead_window() {
  local f role id sid att t out q did
  for f in "$TD/runs/$RUN"/decisions/d-*.md; do
    [ -f "$f" ] && [ "$(lfm "$f" status)" = pending ] || continue
    role="$(lfm "$f" answer_in)"; [ -n "$role" ] || continue
    id="$(lfm "$f" bind_event)"; sid="$(lfm "$f" bind_session_id)"; att="$(lfm "$f" bind_attempt)"
    did="$(lfm "$f" id)"; out=pending
    if [ -n "$id" ] && [ "$id" != - ] && [ "$id" != ambiguous ]; then
      t="$(team_role_transcript "$CLONE" "${sid:--}" "$(session_json claude_config_dir)")"
      out="$(python3 -I "$root/.claude/lib/team_prompt.py" outcome "${t:--}" "$id" 2>/dev/null)" || out=unknown
    else
      # Unbound prompt: no outcome to read; once the stage has no open call, the prompt is gone
      # (otherwise this decision, which nobody else may close, would stop the clock for the attempt).
      t="$(team_role_transcript "$CLONE" "${sid:--}" "$(session_json claude_config_dir)")"
      [ "$(python3 -I "$root/.claude/lib/team_prompt.py" pending-tool "${t:--}" 2>/dev/null)" != "{}" ] \
        || out=gone
    fi
    # An open prompt whose session or attempt is no longer the stage's can never be answered.
    if [ "$out" = pending ] || [ "$out" = unknown ]; then
      [ "$sid" = "$(session_json session_id)" ] && [ "$att" = "$(session_json attempt)" ] || out=gone
    fi
    case "$out" in pending|unknown|"") continue ;; esac
    if [ "$out" = gone ]; then
      lfm_set "$f" status withdrawn; lfm_set "$f" withdrawn_at "$(team_utc)"
      printf '\n## Withdrawn\nprompt gone (the runner)\n' >> "$f"
      team_session_doorbell "$TD" lead "human-only $role: $did withdrawn — prompt gone"
      lead_resolve "$did"; continue
    fi
    lfm_set "$f" status resolved; lfm_set "$f" answered_at "$(team_utc)"
    lfm_set "$f" answered_via "stage-window $id"; lfm_set "$f" answer_outcome "$out"
    printf '\n## Answer\n%s — by the Operator in the %s window\n' "$out" "$role" >> "$f"
    q="$(sed -n '/^## Question$/{n;p;q;}' "$f")"
    printf -- '- %s [%s %s] %s → %s — Operator in the stage window [authority operator-window] [decision %s]\n' \
      "$(team_utc)" "$role" "$att" "$q" "$out" "$did" >> "$TD/runs/$RUN/answers.md"
    team_session_doorbell "$TD" lead "human-only $role: $did answered in the stage window — $out"
    lead_resolve "$did"
  done
}

# lead_resolve <d-n> — the Operator's notification of that decision is answered or moot: no more
# delivery, the Herdr strip drops it (#97). A failed resolve never stops the runner.
lead_resolve() {
  bash "$root/.claude/lib/notify.sh" resolve --team "$TEAM" --run "$RUN" --decision "$1" >/dev/null 2>&1 || true
}

lead_status() {  # → alive|waiting at <dialog> …|dead|none — session <sid> — pending <n>
  local s=none sid=none n
  if [ -n "${RUN:-}" ] && [ "$(team_lead_json run)" = "$RUN" ]; then
    sid="$(team_lead_json session_id)"; s=dead
    ! team_tmux_alive "$(sess_name lead)" || s="$(dialog_word "$(sess_name lead)")"
  fi
  n="$( (cd "$root" && bash .claude/lib/team-lead.sh pending "$TEAM") 2>/dev/null | grep -c . || true)"
  echo "$s — session $sid — pending ${n:-0}"
}

# ---- gates (spec, plan) -----------------------------------------------------------------------

lead_gate_ring() {  # lead_gate_ring <gate> <record> — ack the gate's input record, ring the lead
  ack_name "$2" > "$TD/acked"
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
# order; $TD/verdict-acked lists the verdicts already acted on. → 0 when a verdict accepted the
# record or opened a rework round; 1 keep waiting (escalate, revise, a message to retry, no verdict).
lead_gate() {
  local a f v rel
  a="$(cat "$TD/acked" 2>/dev/null)" || return 1
  case "$a" in "$(rp)$1-$2-"*) ;; *) return 1 ;; esac
  for f in $(ls "$TD/runs/$RUN" | grep -E '^teamlead-(spec|plan|acceptance|decision)-[0-9]+\.json$' \
      | sort -t- -k3,3n || true); do
    [ "$(rec "$TD/runs/$RUN/$f" for)" = "$a" ] || continue
    ! grep -qxF "$f" "$TD/verdict-acked" 2>/dev/null || continue
    rel=".agents/team/runs/$RUN/$f"; v="$(rec "$TD/runs/$RUN/$f" gate) $(rec "$TD/runs/$RUN/$f" verdict)"
    case "$v" in
      "spec approve") lead_say "[team-run] TeamLead approved the spec ($rel). Set **Status:** Approved (TeamLead, $(date +%Y-%m-%d)), commit, and continue with /plan-feature." || return 1 ;;
      "spec revise") lead_say "[team-run] TeamLead: revise the spec — findings in $(rec "$TD/runs/$RUN/$f" ref). Commit, then record review again." || return 1 ;;
      "plan revise") lead_say "[team-run] TeamLead: amend the plan — findings in $(rec "$TD/runs/$RUN/$f" ref). Commit, then record done again." || return 1 ;;
      "plan remode") echo "$f" >> "$TD/verdict-acked"; close_run remode "$rel" ;;
      # Rejected: the approve is spent; the planner is sent the reason (reject_record) and rings
      # the gate again with its next done.
      "plan approve")
        validate_record "$TD/runs/$RUN/$a" \
          || { echo "$f" >> "$TD/verdict-acked"; reject_record "$TD/runs/$RUN/$a" || true; return 1; }
        accept "$TD/runs/$RUN/$a"; echo "$f" >> "$TD/verdict-acked"; return 0 ;;
      # The qa done was validated when the gate was rung; accept it, the wrapup follows.
      "acceptance accept") accept "$TD/runs/$RUN/$a"; echo "$f" >> "$TD/verdict-acked"; return 0 ;;
      # The transition clears verdict-acked; round n+1's acked names never match round n's verdicts.
      "acceptance rework") round_next "$f" || return 1; return 0 ;;
      # abandon-recommended waits for the Operator's decision: close or continue on the same record.
      # close ends the run at whichever gate record it names (team-lead.md §7), not only acceptance.
      "decision close") echo "$f" >> "$TD/verdict-acked"; close_run abandon "$rel" ;;
      # continue opens a round only at the qa's records (§9); elsewhere it changes nothing here.
      "decision continue") [ "$1" != qa ] || team_session_doorbell "$TD" lead "continue granted ($rel) — order the rework: team-verdict.sh acceptance rework --for $a --ref .agents/team/runs/$RUN/rework-$(( $(cur_round) + 1 )).md" ;;
    esac
    echo "$f" >> "$TD/verdict-acked"
  done
  return 1
}

# lead_accepted — the run is ready after the lead's accept and a done wrapup: one `accepted` event
# to the Supervisor, guarded by runs/<run>/accepted.sent (a resume re-enters cmd_advance). Only when
# an `acceptance accept` verdict names the accepted qa record: a lead switched on after the qa was
# accepted wrote no brief, and the event must not point at one.
lead_accepted() {
  local qa f v=""
  [ ! -e "$TD/runs/$RUN/accepted.sent" ] || return 0
  qa="$(accepted_record qa)"
  for f in $(ls "$TD/runs/$RUN" | grep -E '^teamlead-acceptance-[0-9]+\.json$' || true); do
    if [ -n "$qa" ] && [ "$(rec "$TD/runs/$RUN/$f" verdict)" = accept ] \
      && [ "$(rec "$TD/runs/$RUN/$f" for)" = "$(ack_name "$qa")" ]; then v="$f"; fi
  done
  [ -n "$v" ] || { echo "accepted event skipped: no acceptance accept verdict names the accepted qa record"; return 0; }
  lead_event accepted "runs/$(run_ref)/acceptance-brief.md"
  team_utc > "$TD/runs/$RUN/accepted.sent"
}

# close_run <reason> <ref> — end the run without a merge. closed.json goes first, so a resume
# refuses the run even when a later step fails; then the Supervisor event, the lead, the stage.
close_run() {
  local r pr="" next
  r="$(team_accepted_record "$RUN" coder)"; [ -z "$r" ] || pr="$(rec "$r" pr_id)"
  jq -n --arg reason "$1" --arg ref "$2" --arg at "$(team_utc)" --arg pr "$pr" \
    '{reason: $reason, ref: $ref, closed_at: $at,
      pr_id: (if $pr == "" then null else ($pr | tonumber) end)}' > "$TD/runs/$RUN/closed.json"
  if [ -n "$pr" ]; then next="PR $pr to abandon before team-next"; else next="clone free"; fi
  lead_event closed "$2" "reason: $1 — $next"
  # The run's notes go to the shared log before the lead ends; a log failure never blocks the close.
  (cd "$root" && bash .claude/lib/team-lead.sh log-append "$TEAM" closed) >/dev/null \
    || echo "warn: teamlead log not appended — bash .claude/lib/team-lead.sh log-append $TEAM closed" >&2
  (cd "$root" && bash .claude/lib/team-lead.sh end "$TEAM") >/dev/null \
    || echo "warn: TeamLead of $TEAM did not end" >&2
  bash "$root/.claude/lib/team-inbox.sh" --main "$root" close-run "$TEAM" "$RUN" >/dev/null 2>&1 || true  # its inbox → done/
  end_session "$ROLE"
  rm -f "$TD/session.json"
  echo "closed: $1 — $next"
  exit 8
}

# ---- rework rounds (team-lead.md §9) ----------------------------------------------------------
# $TD/round = {run, round, verdict, pr_published}: the durable round and the acceptance rework verdict
# that opened it. A round whose run differs from $RUN reads as round 1 (team_run_ref). The runner's
# record lookups live here too: round n ≥ 2 keeps its records in runs/<run>/r<n>/, the planner's
# stay in round 1. They run with the switch off as well (always round 1 then).

run_ref() { team_run_ref "$TD" "$RUN"; }
accepted_record() { if [ "$1" = planner ]; then team_accepted_record "$RUN" planner; else team_accepted_record "$(run_ref)" "$1"; fi; }

# new_record <role> <attempt> → the attempt's newest record of this round not yet acked, or empty.
new_record() {
  local role="$1" attempt="$2" last ackseq=0 acked=""
  [ -f "$TD/acked" ] && acked="$(cat "$TD/acked")"
  case "$acked" in "$(rp)$role-$attempt-"*) ackseq="${acked#"$(rp)$role-$attempt-"}"; ackseq="${ackseq%.json}" ;; esac
  last="$(team_records "$(run_ref)" "$role" "$attempt" | tail -n 1)"
  [ -n "$last" ] || return 0
  [ "$(rec "$last" seq)" -gt "$ackseq" ] && echo "$last" || true
}

cur_round() { local r; r="$(run_ref)"; case "$r" in */r*) echo "${r##*/r}" ;; *) echo 1 ;; esac; }
rp() { [ "$(cur_round)" = 1 ] || echo "r$(cur_round)/"; }      # the acked-name prefix of this round
ack_name() { echo "${1#"$TD/runs/$RUN/"}"; }                    # a record relative to runs/<run>/
round_field() { jq -r --arg r "$RUN" --arg k "$1" 'select(.run == $r) | .[$k] // empty | tostring' "$TD/round" 2>/dev/null || true; }
# The coder of round n starts from the qa revision the rework verdict of round n-1 was written for.
round_input_rev() { rec "$TD/runs/$RUN/$(rec "$TD/runs/$RUN/$(round_field verdict)" for)" output_rev; }
round_rework() { if [ "$(cur_round)" = 1 ]; then echo none; else rec "$TD/runs/$RUN/$(round_field verdict)" ref; fi; }

# true|false on stdout — whether round 1's PR is published, read live from the provider.
round_pr_published() {
  local pr j
  pr="$(rec "$(team_accepted_record "$RUN" coder)" pr_id)"; [ -n "$pr" ] || return 1
  case "$TEAM_PR_PROVIDER" in
    github) j="$(bash "$root/.claude/lib/team-pr.sh" state "$pr")" || return 1; jq -r '.draft | not' <<<"$j" ;;
    *) team_ado_coords || return 1; j="$(team_pr_json "$pr")" || return 1; jq -r '.isDraft | not' <<<"$j" ;;
  esac
}

# A fixture crash point (smoke only): the runner dies as if killed, leaving the files as they are.
round_crash() { [ "${TEAM_SMOKE:-}" != 1 ] || [ "${TEAM_ROUND_CRASH:-}" != "$1" ] || kill -9 $$; }

# round_next <verdict> — an acceptance rework of round n: the durable intent round-transition first,
# then round_finish. → 1 (keep waiting, retried next poll) when the rework file or the PR state is
# missing.
round_next() {
  local v="$1" n ref pub
  n="$(cur_round)"; ref="$(rec "$TD/runs/$RUN/$v" ref)"
  [ -f "$CLONE/$ref" ] || { echo "rework $v: $ref missing — waiting"; return 1; }
  pub="$(round_pr_published)" || { echo "rework $v: PR state unreadable — retrying"; return 1; }
  jq -n --arg run "$RUN" --argjson from "$n" --argjson to $((n + 1)) --arg v "$v" --argjson pub "$pub" \
    '{run: $run, from: $from, to: $to, verdict: $v, pr_published: $pub}' > "$TD/round-transition.tmp"
  mv "$TD/round-transition.tmp" "$TD/round-transition"
  round_crash 3
  round_finish
}

# Completes a round-transition from its first undone step; every step is idempotent, so a crash at
# any point is finished by round_reconcile on the next start.
round_finish() {
  local t="$TD/round-transition" to
  to="$(jq -r .to "$t")"
  [ ! -f "$TD/session.json" ] || end_session "$(session_json role)"
  mkdir -p "$TD/runs/$RUN/r$to"; rm -f "$TD/session.json" "$TD/acked" "$TD/verdict-acked"
  round_crash 4
  jq '{run, round: .to, verdict, pr_published}' "$t" > "$TD/round.tmp"; mv "$TD/round.tmp" "$TD/round"
  round_crash 4a
  rm -f "$t"
  team_session_doorbell "$TD" lead "round $to started — the coder reworks $(round_rework)"
  echo "round $to started: rework $(round_rework)"
}

# cmd_advance, before the first stage: finish a pending transition of this run; a session.json of an
# earlier round than the durable one is ended and removed.
round_reconcile() {
  local t="$TD/round-transition"
  [ ! -f "$t" ] || [ "$(jq -r .run "$t" 2>/dev/null)" != "$RUN" ] || round_finish
  [ -f "$TD/session.json" ] || return 0
  [ "$(jq -r '.round // 1' "$TD/session.json")" -lt "$(cur_round)" ] || return 0
  end_session "$(session_json role)"; rm -f "$TD/session.json"
}
