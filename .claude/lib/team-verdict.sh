#!/usr/bin/env bash
# The per-run TeamLead's gate verdicts, written into the team clone for the runner to act on.
# Usage: bash .claude/lib/team-verdict.sh <gate> <verdict> --for <record> --message "<line>"
#          [--ref <file>] [--notify human_decision|abandon_decision] [--decision d-<n>]
#        bash .claude/lib/team-verdict.sh event collision --ref <file> --message "<line>"
#   gates: spec → approve|revise|escalate (brainstorm); plan → approve|revise|escalate|remode
#   (remode in quick only). --for names the planner's newest record (a review for spec, a done for
#   plan). revise needs --ref (the findings) and is capped per gate by teams.teamlead.revise_limit;
#   --decision names an answered decision with answer_outcome more-revise that grants one more round.
#   acceptance → accept|rework|abandon-recommended on the qa's newest done record: accept needs
#   runs/<run>/blind-check.md, then acceptance-brief.md (six headings; for a QA verdict
#   ready-with-warnings one `- <warning> → keep|fix|follow-up — <why>` line per warning);
#   abandon-recommended needs --decision d-<n>, pending, opened with --notify abandon_decision.
#   decision → escalate|continue|close|resolved: --for is any file under runs/<run>/ (a record, a
#   verdict, decisions/req-<n>.json) or attention:<line>; escalate needs --ref <the decision file>;
#   continue/close need --decision d-<n> answered with that answer_outcome; resolved closes a
#   decision without changing the run. A used decision becomes status: consumed (once).
#   Writes .agents/team/runs/<run>/teamlead-<gate>-<seq>.json.
#   e.g. bash .claude/lib/team-verdict.sh spec revise --for planner-1-2.json \
#          --ref .agents/team/runs/alfa-20261114-100000/gate-spec-1.md --message "2 findings"
# Exit: 0 written · 2 usage · 3 not the lead · 4 bad gate/verdict/for · 5 revise limit
#       6 spec changed after approval · 7 constraint digest missing (team-lead.sh digest-check)
#       8 acceptance brief incomplete.
#   Contract: .agents/reference/team-lead.md §4, §5
set -euo pipefail

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 2 ] || usage
GATE="$1"; VERDICT="$2"; shift 2
FOR=""; FOR_RAW=""; REF=""; NOTIFY=""; MESSAGE=""; DECISION=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --for) FOR="$(basename "$2")"; FOR_RAW="$2" ;; --ref) REF="$2" ;; --notify) NOTIFY="$2" ;;
    --message) MESSAGE="$2" ;; --decision) DECISION="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$MESSAGE" ] || { echo "error: --message is required" >&2; exit 2; }
case "$MESSAGE" in *$'\n'*) echo "error: --message must be one line" >&2; exit 2 ;; esac
case "$NOTIFY" in ""|human_decision|abandon_decision) ;;
  *) echo "error: --notify must be human_decision or abandon_decision" >&2; exit 2 ;; esac

LIB="$(cd "$(dirname "$0")" && pwd)"
. "$LIB/team-lib.sh"
. "$LIB/team-lead-lib.sh"

team_lead_caller || { echo "error: only this run's TeamLead writes verdicts" >&2; exit 3; }
TD="$(team_dir)"; RUN="$(cat "$TD/run")"; RD="$TD/runs/$RUN"; MAIN="$(team_lead_json main_root)"
TEAM="$(team_json team)"; TICKET="$(team_json ticket)"; MODE="$(jq -r '.mode // "brainstorm"' "$TD/team.json")"
bad() { echo "error: $1" >&2; exit 4; }
rec() { jq -r --arg f "$2" '.[$f] // empty | if type == "array" then join(",") else . end' "$1"; }

