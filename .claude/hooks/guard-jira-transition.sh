#!/usr/bin/env bash
# PreToolUse guard for mcp__atlassian__jira_transition_issue: with the project switch on, every
# status change carries a comment, and an optional per-project transition rule can require evidence
# in it. Off unless `.claude/project-profile.json` says `workflow.jira_transition_comment: true`.
#
#   workflow.jira_transition_comment   true → a blank `comment` is refused (exit 2)
#   workflow.jira_transition_evidence  {"<PROJECT>:<transition id>": "<ERE>"} — the comment must match
#                                      (case-insensitive). Keyed by project: transition ids are
#                                      workflow-scoped. `"*:<id>"` applies to every project without
#                                      its own string key; an exact `""` opts a project out. Default: none.
#
# No jq, no profile, unreadable JSON, the switch not exactly true → silent exit 0, never a hook
# error. An invalid ERE allows the transition and says so through a JSON systemMessage (stderr of an
# exit-0 hook is not shown). Limits: it checks the call's argument, not that Jira stored the comment
# (a transition screen without the comment field drops it), and it sees only this tool — a status
# change through another tool (e.g. jira_update_issue with a transition, on newer MCP servers) is
# outside it. Synchronous.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
PAYLOAD=$(cat)
[ "$(jq -r '.tool_name // ""' <<< "$PAYLOAD" 2>/dev/null)" = mcp__atlassian__jira_transition_issue ] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(jq -r '.cwd // ""' <<< "$PAYLOAD" 2>/dev/null)}"
profile="$root/.claude/project-profile.json"
[ -f "$profile" ] || exit 0
[ "$(jq -r '.workflow.jira_transition_comment == true' "$profile" 2>/dev/null)" = true ] || exit 0

comment=$(jq -r '.tool_input.comment // ""' <<< "$PAYLOAD")
key=$(jq -r '.tool_input.issue_key // "?"' <<< "$PAYLOAD")
tid=$(jq -r '.tool_input.transition_id // "" | tostring' <<< "$PAYLOAD")
switch='workflow.jira_transition_comment in .claude/project-profile.json'

if [ -z "${comment//[[:space:]]/}" ]; then
  printf '%s\n' "Jira guard: the transition of $key without a comment is blocked." \
    "Pass comment= with the evidence (what changed, the PR, the verification). Switch: $switch." >&2
  exit 2
fi

# The exact `<PROJECT>:<id>` string wins (even ""), else `*:<id>`.
rkey=$(jq -r --arg k "${key%%-*}:$tid" --arg w "*:$tid" '.workflow.jira_transition_evidence
  | if (.[$k] | type) == "string" then $k elif (.[$w] | type) == "string" then $w else empty end' \
  "$profile" 2>/dev/null)
[ -n "$rkey" ] || exit 0
rule=$(jq -r --arg k "$rkey" '.workflow.jira_transition_evidence[$k]' "$profile")
[ -n "$rule" ] || exit 0
grep -Eiq -- "$rule" <<< "$comment"
case $? in
  0) exit 0 ;;
  1) printf '%s\n' "Jira guard: transition $tid of $key needs evidence in the comment matching: $rule" \
       "(workflow.jira_transition_evidence[\"$rkey\"] in .claude/project-profile.json)." >&2
     exit 2 ;;
  *) jq -cn --arg m "Jira guard: workflow.jira_transition_evidence[\"$rkey\"] is not a valid regex — the evidence check is skipped." \
       '{systemMessage: $m}'
     exit 0 ;;
esac
