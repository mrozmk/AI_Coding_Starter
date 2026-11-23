#!/usr/bin/env bash
# One matcher for "the Operator typed this in a supervised window". Sourced, never executed.
# Bash 3.2.
#   team_evidence_match <transcript> <text> <since> <id> <used uuids> [exact]
#     → the uuid of the newest typed user message at or after <since> that contains <text> (with
#       `exact`: equals it, both trimmed — an ask-bound decision's whole reply) and is no machine
#       line (TEAM_EVIDENCE_MACHINE_RE: a doorbell, runner, team-watch, hc or [peer] line); a uuid
#       already used by another answer (space-separated list) counts only when that message names
#       <id>. Nothing when no match.
#   team_evidence_latest <transcript> <team> <d-n> <since>
#     → "<uuid>\t<trimmed message>" of the newest typed, non-machine user message at or after
#       <since> addressed to that decision (`<team> <d-n>` first); nothing when none. A multi-line
#       newest message prints an empty text: it still wins, so no older one-line reply matches.
#   team_evidence_machine_line <text> → 0 when the text is a machine line.
# Callers: team-lead-decision.sh d_evidence (the TeamLead window) and decision relay (the
# Supervisor window), team-lineage.sh consent (the Supervisor window), session-host-lib.sh
# sh_send / sh_type (the [peer] marker). It raises the bar; it is not proof (team-lead.md §7).
# Its own file: team-lib.sh has no room, and the callers run from the clone and the main checkout.

# Every line a script or a peer session puts into a supervised window starts with one of these.
TEAM_EVIDENCE_MACHINE_RE='^(stop |gate |prompt |ask |attention |inbox:|relaunched: |human-only |rejected |continue granted |round |close refused: |relayed: |\[peer\] |\[team-run\]|\[team-watch |<hc from=)'

team_evidence_machine_line() { [[ "$1" =~ $TEAM_EVIDENCE_MACHINE_RE ]]; }

team_evidence_match() {
  jq -r --arg x "$2" --arg since "$3" --arg id "$4" \
    --arg used "$5" --arg mode "${6:-}" --arg re "$TEAM_EVIDENCE_MACHINE_RE" '
    def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
    ($used | split(" ") | map(select(. != ""))) as $u
    | select(.type == "user" and ((.isMeta // false) | not) and ((.timestamp // "") >= $since))
    | (.uuid // "?") as $uid
    | (.message.content | if type == "string" then .
        elif type == "array" then (map(select(.type == "text") | .text) | join(" ")) else "" end) as $m
    | select($m != "" and (if $mode == "exact" then ($m | trim) == ($x | trim) else ($m | contains($x)) end)
        and ($m | test($re) | not))
    | select((($u | index($uid)) == null) or ($m | test("(^|[^A-Za-z0-9-])" + $id + "([^0-9]|$)")))
    | $uid' "$1" 2>/dev/null | tail -n 1
}

team_evidence_latest() {
  jq -r --arg team "$2" --arg id "$3" --arg since "$4" --arg re "$TEAM_EVIDENCE_MACHINE_RE" '
    select(.type == "user" and ((.isMeta // false) | not) and ((.timestamp // "") >= $since))
    | (.uuid // "?") as $uid
    | (.message.content | if type == "string" then .
        elif type == "array" then (map(select(.type == "text") | .text) | join(" ")) else "" end) as $m
    | select($m != "" and ($m | test($re) | not))
    | ($m | sub("^\\s+"; "") | sub("\\s+$"; "")) as $t
    | select($t | test("^" + $team + "[[:space:]]+" + $id + "([[:space:]]|$)"))
    | "\($uid)\t\(if ($t | contains("\n")) then "" else $t end)"' "$1" 2>/dev/null | tail -n 1
}
