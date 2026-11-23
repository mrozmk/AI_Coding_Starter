#!/usr/bin/env bash
# Offline contract test of /pr-merge and the /push next-step lines, one block per subject:
# the pre-approved tools; provider routing; the refusals before any write; the strategy mapping;
# the single guarded merge call; required checks only; the rerun route; the GitHub cleanup order;
# the Azure DevOps strings other tests pin; the /push hints; long-lived branches (KEEP); the
# pre-merge reads of Step G5; the argument-less rerun lookup; the failed-switch skip; exact
# ls-remote refs; the quoted Azure message; G3(c) push-vs-pull; the Azure cleanup, report and timeout.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
F="$ST/.claude/commands/pr-merge.md"
fail() { echo "pr-merge-github-test: FAIL — $*"; exit 1; }
has() { grep -qF -- "$1" "$F" || fail "pr-merge.md lacks: $1"; }
N=0

FRONT=$(awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit } f' "$F")
BODY=$(awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { f = 0; b = 1; next } b' "$F")
# First body line matching a fixed string, optionally only after line $2; empty when absent.
# awk -v reads backslash escapes: a needle with `\` goes through `slice … | grep -F` instead.
line_of() { printf '%s\n' "$BODY" | awk -v p="$1" -v from="${2:-0}" 'NR > from && index($0, p) { print NR; exit }'; }
# First body line matching $1 after line $2, printed only when it comes before line $3.
line_between() { local l; l=$(line_of "$1" "$2"); [ -n "$l" ] && [ "$l" -lt "$3" ] && echo "$l"; }
# Body lines strictly between lines $1 and $2.
slice() { printf '%s\n' "$BODY" | awk -v s="$1" -v e="$2" 'NR > s && NR < e'; }
# Body lines $1..$2 contain the fixed string $3.
within() { printf '%s\n' "$BODY" | sed -n "$1,$2p" | grep -qF -- "$3"; }
# Body line of a `## ` heading, and the next `## ` heading after line $1 (empty when none).
heading() { printf '%s\n' "$BODY" | awk -v h="$1" '$0 == h { print NR; exit }'; }
next_heading() { printf '%s\n' "$BODY" | awk -v s="$1" 'NR > s && /^## / { print NR; exit }'; }
# A line inside the GitHub section / the Azure DevOps section (from $2, default its heading) /
# Azure Step 6, as a body line number.
gh_line() { line_between "$1" "$GH" "$GH_END"; }
az_line() { line_between "$1" "${2:-$AZ}" "$GH"; }
a6_line() { line_between "$1" "$A6" "$A7"; }

GH=$(heading '## GitHub path')
[ -n "$GH" ] || fail "no ## GitHub path section"
GH_END=$(next_heading "$GH")
[ -n "$GH_END" ] || GH_END=$(printf '%s\n' "$BODY" | wc -l | tr -d ' ')
SECTION=$(slice "$GH" "$GH_END")
in_gh() { printf '%s\n' "$SECTION" | grep -qF -- "$1" || fail "GitHub path lacks: $1"; }

# (1) allowed-tools: the read-only gh probes and the KEEP / G5 reads, never a merge, a ready, an
#     admin flag or a GraphQL call (it could be a mutation).
TOOLS=$(printf '%s\n' "$FRONT" | sed -n 's/^allowed-tools: //p')
[ -n "$TOOLS" ] || fail "no allowed-tools line"
for t in 'Bash(gh pr view:*)' 'Bash(gh pr list:*)' 'Bash(gh pr checks:*)' 'Bash(gh api user:*)' \
  'Bash(bash .claude/lib/branch-model.sh:*)' 'Bash(gh repo view:*)'; do
  case "$TOOLS" in *"$t"*) ;; *) fail "allowed-tools lacks $t" ;; esac
done
case "$TOOLS" in *"pr merge"*|*"pr ready"*|*"--admin"*) fail "allowed-tools pre-approves a write: $TOOLS" ;; esac
case "$TOOLS" in *"gh api graphql"*|*"gh api:"*) fail "allowed-tools pre-approves gh api graphql" ;; esac
N=$((N + 2))