fm() { sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^$2: *//p" | head -n 1; }
fm_set() {  # fm_set <file> <key> <value> — replace or add one frontmatter key, atomically
  awk -v k="$2" -v v="$3" '/^---$/ { n++; if (n == 2 && !done) print k ": " v; print; next }
    n == 1 && index($0, k ": ") == 1 { print k ": " v; done = 1; next } { print }' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}
verdicts() { ls "$RD" 2>/dev/null | grep -E "^teamlead-$GATE-[0-9]+\.json\$" | sort -t- -k3,3n || true; }
DIGEST=""
write_verdict() {  # → prints the written file
  local seq=1 n target tmp
  n="$(verdicts | tail -n 1)"; [ -z "$n" ] || { n="${n#teamlead-"$GATE"-}"; seq=$((${n%.json} + 1)); }
  target="$RD/teamlead-$GATE-$seq.json"; tmp="$RD/.teamlead-$GATE-$seq.json.tmp"
  [ ! -e "$target" ] || { echo "error: $target already exists" >&2; exit 1; }
  jq -n --arg team "$TEAM" --arg ticket "$TICKET" --arg run "$RUN" --arg gate "$GATE" \
    --argjson seq "$seq" --arg for "$FOR" --arg verdict "$VERDICT" --arg ref "$REF" \
    --arg notify "$NOTIFY" --arg message "$MESSAGE" --arg spec_digest "$DIGEST" \
    --arg decision "$DECISION" --arg written_at "$(team_utc)" \
    --arg session_id "$(team_lead_json session_id)" \
    '{team: $team, ticket: $ticket, run: $run, gate: $gate, seq: $seq, for: $for, verdict: $verdict,
      ref: $ref, notify: $notify, message: $message, spec_digest: $spec_digest,
      decision: $decision, written_at: $written_at, session_id: $session_id}' > "$tmp"
  [ ! -e "$target" ] || { rm -f "$tmp"; echo "error: $target already exists" >&2; exit 1; }
  mv "$tmp" "$target"
  echo "$target"
}
# decision_file <d-n> → its path, or refuses
decision_file() {
  [[ "$1" =~ ^d-[0-9]+$ ]] && [ -f "$RD/decisions/$1.md" ] || bad "--decision $1: no runs/$RUN/decisions/$1.md"
  echo "$RD/decisions/$1.md"
}

if [ "$GATE" = event ]; then
  [ "$VERDICT" = collision ] && [ -n "$REF" ] || usage
  exec bash "$MAIN/.claude/lib/team-inbox.sh" --main "$MAIN" write Supervisor collision \
    --from "$TEAM" --ticket "$TICKET" --run "$RUN" --ref "$REF" --message "$MESSAGE"
fi

# A human decision's gate: no stage record to be the newest of; the decision file carries the state.
if [ "$GATE" = decision ]; then
  case "$VERDICT" in escalate|continue|close|resolved) ;;
    *) bad "verdict $VERDICT is not allowed at the decision gate" ;; esac
  case "$FOR_RAW" in
    attention:*) [[ "$FOR_RAW" =~ ^attention:[1-9][0-9]*$ ]] || bad "--for attention:<line number>"
      FOR="$FOR_RAW" ;;
    *) FOR="${FOR_RAW#"$RD"/}"; FOR="${FOR#.agents/team/runs/"$RUN"/}"
       case "$FOR" in ""|/*|*..*) bad "--for must be a file under runs/$RUN/ or attention:<n>" ;; esac
       [ -f "$RD/$FOR" ] || bad "--for $FOR is not a file under runs/$RUN/" ;;
  esac
  if [ "$VERDICT" = escalate ]; then
    [ -n "$REF" ] && [ -f "$REF" ] || bad "escalate needs --ref <the decision file>"
  else
    [ -n "$DECISION" ] || bad "$VERDICT needs --decision d-<n>"
    df="$(decision_file "$DECISION")"
    case "$VERDICT:$(fm "$df" status)" in
      resolved:pending|resolved:answered) ;;
      resolved:*) bad "$DECISION is $(fm "$df" status) — nothing to resolve" ;;
      *:answered) [ "$(fm "$df" answer_outcome)" = "$VERDICT" ] \
          || bad "$DECISION was answered with outcome $(fm "$df" answer_outcome), not $VERDICT" ;;
      *) bad "$DECISION is $(fm "$df" status), not answered (a control verdict uses it once)" ;;
    esac
  fi
  t="$(write_verdict)"
  if [ -n "$DECISION" ]; then
    if [ "$VERDICT" = resolved ]; then fm_set "$df" status resolved
    else fm_set "$df" status consumed; fi
    fm_set "$df" consumed_by "$(basename "$t")"
  fi
  echo "$t"; exit 0
fi

# The gated record: the gated role's newest record of the launched attempt, in the gate's verdict.
case "$GATE" in
  spec) [ "$MODE" != quick ] || bad "quick mode has no spec gate"; role=planner; want=review ;;
  plan) role=planner; want=done ;;
  acceptance) role=qa; want=done ;;
  *) bad "unknown gate $GATE (spec|plan|acceptance|decision)" ;;
esac
[ -f "$TD/session.json" ] && [ "$(session_json role)" = "$role" ] \
  || bad "no $role session — the $GATE gate is the $role's"
last="$(team_records "$RUN" "$role" "$(session_json attempt)" | tail -n 1)"
[ -n "$FOR" ] && [ -n "$last" ] && [ "$FOR" = "$(basename "$last")" ] \
  || bad "--for ${FOR:-<none>} is not the newest $role record (${last:+$(basename "$last")})"
[ "$(rec "$last" verdict)" = "$want" ] || bad "$FOR is $(rec "$last" verdict), the $GATE gate needs $want"

case "$GATE $VERDICT" in
  "spec approve"|"spec revise"|"spec escalate"|"plan approve"|"plan revise"|"plan escalate") ;;
  "plan remode") [ "$MODE" = quick ] || bad "remode is for quick mode only" ;;
  "acceptance accept"|"acceptance rework"|"acceptance abandon-recommended") ;;
  *) bad "verdict $VERDICT is not allowed at the $GATE gate" ;;
esac
[ "$VERDICT" != revise ] || [ -n "$REF" ] || bad "revise needs --ref <findings file>"

# Acceptance: the blind order-vs-diff check comes first, the brief is written from it.
acc_fail() { echo "error: acceptance: $1" >&2; exit 8; }
if [ "$GATE $VERDICT" = "acceptance accept" ]; then
  blind="$RD/blind-check.md"; brief="$RD/acceptance-brief.md"
  [ -s "$blind" ] || acc_fail "runs/$RUN/blind-check.md missing — the blind order-vs-diff check comes first"
  [ -s "$brief" ] || acc_fail "runs/$RUN/acceptance-brief.md missing"
  ! [ "$brief" -ot "$blind" ] || acc_fail "acceptance-brief.md is older than blind-check.md — write the brief from the blind check"
  for h in "## Ordered vs delivered" "## Scope delta" "## Fit risks" "## Open defects" "## Warnings" \
    "## Recommendation"; do
    grep -qxF "$h" "$brief" || acc_fail "acceptance-brief.md lacks the heading '$h'"
  done
  qr="$RD/qa-report-$(rec "$last" attempt).md"
  [ -f "$qr" ] || acc_fail "no runs/$RUN/$(basename "$qr")"
  if [ "$(sed -n 's/^Verdict: //p' "$qr" | head -n 1)" = ready-with-warnings ]; then
    sect="$(awk '/^## Warnings$/ { f = 1; next } /^## / { f = 0 } f' "$brief")"
    IFS=',' read -ra ws <<<"$(sed -n 's/^Warnings: //p' "$qr" | head -n 1)"
    for w in ${ws[@]+"${ws[@]}"}; do
      w="$(printf '%s' "$w" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"; [ -n "$w" ] || continue
      ok=""
      while IFS= read -r l; do
        case "$l" in "- $w → keep — "?*|"- $w → fix — "?*|"- $w → follow-up — "?*) ok=1 ;; esac
      done <<<"$sect"
      [ -n "$ok" ] || acc_fail "## Warnings has no '- $w → keep|fix|follow-up — <why>' line"
    done
  fi
elif [ "$GATE $VERDICT" = "acceptance abandon-recommended" ]; then
  [ -n "$DECISION" ] || bad "abandon-recommended needs --decision d-<n> (a pending decision opened with --notify abandon_decision)"
  df="$(decision_file "$DECISION")"
  [ "$(fm "$df" status)" = pending ] && [ "$(fm "$df" notify)" = abandon_decision ] \
    || bad "$DECISION is not a pending decision opened with --notify abandon_decision"
fi

if [ "$VERDICT" = revise ]; then
  team_profile_load "$MAIN"
  used=0; grants=0
  for f in $(verdicts); do [ "$(rec "$RD/$f" verdict)" != revise ] || used=$((used + 1)); done
  # Consumed grants count, not verdict files: each answered more-revise decision is spent once.
  for f in "$RD"/decisions/d-*.md; do
    [ -f "$f" ] && [ "$(fm "$f" answer_outcome)" = more-revise ] && [ "$(fm "$f" gate)" = "$GATE" ] \
      && [ "$(fm "$f" status)" = consumed ] && grants=$((grants + 1)) || true
  done
  if [ -n "$DECISION" ]; then
    df="$(decision_file "$DECISION")"
    [ "$(fm "$df" status)" = answered ] && [ "$(fm "$df" answer_outcome)" = more-revise ] \
      && [ "$(fm "$df" gate)" = "$GATE" ] \
      || bad "--decision $DECISION is not an answered, unconsumed more-revise grant for gate $GATE"
    grants=$((grants + 1))
  fi
  if [ "$used" -ge $((TEAM_LEAD_REVISE_LIMIT + grants)) ]; then
    echo "error: revise limit $TEAM_LEAD_REVISE_LIMIT reached for gate $GATE (teams.teamlead.revise_limit) — write escalate with a pending decision, approve$([ "$MODE" != quick ] || echo ', or remode')" >&2
    exit 5
  fi
fi

# The spec is read at the record's output_rev, never from the working tree; the Status line is
# excluded so setting Approved after the gate does not move the digest.
digest() { git show "$1:$2" | grep -v '^\*\*Status:\*\*' | shasum -a 256 | cut -d' ' -f1; }
spec_of() { jq -r '[.artifacts[] | select(startswith(".agents/specs/"))][0] // empty' "$1"; }
# The approve that opens the run's work needs the constraint digest (brainstorm spec, quick plan).
need=""
case "$GATE $VERDICT $MODE" in
  "spec approve "*) need="$(spec_of "$last")" ;;
  "plan approve quick") need="$(jq -r '[.artifacts[] | select(startswith(".agents/plans/"))][0] // empty' "$last")" ;;
esac
if [ -n "$need" ] && ! bash "$LIB/team-lead.sh" digest-check "$TEAM" "$need"; then exit 7; fi

if [ "$GATE $VERDICT" = "spec approve" ]; then
  s="$(spec_of "$last")"; [ -n "$s" ] || bad "$FOR names no spec"
  DIGEST="$(digest "$(rec "$last" output_rev)" "$s")" || bad "spec $s not readable at $FOR's output_rev"
elif [ "$GATE $VERDICT" = "plan approve" ] && [ "$MODE" != quick ]; then
  ok=""
  for f in $(GATE=spec verdicts); do [ "$(rec "$RD/$f" verdict)" != approve ] || ok="$RD/$f"; done
  [ -n "$ok" ] || bad "no spec approve in run $RUN — run the spec gate first"
  s="$(spec_of "$last")"; [ -n "$s" ] || s="$(spec_of "$RD/$(rec "$ok" for)")"
  d="$(digest "$(rec "$last" output_rev)" "$s")" || bad "spec $s not readable at $FOR's output_rev"
  if [ "$d" != "$(rec "$ok" spec_digest)" ]; then
    echo "error: spec changed after approval — re-run the spec gate" >&2; exit 6
  fi
fi

target="$(write_verdict)"
# The grant is spent by this verdict.
if [ -n "$DECISION" ] && [ "$VERDICT" = revise ]; then
  fm_set "$df" status consumed; fm_set "$df" consumed_by "$(basename "$target")"
fi
echo "$target"
