#!/usr/bin/env bash
# One matcher for "the Operator typed this in a supervised window". Sourced, never executed.
# Bash 3.2.
#   team_evidence_match <transcript> <text> <since> <id> <used uuids>
#     → the uuid of the newest typed user message at or after <since> that contains <text> and is
#       no doorbell (stop, gate, prompt, ask, attention, …), runner, team-watch or hc message line; a uuid already used by another answer
#       (space-separated list) counts only when that message names <id>. Nothing when no match.
# Callers: team-lead-decision.sh d_evidence (the TeamLead window) and team-lineage.sh consent (the
# Supervisor window). It raises the bar; it is not proof (team-lead.md §7).
# Its own file: team-lib.sh has no room, and the callers run from the clone and the main checkout.

team_evidence_match() {
  jq -r --arg x "$2" --arg since "$3" --arg id "$4" \
    --arg used "$5" '
    ($used | split(" ") | map(select(. != ""))) as $u
    | select(.type == "user" and ((.isMeta // false) | not) and ((.timestamp // "") >= $since))
    | (.uuid // "?") as $uid
    | (.message.content | if type == "string" then .
        elif type == "array" then (map(select(.type == "text") | .text) | join(" ")) else "" end) as $m
    | select($m != "" and ($m | contains($x))
        and ($m | test("^(stop |gate |prompt |ask |attention |inbox:|relaunched: |human-only |\\[team-run\\]|\\[team-watch |<hc from=)") | not))
    | select((($u | index($uid)) == null) or ($m | test("(^|[^A-Za-z0-9-])" + $id + "([^0-9]|$)")))
    | $uid' "$1" 2>/dev/null | tail -n 1
}
