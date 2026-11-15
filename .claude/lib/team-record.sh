#!/usr/bin/env bash
# Write a team handoff record for the current role (called by planner/coder/qa in a team clone).
#
# Usage: bash .claude/lib/team-record.sh --verdict done|blocked|failed|review [--artifacts a,b]
#          [--pr <id>] [--evidence a,b] [--message "<one line>"]
#   e.g. bash .claude/lib/team-record.sh --verdict done --pr 8371 --artifacts .agents/plans/done/x.md
#   review: the planner's committed spec for the TeamLead's spec gate (one .agents/specs/*.md).
#
# Identity comes from .agents/team/session.json; contract: .agents/reference/team-mode.md §6.
set -euo pipefail

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

VERDICT=""; ARTIFACTS=""; PR=""; EVIDENCE=""; MESSAGE=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --verdict) VERDICT="$2" ;;
    --artifacts) ARTIFACTS="$2" ;;
    --pr) PR="$2" ;;
    --evidence) EVIDENCE="$2" ;;
    --message) MESSAGE="$2" ;;
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
    [ "$(session_json role)" = planner ] || { echo "error: only the planner records review" >&2; exit 2; }
    case "$ARTIFACTS" in .agents/specs/*.md) ;; *) false ;; esac && [[ "$ARTIFACTS" != *,* ]] \
      || { echo "error: --verdict review needs --artifacts <one .agents/specs/*.md>" >&2; exit 2; } ;;
  *) echo "error: --verdict must be done, blocked, failed or review" >&2; exit 2 ;;
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

if [ "$VERDICT" = blocked ] || [ "$VERDICT" = failed ]; then
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
  --arg written_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{team: $team, ticket: $ticket, run: $run, round: $round, role: $role, attempt: $attempt, seq: $seq,
    branch: $branch, input_rev: $input_rev, output_rev: $output_rev, verdict: $verdict,
    pr_id: $pr_id,
    artifacts: ($artifacts | if . == "" then [] else split(",") end),
    evidence: ($evidence | if . == "" then [] else split(",") end),
    notes: $notes, message: $message, written_at: $written_at}' > "$tmp"
[ ! -e "$target" ] || { rm -f "$tmp"; echo "error: $target already exists" >&2; exit 1; }
mv "$tmp" "$target"
echo "$target"
