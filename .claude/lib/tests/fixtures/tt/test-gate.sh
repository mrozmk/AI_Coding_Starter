#!/usr/bin/env bash
#
# test-gate.sh — unit-test gate with a known-failures baseline.
#
# WHY: Tests.UnitTests carried 174 stale failures on develop-netcore7 (CI had test steps removed),
# so a plain `dotnet test` gate fails on every change. This gate fails only on NEW failures.
# The baseline shrinks as tests are repaired; it must never grow except by an explicit owner decision.
#
# Usage: bash .claude/lib/test-gate.sh            # run gate (build must have run first)
#        bash .claude/lib/test-gate.sh --update   # rewrite the baseline from the current run
#
# Integration tests (Tests.IntegrationTests) are excluded: they need the docker infrastructure.

set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
bash "$ROOT/.claude/lib/tests/cost-tests.sh" || exit $?
BASELINE="$ROOT/.agents/reference/test-baseline.txt"
OUT="$(mktemp -d)"
PROJECTS=(
  Tests/Tests.UnitTests
  Tests/TakeTask.AF.RecalculateTodoTasks.UnitTests
  Tests/TakeTask.AF.Reporting.UnitTests
  Tests/TakeTask.AF.Users.UnitTests
  Tests/TakeTask2.NoSQL.UnitTests
  Tests/TakeTask.Workers.DenormalizeNoSQL.UnitTests
  Tests/TakeTask.AF.Monitoring.UnitTests
  Tests/TakeTask.AF.JobsRestarter.UnitTests
)

for p in "${PROJECTS[@]}"; do
  name="$(basename "$p")"
  dotnet test "$ROOT/$p" --no-build -nologo -v q --logger "trx;LogFileName=$OUT/$name.trx" >/dev/null 2>&1
  [ -f "$OUT/$name.trx" ] || { echo "test-gate: no results for $p (build first?)"; exit 2; }
done

python3 - "$OUT" "$BASELINE" "${1:-}" <<'EOF'
import glob, sys, xml.etree.ElementTree as ET
out, baseline_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
ns = {'t': 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010'}
failed, total, passed = set(), 0, 0
for trx in glob.glob(f'{out}/*.trx'):
    root = ET.parse(trx).getroot()
    for r in root.iterfind('.//t:UnitTestResult', ns):
        total += 1
        if r.get('outcome') == 'Passed':
            passed += 1
        elif r.get('outcome') == 'Failed':
            failed.add(r.get('testName'))
if mode == '--update':
    with open(baseline_path, 'w') as f:
        f.write('# Known failing unit tests (test-gate.sh). Shrink only; see TESTING.md.\n')
        f.writelines(n + '\n' for n in sorted(failed))
    print(f'test-gate: baseline rewritten with {len(failed)} failures')
    sys.exit(0)
known = {l.rstrip('\n') for l in open(baseline_path) if l.strip() and not l.startswith('#')}
new, fixed = sorted(failed - known), sorted(known - failed)
print(f'test-gate: total {total}, passed {passed}, failed {len(failed)} '
      f'(baseline {len(known)}, new {len(new)}, now passing {len(fixed)})')
for n in new:
    print(f'  NEW FAILURE: {n}')
if fixed:
    print(f'  {len(fixed)} baseline test(s) now pass — remove them from test-baseline.txt')
sys.exit(1 if new else 0)
EOF
