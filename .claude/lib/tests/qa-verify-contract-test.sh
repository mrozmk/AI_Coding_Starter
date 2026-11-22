#!/usr/bin/env bash
# Offline contract test of /qa-verify's run record: the two hard gates, registry §7 (dispositions,
# the record template and its rules, both marker types), the criterion fingerprint — extracted from
# the registry and run on fixed vectors, so the test runs the same bytes the command runs — the
# re-check rules, Phase 3's one-pass decisions and one approval, and the neighbouring contracts.
# Text and pipeline checks only — nothing is spawned, no tracker is called.
#
# Usage: bash .claude/lib/tests/qa-verify-contract-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CMD=.claude/commands/qa-verify.md
REG=.agents/reference/qa-evidence-families.md
FAILS=()
N=0
check() {  # check <rc> <what>
  N=$((N + 1))
  [ "$1" -eq 0 ] || FAILS+=("$2")
}
has() { grep -qF -- "$2" "$ROOT/$1"; }
lacks() { ! grep -qF -- "$2" "$ROOT/$1"; }
pins() {  # pins <file> <label> — every non-empty stdin line must occur in <file>
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    has "$1" "$line"; check $? "$2: $line"
  done
}

for f in "$CMD" "$REG" .agents/reference/jira-mcp-atlassian.md .agents/reference/tracker-comments.md \
         .claude/lib/tracker-snapshot.mjs; do
  [ -f "$ROOT/$f" ]; check $? "missing file $f"
done

# ---- hard gates: each block whole, byte for byte ------------------------------------------------
gate() {
  awk -v n="$1" '/^<HARD-GATE>$/ { c++; if (c == n) f = 1 } f { print } f && /^<\/HARD-GATE>$/ { exit }' "$ROOT/$CMD"
}
want1=$(cat <<'EOF'
<HARD-GATE>
**Nothing runs before Phase 1 is approved.** No verifier is spawned, no browser is driven, no probe is dispatched until every AC has been classified and the human has explicitly approved the classification table. Correcting a misclassification before verification costs one line; after it, the whole run was spent answering the wrong question.
</HARD-GATE>
EOF
)
want2=$(cat <<'EOF'
<HARD-GATE>
**QA never mutates.** No source edits. No mutating git. No editing the AC text — not to clarify it, not to fix a typo. No transitioning the issue's status. **On finding a defect, record a `FAIL` with a severity and keep verifying — never fix it.** A proposed fix appears only as text in the row's notes. The single permitted outward write is the evidence comment on the tracker, after explicit human approval. This boundary has no exception: a QA run that repairs what it inspects has destroyed the evidence it exists to produce.
</HARD-GATE>
EOF
)
[ "$(gate 1)" = "$want1" ]; check $? "hard gate 1 is not verbatim"
[ "$(gate 2)" = "$want2" ]; check $? "hard gate 2 is not verbatim"

# ---- registry §7 ---------------------------------------------------------------------------------
pins "$REG" "registry" <<'EOF'
## 1. The evidence families  `[framework]`
## 2. Verifier roster  `[project]`
## 3. Semantic classification signals  `[framework]`
## 4. Worked examples  `[framework]`
## 5. Not observable in this repo  `[project]`
## 6. Canonical output contract  `[framework]`
## 7. Router dispositions and the run record  `[framework]`
Framework sections (§1, §3, §4, §6, §7)
`CITED`
`DEFERRED → <KEY>`
`ENV`
Merge order for one criterion: `FAIL` › `ENV` › `NEEDS-HUMAN` › `DEFERRED` › `PASS` / `CITED`.
`PASS (carried from <YYYY-MM-DD>)`
`CITED (carried from <YYYY-MM-DD>)`
qa-verify:v1 deferral src=<SRC> row=<id> fp=<fp>
A deferral marker is never a record candidate.
`- <id> [<6 lowercase hex>] — <disposition>[ (carried from <YYYY-MM-DD>)][ / <severity>] — …`
Not verifiable now — environment
select first, then validate
The **newest** candidate is the record
an invalid newest record is never skipped in favour of an older valid one
counts that disagree with the rows
its `build=` is `-` or 7–40 lowercase hex digits
EOF

# Headings outside fenced blocks: ## 1.…7. in order, §7 the last level-two heading, ### 1a. inside §1.
HEADS=$(awk '/^```/ { fence = !fence; next } !fence && /^##+ / { print NR ":" $0 }' "$ROOT/$REG")
NUMS=$(printf '%s\n' "$HEADS" | sed -n 's/^[0-9]*:## \([0-9][0-9]*\)\. .*/\1/p' | tr '\n' ' ')
[ "$NUMS" = "1 2 3 4 5 6 7 " ]; check $? "registry: numbered level-two headings are not 1..7 in order (got: $NUMS)"
LAST2=$(printf '%s\n' "$HEADS" | grep -E '^[0-9]+:## ' | tail -1 | cut -d: -f2-)
[ "$LAST2" = '## 7. Router dispositions and the run record  `[framework]`' ]; check $? "registry: §7 is not the last level-two heading"
L1=$(printf '%s\n' "$HEADS" | grep -E '^[0-9]+:## 1\. ' | cut -d: -f1)
L1A=$(printf '%s\n' "$HEADS" | grep -E '^[0-9]+:### 1a\. ' | cut -d: -f1)
L2=$(printf '%s\n' "$HEADS" | grep -E '^[0-9]+:## 2\. ' | cut -d: -f1)
[ -n "$L1" ] && [ -n "$L1A" ] && [ -n "$L2" ] && [ "$L1" -lt "$L1A" ] && [ "$L1A" -lt "$L2" ]
check $? "registry: ### 1a. is not between ## 1. and ## 2."

