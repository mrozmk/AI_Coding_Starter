#!/usr/bin/env bash
# The runner's stops that nobody saw before #99: a record the validator rejects, and a stalled stage.
# A rejected record is sent back to its stage session with the validator's reason, verbatim, at most
# twice per attempt (runs/<run>/[r<n>/]rejected-<record> holds each reason, so the count survives a
# resume). The third goes to the lead, which decides; with no lead the runner exits 4. A stall and a
# rejection nobody in the team can fix reach the Operator as one human_decision through notify.sh
# (decision stalled-|rejected-[r<n>-]<role>-<attempt>), resolved (#97) once the run goes on.
# Sourced by team-run.sh from the MAIN checkout, never executed; uses the runner's globals (TEAM, RUN,
# TD, CLONE, root, REJECT_WHY set by team-validate.sh fail) and helpers (rec, ack_name, rp, sess_name,
# sh_hint, team_json, team_lead_on, team_session_doorbell, team_tmux_alive, dialog_where). Bash 3.2.
# Contract: .agents/reference/team-pipeline.md §5, team-lead.md §1

# stop_notify <decision> <summary> <address> — once per decision; runs/<run>/operator-<decision>
# marks it sent, so a resumed runner neither sends it again nor forgets to resolve it. The runner
# exits right after, so a failed call is one warn:, not a retry.
stop_notify() {
  local f="$TD/runs/$RUN/operator-$1" p
  [ ! -f "$f" ] || return 0
  team_channel_names "$root" 2>/dev/null || unset TEAM_CHANNEL_TMUX_PREFIX  # the project id, as lead_notify
  p="${TEAM_CHANNEL_TMUX_PREFIX:-$(basename "$root" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-\n' '-')}"
  if bash "$root/.claude/lib/notify.sh" human_decision --project "$p" --team "$TEAM" \
    --ticket "$(team_json ticket)" --run "$RUN" --decision "$1" --summary "$2" \
    --answer "$3" --hint "$(dialog_where "$3")" --source runner --main "$root" >/dev/null 2>&1; then
    mkdir -p "$TD/runs/$RUN"; printf '%s\n' "$1" > "$f"
  else
    echo "warn: notify.sh failed for $1 — the Operator was not told" >&2
  fi
}

# stop_resolve — the run went on (a record accepted, a new attempt launched): every open item closes.
stop_resolve() {
  local f d
  for f in "$TD/runs/$RUN"/operator-*; do
    [ -f "$f" ] || continue
    d="$(cat "$f")"
    bash "$root/.claude/lib/notify.sh" resolve --team "$TEAM" --run "$RUN" --decision "$d" >/dev/null 2>&1 || true
    rm -f "$f"; echo "operator item resolved: $d"
  done
}

# stall_stop <role> <attempt> — before die 3: a dead runner only the Supervisor/Operator restarts.
stall_stop() {
  stop_notify "stalled-$(rp | tr / -)$1-$2" \
    "$TEAM $1 stalled: no record within the $1 time limit — the runner stopped; look at the session, then /start-team $TEAM" \
    "$(sess_name "$1")"
}

# reject_record <record> — after validate_record failed. → 2 (keep waiting: the stage was sent the
# reason, or the lead was rung), or exit 4. Sent back = acked + <record>.answered, so new_record waits
# for the next seq and the stage clock keeps running; the lead's case is acked only and the clock
# pauses until its answer writes .answered (lead_waiting). Exit 4 leaves the record unacked: a rerun
# validates it again.
reject_record() {
  local r="$1" why="${REJECT_WHY:-see the runner output}" role att d n f name nth
  role="$(rec "$r" role)"; att="$(rec "$r" attempt)"; name="$(sess_name "$role")"
  d="$(dirname "$r")"; printf '%s\n' "$why" > "$d/rejected-$(basename "$r" .json)"
  n=0; for f in "$d/rejected-$role-$att-"*; do [ ! -f "$f" ] || n=$((n + 1)); done
  echo "rejected: $(basename "$r") — $why"
  if [ "$n" -le 2 ] && team_tmux_alive "$name"; then
    ack_name "$r" > "$TD/acked"; touch "$r.answered"
    team_session_doorbell "$TD" "$role" "[team-run] your $(rec "$r" verdict) record ${r#"$CLONE"/} was rejected: $why. Fix the cause, commit, and write the record again ($n of 2) — the run is not done."
    ! team_lead_on || team_session_doorbell "$TD" lead "rejected $role $att: ${r#"$CLONE"/} — $why (sent back to the stage, $n of 2)"
    echo "sent back to $role ($n of 2)"; return 2
  fi
  if team_lead_on; then
    case "$n" in 1) nth=1st ;; 2) nth=2nd ;; 3) nth=3rd ;; *) nth="${n}th" ;; esac
    ack_name "$r" > "$TD/acked"
    team_session_doorbell "$TD" lead "rejected $role $att: ${r#"$CLONE"/} — $why ($nth rejection, the stage is not asked again)"
    echo "waiting for TeamLead: $(basename "$r")"; return 2
  fi
  stop_notify "rejected-$(rp | tr / -)$role-$att" \
    "$TEAM $role: record $(basename "$r") rejected — $why; the runner stopped" "$name"
  die 4 "record $(basename "$r") rejected — session left alive: $(sh_hint "$name")"
}
