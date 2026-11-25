#!/usr/bin/env bash
# The sender's authority path (team-answer.sh --authority teamlead|operator|delegated). Sourced by
# team-answer.sh, never executed; every function uses its globals (TEAM, TD, AUTH, WHY, DECISION,
# ASK, refuse). Bash 3.2. Contract: .agents/reference/team-lead.md §6

# The run belongs to its per-run TeamLead: teamlead.json names the clone's current run.
auth_lead_owned() {
  [ -f "$TD/teamlead.json" ] \
    && [ "$(jq -r '.run // empty' "$TD/teamlead.json" 2>/dev/null)" = "$(cat "$TD/run" 2>/dev/null)" ]
}
auth_lead_caller() { [ "${TEAM_SESSION_ROLE:-}" = TeamLead ] && auth_lead_owned; }
auth_fm() { sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^$2: *//p" | head -n 1; }
auth_fm_set() {  # auth_fm_set <file> <key> <value> — replace or add one frontmatter key, atomically
  FM_K="$2" FM_V="$3" awk '/^---$/ { n++; if (n == 2 && !done) print ENVIRON["FM_K"] ": " ENVIRON["FM_V"]; print; next }
    n == 1 && index($0, ENVIRON["FM_K"] ": ") == 1 { print ENVIRON["FM_K"] ": " ENVIRON["FM_V"]; done = 1; next } { print }' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

# auth_preflight — the caller and decision rules of the authority: only this run's TeamLead
# answers, only its own team; an operator answer names an answered decision bound to this ask.
# `delegated` relays a decision the Supervisor answered under the Operator's mandate
# (answered_via: supervisor-delegated …) and no other; `operator` never relays such a one, so a
# delegated answer is never recorded as the Operator's.
auth_preflight() {
  local d run mr
  case "$AUTH" in teamlead|operator|delegated) ;;
    *) echo "error: --authority must be teamlead, operator or delegated" >&2; exit 2 ;; esac
  [ -n "$WHY" ] && [[ "$WHY" != *$'\n'* ]] \
    || { echo "error: --authority needs --why \"<one line>\"" >&2; exit 2; }
  auth_lead_caller || refuse 7 "authority $AUTH is the run's TeamLead's"
  [ "$TEAM" = "${TEAM_RUN_TEAM:-}" ] || refuse 7 "a TeamLead answers only its own team"
  [ "$AUTH" != teamlead ] || [ -z "$DECISION" ] \
    || { echo "error: --decision goes with --authority operator or delegated" >&2; exit 2; }
  [ "$AUTH" != teamlead ] || return 0
  run="$(cat "$TD/run" 2>/dev/null || true)"
  d="$(cd "$(dirname "$DECISION")" 2>/dev/null && pwd -P)/$(basename "$DECISION")" || d=""
  [ -n "$DECISION" ] && [ -f "$d" ] \
    && [ "$(dirname "$d")" = "$(cd "$TD/runs/$run/decisions" 2>/dev/null && pwd -P)" ] \
    && [ "$(auth_fm "$d" status)" = answered ] \
    || refuse 7 "authority $AUTH needs --decision <an answered runs/$run/decisions/d-<n>.md>"
  case "$AUTH:$(auth_fm "$d" answered_via)" in
    delegated:"supervisor-delegated "*) ;;
    delegated:*) refuse 7 "decision $(auth_fm "$d" id) is not the Supervisor's delegated answer — relay it with --authority operator" ;;
    operator:"supervisor-delegated "*) refuse 7 "decision $(auth_fm "$d" id) is the Supervisor's delegated answer, not the Operator's — relay it with --authority delegated" ;;
  esac
  # The main checkout this clone belongs to — required, and it must be the real one: a checkout
  # that is no clone and whose anchor for this team names this clone. Without it nothing can say
  # whether a delegated answer is on record, so no decision is relayed at all.
  mr="$(jq -r '.main_root // empty' "$TD/teamlead.json" 2>/dev/null || true)"
  [ -n "$mr" ] && [ -d "$mr/.claude/lib" ] && [ ! -f "$mr/.agents/team/team.json" ] \
    && [ "$(jq -r '.clone // ""' "$mr/.agents/team/anchors/$TEAM.json" 2>/dev/null)" = "$(cd "${TD%/.agents/team}" && pwd -P)" ] \
    || refuse 7 "the main checkout of this clone cannot be established (teamlead.json main_root, its anchor for $TEAM) — authority $AUTH cannot be relayed"
  if [ "$AUTH" = operator ]; then
    # Whatever the decision file says now: an answer pinned in the main checkout's delegation
    # ledger is never relayed as the Operator's (the stage hook refuses it too).
    [ ! -e "$mr/.agents/team/delegated/$TEAM-$run-$(auth_fm "$d" id).json" ] \
      || refuse 7 "decision $(auth_fm "$d" id) has a delegated answer on record — relay it with --authority delegated"
    # In a run that has been under the Operator's mandate at any point — expired, paused or
    # revoked since, no matter — Operator authority needs positive human evidence (a typed
    # message or a dialog answer) for the rest of the run: a `terminal` marker is not one.
    # Checked here, before anything is logged or delivered.
    if [ "$(auth_fm "$d" answered_via)" = terminal ]; then
      . "$mr/.claude/lib/team-lead-lib.sh" 2>/dev/null && . "$mr/.claude/lib/team-mandate.sh" 2>/dev/null \
        || refuse 7 "the main checkout's mandate library cannot be loaded — a terminal answer cannot be relayed as the Operator's"
      ! mandate_run_ever "$mr" "$TEAM" "$run" \
        || refuse 7 "run $run is or was under the Operator's mandate — a terminal answer is not taken as the Operator's for the rest of the run; the Operator answers in the TeamLead's dialog or window, or through the Supervisor's relay"
    fi
  fi
  # A decision about an ask binds that ask: a successor ask is never answered with it.
  [ "$(auth_fm "$d" bind_ask)" = "$ASK" ] \
    || refuse 7 "decision $(auth_fm "$d" id) is bound to $(auth_fm "$d" bind_ask), not $ASK"
  DEC_ID="$(auth_fm "$d" id)"; DEC_FILE="$d"
}

# auth_dispatch — after the answer file exists: an operator decision is spent once.
auth_dispatch() {
  [ -n "$DEC_FILE" ] || return 0
  [ "$(auth_fm "$DEC_FILE" status)" = answered ] \
    || refuse 6 "decision $DEC_ID is $(auth_fm "$DEC_FILE" status) — dispatched once only"
  auth_fm_set "$DEC_FILE" status dispatched
  auth_fm_set "$DEC_FILE" dispatched_at "$(team_utc)"
}
