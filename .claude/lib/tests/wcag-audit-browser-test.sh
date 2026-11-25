#!/usr/bin/env bash
# Offline integration test of /wcag-audit: the runner as a subprocess against the planted-defect
# fixture on loopback, with the installed engine cache and Chrome. Runs wcag-audit-browser.test.mjs.
# Fails with doctor's reason when the cache or the sandboxed browser is not usable.
#
# Usage: bash .claude/lib/tests/wcag-audit-browser-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
command -v node >/dev/null 2>&1 || { echo "wcag-audit-browser-test: FAIL — node missing"; exit 1; }
DOCTOR="$(node "$ROOT/.claude/skills/wcag-audit/runner/audit.mjs" doctor --json --launch 2>&1)"
if [ $? -ne 0 ]; then
  echo "$DOCTOR"
  echo "wcag-audit-browser-test: FAIL — engine cache or browser not ready"
  exit 1
fi
T=$(mktemp "${TMPDIR:-/tmp}/wcagbrowser.XXXXXX") || { echo "wcag-audit-browser-test: FAIL — mktemp"; exit 1; }
trap 'rm -f "$T"' EXIT
node --test --test-concurrency=1 --test-reporter=tap "$ROOT/.claude/lib/tests/wcag-audit-browser.test.mjs" >"$T" 2>&1
RC=$?
# node's exit status decides first: a run that crashes after some `ok` lines is a failure.
if [ "$RC" -ne 0 ] || grep -q '^not ok ' "$T" || ! grep -q '^ok ' "$T"; then
  cat "$T"
  echo "wcag-audit-browser-test: FAIL (node exit $RC)"
  exit 1
fi
echo "wcag-audit-browser-test: OK ($(grep -c '^ok ' "$T") checks)"
