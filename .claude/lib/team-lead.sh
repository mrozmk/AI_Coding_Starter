#!/usr/bin/env bash
# The per-run TeamLead's identity and permission profile.
# Usage: bash .claude/lib/team-lead.sh materialize <team>   (from the main checkout)
#        bash .claude/lib/team-lead.sh whoami                (exit 0 when the caller is the lead)
#   materialize writes <clone>/.agents/team/teamlead.settings.json (mode 600): the role profile
#   .claude/team/sessions/TeamLead-run.settings.json unioned with the project and local deny/ask
#   rules, the PR host's update verbs denied for teams.pr_provider, guard-teamlead-write.sh
#   registered for Edit|Write|NotebookEdit.
#   e.g. bash .claude/lib/team-lead.sh materialize alfa
# Contract: .agents/reference/team-lead.md
set -euo pipefail

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
. "$(dirname "$0")/team-lib.sh"

# Same union as supervisor-sessions.sh materialize, written into the clone instead of the main
# checkout's watch/profiles: the lead runs in the clone, the global roles do not.
materialize() {
  local team="$1" root clone loc out pr='[]'
  team_check_name "$team" || exit 2
  root="$(team_root)"
  [ ! -f "$root/.agents/team/team.json" ] \
    || { echo "error: team clone — run team-lead.sh materialize from the main checkout" >&2; exit 1; }
  team_profile_load "$root"
  clone="$(team_clone_dir "$team" "$root")"
  [ -f "$clone/.agents/team/team.json" ] || { echo "error: $clone is not a team clone" >&2; exit 1; }
  case "$TEAM_PR_PROVIDER" in
    github) pr='["Bash(gh pr merge*)","Bash(gh pr edit*)"]' ;;
    azure-devops) pr='["Bash(az repos pr update*)"]' ;;
  esac
  loc="$root/.claude/settings.local.json"
  [ -f "$loc" ] || loc=/dev/null
  out="$clone/.agents/team/teamlead.settings.json"
  ( umask 077
    jq -s --argjson pr "$pr" '
      (.[2] // {}) as $l | [.[0], .[1], $l] as $all
      | {env: .[0].env,
         permissions: {allow: (.[0].permissions.allow // []),
                       deny: ([$all[] | .permissions.deny // [] | .[]] + $pr | unique),
                       ask: ([$all[] | .permissions.ask // [] | .[]] | unique)},
         hooks: {PreToolUse: [{matcher: "Edit|Write|NotebookEdit", hooks: [{type: "command",
           onFailure: "block",
           command: "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard-teamlead-write.sh\""}]}]}}' \
      "$root/.claude/team/sessions/TeamLead-run.settings.json" "$root/.claude/settings.json" "$loc" \
      > "$out.tmp"
    mv "$out.tmp" "$out" )
  jq -r '"profile TeamLead-run: \(.permissions.deny | length) deny,"
    + " \(.permissions.ask | length) ask, \(.permissions.allow | length) allow"' "$out"
}

case "$1" in
  materialize) [ $# -eq 2 ] || usage; materialize "$2" ;;
  whoami) [ $# -eq 1 ] || usage; team_lead_caller ;;
  *) usage ;;
esac
