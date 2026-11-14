#!/usr/bin/env bash
# The per-run TeamLead's gate verdicts, written into the team clone for the runner to act on.
# Usage: bash .claude/lib/team-verdict.sh <gate> <verdict> --for <record> --message "<line>"
#          [--ref <file>] [--notify human_decision|abandon_decision] [--decision d-<n>]
#        bash .claude/lib/team-verdict.sh event collision --ref <file> --message "<line>"
#   gates: spec → approve|revise|escalate (brainstorm); plan → approve|revise|escalate|remode
#   (remode in quick only). --for names the planner's newest record (a review for spec, a done for
#   plan). revise needs --ref (the findings) and is capped per gate by teams.teamlead.revise_limit;
#   --decision names an answered decision with outcome more-revise that grants one more round.
#   Writes .agents/team/runs/<run>/teamlead-<gate>-<seq>.json.
#   e.g. bash .claude/lib/team-verdict.sh spec revise --for planner-1-2.json \
#          --ref .agents/team/runs/alfa-20261114-100000/gate-spec-1.md --message "2 findings"
# Exit: 0 written · 2 usage · 3 not the lead · 4 bad gate/verdict/for · 5 revise limit
#       6 spec changed after approval. Contract: .agents/reference/team-lead.md §4
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 2 ] || usage
GATE="$1"; VERDICT="$2"; shift 2
FOR=""; REF=""; NOTIFY=""; MESSAGE=""; DECISION=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --for) FOR="$(basename "$2")" ;; --ref) REF="$2" ;; --notify) NOTIFY="$2" ;;
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

if [ "$GATE" = event ]; then
  [ "$VERDICT" = collision ] && [ -n "$REF" ] || usage
  exec bash "$MAIN/.claude/lib/team-inbox.sh" --main "$MAIN" write Supervisor collision \
    --from "$TEAM" --ticket "$TICKET" --run "$RUN" --ref "$REF" --message "$MESSAGE"
fi

# The gated record: the planner's newest record of the launched attempt, in the gate's verdict.
case "$GATE" in
  spec) [ "$MODE" != quick ] || bad "quick mode has no spec gate"; want=review ;;
  plan) want=done ;;
  acceptance|decision) bad "gate $GATE is not yet supported" ;;
  *) bad "unknown gate $GATE (spec|plan)" ;;
esac
[ -f "$TD/session.json" ] && [ "$(session_json role)" = planner ] \
  || bad "no planner session — the $GATE gate is the planner's"
last="$(team_records "$RUN" planner "$(session_json attempt)" | tail -n 1)"
[ -n "$FOR" ] && [ -n "$last" ] && [ "$FOR" = "$(basename "$last")" ] \
  || bad "--for ${FOR:-<none>} is not the newest planner record (${last:+$(basename "$last")})"
[ "$(rec "$last" verdict)" = "$want" ] || bad "$FOR is $(rec "$last" verdict), the $GATE gate needs $want"

case "$GATE $VERDICT" in
  "spec approve"|"spec revise"|"spec escalate"|"plan approve"|"plan revise"|"plan escalate") ;;
  "plan remode") [ "$MODE" = quick ] || bad "remode is for quick mode only" ;;
  *) bad "verdict $VERDICT is not allowed at the $GATE gate" ;;
esac
[ "$VERDICT" != revise ] || [ -n "$REF" ] || bad "revise needs --ref <findings file>"

fm() { sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^$2: *//p" | head -n 1; }
verdicts() { ls "$RD" 2>/dev/null | grep -E "^teamlead-$GATE-[0-9]+\.json\$" | sort -t- -k3,3n || true; }

if [ "$VERDICT" = revise ]; then
  team_profile_load "$MAIN"
  used=0; grants=0
  for f in $(verdicts); do [ "$(rec "$RD/$f" verdict)" != revise ] || used=$((used + 1)); done
  for f in "$RD"/decisions/d-*.md; do
    [ -f "$f" ] && [ "$(fm "$f" outcome)" = more-revise ] && [ "$(fm "$f" gate)" = "$GATE" ] \
      && [ -n "$(fm "$f" consumed)" ] && grants=$((grants + 1)) || true
  done
  if [ -n "$DECISION" ]; then
    df="$RD/decisions/$DECISION.md"
    [[ "$DECISION" =~ ^d-[0-9]+$ ]] && [ -f "$df" ] && [ "$(fm "$df" status)" = answered ] \
      && [ "$(fm "$df" outcome)" = more-revise ] && [ "$(fm "$df" gate)" = "$GATE" ] \
      && [ -z "$(fm "$df" consumed)" ] \
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
DIGEST=""
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

seq=1; n="$(verdicts | tail -n 1)"; [ -z "$n" ] || { n="${n#teamlead-"$GATE"-}"; seq=$((${n%.json} + 1)); }
target="$RD/teamlead-$GATE-$seq.json"; tmp="$RD/.teamlead-$GATE-$seq.json.tmp"
[ ! -e "$target" ] || { echo "error: $target already exists" >&2; exit 1; }
jq -n --arg team "$TEAM" --arg ticket "$TICKET" --arg run "$RUN" --arg gate "$GATE" \
  --argjson seq "$seq" --arg for "$FOR" --arg verdict "$VERDICT" --arg ref "$REF" \
  --arg notify "$NOTIFY" --arg message "$MESSAGE" --arg spec_digest "$DIGEST" \
  --arg written_at "$(team_utc)" --arg session_id "$(team_lead_json session_id)" \
  '{team: $team, ticket: $ticket, run: $run, gate: $gate, seq: $seq, for: $for, verdict: $verdict,
    ref: $ref, notify: $notify, message: $message, spec_digest: $spec_digest,
    written_at: $written_at, session_id: $session_id}' > "$tmp"
[ ! -e "$target" ] || { rm -f "$tmp"; echo "error: $target already exists" >&2; exit 1; }
mv "$tmp" "$target"
# The grant is spent by this verdict: consumed goes into the decision's frontmatter.
if [ -n "$DECISION" ] && [ "$VERDICT" = revise ]; then
  awk -v c="consumed: $(basename "$target")" '/^---$/ && ++n == 2 { print c } { print }' "$df" > "$df.tmp"
  mv "$df.tmp" "$df"
fi
echo "$target"
