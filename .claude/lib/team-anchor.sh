#!/usr/bin/env bash
# Runner anchor: <main>/.agents/team/anchors/<team>.json, the trusted copy of a team's
# ticket/branch/line, live session and accepted planner revision. Sourced from the MAIN checkout
# only (team-new, team-next, team-run) — the clone's copy is role-writable. Bash 3.2; the caller
# sets its own shell options. Readers: team_prompt_classes.py (team-mode.md §2).

team_anchor_file() { echo "$1/.agents/team/anchors/$2.json"; }

# team_anchor_put <file> <jq filter> [jq args…] — read ({} when absent), filter, write atomically.
team_anchor_put() {
  local f="$1" filter="$2"; shift 2
  mkdir -p "$(dirname "$f")" || return 1
  { cat "$f" 2>/dev/null || echo '{}'; } \
    | jq "$@" "(if type == \"object\" then . else {} end) | $filter" > "$f.tmp.$$" \
    && mv "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; return 1; }
}

# Usage: team_anchor_init <main> <team> <clone> — after team_write_json; a new ticket replaces all.
team_anchor_init() {
  local f j="$3/.agents/team/team.json"
  f="$(team_anchor_file "$1" "$2")"
  [ -f "$j" ] || return 1
  rm -f "$f"
  # `clone` (physical path) is how team_prompt_classes.py finds the team of a clone: the
  # directory name follows teams.clone_name and cannot be parsed back into the team name.
  team_anchor_put "$f" '{team: $t.team, ticket: $t.ticket, branch: $t.branch, line: $t.line,
    base_sha: $t.base_sha, clone: $clone, written_at: $now}' \
    --argjson t "$(jq -c . "$j")" --arg clone "$(cd "$3" && pwd -P)" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Usage: team_anchor_launch <main> <team> <clone> <run> <role> <attempt> <session_id>
# Ticket/branch/line are never rewritten here: a clone team.json that differs marks a mismatch.
team_anchor_launch() {
  local f j="$3/.agents/team/team.json"
  f="$(team_anchor_file "$1" "$2")"
  [ -f "$j" ] || return 1
  [ -f "$f" ] || team_anchor_init "$1" "$2" "$3" || return 1
  team_anchor_put "$f" '(if .ticket != $t.ticket or .branch != $t.branch or .line != $t.line
      then .mismatch = true else . end)
    | (if .run != $run then del(.planner) else . end)
    | .run = $run | .role = $role | .attempt = $attempt | .session_id = $sid
    | .launched_at = $now' \
    --argjson t "$(jq -c . "$j")" --arg run "$4" --arg role "$5" --argjson attempt "$6" \
    --arg sid "$7" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Usage: team_anchor_planner <main> <team> <record> — an accepted planner record of the run.
team_anchor_planner() {
  local f r="$3"
  f="$(team_anchor_file "$1" "$2")"
  [ -f "$f" ] && [ "$(jq -r .role "$r" 2>/dev/null)" = planner ] || return 0
  team_anchor_put "$f" 'if .run != $r.run or (.planner.run // "") == $r.run then .
    else .planner = {run: $r.run, record: $base, output_rev: $r.output_rev,
      artifacts: ($r.artifacts // [])} end' \
    --argjson r "$(jq -c . "$r")" --arg base "$(basename "$r")"
}