# (2) ## Provider comes first, names the profile keys, STOPs only on a `none` read from
#     teams.pr_provider, and falls back to the origin host on git_host: none.
PV=$(heading '## Provider')
AZ=$(heading '## Azure DevOps path')
[ -n "$PV" ] && [ -n "$AZ" ] || fail "no ## Provider or ## Azure DevOps path section"
[ "$PV" -lt "$AZ" ] && [ "$PV" -lt "$GH" ] || fail "## Provider does not precede both paths"
[ "$AZ" -lt "$GH" ] || fail "## Azure DevOps path does not precede ## GitHub path"
PSEC=$(slice "$PV" "$(next_heading "$PV")")
for p in 'teams.pr_provider' 'git_host' 'teams.pr_provider is none' 'git_host: none' '`origin` host' \
  '`none` read from `teams.pr_provider` → STOP'; do
  printf '%s\n' "$PSEC" | grep -qF -- "$p" || fail "## Provider lacks: $p"
done
printf '%s\n' "$PSEC" | grep -qF -- '- `none` → STOP' && fail "## Provider still STOPs on any none"
N=$((N + 5))

# (3) Refusals before any write: role session, team anchor and own-branch check precede the
#     first `gh pr ready` and the merge call.
READY=$(gh_line 'gh pr ready') || fail "no gh pr ready in the GitHub path"
MERGE=$(gh_line 'gh pr merge <n>') || fail "no gh pr merge <n> in the GitHub path"
for p in '.agents/team/session.json' '.agents/team/team.json' '.agents/team/anchors' 'refs/heads/<HEAD>' 'the PR head moved after the ownership check'; do
  l=$(gh_line "$p") || fail "GitHub path lacks: $p"
  [ "$l" -lt "$READY" ] && [ "$l" -lt "$MERGE" ] || fail "$p comes after a write (line $l)"
done
OWN=$(gh_line 'refs/heads/<HEAD>')
within "$OWN" "$OWN" 'HEAD_SHA' || fail "the own-branch check does not compare with HEAD_SHA"
in_gh "a fork's PR"
N=$((N + 6))

# (4) Strategy mapping.
for m in 'merge commit → `--merge`' 'squash → `--squash`' 'rebase → `--rebase`'; do in_gh "$m"; done
N=$((N + 1))

# (5) Exactly one merge call, head-pinned, no bypass flags; --admin only inside a prohibition.
[ "$(printf '%s\n' "$BODY" | grep -cF 'gh pr merge <n>')" = 1 ] || fail "not exactly one gh pr merge <n> line"
ML=$(printf '%s\n' "$BODY" | sed -n "${MERGE}p")
case "$ML" in *--match-head-commit*) ;; *) fail "the merge call is not pinned with --match-head-commit" ;; esac
case "$ML" in *--admin*|*--auto*|*--delete-branch*) fail "the merge call carries a bypass flag: $ML" ;; esac
case "$ML" in *"--subject '"*) ;; *) fail "the merge subject is not single-quoted: $ML" ;; esac
printf '%s\n' "$SECTION" | grep -F 'gh api user' | grep -qF -- '--repo' && fail "gh api user carries --repo"
while IFS= read -r line; do
  printf '%s\n' "$line" | grep -qi 'never' || fail "--admin outside a prohibition: $line"
done < <(printf '%s\n' "$BODY" | grep -F -- '--admin' || true)
N=$((N + 5))

# (6) Required checks only; an unreadable state is a STOP; checks before the merge.
in_gh '--required'
in_gh 'no required checks reported'
in_gh 'no checks reported'
OTHER=$(gh_line 'any other failure' || gh_line 'Any other failure') || fail "no 'any other failure' rule"
within "$OTHER" "$OTHER" 'STOP' || fail "'any other failure' is not a STOP"
CHECKS=$(gh_line 'gh pr checks') || fail "no gh pr checks in the GitHub path"
[ "$CHECKS" -lt "$MERGE" ] || fail "gh pr checks does not precede the merge"
N=$((N + 5))

