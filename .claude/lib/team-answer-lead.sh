#!/usr/bin/env bash
# The sender's authority path (team-answer.sh --authority class|teamlead|operator). Sourced by
# team-answer.sh, never executed; every function uses its globals (TEAM, ROLE, TD, AUTH, WHY,
# DECISION, action, text, P, T, EVENT, E_EVENT, refuse, sj, newest_record).
# Bash 3.2. Contract: .agents/reference/team-lead.md §6

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

# auth_preflight — before the lock: the caller and decision rules of the authority, and a TeamLead
# session's bare call (no --authority) refused: it would skip the caller and human-only checks.
auth_preflight() {
  local d run
  if [ -z "$AUTH" ]; then
    [ "${TEAM_SESSION_ROLE:-}" != TeamLead ] || refuse 7 "a TeamLead answers only with --authority class|teamlead|operator --why \"<line>\""
    return 0
  fi
  case "$AUTH" in class|teamlead|operator) ;;
    *) echo "error: --authority must be class, teamlead or operator" >&2; exit 2 ;; esac
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
  # A human-only prompt's decision is answered by the Operator in the stage window, never relayed.
  [ ! -f "$d" ] || [ -z "$(auth_fm "$d" answer_in)" ] || refuse 7 \
    "human-only prompt: the Operator answers it in the $(auth_fm "$d" answer_in) window; the runner records it"
  [ -n "$DECISION" ] && [ -f "$d" ] \
    && [ "$(dirname "$d")" = "$(cd "$TD/runs/$run/decisions" 2>/dev/null && pwd -P)" ] \
    && [ "$(auth_fm "$d" status)" = answered ] \
    || refuse 7 "authority operator needs --decision <an answered runs/$run/decisions/d-<n>.md>"
  DEC_ID="$(auth_fm "$d" id)"; DEC_FILE="$d"
  # A decision about a prompt binds that prompt instance: a successor prompt is never approved.
  [ -n "$E_SESSION" ] || E_SESSION="$(auth_fm "$d" bind_session_id)"
  [ -n "$E_RUN" ] || E_RUN="$(auth_fm "$d" bind_run)"
  [ -n "$E_ATTEMPT" ] || E_ATTEMPT="$(auth_fm "$d" bind_attempt)"
  [ -n "$E_FP" ] || E_FP="$(auth_fm "$d" bind_fp)"
  [ -n "$E_EVENT" ] || E_EVENT="$(auth_fm "$d" bind_event)"
  [ -n "$E_PANE" ] || E_PANE="$(auth_fm "$d" bind_pane)"
}

# auth_dispatch — under the send lock, before the first key: an operator decision is spent once.
auth_dispatch() {
  [ -n "$DEC_FILE" ] || return 0
  [ "$(auth_fm "$DEC_FILE" status)" = answered ] \
    || refuse 6 "decision $DEC_ID is $(auth_fm "$DEC_FILE" status) — dispatched once only"
  auth_fm_set "$DEC_FILE" status dispatched
  auth_fm_set "$DEC_FILE" dispatched_at "$(team_utc)"
}

# auth_event — with an authority there is no ledger: the live event must be readable and
# unambiguous, and equal --expect-event when the caller captured one.
auth_event() {
  [ -n "$AUTH" ] && [ "$action" != say ] || return 0
  case "$EVENT" in ambiguous) refuse 5 "ambiguous event" ;; -) refuse 3 "transcript unreadable" ;; esac
  [ -z "$E_EVENT" ] || [ "$EVENT" = "$E_EVENT" ] || refuse 6 "new prompt event"
  # A human-only prompt (a runner request bound to this event) is the Operator's in the stage
  # window: `no` skips the checker, so refuse it here for every action.
  local r run
  run="$(cat "$TD/run" 2>/dev/null || true)"
  for r in "$TD/runs/$run"/decisions/req-*.json; do
    [ -f "$r" ] && [ "$(jq -r '.binding.event // empty' "$r" 2>/dev/null)" = "$EVENT" ] \
      && refuse 9 "human-only prompt ($(basename "$r" .json)): the Operator answers it in the $ROLE window"
  done
  return 0
}

# auth_after — after a delivered answer: the answers.md line (authority calls) and the stop's
# .answered marker (a say, or yes/no on an authority) that resumes the stage clock (lead_waiting).
auth_after() {
  local run rd a acked q ans
  # A clone-less target has no run: nothing to log or mark.
  run="$(cat "$TD/run" 2>/dev/null || true)"; [ -n "$run" ] || return 0
  rd="$TD/runs/$run"; a="$(sj attempt)"
  if [ -n "$AUTH" ] && [ -d "$rd" ]; then
    case "$action" in
      say) q="$(jq -r '.message // "blocked"' "$TD/runs/$(team_run_ref "$TD" "$run")/$(newest_record)" 2>/dev/null || echo blocked)" ;;
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
  # acked is relative to runs/<run>/ (r<n>/<record> in a rework round).
  case "${acked##*/}" in "$ROLE-$a-"*) [ ! -f "$rd/$acked" ] || touch "$rd/$acked.answered" ;; esac
}
