#!/usr/bin/env bash
# Offline unit test of the /wcag-audit runner (policy, criteria, evidence model, pack/ingest, read
# guard, renderer, deps, command/agent/settings contracts). No browser, no network, no engine cache.
# Runs wcag-audit.test.mjs (node:test).
#
# Usage: bash .claude/lib/tests/wcag-audit-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
command -v node >/dev/null 2>&1 || { echo "wcag-audit-test: FAIL — node missing"; exit 1; }
T=$(mktemp "${TMPDIR:-/tmp}/wcagunit.XXXXXX") || { echo "wcag-audit-test: FAIL — mktemp"; exit 1; }
trap 'rm -f "$T"' EXIT
node --test --test-reporter=tap "$ROOT/.claude/lib/tests/wcag-audit.test.mjs" >"$T" 2>&1
RC=$?
# node's exit status decides first: a run that crashes after some `ok` lines is a failure.
if [ "$RC" -ne 0 ] || grep -q '^not ok ' "$T" || ! grep -q '^ok ' "$T"; then
  cat "$T"
  echo "wcag-audit-test: FAIL (node exit $RC)"
  exit 1
fi
echo "wcag-audit-test: OK ($(grep -c '^ok ' "$T") checks)"
