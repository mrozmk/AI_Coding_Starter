#!/usr/bin/env bash
# Offline test of .claude/lib/fix-snapshot.sh: two snapshots around a change name exactly the
# changed paths (tracked edit, new untracked file, deletion), ignore ignored files, and leave the
# real index and working tree untouched.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/fix-snapshot.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fix snapshot.XXXXXX") || { echo "fix-snapshot-test: FAIL — mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
die() { echo "fix-snapshot-test: FAIL — fixture setup: $1"; exit 1; }
fail=0; CHECKS=0
expect() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || { echo "FAIL [$1]: got '$2', want '$3'"; fail=1; }; }

R="$T/repo"; mkdir -p "$R/src" && cd "$R" && git init -q -b main . || die init
printf 'ignored.log\n' > .gitignore
echo a > src/a.txt; echo b > src/b.txt; echo c > src/c.txt
git add -A && git commit -qm base || die commit
echo pre > src/a.txt            # dirt from an earlier iteration: in both snapshots, not in the delta
echo new > early.txt

index_before=$(git ls-files --stage | shasum)
before=$(bash "$SCRIPT") || die "snapshot 1"
expect same-tree "$(bash "$SCRIPT")" "$before"

echo fixed > src/b.txt          # tracked edit
echo t > src/new_test.txt       # untracked file
rm src/c.txt                    # deletion
echo x > ignored.log            # ignored — never part of the scope
after=$(bash "$SCRIPT") || die "snapshot 2"

expect changed-paths "$(git diff --name-only "$before" "$after" | tr '\n' ' ')" "src/b.txt src/c.txt src/new_test.txt "
expect index-untouched "$(git ls-files --stage | shasum)" "$index_before"
expect untracked-still-untracked "$(git status --porcelain -- src/new_test.txt)" "?? src/new_test.txt"

CHECKS=$((CHECKS + 1))
(cd "$T" && bash "$SCRIPT" >/dev/null 2>&1); [ $? = 2 ] || { echo "FAIL [not-a-repo]: expected exit 2"; fail=1; }

[ "$fail" = 0 ] || { echo "fix-snapshot-test: FAIL ($CHECKS checks)"; exit 1; }
echo "fix-snapshot-test: OK ($CHECKS checks)"
