#!/usr/bin/env bash
# Offline test for the trunk-writer rule of .claude/hooks/guard-team-verdict.sh: run from the repo
# root. A role session (session.json present) refuses every command naming a trunk writer unless it
# is an inspection form; a clone between stages and the main checkout pass; the verdict rule holds.
set -uo pipefail
H="$PWD/.claude/hooks/guard-team-verdict.sh"; fail=0; pass=0
[ -f "$H" ] || { echo "FAIL hook present"; exit 1; }
echo "PASS hook present"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/role/.agents/team" "$D/between/.agents/team" "$D/main"
echo '{}' > "$D/role/.agents/team/team.json"
echo '{"role":"coder"}' > "$D/role/.agents/team/session.json"
echo '{}' > "$D/between/.agents/team/team.json"

run() { # <fixture> <command> → exit code; stderr in $D/err
  # A file, not a pipe: the hook may exit before reading stdin, and pipefail would report SIGPIPE.
  jq -nc --arg c "$2" '{session_id:"s-test",tool_name:"Bash",tool_input:{command:$c}}' > "$D/payload"
  (cd /tmp && CLAUDE_PROJECT_DIR="$D/$1" bash "$H") <"$D/payload" 2>"$D/err" >/dev/null
}
expect() { # <rc> <fixture> <stderr text or ""> <command>
  local rc; run "$2" "$4"; rc=$?
  if [ "$rc" = "$1" ] && { [ -z "$3" ] || grep -qF "$3" "$D/err"; }; then
    pass=$((pass + 1)); echo "PASS [$2 → $1] $4"
  else
    echo "FAIL [$2] $4 (rc $rc, expected $1; stderr: $(cat "$D/err"))"; fail=1
  fi
}
SUP="are the Supervisor's"
refused() { expect 2 role "$SUP" "$1"; }
passes() { expect 0 role "" "$1"; }

# --- role session: every non-inspection form is refused
refused 'bash .claude/lib/team-integrate.sh beta'
refused 'bash /abs/x/.claude/lib/team-merge-check.sh beta'
refused 'sh .claude/lib/team-integrate-lock.sh acquire main --owner x'
refused 'TEAM_X=1 bash .claude/lib/team-integrate.sh beta'
refused 'env bash .claude/lib/team-integrate.sh beta'
# role of team A → team B's accepted PR through the wrapper (its child is invisible to a hook)
refused 'cd /main && bash .claude/lib/team-automerge-check.sh alfa'
refused "bash -c 'bash .claude/lib/team-integrate.sh beta'"
refused "/bin/bash -c 'bash .claude/lib/team-integrate.sh beta'"
refused 'echo "$(bash .claude/lib/team-integrate.sh beta)"'
refused 'x=$(bash .claude/lib/team-merge-check.sh beta)'
refused 'bash ".claude/lib/team-integrate.sh" beta'
refused './.claude/lib/team-integrate.sh beta'
refused 'source .claude/lib/team-integrate-lock.sh'
refused "bash -n -c 'bash .claude/lib/team-integrate.sh'"
refused "git -c alias.x='!bash .claude/lib/team-integrate.sh' x"

# --- role session: inspection forms pass
passes 'bash -n .claude/lib/team-integrate.sh'
passes 'cat .claude/lib/team-merge-check.sh'
passes 'grep -n lock .claude/lib/team-integrate.sh'
passes 'git add .claude/lib/team-integrate.sh .claude/lib/team-automerge-check.sh'
passes 'git -C ../AI_Coding_Starter diff .claude/lib/team-integrate.sh'
passes 'git commit -m "fix(team): team-integrate.sh x"'
passes 'bash .claude/lib/team-integrate-lib.sh'
passes 'git status'

# --- no role session: no-op
expect 0 between "" 'bash .claude/lib/team-integrate.sh beta'
expect 0 main "" 'bash .claude/lib/team-integrate.sh beta'

# --- the verdict rule is intact
expect 2 role "not it (refused)" 'TEAM_SESSION_ROLE=TeamLead bash .claude/lib/team-verdict.sh plan approve'

echo "passed=$pass"
[ "$fail" = 0 ] || { echo "guard-team-trunk-test: FAILED"; exit 1; }
echo "guard-team-trunk-test: OK"
