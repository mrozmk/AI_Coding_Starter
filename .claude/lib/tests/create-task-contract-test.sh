#!/usr/bin/env bash
# Offline contract test of /create-task: the skill resolves the tracker through the adapter, routes
# github through its ops (never raw gh), jira through /jira Flow A, refuses tracker none, a team
# clone and a backlog Task before anything is written, and its frontmatter allows exactly the six
# adapter ops it calls. Also pins the pointers other texts carry. Text checks only — nothing is
# spawned, no tracker is called.
#
# Usage: bash .claude/lib/tests/create-task-contract-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

DIR=.claude/skills/create-task
SK="$DIR/SKILL.md"
SHAPE="$DIR/references/task-shape.md"
GHR="$DIR/references/github.md"
JR="$DIR/references/jira.md"
FAILS=()
N=0
check() {  # check <rc> <what>
  N=$((N + 1))
  if [ "$1" -eq 0 ]; then echo "PASS $2"; else FAILS+=("$2"); fi
}
has() { grep -qF -- "$2" "$ROOT/$1" 2>/dev/null; }
lacks() { [ -f "$ROOT/$1" ] && ! grep -qF -- "$2" "$ROOT/$1"; }
# line_after <file> <ERE> <after> → the first matching line number greater than <after>, or empty.
line_after() {
  grep -nE -- "$2" "$ROOT/$1" 2>/dev/null | cut -d: -f1 | awk -v a="$3" '$1 > a { print; exit }'
}
# ordered <file> <ERE>… → 0 when each pattern first matches after the previous one (fail closed).
ordered() {
  local f="$1" at=0 n
  shift
  for re in "$@"; do
    n="$(line_after "$f" "$re" "$at")"
    [ -n "$n" ] || return 1
    at="$n"
  done
}
allowed() { sed -n '2,/^---$/p' "$ROOT/$SK" 2>/dev/null | grep '^allowed-tools:'; }
# The adapter ops the skill text names, outside the frontmatter's allowed-tools line.
skill_ops() {
  [ -d "$ROOT/$DIR" ] || return 0
  find "$ROOT/$DIR" -type f -name '*.md' -print0 \
    | xargs -0 grep -h -v '^allowed-tools:' \
    | grep -oE 'team-tracker\.sh [a-z-]+' | sed 's/^team-tracker\.sh //' | sort -u
}

ok=0
for f in "$SK" "$SHAPE" "$GHR" "$JR"; do [ -f "$ROOT/$f" ] || ok=1; done
check "$ok" "skill files exist"

has "$SK" 'bash .claude/lib/team-tracker.sh which'
check $? "skill resolves the tracker through which"
{ has "$SK" 'create-issue --marker' || has "$GHR" 'create-issue --marker'; }
check $? "skill routes github through create-issue"
has "$SK" 'Flow A'
check $? "skill routes jira through /jira Flow A"
has "$SK" '/update-backlog' && has "$SK" 'tracker: none'
check $? "skill refuses tracker none with the way"

raw=0
if [ -d "$ROOT/$DIR" ]; then
  grep -rqE 'gh issue create|gh issue edit|gh project item-add' "$ROOT/$DIR" && raw=1
else raw=1; fi
check "$raw" "skill never calls raw gh"

AL="$(allowed)"
ops="$(skill_ops)"
ok=0
[ -n "$AL" ] && [ -n "$ops" ] || ok=1
for o in $ops; do printf '%s' "$AL" | grep -qF "team-tracker.sh $o" || ok=1; done
check "$ok" "frontmatter allows every adapter op the skill calls"

ok=0
[ -n "$ops" ] || ok=1
for o in $ops; do
  case "$o" in which|create-issue|add-labels|set-status|add-sub-issue|item-status) ;; *) ok=1 ;; esac
done
check "$ok" "skill calls only its six adapter ops"

want="$(printf '%s\n' 'Bash(bash .claude/lib/team-tracker.sh which)' \
  'Bash(bash .claude/lib/team-tracker.sh create-issue:*)' 'Bash(bash .claude/lib/team-tracker.sh add-labels:*)' \
  'Bash(bash .claude/lib/team-tracker.sh set-status:*)' 'Bash(bash .claude/lib/team-tracker.sh add-sub-issue:*)' \
  'Bash(bash .claude/lib/team-tracker.sh item-status:*)' | sort)"
got="$(printf '%s' "$AL" | grep -oE 'Bash\([^)]*\)' | sort)"
[ -n "$got" ] && [ "$got" = "$want" ]
check $? "frontmatter Bash patterns are exactly the six"

ordered "$SK" 'Refusals — stop before anything is written' '\.agents/team/team\.json' \
  'ask the Supervisor or the Advisor' '/jira sync' 'bash \.claude/lib/team-tracker\.sh which' \
  '<!-- create-task-intent:' '`--dry-run` → stop here' 'references/github\.md'
check $? "refusals come first and stop"

has "$SK" '.agents/team/session.json' && has "$SK" '.agents/team/team.json'
check $? "skill refuses in a team clone"
has "$SK" '/github-sync' && has "$SK" '/jira sync' && has "$SK" '<!-- backlog:'
check $? "skill refuses a backlog Task"
has "$SHAPE" 'no backtick and no `$(`'
check $? "title carries no backtick"
has "$SK" 'the execution controls of this invocation (`--dry-run`, `--review`) always apply'
check $? "execution controls apply on a retry"
has "$SK" '<!-- create-task-intent:' && has "$SK" 'a Jira draft is not replayable' \
  && has "$GHR" 'on `exists` no status is written' && has "$GHR" 'every `<!-- create-task:` line in it is removed'
check $? "retry replays the saved intent"
has "$SK" 'created via team-tracker.sh create-issue' && has "$SK" 'created via /jira Flow A'
check $? "report is per tracker"
has .claude/skills/jira/SKILL.md 'already rendered by `/create-task`' && has "$JR" 'verbatim'
check $? "jira keeps the drafted description"
has "$SK" '--dry-run' && has "$SK" 'created via team-tracker.sh create-issue'
check $? "skill has dry-run and the report line"
has "$GHR" '<!-- create-task:'
check $? "marker shape"
lacks .claude/settings.json 'team-tracker.sh create-issue'
check $? "shipped settings stay untouched"
has .agents/reference/roles/supervisor.md '/create-task'
check $? "supervisor names /create-task"
has .claude/commands/brainstorm.md '/create-task'
check $? "brainstorm names /create-task"
GW=.claude/team/tracker/github-wrapup.md
JW=.claude/team/tracker/jira-wrapup.md
has "$GW" "$SHAPE" && has "$JW" "$SHAPE" && has "$GW" 'create-followup --marker' \
  && has "$GW" 'Follow-up of #{{TICKET}} · origin #{{ORIGIN_TICKET}}' \
  && has "$JW" 'Follow-up of {{TICKET}} · origin {{ORIGIN_TICKET}}'
check $? "wrapup blocks use the task shape and keep their writer"
has .agents/reference/security-egress.md "$SK"
check $? "egress exceptions record the allowance"
has .claude/docs/guide.md '/create-task'
check $? "guide lists /create-task"

for f in "${FAILS[@]+"${FAILS[@]}"}"; do echo "FAIL [$f]"; done
[ "${#FAILS[@]}" -eq 0 ] || exit 1
echo "create-task-contract-test: OK ($N checks)"