# (7) Rerun: an already merged PR goes through the tracker step and the cleanup, with MERGE_SHA
#     from the MERGED row's mergeCommit.oid; G6 has no own re-read.
RR=$(gh_line '| `state: MERGED` |') || fail "no state: MERGED row"
RL=$(printf '%s\n' "$BODY" | sed -n "${RR}p")
case "$RL" in *'Step G6'*'Step G7'*) ;; *) fail "the MERGED row does not route to Step G6 then Step G7" ;; esac
case "$RL" in *MERGE_SHA*) ;; *) fail "the MERGED row does not set MERGE_SHA" ;; esac
case "$RL" in *'mergeCommit.oid'*) ;; *) fail "the MERGED row does not name mergeCommit.oid" ;; esac
G6=$(gh_line '### Step G6') || fail "no Step G6"
G7=$(gh_line '### Step G7') || fail "no Step G7"
slice "$G6" "$G7" | grep -qF -- '--json mergeCommit' && fail "Step G6 still re-reads mergeCommit"
N=$((N + 4))

# (8) Cleanup order inside G7 items 0–2 (the KEEP read before item 0 is pinned by (20)); both
#     deletions guarded by HEAD_SHA on their own line.
G0=$(line_between '0. **Shared head.**' "$G7" "$GH_END") || fail "Step G7 lacks item 0 (Shared head)"
prev=$((G0 - 1))
for p in '--head <HEAD> --state open' 'git ls-remote --exit-code' 'git push origin --delete' 'git switch <BASE>' 'git pull --ff-only' 'git branch -D' 'git fetch origin --prune'; do
  l=$(line_between "$p" "$((G0 - 1))" "$GH_END") || fail "Step G7 items 0–2 lack: $p"
  [ "$l" -gt "$prev" ] || fail "Step G7 order: $p (line $l) not after line $prev"
  prev=$l
done
for p in 'git push origin --delete' 'git branch -D'; do
  l=$(line_of "$p" "$G7")
  within "$l" "$l" 'HEAD_SHA' || fail "$p is not guarded by HEAD_SHA on its line"
done
N=$((N + 2))

# (9) The Azure DevOps strings other tests pin are still there.
has 'teams.policy.pr.self_approve is off'
has '**4a**, then **5a**'
has '**4a**, then **5b**'
N=$((N + 3))

# (10) /push names the next step on a pr-only repo and skips that line inside /pr-create Step 5;
#      /pr-create no longer says "azure-devops only".
P="$ST/.claude/commands/push.md"
grep -qF 'Next: /pr-create, then /pr-merge.' "$P" || fail "push.md lacks the /pr-merge next-step line"
grep -qF 'Next: /pr-create, then merge the PR on the host.' "$P" || fail "push.md lacks the host-merge next-step line"
! grep -qF "(azure-devops) or the host's merge" "$ST/.claude/commands/pr-create.md" \
  || fail "pr-create.md still limits /pr-merge to azure-devops"
grep -qF '`/pr-create` Step 5' "$P" || fail "push.md does not skip its next-step line inside /pr-create Step 5"
grep -F '`/pr-create` Step 5' "$P" | grep -qF 'skipped' || fail "push.md's /pr-create Step 5 line does not say skipped"
N=$((N + 5))

# (11) KEEP: one definition in ## Guardrails from branch-model.sh; exit 3 or an empty protected=
#      falls back to the /push step 2 names, any other non-zero exit keeps every branch.
GR=$(heading '## Guardrails') || true
[ -n "$GR" ] || fail "no ## Guardrails section"
GSEC=$(slice "$GR" "$(next_heading "$GR")")
for p in 'KEEP' 'branch-model.sh fields' '`main`, `master`, `trunk`, `develop`' 'empty `protected=`' \
  'block absent or field empty' 'Any other non-zero exit' 'every source/head branch counts as in `KEEP`'; do
  printf '%s\n' "$GSEC" | grep -qF -- "$p" || fail "## Guardrails lacks: $p"
done
N=$((N + 6))

