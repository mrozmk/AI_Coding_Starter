#!/usr/bin/env bash
# Write a team handoff record for the current role (called by planner/coder/qa in a team clone).
#
# Usage: bash .claude/lib/team-record.sh --verdict done|blocked|failed [--artifacts a,b]
#          [--pr <id>] [--evidence a,b] [--message "<one line>"]
#        bash .claude/lib/team-record.sh --verdict blocked --proposals <run dir>/wrapup_proposals-<a>_<k>.json
#   e.g. bash .claude/lib/team-record.sh --verdict done --pr 8371 --artifacts .agents/plans/done/x.md
#   --proposals: the wrapup's items for this run's TeamLead (team_wrapup.py); the stop is marked
#   `proposals` so audits and status do not count it as a block, and adds no notes line. <a> is the
#   attempt, <k> the first number no file of the attempt uses yet; a file a verdict names is refused.
#
# Identity comes from .agents/team/session.json; contract: .agents/reference/team-mode.md §6.
set -euo pipefail

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

VERDICT=""; ARTIFACTS=""; PR=""; EVIDENCE=""; MESSAGE=""; PROPOSALS=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --verdict) VERDICT="$2" ;;
    --artifacts) ARTIFACTS="$2" ;;
    --pr) PR="$2" ;;
    --evidence) EVIDENCE="$2" ;;
    --message) MESSAGE="$2" ;;
    --proposals) PROPOSALS="$2" ;;
    *) usage ;;
  esac
  shift 2
done

. "$(dirname "$0")/team-lib.sh"

[ "${TEAM_SESSION_ROLE:-}" != TeamLead ] \
  || { echo "error: TeamLead writes verdicts with team-verdict.sh, never stage records" >&2; exit 1; }

[ -f "$(team_dir)/session.json" ] || { echo "error: not in team mode (no session.json)" >&2; exit 1; }
case "$VERDICT" in
  done|blocked|failed) ;;
  review)
    echo "error: --verdict review is gone: there is no spec gate — approve the spec yourself and record done after /plan-feature" >&2; exit 2 ;;
  *) echo "error: --verdict must be done, blocked or failed" >&2; exit 2 ;;
esac
if [ -n "$PR" ] && ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  echo "error: --pr must be numeric" >&2; exit 2
fi
case "$MESSAGE" in *$'\n'*) echo "error: --message must be one line" >&2; exit 2 ;; esac

team="$(session_json team)"; role="$(session_json role)"; run="$(session_json run)"
attempt="$(session_json attempt)"; ticket="$(session_json ticket)"; input_rev="$(session_json input_rev)"
branch="$(team_json branch)"
output_rev="$(git rev-parse HEAD)"
# A rework round n ≥ 2 writes into runs/<run>/r<n>/ (team-lead.md §9); `run` stays the logical id.
round="$(jq -r '.round // 1' "$(team_dir)/session.json")"; ref="$run"; [ "$round" = 1 ] || ref="$run/r$round"
notes="$(team_notes_init "$ref")"

if [ -n "$PROPOSALS" ]; then
  [ "$role" = wrapup ] && [ "$VERDICT" = blocked ] \
    || { echo "error: --proposals is the wrapup's, with --verdict blocked" >&2; exit 2; }
  [ "$(jq -r '.run // empty' "$(team_dir)/teamlead.json" 2>/dev/null)" = "$run" ] \
    || { echo "error: --proposals needs this run's TeamLead (no teamlead.json for $run)" >&2; exit 2; }
  PROPOSALS="${PROPOSALS#./}"
  [ "$(dirname "$PROPOSALS")" = ".agents/team/runs/$ref" ] \
    && [[ "$(basename "$PROPOSALS")" =~ ^wrapup_proposals-${attempt}_[1-9][0-9]*\.json$ ]] \
    || { echo "error: --proposals must be .agents/team/runs/$ref/wrapup_proposals-${attempt}_<k>.json" >&2; exit 2; }
  # A decided file is never rewritten into a second stop: the lead could not decide it again.
  for v in "$(team_dir)/runs/$run"/teamlead-wrapup-*.json; do
    [ -f "$v" ] || continue
    [ "$(jq -r '.for // empty' "$v")" != "${PROPOSALS#.agents/team/runs/"$run"/}" ] \
      || { echo "error: $PROPOSALS is already decided ($(basename "$v")) — write wrapup_proposals-${attempt}_<next k>.json" >&2; exit 2; }
  done
  python3 -I "$(dirname "$0")/team_wrapup.py" check "$(team_root)/$PROPOSALS" >/dev/null || exit 2
  MESSAGE="wrapup proposals: $PROPOSALS"
elif [ "$VERDICT" = blocked ] || [ "$VERDICT" = failed ]; then
  [ -n "$MESSAGE" ] || { echo "error: --verdict $VERDICT requires --message" >&2; exit 2; }
  echo "- [$role $attempt] $MESSAGE" >> "$notes"
fi

seq="$(team_next_seq "$ref" "$role" "$attempt")"
dir="$(team_dir)/runs/$ref"
target="$dir/$role-$attempt-$seq.json"
tmp="$dir/.$role-$attempt-$seq.json.tmp"
[ ! -e "$target" ] || { echo "error: $target already exists" >&2; exit 1; }

jq -n --arg team "$team" --arg ticket "$ticket" --arg run "$run" --argjson round "$round" --arg role "$role" \
  --argjson attempt "$attempt" --argjson seq "$seq" --arg branch "$branch" \
  --arg input_rev "$input_rev" --arg output_rev "$output_rev" --arg verdict "$VERDICT" \
  --argjson pr_id "${PR:-null}" --arg artifacts "$ARTIFACTS" --arg evidence "$EVIDENCE" \
  --arg notes "${notes#"$(team_root)"/}" --arg message "$MESSAGE" \
  --arg written_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg proposals "$PROPOSALS" \
  '{team: $team, ticket: $ticket, run: $run, round: $round, role: $role, attempt: $attempt, seq: $seq,
    branch: $branch, input_rev: $input_rev, output_rev: $output_rev, verdict: $verdict,
    pr_id: $pr_id,
    artifacts: ($artifacts | if . == "" then [] else split(",") end),
    evidence: ($evidence | if . == "" then [] else split(",") end),
    notes: $notes, message: $message, written_at: $written_at}
  + (if $proposals == "" then {} else {proposals: $proposals} end)' > "$tmp"
[ ! -e "$target" ] || { rm -f "$tmp"; echo "error: $target already exists" >&2; exit 1; }
mv "$tmp" "$target"
echo "$target"
