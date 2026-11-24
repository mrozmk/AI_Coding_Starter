#!/usr/bin/env bash
# Offline contract test of /qa-verify's run record: the two hard gates, registry §7 (dispositions,
# the record template and its rules, both marker types), the criterion fingerprint — extracted from
# the registry and run on fixed vectors, so the test runs the same bytes the command runs — the
# re-check rules, Phase 3's one-pass decisions and one approval, the modes, the pool, groups, the
# feature path and deferrals, the task ledger (citation, the rank, the light path), the per-ticket
# host-and-build decision, the deployed line and the base-filtered merge set, the ENV evidence rule,
# the browser drivers and the script skeleton (extracted and run against a stub Playwright), and the
# neighbouring contracts.
# Text and pipeline checks only — nothing is spawned, no tracker is called, no real browser runs.
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
**QA never mutates.** No source edits. No mutating git. No editing the AC text — not to clarify it, not to fix a typo. No transitioning the issue's status. **On finding a defect, record a `FAIL` with a severity and keep verifying — never fix it.** A proposed fix appears only as text in the row's notes. The permitted outward writes are the run's tracker comments — records and deferral pointers — after explicit human approval, and the one-time `qa.pool_status` setting with its `decisions.md` entry, on the Operator's answer. This boundary has no exception: a QA run that repairs what it inspects has destroyed the evidence it exists to produce.
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
charged to <KEY>
Verify it when this ticket reaches <pool status>.
`group=-` for a single-ticket run
is a re-check-form record with `build=-`
any disposition may carry
mode=first|recheck|light
history comparisons count that pair as one criterion
EOF
lacks "$REG" '`group=-` and `mode=first|recheck` in this revision'; check $? "registry still says group=- only"
lacks "$REG" '`light` is reserved'; check $? "registry still reserves light"

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
# A plain heredoc file: bash 3.2 reads the `#` of `(PR #<n>)` inside `$( … )` as a comment.
cat > "$WORK/want-tpl.txt" <<'EOF'
## QA verification — <ticket or feature title>

- Run: <UTC date> · <first | re-check of <date> | light> · group: <keys, or single>
- Environment: <host> (<reason>) · build: <sha | skew state>
- Criteria from: <ticket description | spec path> (<n> criteria)