# (12) G5: the long-lived-head and merge-queue reads sit between the checks and the merge call;
#      deleteBranchOnMerge true and a failed read each STOP with their own message (no "merge on
#      the host keeping the branch" advice); the queue rule and a failed GraphQL read STOP; the
#      post-merge re-read watches autoMergeRequest.
for p in 'deleteBranchOnMerge' 'isMergeQueueEnabled'; do
  l=$(gh_line "$p") || fail "GitHub path lacks: $p"
  [ "$l" -gt "$CHECKS" ] && [ "$l" -lt "$MERGE" ] || fail "$p is not between gh pr checks and the merge (line $l)"
done
DB=$(gh_line 'deleteBranchOnMerge --jq') || fail "no deleteBranchOnMerge read"
within $((DB + 1)) $((DB + 1)) '`true` → STOP' || fail "deleteBranchOnMerge true is not a STOP"
DBF=$(line_between 'cannot read `deleteBranchOnMerge`' "$DB" "$MERGE") || fail "no own STOP message for a failed deleteBranchOnMerge read"
within $((DBF - 1)) "$DBF" 'A failed read → STOP with the error verbatim' \
  || fail "a failed deleteBranchOnMerge read is not a STOP with the error"
in_gh 'a merge on the host deletes it too'
printf '%s\n' "$SECTION" | grep -qF 'merge on the host keeping the branch' && fail "G5 still advises a host merge keeping the branch"
Q=$(gh_line 'isMergeQueueEnabled: true') || fail "no isMergeQueueEnabled: true rule"
within "$Q" $((Q + 2)) 'STOP' || fail "isMergeQueueEnabled: true is not a STOP"
in_gh 'the PR moved after the checks'
GQ=$(line_between 'unreadable is not "no queue"' "$GH" "$MERGE") || fail "no GraphQL failed-read rule before the merge"
within "$GQ" "$GQ" 'A failed read → STOP' || fail "the GraphQL failed read is not a STOP"
AM=$(gh_line 'autoMergeRequest') || fail "GitHub path lacks autoMergeRequest"
[ "$AM" -gt "$MERGE" ] || fail "autoMergeRequest does not follow the merge call"
N=$((N + 10))

# (13) G7: the KEEP skip comes before the first remote deletion.
K7=$(line_of 'KEEP' "$G7"); DEL=$(line_of 'git push origin --delete' "$G7")
[ -n "$K7" ] && [ "$K7" -lt "$DEL" ] || fail "Step G7 has no KEEP skip before git push origin --delete"
N=$((N + 1))

# (14) G2: the argument-less rerun lookup, guarded by the local tip (a mismatch STOPs); the
#      `<n>` read requests mergeCommit.
G2=$(gh_line '### Step G2') || fail "no Step G2"
G3=$(gh_line '### Step G3') || fail "no Step G3"
for p in '--state merged' 'refs/heads/<BRANCH>'; do
  line_between "$p" "$G2" "$G3" >/dev/null || fail "Step G2 lacks: $p"
done
GV=$(line_between '`<n>` → `gh pr view <n>' "$G2" "$G3") || fail "Step G2 lacks the gh pr view <n> read"
within "$GV" "$GV" ',mergeCommit' || fail "Step G2's gh pr view does not request mergeCommit"
TM=$(line_between 'local tip different or absent' "$G2" "$G3") || fail "Step G2 lacks the tip-mismatch rule"
within "$TM" "$TM" 'STOP' || fail "the merged-fallback tip mismatch is not a STOP"
N=$((N + 4))

# (15) A failed switch skips the rest of the local cleanup, on both paths; G7's base-state item
#      is skipped with it.
SW=$(line_of 'git switch <BASE>' "$G7")
within "$SW" $((SW + 1)) 'skip the rest' || fail "Step G7: no skip after a failed git switch <BASE>"
A6=$(az_line '### Step 6 — Cleanup') || fail "no Azure Step 6 — Cleanup"
SWA=$(az_line 'git switch <TARGET>' "$A6") || fail "Azure Step 6 lacks git switch <TARGET>"
within "$SWA" $((SWA + 2)) 'skip the rest' || fail "Azure Step 6: no skip after a failed git switch <TARGET>"
G73=$(line_between '**Base state**' "$G7" "$GH_END") || fail "Step G7 lacks item 3"
within "$G73" "$G73" 'only when item 2 reached its pull' || fail "Step G7 item 3 is not skipped with item 2"
in_gh 'skipped — why, with no base-state line'
N=$((N + 5))