# The record template: the first fenced markdown block after ### 7b., whole and in order.
got_tpl=$(awk '/^### 7b\./ { s = 1 } s && /^```markdown$/ { f = 1; next } f && /^```$/ { exit } f { print }' "$ROOT/$REG")
want_tpl=$(cat <<'EOF'
## QA verification — <ticket or feature title>

- Run: <UTC date> · <first | re-check of <date> | light> · group: <keys, or single>
- Environment: <host> (<reason>) · build: <sha | skew state>
- Criteria from: <ticket description | spec path> (<n> criteria)

### Criteria
- <id> [<fp>] — PASS — <family> — <observed value, one line>
- <id> [<fp>] — FAIL / <blocker|major|minor> — <family> — <observed value; the clause it contradicts>
- <id> [<fp>] — CITED — task ledger: met (<file:line>)
- <id> [<fp>] — DEFERRED → <KEY> — <what must land there first>
- <id> [<fp>] — ENV — <what in the environment is not ready, and how that was shown>
- <id> [<fp>] — NEEDS-HUMAN — <reason>

### Feature path
- F1 — PASS — <steps in one line> (<from spec … | derived>)

### Outside the criteria
- <observation, with the ticket it concerns when known>

**Blockers: <n>.** <Acceptable — move the ticket yourself | Not acceptable | Not verifiable now — environment>
qa-verify:v1 record run=<utc> ticket=<KEY> mode=<first|recheck|light> group=<id|-> build=<sha|-> pass=<n> fail=<n> cited=<n> deferred=<n> env=<n> needs-human=<n>
EOF
)
[ "$got_tpl" = "$want_tpl" ]; check $? "registry §7b: the record template is not verbatim or not in order"

# ---- the fingerprint: extract the registry block and run it --------------------------------------
awk '/^<!-- qa-fingerprint:end -->$/{exit} f; /^<!-- qa-fingerprint:begin -->$/{f=1}' "$ROOT/$REG" | sed '/^```/d' > "$WORK/fp.sh"
[ -s "$WORK/fp.sh" ]; check $? "fingerprint: the extracted block is empty"
! grep -q extract "$WORK/fp.sh"; check $? "fingerprint: the extraction swallowed the documenting sentence"
! grep -q '<!--' "$WORK/fp.sh"; check $? "fingerprint: the extraction kept a marker line"
grep -q shasum "$WORK/fp.sh"; check $? "fingerprint: the block has no shasum"

V=0
fpv() {  # fpv <text> <want> — the text written with printf '%s', fingerprinted, exit 0 required
  V=$((V + 1)); printf '%s' "$1" > "$WORK/v$V.txt"
  local got rc; got=$(bash "$WORK/fp.sh" < "$WORK/v$V.txt"); rc=$?
  [ "$rc" -eq 0 ] && [ "$got" = "$2" ]; check $? "fingerprint: '$1' → '$got' (rc $rc), want $2"
}
fpv 'The banner shows the decline reason' f21723
printf '%s' 'The banner shows the decline reason' > "$WORK/plain.txt"
bash "$WORK/fp.sh" < "$WORK/plain.txt" | grep -Eqx '[0-9a-f]{6}'; check $? "fingerprint: output is not six lowercase hex"
fpv 'The banner shows the `decline` reason' f21723
fpv 'AC-3: The banner shows the decline reason' f21723
printf '%s\n%s' '- **E1-2.AC1** — The **banner** shows   the' '  _decline_ [reason](http://x/y)' > "$WORK/two.txt"
[ "$(bash "$WORK/fp.sh" < "$WORK/two.txt")" = f21723 ]; check $? "fingerprint: the two-line bold/italic/link variant"
printf '%s\n' 'The banner shows the decline reason' > "$WORK/nl.txt"
[ "$(bash "$WORK/fp.sh" < "$WORK/nl.txt")" = f21723 ]; check $? "fingerprint: a trailing newline changes the value"
fpv '- **AC1** Open menu' b40b37
fpv '- AC2 Open menu' b40b37
fpv '- AC1. Open menu' b40b37
fpv '- AC2. Open menu' b40b37
fpv 'Open *menu*' b40b37
fpv 'Open _menu_' b40b37
fpv 'Open ~~menu~~' b40b37
fpv 'Show ``a*b``' 5e1921
fpv 'Show ``ab``' e85526
fpv 'Open `foo_bar`' 0a0831
fpv 'Open foo_bar' 0a0831
fpv 'Open foobar' 0246d0
fpv 'Read `~/.agent-mail`' ba7442
fpv 'Read `/.agent-mail`' 08dbbe
fpv 'Use `_doc`' d26f99
fpv 'Use `doc`' a9c6dd
fpv 'Render `[KEY](old)`' cf973d
fpv 'Render `[KEY](new)`' a326dd
fpv 'See [the docs](http://a/b) now' 00aff4
fpv 'See the docs now' 00aff4
fpv 'The banner shows the refusal reason' f723b2
fpv 'the banner shows the decline reason' 0a1ec5
fpv 'ACME logo shows' f27b7e
fpv 'logo shows' 64ec76

