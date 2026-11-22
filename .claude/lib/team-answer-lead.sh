#!/usr/bin/env bash
# The sender's authority path (team-answer.sh --authority teamlead|operator). Sourced by
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
  awk -v k="$2" -v v="$3" '/^---$/ { n++; if (n == 2 && !done) print k ": " v; print; next }
    n == 1 && index($0, k ": ") == 1 { print k ": " v; done = 1; next } { print }' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

# auth_preflight — the caller and decision rules of the authority: only this run's TeamLead
# answers, only its own team; an operator answer names an answered decision bound to this ask.
auth_preflight() {
  local d run
  case "$AUTH" in teamlead|operator) ;;
    *) echo "error: --authority must be teamlead or operator" >&2; exit 2 ;; esac
  [ -n "$WHY" ] && [[ "$WHY" != *$'\n'* ]] \
    || { echo "error: --authority needs --why \"<one line>\"" >&2; exit 2; }
  auth_lead_caller || refuse 7 "authority $AUTH is the run's TeamLead's"
  [ "$TEAM" = "${TEAM_RUN_TEAM:-}" ] || refuse 7 "a TeamLead answers only its own team"
  [ "$AUTH" = operator ] || [ -z "$DECISION" ] \
    || { echo "error: --decision goes with --authority operator" >&2; exit 2; }
  [ "$AUTH" = operator ] || return 0
  run="$(cat "$TD/run" 2>/dev/null || true)"
  d="$(cd "$(dirname "$DECISION")" 2>/dev/null && pwd -P)/$(basename "$DECISION")" || d=""
  [ -n "$DECISION" ] && [ -f "$d" ] \
    && [ "$(dirname "$d")" = "$(cd "$TD/runs/$run/decisions" 2>/dev/null && pwd -P)" ] \
    && [ "$(auth_fm "$d" status)" = answered ] \
    || refuse 7 "authority operator needs --decision <an answered runs/$run/decisions/d-<n>.md>"
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
