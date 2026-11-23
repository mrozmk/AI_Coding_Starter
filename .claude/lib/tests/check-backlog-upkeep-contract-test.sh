#!/usr/bin/env bash
# Offline contract test of /check-backlog's upkeep step: step 5a sits between the grill and the
# apply, reads upkeep.sh due --format json, dedupes against a live [upkeep:<id>] Task, asks Add /
# Not now, defers the decline past the last apply; the writes-nothing contract names the decline;
# quality-tasks.md carries the reminder marker and the Reminder Tasks section; backlog-check.mjs
# mirrors the marker; /brainstorm still skips an [upkeep: Task. Text checks only; slices fail closed.
#
# Usage: bash .claude/lib/tests/check-backlog-upkeep-contract-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CB=.claude/commands/check-backlog.md
UB=.claude/commands/update-backlog.md
BS=.claude/commands/brainstorm.md
QT=.claude/skills/backlog/quality-tasks.md
BC=.claude/lib/backlog-check.mjs
FAILS=()
N=0
check() {  # check <rc> <what>
  N=$((N + 1))
  [ "$1" -eq 0 ] || FAILS+=("$2")
}
# slice <file> <start line> <end line> — the lines strictly between two whole-line headings; empty
# when either is missing or the end does not follow the start (never a widened slice).
slice() {
  awk -v s="$2" -v e="$3" '!a && $0 == s { a = 1; next }
    a && $0 == e { f = 1; exit }
    a { b = b $0 "\n" }
    END { if (f) printf "%s", b }' "$1"
}
in_slice() { printf '%s' "$1" | grep -qF -- "$2"; }

for f in "$CB" "$UB" "$BS" "$QT" "$BC"; do
  [ -f "$ROOT/$f" ]; check $? "missing file $f"
done

# The helper itself: a missing end yields nothing, a mid-line mention is not the heading.
printf '## A\nx\n' > "$WORK/t1"; [ -z "$(slice "$WORK/t1" '## A' '## B')" ]; check $? "slice widens on a missing end"
printf 'see ## A\n## A\ny\n## B\n' > "$WORK/t2"; [ "$(slice "$WORK/t2" '## A' '## B')" = y ]; check $? "slice matches a mid-line mention"

# Step 5a exists, between the grill and the apply.
S5=$(slice "$ROOT/$CB" '## 5. Grill' '## 5a. Upkeep due')
S5A=$(slice "$ROOT/$CB" '## 5a. Upkeep due' '## 6. Apply')
[ -n "$S5" ]; check $? "check-backlog step 5a does not follow step 5"
[ -n "$S5A" ]; check $? "check-backlog step 5a slice not found before step 6"

while IFS= read -r n; do
  [ -n "$n" ] || continue; in_slice "$S5A" "$n"; check $? "check-backlog step 5a lacks: $n"
done <<'EOF'
`bash .claude/lib/upkeep.sh due --format json`
`ask: true`
`(withdrawn)`
is not `DONE`
`[upkeep:<id>]`
`upkeep <id>: already planned as <Task id>`
Upkeep due: `<command>` — `<reason>`. Add a backlog Task?
**Add the Task (Recommended)**
**Not now**
outside the grill's cap of 8
`add (tech)`
Reminder Tasks
one `D-n`
`bash .claude/lib/upkeep.sh decline <id>`
after the run's last apply
`Upkeep: not checked — <reason>`
`schema` equal to `1` and an `items` array
no item with `ask: true` → this step says nothing
write pending recovery
only after `/update-backlog` Phase 8 verified the write
several declines run one after another
EOF

grep -qF 'an upkeep decline (`upkeep.sh decline`, step 5a)' "$ROOT/$CB"; check $? "check-backlog intro does not name the upkeep decline"

S7=$(slice "$ROOT/$CB" '## 7. Post-fix review' '## 8. Cross-model review (Codex) — once')
[ -n "$S7" ]; check $? "check-backlog step 7 slice not found"
in_slice "$S7" "outside the run's"; check $? "check-backlog step 7 round-2 scope does not reach outside the run's scope"
in_slice "$S7" 'quality-tasks.md'; check $? "check-backlog step 7 SOURCES lacks quality-tasks.md"

S9=$(slice "$ROOT/$CB" '## 9. Report' '## 10. Record')
[ -n "$S9" ]; check $? "check-backlog step 9 slice not found"
in_slice "$S9" '`Upkeep:`'; check $? "check-backlog step 9 lacks the Upkeep line"

grep -qF 'BA direct decision (upkeep <id>: Add the Task)' "$ROOT/$CB"; check $? "check-backlog step 6 lacks the upkeep D-n source"

# quality-tasks.md: the reminder marker row and the Reminder Tasks section.
grep -qF '| `[upkeep:refresh-brief]` | `/maintain:refresh-brief` | reminder | `M` |' "$ROOT/$QT"; check $? "quality-tasks marker row for refresh-brief"
grep -qx '## Reminder Tasks' "$ROOT/$QT"; check $? "quality-tasks lacks the Reminder Tasks heading"
SR=$(slice "$ROOT/$QT" '## Reminder Tasks' '## Detail templates (`/setup:delivery-plan` step 2, `/update-backlog` under `**Detail:** full`)')
[ -n "$SR" ]; check $? "quality-tasks Reminder Tasks slice not found before Detail templates"
while IFS= read -r n; do
  [ -n "$n" ] || continue; in_slice "$SR" "$n"; check $? "quality-tasks Reminder Tasks lacks: $n"
done <<'EOF'
`[upkeep:<id>] Run <command>`
Quality & upkeep
upkeep: recorded <id> in <path>
EOF
DT=$(awk 'f { print } $0 == "## Detail templates (`/setup:delivery-plan` step 2, `/update-backlog` under `**Detail:** full`)" { f = 1 }' "$ROOT/$QT")
in_slice "$DT" '- **Reminder Task** — an unnumbered'; check $? "quality-tasks Detail templates lack the Reminder Task bullet"

grep -qF "'upkeep:refresh-brief': { kind: 'reminder'" "$ROOT/$BC"; check $? "backlog-check.mjs lacks the refresh-brief marker"
grep -qF 'planned: false }' "$ROOT/$BC"; check $? "backlog-check.mjs refresh-brief marker is not reminder-only"

grep -qF 'arrives placed' "$ROOT/$UB"; check $? "update-backlog Phase 4 lacks the placed upkeep intent"
grep -qF 'already planned as <Task id>' "$ROOT/$UB"; check $? "update-backlog Phase 4 lacks the upkeep dedupe"

grep -qF '(`[audit:` or `[upkeep:`' "$ROOT/$BS"; check $? "brainstorm Step 0 marker condition"
grep -qF 'not designed — skip it' "$ROOT/$BS"; check $? "brainstorm Step 0 skip"
grep -qF 'is a quality Task — run `<command>`' "$ROOT/$BS"; check $? "brainstorm Step 0 command line"

for f in "${FAILS[@]+"${FAILS[@]}"}"; do echo "FAIL [$f]"; done
[ "${#FAILS[@]}" -eq 0 ] || exit 1
echo "check-backlog-upkeep-contract-test: OK ($N checks)"