# pipefail: a failing stage fails the block
sed 's/cut -c1-6/false/' "$WORK/fp.sh" > "$WORK/fp-broken.sh"
bash "$WORK/fp-broken.sh" < "$WORK/plain.txt" >/dev/null 2>&1
[ $? -ne 0 ]; check $? "fingerprint: a failing stage does not fail the block (pipefail)"

# The command's loop (Phase 0 step 1b), run as written.
mkdir -p "$WORK/qa-fp"
printf '%s' 'The banner shows the decline reason' > "$WORK/qa-fp/AC-1.txt"
printf '%s' 'Open menu' > "$WORK/qa-fp/AC-2.txt"
loop_out=$(for f in "$WORK"/qa-fp/*.txt; do printf '%s ' "${f##*/}"; bash "$WORK/fp.sh" < "$f"; done)
[ "$loop_out" = "$(printf '%s\n%s' 'AC-1.txt f21723' 'AC-2.txt b40b37')" ]; check $? "fingerprint: the command's loop output ($loop_out)"
has "$CMD" 'bash <scratchpad>/qa-fp.sh < "$f"'; check $? "qa-verify: the Phase 0 loop does not feed the extracted file"

# ---- re-check rules -------------------------------------------------------------------------------
pins "$CMD" "re-check" <<'EOF'
## Phase 0.5 — Re-check plan
| No record on the target | First run — `mode=first` |
| No `qa-verify:v1 record` marker (an older, marker-less comment), an unknown `qa-verify:v<N>`, or a record that fails validation (registry §7b) | Full run — `mode=first`; the gate says why |
| The record has `fail` > 0, today's criteria and the record's rows match one-to-one by fingerprint (no new, gone or duplicated fingerprint), and its `build=` sha resolves to the same commit as this run's `BUILD_SHA` | Stop before the gate: no commit since the failed record — nothing to re-check |
| The record has `fail` > 0 but the criteria changed, `build=-`, `BUILD_SHA` is `-`, or the two commits differ | No stop — continue with the rows below |
| A fingerprint of today's criteria is not in the record | Verify as new |
| A fingerprint of the record is not in today's criteria | Drop; list as removed |
| A fingerprint occurs more than once among today's criteria, or its record rows disagree | Verify as new — no history taken |
| Matched; one of its rows is not `PASS` or `CITED` | Verify |
| Matched; every row `PASS` / `CITED`; PR data available; no changed file matches its subject or mount target | Carry — `PASS (carried from <date>)` / `CITED (carried from <date>)` |
| Matched; every row `PASS` / `CITED`; a changed file matches its subject or mount target | Verify |
| Matched; every row `PASS` / `CITED`; the match is uncertain or PR data is unavailable | Verify every observed row again; carry only `CITED` rows |
PR data: unavailable — every observed row is verified again
a row whose disposition came from a verifier
`git rev-parse --verify --quiet "<build>^{commit}"`
a deployed sha is never stamped on an observation of another host
EOF

# ---- Phase 3 ----------------------------------------------------------------------------------------
pins "$CMD" "phase 3" <<'EOF'
Accept all recommendations
team-tracker.sh comment
--marker
include="comments"
The command never transitions a ticket.
EOF
for neg in 'sign-off box' 'signs each row' 'row by row' '## Tracker comment (prepared)'; do
  lacks "$CMD" "$neg"; check $? "qa-verify still says: $neg"
done

# ---- neighbours ------------------------------------------------------------------------------------
has .agents/reference/jira-mcp-atlassian.md '`AC-3`'; check $? "jira-mcp-atlassian: no AC-3 example"
has .agents/reference/jira-mcp-atlassian.md 'AC3'; check $? "jira-mcp-atlassian: no AC3 rule"
has .agents/reference/tracker-comments.md 'qa-verify:v1 record'; check $? "tracker-comments: the QA record is not a named producer"
has .claude/lib/tracker-snapshot.mjs 'qa-verify:v1 record'; check $? "tracker-snapshot.mjs: ownMarker does not know the QA record"

for f in "${FAILS[@]+"${FAILS[@]}"}"; do echo "FAIL [$f]"; done
[ "${#FAILS[@]}" -eq 0 ] || exit 1
echo "qa-verify-contract-test: OK ($N checks)"
