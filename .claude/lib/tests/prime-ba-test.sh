#!/usr/bin/env bash
# Offline unit test of .claude/lib/prime-ba.mjs (selector, extracts, paging, pending queue, code roots). No network.
# Runs prime-ba.test.mjs (node:test).
#
# Usage: bash .claude/lib/tests/prime-ba-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
command -v node >/dev/null 2>&1 || { echo "prime-ba-test: FAIL — node missing"; exit 1; }
T=$(mktemp "${TMPDIR:-/tmp}/primeba.XXXXXX") || { echo "prime-ba-test: FAIL — mktemp"; exit 1; }
trap 'rm -f "$T"' EXIT
node --test --test-reporter=tap "$ROOT/.claude/lib/tests/prime-ba.test.mjs" >"$T" 2>&1
RC=$?
# node's exit status decides first: a run that crashes after some `ok` lines is a failure.
if [ "$RC" -ne 0 ] || grep -q '^not ok ' "$T" || ! grep -q '^ok ' "$T"; then
  cat "$T"
  echo "prime-ba-test: FAIL (node exit $RC)"
  exit 1
fi
echo "prime-ba-test: OK ($(grep -c '^ok ' "$T") checks)"