# (16) ls-remote matches the exact ref on both paths — the deleting reads, after the shared-head
#      lookup (G7 item 0) and after the other-active-PR lookup (Azure Step 6); the KEEP reads
#      before them are pinned by (20) and (21).
grep -qF 'ls-remote --heads' "$F" && fail "pr-merge.md still uses ls-remote --heads"
LR=$(line_of 'git ls-remote --exit-code' "$G0")
within "$LR" "$LR" 'refs/heads/<HEAD>' || fail "Step G7 ls-remote is not refs/heads/<HEAD>"
ASRC=$(az_line '--source-branch "<SOURCE>" --status active' "$A6") || fail "Azure Step 6 lacks the other-active-PR lookup"
LRA=$(az_line 'git ls-remote --exit-code' "$ASRC") || fail "Azure Step 6 lacks git ls-remote --exit-code after the active-PR lookup"
within "$LRA" "$LRA" 'refs/heads/<SOURCE>' || fail "Azure Step 6 ls-remote is not refs/heads/<SOURCE>"
N=$((N + 3))

# (17) Azure: single-quoted merge message with the '\'' escape rule, the source branch never
#      deleted by the host.
grep -qF -- '--merge-commit-message "' "$F" && fail "a double-quoted --merge-commit-message is left"
grep -qF -- '--delete-source-branch true' "$F" && fail "--delete-source-branch true is left"
has "--merge-commit-message '<MSG>'"
has '--delete-source-branch false'
slice "$AZ" "$GH" | grep -qF -- "each \`'\` of the title written as \`'\\''\`" \
  || fail "the Azure message lacks the '\\'' escape rule"
N=$((N + 5))

# (18) G3(c): local branch ahead of the PR head → push, not pull.
G4=$(gh_line '### Step G4') || fail "no Step G4"
for p in 'merge-base --is-ancestor' 'run /push'; do
  line_between "$p" "$G3" "$G4" >/dev/null || fail "Step G3 lacks: $p"
done
N=$((N + 2))

# (19) Azure cleanup, report and timeout: KEEP, the other-active-PR lookup and the MERGED_SRC keep
#      rule precede the remote deletion; Step 6.2 deletes the local branch only outside KEEP at
#      MERGED_SRC; the 5c timeout and Step 7 say a re-run deletes the branch; Step 7 follows the
#      skip and keep paths.
A7=$(az_line '### Step 7' "$A6") || fail "no Azure Step 7"
ADEL=$(a6_line 'git push origin --delete <SOURCE>') || fail "Azure Step 6 lacks git push origin --delete <SOURCE>"
for p in 'lastMergeSourceCommit' 'KEEP' '--source-branch "<SOURCE>" --status active' 'differs from `MERGED_SRC`'; do
  l=$(a6_line "$p") || fail "Azure Step 6 lacks: $p"
  [ "$l" -lt "$ADEL" ] || fail "Azure Step 6: $p (line $l) not before the remote deletion"
done
MV=$(a6_line 'differs from `MERGED_SRC`')
within "$MV" $((MV + 1)) 'kept' || fail "Azure Step 6: a moved origin/<SOURCE> is not kept"
ABD=$(a6_line 'git branch -D <SOURCE>') || fail "Azure Step 6 lacks git branch -D <SOURCE>"
for p in 'KEEP' 'MERGED_SRC'; do
  within $((ABD - 1)) "$ABD" "$p" || fail "Azure git branch -D <SOURCE> is not guarded by $p"
done
A5C=$(az_line '**5c. Wait for it**') || fail "no Azure 5c"
TO=$(line_between 'Timeout →' "$A5C" "$A7") || fail "Azure 5c lacks its timeout exit"
within "$TO" $((TO + 2)) 're-run after the PR completes' || fail "Azure 5c timeout does not say a re-run deletes the branch"
A7SEC=$(slice "$A7" "$GH")
for p in 'deleted only by a re-run' 'tip ≠ `MERGED_SRC`' 'failed switch'; do
  printf '%s\n' "$A7SEC" | grep -qF -- "$p" || fail "Azure Step 7 lacks: $p"
