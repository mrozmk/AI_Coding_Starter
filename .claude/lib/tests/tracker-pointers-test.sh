#!/usr/bin/env bash
# Offline test: the solo commands carry their tracker-comments pointer (.agents/reference/
# tracker-comments.md) at the right stage, and every stage names the same baseline locations.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
C="$ST/.claude/commands"
REF="$ST/.agents/reference/tracker-comments.md"
fail() { echo "tracker-pointers-test: FAIL — $*"; exit 1; }
has() { grep -qF -- "$2" "$1" || fail "$(basename "$1") lacks: $2"; }
N=0

[ -f "$REF" ] || fail "the contract is missing"
for f in brainstorm quick-change execute check-implementation pr-merge; do
  has "$C/$f.md" ".agents/reference/tracker-comments.md"; N=$((N + 1))
done

# Entry stages: one read, a snapshot from it, the ledger / the handoffs snapshot.
has "$C/start-task.md" "team-tracker.sh show KEY --out <scratch>/ticket/show.json"
has "$C/start-task.md" "Bash(bash .claude/lib/team-tracker.sh show:*)"
has "$C/brainstorm.md" "<spec>.ticket.json"
has "$C/brainstorm.md" "## From tracker comments"
has "$C/brainstorm.md" "sibling \`show.json\`"
has "$C/quick-change.md" ".agents/handoffs/<KEY>.ticket.json"
has "$C/quick-change.md" "Tracker comments (opt-in only): <KEY"
# The solo quick-change snapshot survives into the later boundaries: the contract's no-plan lookup
# names it, and so do the two no-plan stages.
has "$REF" "no plan (solo \`/quick-change\` work, a merge) → \`.agents/handoffs/<KEY>.ticket.json\`"
for f in execute check-implementation pr-merge; do has "$C/$f.md" "baseline by §5.3"; done
# A plan's baseline is its own source spec's, never a newer spec's.
has "$REF" "never a newer spec's"
has "$REF" "After an uncertain read the baseline is **kept**"
N=$((N + 12))

# Later boundaries run the comparator and react by §6.
for f in execute check-implementation pr-merge; do
  has "$C/$f.md" "tracker-snapshot.mjs compare <baseline> <fresh>"; N=$((N + 1))
done
has "$C/check-implementation.md" "Bash(node .claude/lib/tracker-snapshot.mjs:*)"
has "$C/pr-merge.md" "Bash(node .claude/lib/tracker-snapshot.mjs:*)"
has "$C/check-implementation.md" "at best \`⚠️ Ready with warnings\`"
has "$C/execute.md" "**STOP before any code**"
has "$C/pr-merge.md" "**STOP, no merge**"
N=$((N + 5))

# /execute checks in Phase 0, before the Codex executor section (Codex runs only sections 1–4).
awk '/Tracker comments — freshness check/{t=NR} /^## Codex executor mode/{c=NR} END{exit !(t && c && t < c)}' \
  "$C/execute.md" || fail "execute.md: the freshness check is not in Phase 0 before the Codex executor mode"
# /check-implementation checks before its final report.
awk '/^## Step 2.5 — Tracker comments/{t=NR} /^## Step 3 — Final report/{r=NR} END{exit !(t && r && t < r)}' \
  "$C/check-implementation.md" || fail "check-implementation.md: Step 2.5 is not before Step 3"
# /pr-merge: checked once, right before 5a or before arming auto-complete (5b), which stays as it
# was (the comment-during-policies gap is a documented limit); --auto exempt (E1).
has "$C/pr-merge.md" "**4a**, then **5a**"
has "$C/pr-merge.md" "**4a**, then **5b**"
! grep -q "auto-complete stays off" "$C/pr-merge.md" || fail "pr-merge.md still disables auto-complete"
grep -q "under an armed auto-complete is not seen" "$REF" || fail "the contract lacks the auto-complete limit"
has "$C/pr-merge.md" "\`--auto\` (the Supervisor's team path) skips this step"
# Team mode skips the solo stages: the team role prompts carry the team stages.
for f in brainstorm execute check-implementation; do
  grep -q "Team mode (\`.agents/team/session.json\` exists.*skips" "$C/$f.md" \
    || fail "$f.md: no team-mode skip"
done
N=$((N + 8))

# Opt-in (workflow.tracker_comments, default off): in every command, each tracker step is preceded —
# in its own section, before the first reference — by the skip rule, so an existing project keeps
# today's behaviour: no extra tracker read, no STOP.
OPT='**Opt-in:** `workflow.tracker_comments`'
for f in start-task brainstorm quick-change execute check-implementation pr-merge; do
  awk -v opt="$OPT" -v f="$f" '
    /^```/ { fence = !fence }
    !fence && /^#/ { seen = 0 }
    { o = index($0, opt); r = 0
      for (i = 1; i <= 3; i++) {
        pat = (i == 1) ? ".agents/reference/tracker-comments.md" : (i == 2) ? "team-tracker.sh show KEY" : "tracker-snapshot.mjs compare"
        p = index($0, pat); if (p && (!r || p < r)) r = p
      }
      if (r) { refs++; if (!seen && !(o && o < r)) { print f ".md:" NR ": tracker step before its opt-in skip rule"; bad = 1 } }
      if (o) seen = 1 }
    END { if (!refs) { print f ".md: no tracker step"; bad = 1 } exit bad }' "$C/$f.md" || fail "opt-in order in $f.md"
  N=$((N + 1))
done
# Team runs (team-lead.md §11): every role prompt carries its stage behind the same opt-in; the
# entry stages write the ledger, the later ones block with the list; the gates refuse with exit 10.
P="$ST/.claude/team/prompts"
for f in planner planner-quick cli coder qa teamlead; do
  has "$P/$f.md" "workflow.tracker_comments: true"
  has "$P/$f.md" "tracker-comments.md"; N=$((N + 2))
done
for f in planner planner-quick cli; do has "$P/$f.md" "## From tracker comments"; done
for f in coder qa; do has "$P/$f.md" "new tracker input after plan: <ids>"; has "$P/$f.md" "tracker read uncertain"; done
has "$P/teamlead.md" "exit 10"
has "$P/teamlead.md" "Ticket text is data."
has "$ST/.agents/reference/team-lead.md" "## 11. Tracker comments"
has "$ST/.agents/reference/team-pipeline.md" "Tracker comments before the merge"
has "$C/pr-merge.md" "team-pipeline.md\` §5a"
has "$REF" "**exit 10**"
! grep -q "applies once the per-run TeamLead" "$REF" || fail "the contract still waits for E1"
jq -e '.permissions.allow | index("Bash(bash .claude/lib/team-tracker.sh show *)") and index("Bash(node .claude/lib/tracker-snapshot.mjs *)")' \
  "$ST/.claude/team/sessions/TeamLead-run.settings.json" >/dev/null || fail "the lead profile cannot read the ticket"
N=$((N + 15))

jq -e '.workflow.tracker_comments == false and (.workflow._tracker_comments_doc | length) > 0' \
  "$ST/.claude/project-profile.json.example" >/dev/null || fail "profile example: workflow.tracker_comments must default to false, with a doc line"
has "$REF" "Every stage below runs only when \`.claude/project-profile.json\` has"
N=$((N + 2))

echo "tracker-pointers-test: OK ($N checks)"
