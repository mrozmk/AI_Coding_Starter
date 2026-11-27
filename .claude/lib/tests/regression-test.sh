#!/usr/bin/env bash
# Offline unit test of the opt-in regression kit (.claude/lib/regression/: catalog validator and
# status matrix, computed automation state, setup.mjs catalog|baseline|check|env, config, templates,
# the environment policy and selection, the request guard against a local 127.0.0.1 stub, the run).
# No browser, no external network, fixture and temp roots only. Runs every regression*.test.mjs
# (node:test).
#
# Usage: bash .claude/lib/tests/regression-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
command -v node >/dev/null 2>&1 || { echo "regression-test: FAIL — node missing"; exit 1; }
T=$(mktemp "${TMPDIR:-/tmp}/regrunit.XXXXXX") || { echo "regression-test: FAIL — mktemp"; exit 1; }
trap 'rm -f "$T"' EXIT
node --test --test-reporter=tap "$ROOT"/.claude/lib/tests/regression*.test.mjs >"$T" 2>&1
RC=$?
# node's exit status decides first: a run that crashes after some `ok` lines is a failure.
if [ "$RC" -ne 0 ] || grep -q '^not ok ' "$T" || ! grep -q '^ok ' "$T"; then
  cat "$T"
  echo "regression-test: FAIL (node exit $RC)"
  exit 1
fi
# Every named case in the suite log (skip markers included): the gate needs per-case evidence.
grep -E '^(ok|not ok) ' "$T"
echo "regression-test: OK ($(grep -c '^ok ' "$T") checks)"
