#!/usr/bin/env bash
# Offline contract test of /maintain:refresh-brief's non-goals handling: PRD sources are found by
# heading (the template's section number is only a hint), a bare exclusion gets no invented reason,
# the "Non-goals about to vanish" stop fires for an absent or empty list and for an old item missing
# from the PRD's full list (one "same item" rule), the Step 6 warning matches, and the guide states
# the brief's 60-line cap. Text checks only; slices fail closed.
#
# Usage: bash .claude/lib/tests/refresh-brief-contract-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

RB=.claude/commands/maintain/refresh-brief.md
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

for f in "$RB" .claude/docs/guide.md; do
  [ -f "$ROOT/$f" ]; check $? "missing file $f"
done

# The helper itself: a missing end yields nothing, a mid-line mention is not the heading.
printf '## A\nx\n' > "$WORK/t1"; [ -z "$(slice "$WORK/t1" '## A' '## B')" ]; check $? "slice widens on a missing end"
printf 'see ## A\n## A\ny\n## B\n' > "$WORK/t2"; [ "$(slice "$WORK/t2" '## A' '## B')" = y ]; check $? "slice matches a mid-line mention"

S2=$(slice "$ROOT/$RB" '### 2. Read PRD' '### 3. Write `project-brief.md`')
S3=$(slice "$ROOT/$RB" '### 3. Write `project-brief.md`' '### 4. Decide on `business-model.md`')
S6=$(slice "$ROOT/$RB" '### 6. Report' '## Notes')
[ -n "$S2" ]; check $? "refresh-brief Step 2 slice not found"
[ -n "$S3" ]; check $? "refresh-brief Step 3 slice not found"
[ -n "$S6" ]; check $? "refresh-brief Step 6 slice not found"

while IFS= read -r n; do
  [ -n "$n" ] || continue; in_slice "$S2" "$n"; check $? "refresh-brief Step 2 lacks: $n"
done <<'EOF'
Find each by its heading
are only a hint
its §7 can be Tools / Features
may have no Goals section at all
EOF

while IFS= read -r n; do
  [ -n "$n" ] || continue; in_slice "$S3" "$n"; check $? "refresh-brief Step 3 lacks: $n"
done <<'EOF'
`<excluded thing>` alone when it gives a bare exclusion — never invent a reason
on the item or on the list's label
`+<N> more — <PRD path> → <the list's heading>`
No non-goals list, or an empty one → omit this section and Change test
no Goals section → from the in-scope list alone
When the PRD's Users & stakeholders section (§3 in the template) has a **Source precedence** block
**Non-goals about to vanish:**
this PRD's non-goals list is absent or empty
missing from the PRD's **full** list
the `+<N> more` line is not an item
Same item = the same excluded thing once list syntax (`- [ ]`), the reason and the horizon qualifier are set aside
doubt → treat it as missing
Never carry an old item over
EOF

! in_slice "$S3" 'and this PRD has no §4 list, stop before writing'; check $? "refresh-brief Step 3 still stops only for a missing §4 list"
! in_slice "$S3" '`<excluded thing> — <reason>`, in the PRD'"'"'s wording'; check $? "refresh-brief Step 3 still demands a reason for every non-goal"
in_slice "$S3" '**Hard cap: 60 lines of body content**'; check $? "refresh-brief Step 3 cap is not 60 lines"

in_slice "$S6" 'or it is empty — Non-goals and Change test omitted'; check $? "refresh-brief Step 6 warning does not cover an empty list"
in_slice "$S6" '← only when that list is absent or empty'; check $? "refresh-brief Step 6 warning condition"

grep -qF '60-line TL;DR' "$ROOT/.claude/docs/guide.md"; check $? "guide.md does not state the 60-line brief"
! grep -qF '50-line TL;DR' "$ROOT/.claude/docs/guide.md"; check $? "guide.md still states a 50-line brief"

for f in "${FAILS[@]+"${FAILS[@]}"}"; do echo "FAIL [$f]"; done
[ "${#FAILS[@]}" -eq 0 ] || exit 1
echo "refresh-brief-contract-test: OK ($N checks)"
