#!/usr/bin/env bash
# Offline contract test of /brainstorm-ba: the certainty gate carries its sentence verbatim and has no
# yield, the command refuses a team clone and an empty call, verifies Tasks through the checker and
# the tracker in every state, routes through the six-row table and allocates no criterion id; the
# wiring in /update-backlog, /plan-feature, /brainstorm, /prime-ba and the shared review reference
# holds; the worked-proof fixture is complete and checker-clean. Text checks only — nothing is
# spawned, no tracker is called; the fixture is checked in a temporary copy.
#
# Usage: bash .claude/lib/tests/brainstorm-ba-contract-test.sh [root]   (default: this checkout)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

CMD=.claude/commands/brainstorm-ba.md
REF=.agents/reference/spec-cross-review.md
FX=.claude/lib/tests/fixtures/brainstorm-ba
FAILS=()
N=0
check() {  # check <rc> <what>
  N=$((N + 1))
  if [ "$1" -eq 0 ]; then echo "PASS $2"; else FAILS+=("$2"); fi
}
has() { grep -qF -- "$2" "$ROOT/$1" 2>/dev/null; }
lacks() { [ -f "$ROOT/$1" ] && ! grep -qF -- "$2" "$ROOT/$1"; }

# ---- the command ----------------------------------------------------------------------------
has "$CMD" '> **If you are not 99 % sure — ask. Never guess, never fill a gap with a silent default.**'
check $? "certainty sentence verbatim"
has "$CMD" 'it has no yield'
check $? "it has no yield"
has "$CMD" '<HARD-GATE>' && has "$CMD" '<CERTAINTY-GATE>' && has "$CMD" '<TERMINAL-GATE>'
check $? "three gate blocks"
has "$CMD" '.agents/team/session.json' && has "$CMD" '.agents/team/team.json' && has "$CMD" 'D-A16'
check $? "team clone refused (session.json, team.json, D-A16)"
has "$CMD" 'Never pick a backlog Task'
check $? "empty call asks, never picks"
has "$CMD" 'with `Waiting —`' && has "$CMD" 'never a second spec for the same input' \
  && has "$CMD" 'revision moved while'
check $? "resume covers a Waiting and a Draft requirements spec and re-judges stale rows"
has "$CMD" 'testing in this order:'
check $? "pre-Scope is tested before new-format"
has "$CMD" 'never the whole spec'
check $? "create-task gets one ready Task, never the whole spec"
has "$CMD" 'list --state all' && has "$CMD" 'start_at'
check $? "tracker read in every state (github list --state all, jira paged with start_at)"
has "$CMD" 'withdrawn: false' && has "$CMD" '--next-ids' && has "$CMD" '--impact'
check $? "criteria and protection from the checker"
has "$CMD" '--no-replace-objects' && has "$CMD" '[unverified — uncommitted]'
check $? "hardened committed-object reads; uncommitted claims unverified"
has "$CMD" '`/update-backlog <spec>` → `/jira draft`' && has "$CMD" '`/update-backlog <spec>` → `/github-sync`' \
  && has "$CMD" '`/jira create`' && has "$CMD" '`/create-task <draft>`' && has "$CMD" 'the spec stays the local record'
check $? "six routing rows"
has "$CMD" 'No criterion id is allocated here'
check $? "No criterion id is allocated here"
has "$CMD" '**Kind:** requirements'
check $? "spec header carries Kind requirements"
has "$CMD" 'runtime-mark.sh stage end brainstorm-ba'
check $? "stage end marker"
lacks "$CMD" '!`'
check $? "no skill-load probe"
lacks "$CMD" '/plan-feature <' && has "$CMD" 'Never `/plan-feature`'
check $? "never hands off to /plan-feature"

# ---- wiring ---------------------------------------------------------------------------------
has .claude/commands/update-backlog.md 'resume it with `/brainstorm-ba <path>`' \
  && has .claude/commands/update-backlog.md 'never becomes `[Assumption — to verify]`'
check $? "update-backlog skips an unapproved requirements spec and keeps its open questions"
has .claude/commands/plan-feature.md 'is a requirements spec (`/brainstorm-ba`)' \
  && has .claude/commands/plan-feature.md 'holds only requirements specs'
check $? "plan-feature refuses a requirements spec and stops when only those remain"
has .claude/commands/brainstorm.md 'this is `/brainstorm-ba` work'
check $? "brainstorm points requirement work at /brainstorm-ba"
has .claude/commands/prime-ba.md 'WAITING' && has .claude/commands/prime-ba.md '/brainstorm-ba <spec>' \
  && has .claude/lib/prime-ba.mjs 'WAITING\t'
check $? "prime-ba lists a waiting requirements spec"

# The shared review reference — or, on the cut-first fallback, a command without the step.
if [ -f "$ROOT/$REF" ]; then
  has "$REF" 'BOUND_SECTIONS' && has "$REF" 'WAKEUP_PROMPT' && has "$REF" 'CONTINUE_TO' \
    && has "$REF" '`/brainstorm` Step 8' && has "$REF" '`/brainstorm-ba` Step 7'
  check $? "spec-cross-review names its parameters and both callers"
  has .claude/commands/brainstorm.md 'spec-cross-review.md' && has "$CMD" 'spec-cross-review.md' \
    && has .claude/commands/brainstorm.md '#### Step 8.3' && has .claude/commands/brainstorm.md '#### Step 8.8'
  check $? "both commands link the reference; brainstorm keeps 8.3 and 8.8"
else
  has "$CMD" 'v1 has no cross-model review step' && has .claude/commands/brainstorm.md '#### Step 8.5'
  check $? "cut-first fallback: no review step, brainstorm Step 8 untouched"
fi

# ---- the worked-proof fixture ---------------------------------------------------------------
ok=0
for f in .claude/project-profile.json docs/PRD.md .agents/backlog.md .agents/backlog/E1-reading-list.md \
    .agents/specs/2026-01-12-mark-read.md src/list.js inputs/input.md README.md; do
  [ -f "$ROOT/$FX/$f" ] || { echo "  missing $FX/$f"; ok=1; }
done
check $ok "fixture has its eight files"
! grep -rqF --exclude=README.md 'publisher catalogue' "$ROOT/$FX" 2>/dev/null
check $? "the stage-2 reply lives only in the fixture README"

TMP="$(mktemp -d)"
cp -R "$ROOT/$FX/." "$TMP/"
node "$ROOT/.claude/lib/backlog-check.mjs" --root "$TMP" >/dev/null 2>&1
check $? "fixture is checker-clean (exit 0)"
node "$ROOT/.claude/lib/backlog-check.mjs" --root "$TMP" --next-ids E1-2 2>/dev/null \
  | jq -e '.tasks["E1-2"] | .source == ".agents/specs/2026-01-12-mark-read.md"
      and any(.current[]; .id == "E1-2.AC2" and .withdrawn)
      and any(.current[]; .id == "E1-2.AC3" and (.withdrawn | not))' >/dev/null 2>&1
check $? "E1-2 resolves to the spec in Ref, AC2 withdrawn, AC3 active"
rm -r "$TMP"

for f in "${FAILS[@]+"${FAILS[@]}"}"; do echo "FAIL [$f]"; done
[ "${#FAILS[@]}" -eq 0 ] || exit 1
echo "brainstorm-ba-contract-test: OK ($N checks)"
