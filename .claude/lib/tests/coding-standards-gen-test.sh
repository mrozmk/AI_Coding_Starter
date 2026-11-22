#!/usr/bin/env bash
# Offline test of the coding-standards generation chain: the config/CI scan
# (.claude/lib/standards-tools.mjs), the verifying renderer (.claude/lib/coding-standards-render.mjs)
# and the map-codebase workflow under a stub harness. Runs coding-standards-gen.test.mjs (node:test).
#
# Usage: bash .claude/lib/tests/coding-standards-gen-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
command -v node >/dev/null 2>&1 || { echo "coding-standards-gen-test: FAIL — node missing"; exit 1; }
T=$(mktemp "${TMPDIR:-/tmp}/csgen.XXXXXX") || { echo "coding-standards-gen-test: FAIL — mktemp"; exit 1; }
trap 'rm -f "$T"' EXIT
node --test --test-reporter=tap "$ROOT/.claude/lib/tests/coding-standards-gen.test.mjs" >"$T" 2>&1
if grep -q '^not ok ' "$T" || ! grep -q '^ok ' "$T"; then
  cat "$T"
  echo "coding-standards-gen-test: FAIL"
  exit 1
fi
echo "coding-standards-gen-test: OK ($(grep -c '^ok ' "$T") checks)"