### Criteria
- <id> [<fp>] — PASS — <family> — <observed value, one line>
- <id> [<fp>] — FAIL / <blocker|major|minor> — <family> — <observed value; the clause it contradicts>
- <id> [<fp>] — CITED — task ledger: met (PR #<n>)
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
want_tpl=$(cat "$WORK/want-tpl.txt")
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
# list markers and task-list checkboxes (#196)
fpv 'The menu opens on click' ca3187
fpv '- [ ] The menu opens on click' ca3187
fpv '- [x] The menu opens on click' ca3187
fpv '- [X] The menu opens on click' ca3187
fpv '1) The menu opens on click' ca3187
fpv '1. The menu opens on click' ca3187
fpv '- [x] **AC1** The menu opens on click' ca3187
fpv '[x] The menu opens on click' dd99c1
fpv '- `[x]` The menu opens on click' dd99c1
fpv '- [x](http://a/b) The menu opens on click' 7a76cf
fpv '- [x]' e3b0c4
printf '%s\n' '- [x]' > "$WORK/box-nl.txt"
[ "$(bash "$WORK/fp.sh" < "$WORK/box-nl.txt")" = e3b0c4 ]; check $? "fingerprint: an empty checkbox with a trailing newline"

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
| The record has `fail` > 0, today's criteria and the record's rows match one-to-one by fingerprint (no new, gone or duplicated fingerprint), and its `build=` sha resolves to the same commit as this ticket's `BUILD_SHA` (Step 0.76) | Stop before the gate: no commit since the failed record — nothing to re-check |
| The record has `fail` > 0 but the criteria changed, `build=-`, `BUILD_SHA` is `-`, or the two commits differ | No stop — continue with the rows below |
| A fingerprint of today's criteria is not in the record | Verify as new |
| A fingerprint of the record is not in today's criteria | Drop; list as removed |
| A fingerprint occurs more than once among today's criteria, or its record rows disagree | Verify as new — no history taken |
| Matched; one of its rows is not `PASS` or `CITED` | Verify |
| Matched; every row `PASS` / `CITED`; PR data available; no changed file matches its subject or mount target | Carry — `PASS (carried from <date>)` / `CITED (carried from <date>)` |
| Matched; every row `PASS` / `CITED`; a changed file matches its subject or mount target | Verify |
| Matched; every row `PASS` / `CITED`; the match is uncertain or PR data is unavailable | Verify every observed row again; carry only `CITED` rows |
carry: PR data not used — every observed row is verified again
Step 0.76 takes the ticket's merge commits from the Step 0.75 read in a re-check run too
Step 0.76 takes the ticket's merge commits from this read in every mode, a re-check run included; only Phase 0.5's carry decision does not use PR data yet.
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

# ---- the task ledger: citation, the rank, the light path ----------------------------------------------
pins "$CMD" "ledger" <<'EOF'
**Task ledger** — read from the PR descriptions above
an open or closed-unmerged PR's ledger is never read for citation
Only `present` is a ledger
To check by hand:
the row list ends at the first line that is neither a row nor a label
blank lines between the groups are skipped
a plan-local `AC-n` is never matched by id
every eligible ledger must match the criterion as `met`
a ledger row `met` becomes `CITED` only for the `contract / type / boundary` family
registry §5 and QA's own earlier `FAIL` win over citation
history not established — static rows verified, not cited
a criterion that is both structural and visible gets a `CITED` row and its observed row
A passing test in the ledger never stands in for an observation
supporting, not an observation
`qa-contract` receives only the static rows the ledger does not cite as `met`
are re-derived from the current ledger, never carried
a valid two-row pair counts as one criterion
1. **re-check**
2. **deferred**
3. **sensitive**
4. **UI**
5. **links**
6. **time in pool**
rank <n>: re-check <yes|no> · deferred <n> · sensitive <n>[?] · UI <n>[?] · links <n> · in pool <d>
L1 — every ticket's ledger is `present` with `met = total`
L2 — every criterion matches a `met` row
L3 — every criterion is static-only and still citable after every guard; every feature-path row is static-only
L4 — complete PR file lists touching no UI and no sensitive path
L5 — no incoming deferral
L6 — no open `FAIL` and no stopped ticket
L7 — complete history
A ticket without a ledger never gets the light path.
LIGHT PATH: offered
a planned smoke resolves its driver like a `qa-runtime-ui` row
light — no smoke: driver subagent runs no smoke
`full <group id>`
`full <group id>` sets the group's ledgers aside
the empty-template skip of step 3 does not apply to a smoke at a named route
a smoke invalidated by build drift counts as a failed smoke
a failed smoke drops that ticket to a full run in the same session
recomputed after the fallback from the sources actually used
no checkout or host observed
merged into <base>, not <L> — its ledger is not used
only the run of backticked tokens right after the label
Rank keys 1, 3 and 4 (Step 0.8 → Order) are computed for a single run too
A single run turns it down with `full` (or `full <KEY>`)
or `mode=recheck` with the Run line `re-check of <date>` when the ticket's newest record validated
smoke failed at <target> — <error>; check it before you move it
as it stands after the one-pass decision (step 2)
Replacement is per criterion, not per physical row
- <id> [<fp>] — CITED — task ledger: met (PR #<n>)
EOF
pins .claude/agents/qa-contract.md "qa-contract" <<'EOF'
## When you are spawned
only for the static criteria the task ledger does not cite as `met`
EOF
lacks "$CMD" 'met (<file:line>)'; check $? "qa-verify still cites a file:line from Met: rows"
lacks "$CMD" 'on a line or heading containing "sensitive"'; check $? "qa-verify still harvests any line that says sensitive"

# ---- modes, pool, groups ----------------------------------------------------------------------------
POOL_PINS=$(cat <<'EOF'
## Step 0.1 — Mode
## Step 0.2 — The pool
## Step 0.75 — PR data and incoming deferrals
## Step 0.8 — Groups
qa-fp/<KEY>/<ac_id>.txt
<KEY> <id> <change>
(group <id>)
target read not complete — a duplicate pointer is possible (deduplicated on read)
a sibling result was posted on the same record
open F<n> from group <id>
file record — no pointer posted
a group is capped at 5 tickets — split the list
pool mode needs qa.pool_status
team-tracker.sh pool --status
team-tracker.sh item-status
team-pr.sh prs
team-pr.sh files
more tickets in <pool_status> not read
by approximate time in status
1. **link**
2. **files**
3. **spec**
4. **epic**
never merges them
charged to <KEY>
from spec <path>
from epic <KEY>
deferred-in from <SRC>
Verify it when this ticket reaches QA.
target done — verify in the next run of <SRC>
target state unknown — pointer posted
listed as stale
verified in the run of group <group id>
F<n> is charged here — verify it in a group run with <keys>
<KEY>:<ac_id>
tracker none has no pool
F<n>@<group id>
<group id>-F<n>@<origin group id>.mjs
the numbers of open rows whose origin group is this group are reserved
One row per origin group and number
conflicting copies of F<n>@<group id>
**Each conflicting copy has its own id** `F<n>@<group id>~<KEY>`, `<KEY>` the ticket whose record the copy was read from
`F1@A+B~A` and `F1@A+B~B`
<group id>-F<n>@<origin group id>~<KEY>.mjs
each copy listed by its own id `F<n>@<group id>~<KEY>`
`F<n>@<group id>~<KEY>` (a conflicting copy)
each conflicting copy's `F<n>@<group id>~<KEY>` — appears exactly once
`F<n>@<group id>~<KEY> <change>`
a conflicting copy: `F<n>@<group id>~<KEY>`) per charged feature-path `FAIL`
A rechecked open row keeps its identity in the record
F1@A+B
a shared route or screen still makes the edge
npm-shrinkwrap.json
Package.resolved
`DEFERRED → <KEY>` is offered only for a criterion row
a feature-path row is never deferred
shared-by-design paths
bun.lockb
CHANGELOG*
.agents/memory/**
.claude/lib/tests/team-suite.sh
EOF
)
pins "$CMD" "pool" <<< "$POOL_PINS"
for neg in 'In this revision a `DEFERRED` row is a plain row' '**PR data is not read by this command yet.**' \
           '**No argument → list candidates and stop.**'; do
  lacks "$CMD" "$neg"; check $? "qa-verify still says: $neg"
done

# Phase 1 prints the pool listing, the groups, the proposal and the feature path in that order —
# looked up inside the Phase 1 section only (the same phrases occur in Step 0.8).
P1="$WORK/phase1.md"
awk '/^## Phase 1 — Gate/ { f = 1; next } f && /^## / { exit } f' "$ROOT/$CMD" > "$P1"
prev=0; ord_ok=0
for ph in 'the pool listing' 'the groups with edges' 'proposed for this run' 'the feature path per group'; do
  ln=$(grep -nF -- "$ph" "$P1" | head -1 | cut -d: -f1)
  if [ -z "$ln" ] || [ "$ln" -le "$prev" ]; then ord_ok=1; break; fi
  prev=$ln
done
check $ord_ok "phase 1: the pool listing, groups, proposal and feature path are not in order"

# Break-check: a command without one pool pin must fail the same pins.
mkdir -p "$WORK/b/.claude/commands"
grep -vF 'never merges them' "$ROOT/$CMD" > "$WORK/b/$CMD"
# In a subshell: ROOT, FAILS and N change only in its own copies.
( ROOT=$WORK/b; FAILS=(); pins "$CMD" "pool" <<< "$POOL_PINS"; [ "${#FAILS[@]}" -gt 0 ] )
check $? "break-check: a removed pool pin went unnoticed"

# ---- environment readiness --------------------------------------------------------------------------
# The per-ticket host-and-build decision (Step 0.76), the ENV evidence rule (Phase 2.5 question 4) and
# the probe lines /prime-qa transcribes. A plain heredoc file — bash 3.2, see the browser drivers note.
cat > "$WORK/env-pins.txt" <<'EOF'
## Step 0.76 — Host and build per ticket
git merge-base --is-ancestor
git rev-parse --is-shallow-repository
contains | lacks | unknown
server provenance not verified
never a pass of the build check
this checkout lacks merge
no single build contains every ticket of group
is not in this clone — git fetch
PR discovery: a merged follow-up
DEPLOYED_SHA: <the probe's line, verbatim>
HOST: <deployed | local | none (ENV) | none>
Is the cause in this ticket's code, or in the environment?
DECISION: ENV
the row stays `FAIL`
not `truncated`
## Environment defects
The command creates no ticket and posts none of these texts.
Never write `ENV` without its evidence
FEATURE PATH HOST:
one preflight per host
local checkout lacks merge
cause not identified
older record without build provenance
deployed build changed during observation
no build contains both
DEPLOYED LINE:
deployed_branch
its merge is not checked against deployed
only when it is proven **by a deployed build**
makes kind 3 unavailable
no deployed build is known to contain them
never takes row 5's deployed outcome
maps to exactly that name for this environment
EOF
ENV_PINS=$(cat "$WORK/env-pins.txt")
pins "$CMD" "env" <<< "$ENV_PINS"
for f in "$CMD" .claude/commands/prime-qa.md; do
  for neg in 'build-skew' 'BUILD_SKEW' 'MISMATCH'; do
    lacks "$f" "$neg"; check $? "$f still says: $neg"
  done
done
pins .claude/commands/prime-qa.md "prime-qa env" <<'EOF'
Step 0.76
`deployed-sha: <sha> (differs)`
**Readiness:**
Every runtime or visual observation made **on the deployed host** carries that caveat (`/qa-verify` Step 0.76 row 5); an observation on the local host or of the checkout does not.
A readiness line is context, not proof: it is never `ENV` evidence on its own
quoted beside kind-3 evidence, never in place of it
EOF
for neg in 'Re-check does not use PR data' 'PR data: unavailable — every observed row is verified again'; do
  lacks "$CMD" "$neg"; check $? "qa-verify still says: $neg"
done
for neg in 'may cite it as `ENV` evidence' 'Every runtime or visual observation this session carries that caveat'; do
  lacks .claude/commands/prime-qa.md "$neg"; check $? "prime-qa still says: $neg"
done
jq -e '(.readiness_checks | type == "array") and has("_readiness_checks_doc")' "$ROOT/.claude/qa-env.json" >/dev/null 2>&1
check $? "qa-env.json: readiness_checks shape"

# Conditions bound to outcomes: each rule line must occur WHOLE inside its own section, so a flipped
# outcome with every name kept still fails. `@@ <heading>` opens the section the next lines live in.
cat > "$WORK/env-rules.txt" <<'EOF'
@@ Step 0.75 — PR data and incoming deferrals
- `bash .claude/lib/team-pr.sh prs <key>` — every PR that references the ticket (a GitHub issue number or a tracker key), with `relation` `closes` · `branch` · `mentions`, its `base_ref` (the branch it targets) and, once merged, its `merge_commit`. The ticket's PRs are the `closes` and `branch` ones; `mentions` are shown, never used for files or merge commits (a PR that only names a ticket did not change it).
@@ Step 0.76 — Host and build per ticket
- `L` — **the deployed line**, the branch the deployed host serves: `.claude/qa-env.json → deployed_branch`, else `workflow.integration` of `.claude/project-profile.json`, else `workflow.trunk` (an absent key reads as empty); none set → `L` unresolved. Gate item 2 prints `DEPLOYED LINE: <L> (from <qa-env.json deployed_branch | workflow.integration | workflow.trunk>)` or `DEPLOYED LINE: unknown — <why>`.
- `M_all` — the ticket's merge commits: `merge_commit` of every merged PR with relation `closes` or `branch` that `team-pr.sh prs` returns (Step 0.75); `mentions` never count. Every merge a check uses must be contained, a follow-up fix PR included — `M` (or `M_all` when every PR is excluded) in `D`, `M_H` in `H`.
- `M` — the merges checked against the deployed build: those of `M_all` whose PR's `base_ref` equals `L`. With `L` resolved and every merged `closes` / `branch` PR's `base_ref` non-empty, a merged PR into another base is no evidence about `D` — gate item 6 prints `PR #<n> merged into <base>, not <L> — its merge is not checked against deployed` — and adds nothing to `M`. Every PR excluded — the Step 0.75 read succeeded, it found at least one merged `closes` / `branch` PR, and every one targets a known base other than `L` — → `D` is judged on `M_all` instead: `contains` → the table's `contains` rows (1, or 2 / 4 when deployed is not usable); otherwise the observed rows are `NEEDS-HUMAN — the ticket's PRs target <base>, not the deployed line <L> — no deployed build is known to contain them`, with local acceptable as in row 2 (`M_H`∈`H` = `contains`) — never row 3 and never row 5's equality fallback. In that branch the gate prints this line instead of the not-checked lines, and its negative result is never `M`∈`D` = `lacks` for the feature-path rule or kind 2. No merged PR at all, or no PR data, stays row 5. Otherwise **Base unknown** below decides `D`.
- `M_H` — the merges checked against the checkout: those of `M_all` whose PR's `base_ref` equals `L` or is empty (all of `M_all` when `L` is unresolved); when that leaves none, all of `M_all` — so a merge whose line is not established, or a ticket whose every PR went to another base, still needs a checkout that contains it. Wherever this step judges the checkout — `M`∈`H`, and "`M` is known" / "`M` unknown" in row 5, the static-rows rule and the feature-path acceptable hosts — it reads `M_H`.
- **Base unknown:** with `L` unresolved, or a merged `closes` / `branch` PR whose `base_ref` is empty, `M`∈`D` is computed per merge on the merges of PRs whose `base_ref` equals `L` or is empty (all of `M_all` when `L` is unresolved): a `lacks` of a merge whose PR targets `L` stays `lacks`; a `lacks` only of merges whose line is not established (an empty `base_ref`, or any merge when `L` is unresolved) becomes `unknown` (`deployed line unknown — <why>` / `base of PR #<n> unknown`); `contains` stays `contains`. A `lacks` downgraded here never takes row 5's deployed outcome: deployed is no acceptable host for that ticket (the feature-path acceptable hosts included) — local only when `M_H`∈`H` = `contains`, else the observed rows are `NEEDS-HUMAN — deployed <D> lacks merge <m> (<deployed line unknown — <why> | base of PR #<n> unknown>)`. A merged PR into another known base is still printed as not checked against deployed — as in a shallow clone, `lacks` is what writes `ENV`, and an unestablished line is no proof.
- Row 5 is never a pass of the build check: it is the old equality rule, stated with the input that was missing (`merge commit unknown — <why>` / `deployed SHA unreadable` / `containment unknown — <git error | shallow clone | deployed line unknown — <why> | base of PR #<n> unknown>`). Choose the host first; the stamp and `BUILD_SHA` follow from the chosen host, so a deployed SHA is never written for a local observation.
- An empty intersection writes `ENV — no single build contains every ticket of group <id>` only when it is proven **by a deployed build**: every usable host has a proven `lacks` for some group ticket, and some group ticket has `M`∈`D` = `lacks` on a usable deployed host. An empty intersection whose only proven lack is the local checkout's (no group ticket with `M`∈`D` = `lacks`) leaves the feature-path rows `NEEDS-HUMAN — local checkout lacks merge <m> of <KEY> — git pull, then re-run` (a tester's stale checkout is not an environment defect, as in row 5); any other empty intersection (a host down, a containment `unknown`) leaves them `NEEDS-HUMAN` with each ticket's stamp quoted. This is the second build-decision source of `ENV` next to row 3; its evidence is a deployed build older than a group ticket's merge, with no usable host containing every group ticket.
- Containment is computed per `m` with `git merge-base --is-ancestor "<m>" "<X>"` and has three outcomes, `contains | lacks | unknown`: `contains` when every `m` exits 0, `lacks` when some `m` exits 1 and the rest exit 0 or 1, `unknown` on any other exit or any unresolved input; in a shallow clone (`git rev-parse --is-shallow-repository` prints `true`) a `lacks` becomes `unknown`, because missing history can make a contained commit look absent and `lacks` is what writes `ENV`.
| 1 | `M`∈`D` = `contains`, deployed usable | deployed | `D` | `deployed <url> @ <D> — contains merge <m…>` |
| 2 | `M`∈`D` = `lacks`, or `M`∈`D` = `contains` with deployed not usable; local usable; `M`∈`H` = `contains` | local | `H` only when this session started the local server from a clean tree at `H` (`git status --porcelain` empty); else `-` | `local <url> — server provenance not verified` (or `local <url> @ <H> — started by this session`) |
| 3 | `M`∈`D` = `lacks`, row 2 does not apply | none — the observed rows are `ENV` | `-` | `ENV — deployed <D> lacks merge <m> (git merge-base --is-ancestor)`, plus why local is no alternative (`local HEAD lacks <m>` / `local host down` / `no local_url` / `local containment unknown`) |
| 4 | `M`∈`D` = `contains`, deployed not usable, row 2 does not apply | none — the observed rows are `NEEDS-HUMAN` | `-` | `deployed <url> unreachable; its build <D> contains the merge` |
| 5 | `M`∈`D` = `unknown` — no PR data, no merged PR, a merge commit or `D` not in this clone, `D` not readable, a git error, a shallow clone's `lacks` — **the old rule** | first the host: `deployed-sha … (equal)` or `not verified`, with deployed usable → deployed; `(differs)`, deployed not usable, or `not applicable` → local if usable; nothing usable → none | from the chosen host only: deployed with `(equal)` → `D`; every other outcome (local, not-verified deployed, none) → `-` | deployed `(equal)` → `deployed <url> @ <D>`; `(differs)` → `⚠️ deployed build differs from HEAD and the ticket's merge is not established (<why>) — local <url>, server provenance not verified`; deployed `not verified` → `⚠️ build not verified — deployed build may lag HEAD`; `not applicable` → `verified against local <url>` (no warning — the never-collapse rule of Step 0); `(equal)` but deployed not usable → `local <url>, server provenance not verified` — never `D`; `not verified` but deployed not usable → `⚠️ deployed build not verified and deployed host not usable — local <url>, server provenance not verified`; nothing usable → `no usable host — <why> (deployed: <the deployed-sha state or not usable>; local: <down | no local_url | NOT PROBED | checkout lacks merge <m>>)`, the observed rows `NEEDS-HUMAN` |
- Row 5 applies the old rule only to what is unknown: when `M` is known, local is an acceptable host in row 5 only if `M`∈`H` = `contains`; with `M`∈`H` = `lacks` the local candidate is dropped (`local checkout lacks merge <m> — git pull, then re-run`) and, with no other host, the observed rows are `NEEDS-HUMAN` (a tester's stale checkout is not an environment defect); with `M` unknown, row 5 keeps the old fallback.
- A ticket's final `BUILD_SHA` is set after Phase 0 classification from the sources its rows actually use: only observed rows → the table's value; only Lane P rows → `H` when `git status --porcelain` is empty, else `-`; both, with the observed build ≠ `H` or unproven → `-` (mixed sources, the registry §7b deferral-result convention); both on `H` → `H` only with a clean tree (`git status --porcelain` empty), else `-`; Lane P rows held back by the static-rows rule above read nothing and are no source, and a ticket left with no source → `-`.
@@ Phase 2.5 — Self-audit
   1. **Kind 1 — an independent surface:** the same failure observed in this run on a surface independent of the ticket's change, named, and shown not to render or call anything the ticket's PRs changed. Available only with a complete PR file list (Step 0.75 read succeeded, not `truncated`) and the surface's own files (its route, component and the shared modules it imports) absent from it; for a feature-path row `F<n>` the list is the union of every group ticket's PR files, each read complete, so a surface that uses a module another group ticket changed does not qualify. The surface's route, component and imports are traced at the build both failures were observed on — on the deployed host `git show "<D>:<path>"` for a resolved `D`, on a clean checkout the working tree — and when that revision or the dependency chain cannot be established, kind 1 is unavailable.
   2. **Kind 2 — an older build:** the build under test is older than the ticket's merge — Step 0.76 row 3 or the feature-path rule.
   3. **Kind 3 — an external resource shown absent:** observed in the failing step itself — a response from that system captured in the row's evidence (a status, an error body naming the missing schema, space or resource) **and** the request that step sent (the id, name or path it asked for), whose value equals an **independent expected value**: the value the criterion itself names — taken as is when the criterion comes from the tracker issue, and as a file value under the checks below when it was taken from a spec; when the request addresses that resource by another identifier than the one the criterion names (an id for a named space), the identifier a file under the checks below maps to exactly that name for this environment, cited beside the name it maps; or, only for a resource the criterion does not name, a value in a file — a spec (the one a criterion or a feature-path row was taken from included), `.claude/qa-env.json`, a configuration file — absent from the ticket's PR file list (Step 0.75 read complete, not `truncated`; a feature-path row `F<n>`: the union of every group ticket's lists; a `deferred-in from <SRC>` row: the union of the source's and the target's lists, the source's read with `bash .claude/lib/team-pr.sh files` on its PRs, each complete), cited as `<path>:<key> = <value>`, its key applying to this criterion and this environment, and read at the revision proven to serve **this row**: `git show "<D>:<path>"` for a row observed on the deployed origin under the stamp `deployed <url> @ <D>`, `git show "<H>:<path>"` for a row served by a local server this session started from a clean tree at `H`; a row whose own observation has no proven revision (a local server whose provenance is not verified, a final origin other than the ticket's chosen host) has no file source — the ticket's aggregate `build=` does not decide it. A value only the ticket's code or a file its PRs changed supplies is not independent; a request not captured, a requested value that differs from the expected one, applicable sources that disagree, or no independent expected value makes kind 3 unavailable — the ticket may have asked for the wrong resource. A `readiness <name>: FAILED | UNREACHABLE` line is context, not proof — an anonymous probe from the tester's machine measures that machine's access (a VPN gap, a `401` to an unauthenticated probe), not what the observed host used; quote it beside kind-3 evidence, never in place of it.
EOF
env_rules() {  # every rule line occurs as a whole line inside the section its `@@` header names
  local line sec="" n=0
  while IFS= read -r line; do
    case "$line" in
      "") continue ;;
      "@@ "*) sec="## ${line#@@ }"
              awk -v h="$sec" 'index($0, h) == 1 { f = 1; next } f && /^## / { exit } f' "$ROOT/$CMD" > "$WORK/env-sec.md"
              continue ;;
    esac
    n=$((n + 1))
    grep -qxF -- "$line" "$WORK/env-sec.md"; check $? "env rule $n not whole in '$sec': ${line:0:70}"
  done < "$WORK/env-rules.txt"
}
env_rules
lacks "$CMD" 'An empty intersection that is proven — every usable host'; check $? "qa-verify: the feature-path ENV still counts a local lack as proof"

# Break-checks: a removed pin line, and an outcome flipped with every name kept, must both fail.
mkdir -p "$WORK/be/.claude/commands" "$WORK/br/.claude/commands"
grep -vF 'never a pass of the build check' "$ROOT/$CMD" > "$WORK/be/$CMD"
( ROOT=$WORK/be; FAILS=(); pins "$CMD" "env" <<< "$ENV_PINS"; [ "${#FAILS[@]}" -gt 0 ] )
check $? "break-check: a removed env pin went unnoticed"
sed '/^| 2 | /s/| local |/| deployed |/' "$ROOT/$CMD" > "$WORK/br/$CMD"
! cmp -s "$ROOT/$CMD" "$WORK/br/$CMD"; check $? "break-check: row 2's host cell was not found to flip"
( ROOT=$WORK/br; FAILS=(); env_rules; [ "${#FAILS[@]}" -gt 0 ] )
check $? "break-check: a flipped Step 0.76 outcome went unnoticed"
# The feature-path rule reverted to the old text (a local lack counted as ENV proof) must fail.
cat > "$WORK/fp-old.txt" <<'EOF'
- An empty intersection that is proven — every usable host `lacks` for some ticket — writes `ENV — no single build contains every ticket of group <id>`; otherwise (a host down, containment unknown) the feature-path rows are `NEEDS-HUMAN` with each ticket's stamp quoted. This is the second build-decision source of `ENV` next to row 3; its evidence is a build older than a group ticket's merge on every usable host.
EOF
mkdir -p "$WORK/bf/.claude/commands"
awk -v old="$(cat "$WORK/fp-old.txt")" 'index($0, "- An empty intersection writes `ENV") == 1 { print old; next } { print }' "$ROOT/$CMD" > "$WORK/bf/$CMD"
grep -qxF -f "$WORK/fp-old.txt" "$WORK/bf/$CMD" && ! grep -qF 'by a deployed build' "$WORK/bf/$CMD"
check $? "break-check: the feature-path rule was not reverted in the copy"
( ROOT=$WORK/bf; FAILS=(); env_rules; [ "${#FAILS[@]}" -gt 0 ] )
check $? "break-check: a feature-path ENV reverted to counting local lacks went unnoticed"

# ---- browser drivers ---------------------------------------------------------------------------------
# A plain heredoc, not $(cat <<…): bash 3.2 misparses the apostrophes below inside a command substitution.
cat > "$WORK/browser-pins.txt" <<'EOF'
### Lane S — the browser drivers
#### Driver `script` (default)
#### Driver `mcp`
#### Driver `subagent`
The fall-back order is script → mcp → NEEDS-HUMAN, and it applies only to `script`.
are chosen on purpose and fall straight to `NEEDS-HUMAN`.
Browser drivers apply only to the rows the project roster (registry §2) binds to `qa-runtime-ui`
<artifacts_dir>/<run>/<KEY>-<ac_id>.mjs
<artifacts_dir>/<run>/<group id>-F<n>.mjs
never `launchPersistentContext`
never `waitForTimeout`
A script that hits its hard limit → the row is `NEEDS-HUMAN` with the limit and the step quoted — no retry of that row.
A wait that times out at the action timeout is an observation, not a crash
A visual row is never decided from computed values alone
decided from computed values alone
driver: script (main session)
This retry applies to spawned agents only.
artifacts dir <dir> is committable
not established in the <driver> browser
mcp: a single call is bounded by the server's own timeouts
BROWSER_DRIVER: <configured> → <effective> (<reason>)
an empty `channel` or `user_agent` is written as `undefined`
every tag in `required` has at least one assertion
a desktop server of the `browser automation` class (any but the one named by `qa-env.json → device_mcp_server`
rev-parse --path-format=absolute --git-path info/exclude
a set `channel` cannot be established in an MCP-launched browser
dispatched width tags
the mount is verified on the parsed final URL
mount not verified under mcp
MCP output directory not established
never write into a run directory this run did not create
nothing later replaces it
the intended human gate
<!-- qa-script:begin -->
<!-- qa-script:end -->
LC_ALL=C git -C <ancestor> rev-parse --show-toplevel
not a git repository (or any of the parent directories)
not a git repository (or any parent up to mount point <dir>)
cannot tell which repository owns <dir>
a false assertion at a dispatched width tag
script asserted <tags>, dispatched <tags>
redirected to
one that fails the same mount rule ends the row
EOF
BROWSER_PINS=$(cat "$WORK/browser-pins.txt")
pins "$CMD" "browser" <<< "$BROWSER_PINS"
mkdir -p "$WORK/bb/.claude/commands"
grep -vF 'no retry of that row' "$ROOT/$CMD" > "$WORK/bb/$CMD"
( ROOT=$WORK/bb; FAILS=(); pins "$CMD" "browser" <<< "$BROWSER_PINS"; [ "${#FAILS[@]}" -gt 0 ] )
check $? "break-check: a removed browser pin went unnoticed"

UI=.claude/agents/qa-runtime-ui.md
pins "$UI" "qa-runtime-ui" <<'EOF'
browser_driver to subagent (not the default)
A visual criterion is never decided from computed values alone
BROWSER_LAUNCH
<ARTIFACTS_DIR>/<KEY>-<ac-id>-<slug>.png
EOF
# A plain YAML scalar with ': ' does not parse; the agent would still show in the Phase-0 listing.
! sed -n 's/^description: //p' "$ROOT/$UI" | grep -q ': '; check $? "qa-runtime-ui: description contains ': '"

# qa-env.json: the shape, not the defaults (a downstream may set another driver).
jq -e '(.browser_driver // "") as $d | (["","script","mcp","subagent"] | index($d)) != null
  and (.browser_launch | type == "object" and has("channel") and has("user_agent") and has("ignore_https_errors"))
  and (.browser_launch.ignore_https_errors | type == "boolean")
  and has("_browser_driver_doc") and has("_browser_launch_doc")' "$ROOT/.claude/qa-env.json" >/dev/null 2>&1
check $? "qa-env.json: browser_driver / browser_launch shape"
has .claude/commands/prime-qa.md '`browser-driver: …`'; check $? "prime-qa: no browser-driver reading row"
has .claude/commands/prime-qa.md '**Browser driver:**'; check $? "prime-qa: no Browser driver fact"

# The script skeleton: extracted from the command, checked as text, then run against a stub Playwright.
awk '/^<!-- qa-script:end -->$/{exit} f; /^<!-- qa-script:begin -->$/{f=1}' "$ROOT/$CMD" | sed '/^```/d' > "$WORK/skel.mjs"
[ -s "$WORK/skel.mjs" ]; check $? "skeleton: the extracted block is empty"
for want in 'newContext(' 'setDefaultTimeout(' 'setDefaultNavigationTimeout(' 'emit(124)' 'process.exit(code)' \
            'ariaSnapshot()' 'resp.status()' 'result.required.push(tag)' '${OUT}/${BASE}-${tag}.png' \
            'not the mount target' 'searchParams' 'page.screenshot(' 'after load, not the mount target'; do
  grep -qF -- "$want" "$WORK/skel.mjs"; check $? "skeleton: lacks $want"
done
for neg in waitForTimeout launchPersistentContext userDataDir; do
  ! grep -qF -- "$neg" "$WORK/skel.mjs"; check $? "skeleton: contains $neg"
done
for re in '^const HARD_LIMIT_MS = 120000;$' '^const ROOT = ' '^const OUT = ' '^const TARGET = ' \
          '^const WIDTHS = \[\];' '^const EXPECT_URL = '; do
  [ "$(grep -c -- "$re" "$WORK/skel.mjs")" = 1 ]; check $? "skeleton: not exactly one line matching $re"
done

if ! command -v node >/dev/null 2>&1; then
  echo "skip: node absent — skeleton stub runs not executed"; check 0 "skeleton stub runs skipped"
else
  node --check "$WORK/skel.mjs" 2>/dev/null; check $? "skeleton: node --check fails"
  S="$WORK/stub"; mkdir -p "$S/node_modules/playwright"
  printf '{}\n' > "$S/package.json"
  printf '{"name":"playwright","version":"1.50.0","main":"index.js"}\n' > "$S/node_modules/playwright/package.json"
  cat > "$S/node_modules/playwright/index.js" <<'EOF'
let calls = 0;
let waited = false;
const loc = {
  waitFor() {
    if (process.env.STUB_HANG) return new Promise(() => {});
    calls += 1;
    waited = true;
    if (process.env.STUB_TIMEOUT_AT && calls === Number(process.env.STUB_TIMEOUT_AT)) {
      const e = new Error('Timeout 10000ms exceeded'); e.name = 'TimeoutError'; return Promise.reject(e);
    }
    return Promise.resolve();
  },
  ariaSnapshot: async () => '- button "Pay"',
  screenshot: async () => {},
  textContent: async () => 'Pay',
};
const page = {
  goto: async () => ({ status: () => Number(process.env.STUB_STATUS || 200) }),
  url: () => (waited && process.env.STUB_URL_AFTER) || process.env.STUB_URL || 'http://localhost:3000/route',
  screenshot: async () => {},
  locator: () => loc,
};
const context = { setDefaultTimeout() {}, setDefaultNavigationTimeout() {}, newPage: async () => page, close: async () => {} };
const browser = { newContext: async () => context, close: async () => {}, version: () => 'stub' };
module.exports = { chromium: { launch: async () => browser } };
EOF
  sed -e "s#^const ROOT = .*#const ROOT = '$S';#" -e "s#^const OUT = .*#const OUT = '$WORK';#" \
      -e 's#^const HARD_LIMIT_MS = 120000;#const HARD_LIMIT_MS = 1000;#' "$WORK/skel.mjs" > "$WORK/run.mjs"
  sed -e 's#^const WIDTHS = \[\];#const WIDTHS = [1024, 1440];#' "$WORK/run.mjs" > "$WORK/run2.mjs"
  sed -e "s#^const TARGET = .*#const TARGET = 'http://localhost:3000/storybook?path=/story/button--primary';#" \
      "$WORK/run.mjs" > "$WORK/run3.mjs"
  sed -e "s@^const TARGET = .*@const TARGET = 'http://localhost:3000/#/components/button';@" \
      "$WORK/run.mjs" > "$WORK/runH.mjs"
  sed -e "s#^const TARGET = .*#const TARGET = 'http://localhost:3000/list?tag=one\&tag=two';#" \
      "$WORK/run.mjs" > "$WORK/runQ.mjs"
  NODE_RUN="node --no-global-search-paths"

  STUB_HANG=1 $NODE_RUN "$WORK/run.mjs" > "$WORK/hang.json"; rc=$?
  [ "$rc" -eq 124 ]; check $? "skeleton stub: a hang exits $rc, want 124"
  [ "$(wc -l < "$WORK/hang.json" | tr -d ' ')" = 1 ]; check $? "skeleton stub: a hang prints not exactly one JSON line"
  jq -e '.status == "hard-limit" and .error == "hard limit 1000 ms reached at step observe default"' "$WORK/hang.json" >/dev/null 2>&1
  check $? "skeleton stub: the hard-limit JSON"

  $NODE_RUN "$WORK/run.mjs" > "$WORK/done.json"; rc=$?
  [ "$rc" -eq 0 ]; check $? "skeleton stub: done exits $rc, want 0"
  jq -e '.status == "done" and .observed["default.text"] == "Pay" and .observed["default.http"] == 200
    and (.assertions | length) == 1 and .assertions[0].ok == false and (.screenshots | length) == 2' "$WORK/done.json" >/dev/null 2>&1
  check $? "skeleton stub: the done JSON"

  STUB_STATUS=403 $NODE_RUN "$WORK/run.mjs" > "$WORK/http.json"; rc=$?
  [ "$rc" -eq 1 ] && jq -e '.status == "error" and (.error | startswith("HTTP 403 at "))' "$WORK/http.json" >/dev/null 2>&1
  check $? "skeleton stub: HTTP 403 is not an environment error (rc $rc)"

  mount() {  # mount <script> <final url> <label> — a wrong mount must end as an error
    STUB_URL="$2" $NODE_RUN "$1" > "$WORK/mount.json"; local r=$?
    [ "$r" -eq 1 ] && jq -e '.status == "error" and (.error | test("not the mount target"))' "$WORK/mount.json" >/dev/null 2>&1
    check $? "skeleton stub: $3 passed the mount check (rc $r)"
  }
  mount "$WORK/run.mjs" 'http://localhost:3000/login?return=/route' "a login redirect"
  mount "$WORK/run.mjs" 'http://stub.test/route' "another host"
  mount "$WORK/run3.mjs" 'http://localhost:3000/storybook?path=/story/button--danger' "another story"
  STUB_URL='http://localhost:3000/storybook?path=/story/button--primary&args=x' $NODE_RUN "$WORK/run3.mjs" > "$WORK/extra.json"
  check $? "skeleton stub: an extra query parameter failed the mount check"
  mount "$WORK/runH.mjs" 'http://localhost:3000/#/login' "a hash-route redirect"
  mount "$WORK/runQ.mjs" 'http://localhost:3000/list?tag=one' "a missing value of a repeated key"
  STUB_URL='http://localhost:3000/list?tag=two&tag=one' $NODE_RUN "$WORK/runQ.mjs" > "$WORK/repeat.json"
  check $? "skeleton stub: every value of a repeated key present failed the mount check"
  STUB_URL='http://localhost:3000/#/components/button' $NODE_RUN "$WORK/runH.mjs" > "$WORK/hash.json"
  check $? "skeleton stub: the right hash route failed the mount check"
  STUB_URL_AFTER='http://localhost:3000/login' $NODE_RUN "$WORK/run.mjs" > "$WORK/late.json"; rc=$?
  [ "$rc" -eq 1 ] && jq -e '.status == "error" and (.error | test("redirected to http://localhost:3000/login after load"))' "$WORK/late.json" >/dev/null 2>&1
  check $? "skeleton stub: a redirect after load passed the mount check (rc $rc)"
  STUB_URL_AFTER='http://localhost:3000/login' STUB_TIMEOUT_AT=1 $NODE_RUN "$WORK/run.mjs" > "$WORK/late-to.json"; rc=$?
  [ "$rc" -eq 1 ] && jq -e '.status == "error" and (.error | test("redirected to http://localhost:3000/login after load"))' "$WORK/late-to.json" >/dev/null 2>&1
  check $? "skeleton stub: a redirect during a timed-out wait reads as a timeout (rc $rc)"

  STUB_TIMEOUT_AT=2 $NODE_RUN "$WORK/run2.mjs" > "$WORK/widths.json"; rc=$?
  [ "$rc" -eq 0 ] && jq -e '.status == "done" and .required == ["w1024","w1440"]
    and (.observed["w1440.visible"] | startswith("condition not met")) and (.assertions | length) == 1' "$WORK/widths.json" >/dev/null 2>&1
  check $? "skeleton stub: two widths with a timed-out second wait (rc $rc)"
fi

# ---- neighbours ------------------------------------------------------------------------------------
has .agents/reference/jira-mcp-atlassian.md '`AC-3`'; check $? "jira-mcp-atlassian: no AC-3 example"
has .agents/reference/jira-mcp-atlassian.md 'AC3'; check $? "jira-mcp-atlassian: no AC3 rule"
has .agents/reference/tracker-comments.md 'qa-verify:v1 record'; check $? "tracker-comments: the QA record is not a named producer"
has .claude/lib/tracker-snapshot.mjs 'qa-verify:v1 record'; check $? "tracker-snapshot.mjs: ownMarker does not know the QA record"
has .agents/reference/tracker-comments.md 'qa-verify:v1 deferral'; check $? "tracker-comments: the deferral pointer is not a named producer"
has .claude/lib/tracker-snapshot.mjs 'qa-verify:v1 deferral'; check $? "tracker-snapshot.mjs: ownMarker does not know the deferral pointer"
has .claude/lib/team-tracker.sh 'op_pool'; check $? "team-tracker.sh: no pool op"
has .claude/lib/team-pr.sh 'op_prs'; check $? "team-pr.sh: no prs op"
has .agents/reference/pr-host-api.md 'PR facts for `/qa-verify`'; check $? "pr-host-api: no PR facts section"
has .claude/project-profile.json.example 'pool_status'; check $? "profile example: no qa.pool_status"
has .claude/starter-sync-playbook.md 'pr-host-api.md'; check $? "sync playbook: pr-host-api §8 is not routed"

for f in "${FAILS[@]+"${FAILS[@]}"}"; do echo "FAIL [$f]"; done
[ "${#FAILS[@]}" -eq 0 ] || exit 1
echo "qa-verify-contract-test: OK ($N checks)"