done
N=$((N + 11))

# (20) G7 KEEP: a long-lived head is reported from an exact-ref existence read, before item 0 —
#      kept, gone from origin, or existence unknown; never a bare "kept".
KL=$(line_between '**Long-lived head.**' "$G7" "$G0") || fail "Step G7 lacks the Long-lived head item before item 0"
line_between 'git ls-remote --exit-code origin refs/heads/<HEAD>' "$((KL - 1))" "$G0" >/dev/null \
  || fail "Step G7 Long-lived head lacks the exact-ref read git ls-remote --exit-code origin refs/heads/<HEAD>"
for p in 'long-lived branch — kept' 'gone from origin; restore it on the host' 'existence on origin unknown'; do
  slice "$((KL - 1))" "$G0" | grep -qF -- "$p" || fail "Step G7 Long-lived head lacks: $p"
done
N=$((N + 2))

# (21) Azure Step 6.1 KEEP: the same exact-ref read for <SOURCE>, on or after the KEEP bullet and
#      before the other-active-PR lookup; the three reports in Step 6.
AK=$(a6_line 'KEEP') || fail "Azure Step 6 lacks the KEEP bullet"
line_between 'git ls-remote --exit-code origin refs/heads/<SOURCE>' "$((AK - 1))" "$ASRC" >/dev/null \
  || fail "Azure Step 6.1 KEEP bullet lacks the exact-ref read git ls-remote --exit-code origin refs/heads/<SOURCE>"
for p in 'long-lived branch — kept' 'gone from origin; restore it on the host' 'existence on origin unknown'; do
  slice "$A6" "$A7" | grep -qF -- "$p" || fail "Azure Step 6 lacks: $p"
done
N=$((N + 2))

# (20b) The final reports carry the exact-ref result of a long-lived branch: Azure Step 7 and G8.
G8=$(gh_line '### Step G8') || fail "no Step G8"
for p in 'gone from origin' 'existence on origin unknown'; do
  printf '%s\n' "$A7SEC" | grep -qF -- "$p" || fail "Azure Step 7 lacks: $p"
  slice "$G8" "$GH_END" | grep -qF -- "$p" || fail "Step G8 lacks: $p"
done
N=$((N + 2))

# (22) Azure C2: Step 3 reads completionOptions.deleteSourceBranch; a Step 4 row disarms an
#      auto-complete armed with source deletion before the draft and vote rows, and STOPs when it
#      stays armed.
A3=$(az_line '### Step 3') || fail "no Azure Step 3"
A4=$(az_line '### Step 4 ' "$A3") || fail "no Azure Step 4"
QL=$(line_between 'az repos pr show --id <PR_ID>' "$A3" "$A4") || fail "Azure Step 3 lacks its az repos pr show read"
within "$QL" "$QL" 'deleteSource:completionOptions.deleteSourceBranch' \
  || fail "Azure Step 3 query lacks deleteSource:completionOptions.deleteSourceBranch"
DS=$(az_line '`deleteSource: true`' "$A4") || fail "Azure Step 4 lacks the deleteSource: true row"
DR=$(az_line '| `isDraft: true` |' "$A4") || fail "Azure Step 4 lacks the isDraft row"
VR=$(az_line 'az repos pr set-vote' "$A4") || fail "Azure Step 4 lacks the set-vote row"
[ "$DS" -lt "$DR" ] && [ "$DS" -lt "$VR" ] || fail "Azure Step 4: the deleteSource row does not precede the draft and vote rows"
within "$DS" "$DS" '--auto-complete false' || fail "Azure Step 4 deleteSource row does not disarm with --auto-complete false"
within "$DS" "$DS" 'auto-complete is still set with source deletion on' \
  || fail "Azure Step 4 deleteSource row lacks its still-armed STOP"
N=$((N + 3))

echo "pr-merge-github-test: OK ($N checks)"
