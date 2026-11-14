#!/usr/bin/env bash
# The sender's authority path (team-answer.sh --authority class|teamlead|operator). Sourced by
# team-answer.sh, never executed; every function uses its globals (TEAM, ROLE, TD, AUTH, WHY,
# DECISION, TIER, SESSION, action, text, P, T, EVENT, E_EVENT, refuse, sj, newest_record).
# Bash 3.2. Contract: .agents/reference/team-lead.md §6

# The run belongs to its per-run TeamLead: teamlead.json names the clone's current run.
auth_lead_owned() {
  [ -f "$TD/teamlead.json" ] \
    && [ "$(jq -r '.run // empty' "$TD/teamlead.json" 2>/dev/null)" = "$(cat "$TD/run" 2>/dev/null)" ]
}
auth_lead_caller() { [ "${TEAM_SESSION_ROLE:-}" = TeamLead ] && auth_lead_owned; }
auth_fm() { sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^$2: *//p" | head -n 1; }

# auth_preflight — before the lock: the caller and decision rules of the authority, and the
# legacy refusal: a lead-owned run takes no --tier (the human-only check must not be bypassed).
auth_preflight() {
  local d run
  if [ -z "$AUTH" ]; then
    { [ -n "$TIER" ] && auth_lead_owned; } && refuse 8 "run is owned by its TeamLead — use --authority"
    return 0
  fi
  case "$AUTH" in class|teamlead|operator) ;;
    *) echo "error: --authority must be class, teamlead or operator" >&2; exit 2 ;; esac
  [ -z "$TIER" ] && [ -z "$SESSION" ] \
    || { echo "error: --authority excludes --tier and --session" >&2; exit 2; }
  [ -n "$WHY" ] && [[ "$WHY" != *$'\n'* ]] \
    || { echo "error: --authority needs --why \"<one line>\"" >&2; exit 2; }
  if [ "$AUTH" != class ] || auth_lead_caller; then
    auth_lead_caller || refuse 7 "authority $AUTH is the run's TeamLead's"
    [ "$TEAM" = "${TEAM_RUN_TEAM:-}" ] || refuse 7 "a TeamLead answers only its own team"
  fi
  [ "$AUTH" = operator ] || [ -z "$DECISION" ] \
    || { echo "error: --decision goes with --authority operator" >&2; exit 2; }
  [ "$AUTH" = operator ] || return 0
  run="$(cat "$TD/run" 2>/dev/null || true)"
  d="$(cd "$(dirname "$DECISION")" 2>/dev/null && pwd -P)/$(basename "$DECISION")" || d=""
  [ -n "$DECISION" ] && [ -f "$d" ] \
    && [ "$(dirname "$d")" = "$(cd "$TD/runs/$run/decisions" 2>/dev/null && pwd -P)" ] \
    && [ "$(auth_fm "$d" status)" = answered ] \
    || refuse 7 "authority operator needs --decision <an answered runs/$run/decisions/d-<n>.md>"
  DEC_ID="$(auth_fm "$d" id)"
}

# auth_event — with an authority there is no ledger: the live event must be readable and
# unambiguous, and equal --expect-event when the caller captured one.
auth_event() {
  [ -n "$AUTH" ] && [ "$action" != say ] || return 0
  case "$EVENT" in ambiguous) refuse 5 "ambiguous event" ;; -) refuse 3 "transcript unreadable" ;; esac
  [ -z "$E_EVENT" ] || [ "$EVENT" = "$E_EVENT" ] || refuse 6 "new prompt event"
}

# auth_after — after a delivered answer: the answers.md line (authority calls) and the stop's
# .answered marker (a say, or yes/no on an authority) that resumes the stage clock (lead_waiting).
auth_after() {
  local run rd a acked q ans
  # A clone-less target (a supervision session) has no run: nothing to log or mark.
  run="$(cat "$TD/run" 2>/dev/null || true)"; [ -n "$run" ] || return 0
  rd="$TD/runs/$run"; a="$(sj attempt)"
  if [ -n "$AUTH" ] && [ -d "$rd" ]; then
    case "$action" in
      say) q="$(jq -r '.message // "blocked"' "$rd/$(newest_record)" 2>/dev/null || echo blocked)" ;;
      *) q="$(jq -r '(.question // []) | join(" ")' <<<"$P" 2>/dev/null || true)"
         [ -n "$q" ] || q="$(jq -r '.command // .title // .header // "prompt"' <<<"$P" 2>/dev/null || true)" ;;
    esac
    q="$(printf '%s' "$q" | tr '\n' ' ' | cut -c1-160)"
    case "$action" in yes|no) ans="$action${text:+: $text}" ;; *) ans="$action: $text" ;; esac
    echo "- $(team_utc) [$ROLE $a] $q → $ans — $WHY [authority $AUTH]${DEC_ID:+ [decision $DEC_ID]}" \
      >> "$rd/answers.md"
  fi
  case "$action" in say) ;; yes|no) [ -n "$AUTH" ] || return 0 ;; *) return 0 ;; esac
  acked="$(cat "$TD/acked" 2>/dev/null || true)"
  case "$acked" in "$ROLE-$a-"*) [ ! -f "$rd/$acked" ] || touch "$rd/$acked.answered" ;; esac
}
