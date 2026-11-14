#!/usr/bin/env bash
# Offline test of .claude/lib/starter-fork-commit.sh against fixture repositories: a local starter
# with three commits, then a template copy, a clone, a brownfield copy and the failure cases.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/starter-fork-commit.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/starter fork.XXXXXX") || { echo "starter-fork-commit-test: FAIL — mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
die() { echo "starter-fork-commit-test: FAIL — fixture setup: $1"; exit 1; }
fail=0; CHECKS=0
check() { # <label> <dir> <expected exit> <expected stdout regex, or "" for no output>
  CHECKS=$((CHECKS + 1))
  local out rc
  out=$(cd "$2" && bash "$SCRIPT" "file://$T/starter" 2>"$T/err"); rc=$?
  if [ "$rc" != "$3" ] || { [ -z "$4" ] && [ -n "$out" ]; } \
     || { [ -n "$4" ] && ! printf '%s\n' "$out" | grep -Eq -- "$4"; }; then
    echo "FAIL [$1]: rc=$rc out='$out' err='$(cat "$T/err")'"; fail=1
  fi
}

# Starter: c1 → c2 → c3; c2 and c3 share the .claude/ tree, c3 changes .agents/ only.
mkdir -p "$T/starter/.claude" "$T/starter/.agents" || die mkdir
cd "$T/starter" && git init -q -b main . || die init
echo one > .claude/a.md; echo r1 > .agents/r.md; git add -A && git commit -qm c1 || die c1
echo two > .claude/a.md; git add -A && git commit -qm c2 || die c2
echo r3 > .agents/r.md; git add -A && git commit -qm c3 || die c3
C2=$(git rev-parse --short HEAD~1); C3=$(git rev-parse --short HEAD)

# 1. "Use this template": one squashed commit with c2's tree, later project commits on top.
mkdir "$T/tpl" && cd "$T/tpl" && git init -q -b main . || die tpl
git -C "$T/starter" archive HEAD~1 | tar -x -C "$T/tpl" && git add -A && git commit -qm init || die tpl-commit
echo app > app.txt && git add -A && git commit -qm app || die tpl-app
check template "$T/tpl" 0 "^$C2 [0-9]{4}-[0-9]{2}-[0-9]{2} root-tree$"

# 2. `git clone` at c2 plus project commits → history, not c3.
git clone -q "$T/starter" "$T/clone" && cd "$T/clone" && git reset -q --hard HEAD~1 || die clone
echo app > app.txt && git add -A && git commit -qm app || die clone-app
check clone "$T/clone" 0 "^$C2 .* history$"

# 3. A clone of the starter's tip.
git clone -q "$T/starter" "$T/tip" || die tip
check tip "$T/tip" 0 "^$C3 .* history$"

# 4. Brownfield: own history, .claude/ copied from c3 (identical tree) → no answer.
mkdir "$T/brown" && cd "$T/brown" && git init -q -b main . && echo src > src.txt && git add -A \
  && git commit -qm own || die brown
cp -R "$T/starter/.claude" "$T/starter/.agents" . && git add -A && git commit -qm harness || die brown-copy
check brownfield "$T/brown" 1 ""

# 5. Template edited before its first commit → no exact match.
mkdir "$T/edit" && cd "$T/edit" && git init -q -b main . || die edit
git -C "$T/starter" archive HEAD | tar -x -C "$T/edit" && echo x >> .claude/a.md && git add -A \
  && git commit -qm init || die edit-commit
check edited "$T/edit" 1 ""

# 6. `git init` with no commit yet.
mkdir "$T/empty" && git -C "$T/empty" init -q || die empty
check no-commits "$T/empty" 1 ""
grep -q "no commits" "$T/err" || { echo "FAIL [no-commits]: reason missing"; fail=1; }

# 7. Unreachable starter.
CHECKS=$((CHECKS + 1))
(cd "$T/tpl" && bash "$SCRIPT" "file://$T/missing" >/dev/null 2>"$T/err"); rc=$?
{ [ "$rc" = 1 ] && grep -q "cannot fetch" "$T/err"; } || { echo "FAIL [unreachable]: rc=$rc $(cat "$T/err")"; fail=1; }

# 8. Unknown ref.
CHECKS=$((CHECKS + 1))
(cd "$T/tpl" && bash "$SCRIPT" "file://$T/starter" nope >/dev/null 2>"$T/err"); rc=$?
{ [ "$rc" = 1 ] && grep -q "no ref nope" "$T/err"; } || { echo "FAIL [ref]: rc=$rc $(cat "$T/err")"; fail=1; }

[ "$fail" = 0 ] || { echo "starter-fork-commit-test: FAIL ($CHECKS checks)"; exit 1; }
echo "starter-fork-commit-test: OK ($CHECKS checks)"
