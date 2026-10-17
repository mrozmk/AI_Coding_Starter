#!/usr/bin/env bash
# Unit tests for the token-usage tool (.claude/lib/costs). Optional arg: unittest -k pattern.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
COSTS="$ROOT/.claude/lib/costs"
OUT=$(mktemp)
trap 'rm -f "$OUT" || true' EXIT
args=(-m unittest discover -s "$COSTS/tests" -t "$COSTS" -p 'test_*.py')
[ $# -gt 0 ] && args+=(-k "$1")
rc=0; python3 "${args[@]}" >"$OUT" 2>&1 || rc=$?
cat "$OUT"
ran=$(sed -nE 's/^Ran ([0-9]+) tests?.*/\1/p' "$OUT")
if [ "$rc" -ne 0 ] || [ "${ran:-0}" -eq 0 ]; then
  echo "cost-tests: FAIL (rc=$rc, ran=${ran:-0})" >&2
  exit 1
fi
echo "cost-tests: OK ($ran tests)"
