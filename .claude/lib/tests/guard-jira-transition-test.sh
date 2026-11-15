#!/usr/bin/env bash
# Offline test for .claude/hooks/guard-jira-transition.sh: off by default and silent; on, a blank
# comment is refused; the per-project evidence rule; an invalid rule allows and says so on stdout;
# core settings.json registers the hook once, synchronously, for exactly that tool.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
HOOK="$ST/.claude/hooks/guard-jira-transition.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
P="$WORK/proj"; mkdir -p "$P/.claude"
export CLAUDE_PROJECT_DIR="$P"

fail() { echo "guard-jira-transition-test: FAIL — $*"; exit 1; }
N=0
call() {  # call <comment|-> [tool] [transition id] [key] → RC, OUT, ERR (- = no comment field)
  local c="$1" tool="${2:-mcp__atlassian__jira_transition_issue}" tid="${3:-31}" key="${4:-PROJ-7}"
  set +e
  jq -n --arg t "$tool" --arg c "$c" --arg i "$tid" --arg k "$key" \
    '{tool_name: $t, tool_input: ({issue_key: $k, transition_id: $i}
      + (if $c == "-" then {} else {comment: $c} end))}' \
    | bash "$HOOK" > "$WORK/out" 2> "$WORK/err"
  RC=$?; set -e; OUT=$(cat "$WORK/out"); ERR=$(cat "$WORK/err"); N=$((N + 1))
}
expect() { [ "$RC" = "$1" ] || fail "$2: exit $RC, expected $1 ($ERR)"; }
silent() { [ -z "$OUT" ] && [ -z "$ERR" ] || fail "$1: not silent (out: $OUT err: $ERR)"; }
profile() { printf '%s\n' "$1" > "$P/.claude/project-profile.json"; }

# (1) off: no profile, no key, false, a string "true", unreadable JSON, no jq → silent allow
rm -f "$P/.claude/project-profile.json"; call -; expect 0 "1 no profile"; silent "1 no profile"
profile '{"workflow": {}}'; call -; expect 0 "1 no key"; silent "1 no key"
profile '{"workflow": {"jira_transition_comment": false}}'; call ''; expect 0 "1 false"; silent "1 false"
profile '{"workflow": {"jira_transition_comment": "true"}}'; call ''; expect 0 "1 string"; silent "1 string"
profile '{not json'; call ''; expect 0 "1 bad json"; silent "1 bad json"
profile '{"workflow": {"jira_transition_comment": true}}'
mkdir -p "$WORK/nojq"; for b in bash cat; do ln -s "$(command -v $b)" "$WORK/nojq/$b"; done
set +e; printf '{}' | env PATH="$WORK/nojq" bash "$HOOK" > "$WORK/out" 2> "$WORK/err"; RC=$?; set -e
expect 0 "1 no jq"; [ ! -s "$WORK/out" ] && [ ! -s "$WORK/err" ] || fail "1 no jq: not silent"

# (2) on: blank or whitespace comment → 2 naming the switch; a comment → 0; other tools untouched
call -; expect 2 "2 no comment field"; case "$ERR" in *jira_transition_comment*) ;; *) fail "2: no switch named" ;; esac
call '   '; expect 2 "2 whitespace comment"
call 'Merged in PR 12, verified on staging'; expect 0 "2 comment"; silent "2 comment"
call '' mcp__atlassian__jira_update_issue; expect 0 "2 another tool"; silent "2 another tool"

# (3) evidence rule, per project and id
profile '{"workflow": {"jira_transition_comment": true,
  "jira_transition_evidence": {"PROJ:31": "Release-[0-9]+|no deploy"}}}'
call 'shipped in Release-42'; expect 0 "3 matching"
call 'NO DEPLOY — docs only'; expect 0 "3 case-insensitive"
call 'done'; expect 2 "3 not matching"; case "$ERR" in *Release-*) ;; *) fail "3: the pattern is not named" ;; esac
call 'done' mcp__atlassian__jira_transition_issue 21; expect 0 "3 another transition id"
call 'done' mcp__atlassian__jira_transition_issue 31 OTHER-3; expect 0 "3 the same id in another project"

# (3b) project wildcard "*:<id>": every project without its own string key; the exact key wins,
# an exact "" opts that project out, and the wildcard is per transition id
profile '{"workflow": {"jira_transition_comment": true, "jira_transition_evidence":
  {"*:31": "Release-[0-9]+", "PROJ:31": "no deploy", "FREE:31": ""}}}'
call 'done' mcp__atlassian__jira_transition_issue 31 OTHER-3; expect 2 "3b wildcard applies to another project"
case "$ERR" in *'["*:31"]'*) ;; *) fail "3b: the wildcard key is not named ($ERR)" ;; esac
call 'Release-7' mcp__atlassian__jira_transition_issue 31 OTHER-3; expect 0 "3b wildcard matching"
call 'no deploy' mcp__atlassian__jira_transition_issue 31 PROJ-7; expect 0 "3b exact key wins (its rule)"
call 'Release-7' mcp__atlassian__jira_transition_issue 31 PROJ-7; expect 2 "3b exact key wins (not the wildcard)"
case "$ERR" in *'["PROJ:31"]'*) ;; *) fail "3b: the exact key is not named ($ERR)" ;; esac
call 'done' mcp__atlassian__jira_transition_issue 31 FREE-1; expect 0 "3b exact empty string opts out"
call 'done' mcp__atlassian__jira_transition_issue 21 OTHER-3; expect 0 "3b wildcard is per transition id"

# (4) an invalid rule allows, and says so through a systemMessage
profile '{"workflow": {"jira_transition_comment": true, "jira_transition_evidence": {"PROJ:31": "(["}}}'
call 'done'; expect 0 "4 invalid regex"
[ "$(jq -r '.systemMessage' <<< "$OUT" 2>/dev/null)" != null ] || fail "4: no systemMessage ($OUT)"

# (5) core settings.json: registered once, exact matcher, synchronous
S="$ST/.claude/settings.json"
[ "$(jq '[.hooks.PreToolUse[] | select(.matcher == "mcp__atlassian__jira_transition_issue") | .hooks[]
  | select((.command | test("guard-jira-transition.sh")) and (.async // false) == false)] | length' "$S")" = 1 ] \
  || fail "5: settings.json does not register the hook once, synchronously"
[ "$(jq '[.hooks[]?[]?.hooks[]? | select((.command // "") | test("guard-jira-transition"))] | length' "$S")" = 1 ] \
  || fail "5: the hook is registered elsewhere too"

echo "guard-jira-transition-test: OK ($N cases)"
