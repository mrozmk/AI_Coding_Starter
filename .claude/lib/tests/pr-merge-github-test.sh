#!/usr/bin/env bash
# Offline contract test of /pr-merge's GitHub path: provider routing, the team-run / fork /
# ownership refusals before any write, the Branch-model strategy mapping, a single guarded merge
# call (never --admin / --auto / --delete-branch), required checks only, the rerun route and the
# guarded cleanup order — plus the Azure DevOps strings other tests pin and the /push hint; then
# the hardening: long-lived heads (KEEP) never deleted, the merge-queue / moved-PR read before the
# merge, rerun MERGE_SHA and lookup, failed-switch skip, exact ls-remote refs, the quoted Azure
# message, G3(c) push-vs-pull, the git_host none fallback and /push inside /pr-create.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
F="$ST/.claude/commands/pr-merge.md"
fail() { echo "pr-merge-github-test: FAIL — $*"; exit 1; }
has() { grep -qF -- "$1" "$F" || fail "pr-merge.md lacks: $1"; }
N=0

FRONT=$(awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit } f' "$F")
BODY=$(awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { f = 0; b = 1; next } b' "$F")
# First body line matching a fixed string, optionally only after line $2; empty when absent.
line_of() { printf '%s\n' "$BODY" | awk -v p="$1" -v from="${2:-0}" 'NR > from && index($0, p) { print NR; exit }'; }
# Body line of a `## ` heading; the GitHub section runs from it to the next `## ` heading.
heading() { printf '%s\n' "$BODY" | awk -v h="$1" '$0 == h { print NR; exit }'; }
GH=$(heading '## GitHub path')
[ -n "$GH" ] || fail "no ## GitHub path section"
GH_END=$(printf '%s\n' "$BODY" | awk -v s="$GH" 'NR > s && /^## / { print NR; exit }')
[ -n "$GH_END" ] || GH_END=$(printf '%s\n' "$BODY" | wc -l | tr -d ' ')
SECTION=$(printf '%s\n' "$BODY" | awk -v s="$GH" -v e="$GH_END" 'NR > s && NR < e')
in_gh() { printf '%s\n' "$SECTION" | grep -qF -- "$1" || fail "GitHub path lacks: $1"; }
# Line inside the GitHub section, as a body line number.
gh_line() { local l; l=$(line_of "$1" "$GH"); [ -n "$l" ] && [ "$l" -lt "$GH_END" ] && echo "$l"; }

# (1) allowed-tools: the read-only gh probes, never a merge, a ready or an admin flag.
TOOLS=$(printf '%s\n' "$FRONT" | sed -n 's/^allowed-tools: //p')
[ -n "$TOOLS" ] || fail "no allowed-tools line"
for t in 'Bash(gh pr view:*)' 'Bash(gh pr list:*)' 'Bash(gh pr checks:*)' 'Bash(gh api user:*)'; do
  case "$TOOLS" in *"$t"*) ;; *) fail "allowed-tools lacks $t" ;; esac
done
case "$TOOLS" in *"pr merge"*|*"pr ready"*|*"--admin"*) fail "allowed-tools pre-approves a write: $TOOLS" ;; esac
N=$((N + 1))

# (2) Provider routing comes first and names the profile keys and the `none` STOP.
PV=$(heading '## Provider')
AZ=$(heading '## Azure DevOps path')
[ -n "$PV" ] && [ -n "$AZ" ] || fail "no ## Provider or ## Azure DevOps path section"
[ "$PV" -lt "$AZ" ] && [ "$PV" -lt "$GH" ] || fail "## Provider does not precede both paths"
PV_END=$(printf '%s\n' "$BODY" | awk -v s="$PV" 'NR > s && /^## / { print NR; exit }')
PSEC=$(printf '%s\n' "$BODY" | awk -v s="$PV" -v e="$PV_END" 'NR > s && NR < e')
for p in 'teams.pr_provider' 'git_host' 'teams.pr_provider is none'; do
  printf '%s\n' "$PSEC" | grep -qF -- "$p" || fail "## Provider lacks: $p"
done
N=$((N + 1))

# (3) Refusals before any write: role session, team anchor and own-branch check precede the
#     first `gh pr ready` and the merge call.
READY=$(gh_line 'gh pr ready') || fail "no gh pr ready in the GitHub path"
MERGE=$(gh_line 'gh pr merge <n>') || fail "no gh pr merge <n> in the GitHub path"
for p in '.agents/team/session.json' '.agents/team/team.json' '.agents/team/anchors' 'refs/heads/<HEAD>' 'the PR head moved after the ownership check'; do
  l=$(gh_line "$p") || fail "GitHub path lacks: $p"
  [ "$l" -lt "$READY" ] && [ "$l" -lt "$MERGE" ] || fail "$p comes after a write (line $l)"
done
OWN=$(gh_line 'refs/heads/<HEAD>')
printf '%s\n' "$BODY" | sed -n "${OWN}p" | grep -qF 'HEAD_SHA' || fail "the own-branch check does not compare with HEAD_SHA"
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
printf '%s\n' "$BODY" | sed -n "${OTHER}p" | grep -qF 'STOP' || fail "'any other failure' is not a STOP"
CHECKS=$(gh_line 'gh pr checks') || fail "no gh pr checks in the GitHub path"
[ "$CHECKS" -lt "$MERGE" ] || fail "gh pr checks does not precede the merge"
N=$((N + 5))

# (7) Rerun: an already merged PR goes through the tracker step and the cleanup.
RR=$(gh_line '| `state: MERGED` |') || fail "no state: MERGED row"
RL=$(printf '%s\n' "$BODY" | sed -n "${RR}p")
case "$RL" in *'Step G6'*'Step G7'*) ;; *) fail "the MERGED row does not route to Step G6 then Step G7" ;; esac
N=$((N + 1))

# (8) Cleanup order inside G7; both deletions guarded by HEAD_SHA on their own line.
G7=$(gh_line '### Step G7') || fail "no Step G7"
prev=$G7
for p in '--head <HEAD> --state open' 'git ls-remote --exit-code' 'git push origin --delete' 'git switch <BASE>' 'git pull --ff-only' 'git branch -D' 'git fetch origin --prune'; do
  l=$(line_of "$p" "$G7"); [ -n "$l" ] && [ "$l" -lt "$GH_END" ] || fail "Step G7 lacks: $p"
  [ "$l" -gt "$prev" ] || fail "Step G7 order: $p (line $l) not after line $prev"
  prev=$l
done
for p in 'git push origin --delete' 'git branch -D'; do
  l=$(line_of "$p" "$G7")
  printf '%s\n' "$BODY" | sed -n "${l}p" | grep -qF 'HEAD_SHA' || fail "$p is not guarded by HEAD_SHA on its line"
done
N=$((N + 2))

# (9) The Azure DevOps strings other tests pin are still there.
has 'teams.policy.pr.self_approve is off'
has '**4a**, then **5a**'
has '**4a**, then **5b**'
N=$((N + 3))

# (10) /push names the next step on a pr-only repo; /pr-create no longer says "azure-devops only".
P="$ST/.claude/commands/push.md"
grep -qF 'Next: /pr-create, then /pr-merge.' "$P" || fail "push.md lacks the /pr-merge next-step line"
grep -qF 'Next: /pr-create, then merge the PR on the host.' "$P" || fail "push.md lacks the host-merge next-step line"
! grep -qF "(azure-devops) or the host's merge" "$ST/.claude/commands/pr-create.md" \
  || fail "pr-create.md still limits /pr-merge to azure-devops"
N=$((N + 3))

# Azure DevOps section bounds (it ends where the GitHub path starts).
[ "$AZ" -lt "$GH" ] || fail "## Azure DevOps path does not precede ## GitHub path"
az_line() { local l; l=$(line_of "$1" "${2:-$AZ}"); [ -n "$l" ] && [ "$l" -lt "$GH" ] && echo "$l"; }
GR=$(heading '## Guardrails') || true
[ -n "$GR" ] || fail "no ## Guardrails section"
GR_END=$(printf '%s\n' "$BODY" | awk -v s="$GR" 'NR > s && /^## / { print NR; exit }')
GSEC=$(printf '%s\n' "$BODY" | awk -v s="$GR" -v e="$GR_END" 'NR > s && NR < e')

# (11) KEEP: one definition in ## Guardrails from branch-model.sh, with the /push fallback; the
#      read-only tools are pre-approved, a GraphQL call (could be a mutation) is not.
for p in 'KEEP' 'branch-model.sh fields' '`main`, `master`, `trunk`, `develop`'; do
  printf '%s\n' "$GSEC" | grep -qF -- "$p" || fail "## Guardrails lacks: $p"
done
for t in 'Bash(bash .claude/lib/branch-model.sh:*)' 'Bash(gh repo view:*)'; do
  case "$TOOLS" in *"$t"*) ;; *) fail "allowed-tools lacks $t" ;; esac
done
case "$TOOLS" in *"gh api graphql"*|*"gh api:"*) fail "allowed-tools pre-approves gh api graphql" ;; esac
N=$((N + 3))

# (12) G5: the long-lived-head and merge-queue reads sit between the checks and the merge call;
#      the queue read STOPs; the post-merge re-read watches autoMergeRequest.
for p in 'deleteBranchOnMerge' 'isMergeQueueEnabled'; do
  l=$(gh_line "$p") || fail "GitHub path lacks: $p"
  [ "$l" -gt "$CHECKS" ] && [ "$l" -lt "$MERGE" ] || fail "$p is not between gh pr checks and the merge (line $l)"
done
Q=$(gh_line 'isMergeQueueEnabled: true') || fail "no isMergeQueueEnabled: true rule"
printf '%s\n' "$BODY" | sed -n "${Q},$((Q + 2))p" | grep -qF 'STOP' || fail "isMergeQueueEnabled: true is not a STOP"
in_gh 'the PR moved after the checks'
AM=$(gh_line 'autoMergeRequest') || fail "GitHub path lacks autoMergeRequest"
[ "$AM" -gt "$MERGE" ] || fail "autoMergeRequest does not follow the merge call"
N=$((N + 4))

# (13) G7: the KEEP skip comes before the first remote deletion.
K7=$(line_of 'KEEP' "$G7"); DEL=$(line_of 'git push origin --delete' "$G7")
[ -n "$K7" ] && [ "$K7" -lt "$DEL" ] || fail "Step G7 has no KEEP skip before git push origin --delete"
N=$((N + 1))

# (14) Rerun MERGE_SHA comes from the MERGED row; G6 has no own re-read.
case "$RL" in *MERGE_SHA*) ;; *) fail "the MERGED row does not set MERGE_SHA" ;; esac
G6=$(gh_line '### Step G6') || fail "no Step G6"
printf '%s\n' "$BODY" | awk -v s="$G6" -v e="$G7" 'NR > s && NR < e' | grep -qF -- '--json mergeCommit' \
  && fail "Step G6 still re-reads mergeCommit"
N=$((N + 2))

# (15) G2: the argument-less rerun lookup, guarded by the local tip.
G2=$(gh_line '### Step G2') || fail "no Step G2"
G3=$(gh_line '### Step G3') || fail "no Step G3"
for p in '--state merged' 'refs/heads/<BRANCH>'; do
  l=$(line_of "$p" "$G2"); [ -n "$l" ] && [ "$l" -lt "$G3" ] || fail "Step G2 lacks: $p"
done
N=$((N + 2))

# (16) A failed switch skips the rest of the local cleanup, on both paths.
SW=$(line_of 'git switch <BASE>' "$G7")
printf '%s\n' "$BODY" | sed -n "${SW},$((SW + 1))p" | grep -qF 'skip the rest' || fail "Step G7: no skip after a failed git switch <BASE>"
A6=$(az_line '### Step 6 — Cleanup') || fail "no Azure Step 6 — Cleanup"
SWA=$(az_line 'git switch <TARGET>' "$A6") || fail "Azure Step 6 lacks git switch <TARGET>"
printf '%s\n' "$BODY" | sed -n "${SWA},$((SWA + 2))p" | grep -qF 'skip the rest' || fail "Azure Step 6: no skip after a failed git switch <TARGET>"
N=$((N + 2))

# (17) ls-remote matches the exact ref on both paths.
grep -qF 'ls-remote --heads' "$F" && fail "pr-merge.md still uses ls-remote --heads"
LR=$(line_of 'git ls-remote --exit-code' "$G7")
printf '%s\n' "$BODY" | sed -n "${LR}p" | grep -qF 'refs/heads/<HEAD>' || fail "Step G7 ls-remote is not refs/heads/<HEAD>"
LRA=$(az_line 'git ls-remote --exit-code' "$A6") || fail "Azure Step 6 lacks git ls-remote --exit-code"
printf '%s\n' "$BODY" | sed -n "${LRA}p" | grep -qF 'refs/heads/<SOURCE>' || fail "Azure Step 6 ls-remote is not refs/heads/<SOURCE>"
N=$((N + 3))

# (18) Azure: single-quoted merge message, the source branch never deleted by the host.
grep -qF -- '--merge-commit-message "' "$F" && fail "a double-quoted --merge-commit-message is left"
grep -qF -- '--delete-source-branch true' "$F" && fail "--delete-source-branch true is left"
has "--merge-commit-message '<MSG>'"
has '--delete-source-branch false'
N=$((N + 4))

# (19) G3(c): local branch ahead of the PR head → push, not pull.
for p in 'merge-base --is-ancestor' 'run /push'; do
  l=$(line_of "$p" "$G3"); [ -n "$l" ] && [ "$l" -lt "$(gh_line '### Step G4')" ] || fail "Step G3 lacks: $p"
done
N=$((N + 2))

# (20) ## Provider: git_host none falls back to the origin host.
printf '%s\n' "$PSEC" | grep -qF 'git_host: none' || fail "## Provider does not name git_host: none"
printf '%s\n' "$PSEC" | grep -qF '`origin` host' || fail "## Provider lacks the origin fallback"
N=$((N + 2))

# (21) /push skips its next-step line inside /pr-create.
grep -qF '`/pr-create` Step 5' "$P" || fail "push.md does not skip its next-step line inside /pr-create Step 5"
grep -F '`/pr-create` Step 5' "$P" | grep -qF 'skipped' || fail "push.md's /pr-create Step 5 line does not say skipped"
N=$((N + 2))

# (22) Azure Step 6.1: KEEP, the other-active-PR lookup and the MERGED_SRC keep rule precede the
#      remote deletion; Step 6.2 deletes the local branch only outside KEEP at MERGED_SRC.
A7=$(az_line '### Step 7' "$A6") || fail "no Azure Step 7"
a6_line() { local l; l=$(line_of "$1" "$A6"); [ -n "$l" ] && [ "$l" -lt "$A7" ] && echo "$l"; }
ADEL=$(a6_line 'git push origin --delete <SOURCE>') || fail "Azure Step 6 lacks git push origin --delete <SOURCE>"
for p in 'lastMergeSourceCommit' 'KEEP' '--source-branch "<SOURCE>" --status active' 'differs from `MERGED_SRC`'; do
  l=$(a6_line "$p") || fail "Azure Step 6 lacks: $p"
  [ "$l" -lt "$ADEL" ] || fail "Azure Step 6: $p (line $l) not before the remote deletion"
done
MV=$(a6_line 'differs from `MERGED_SRC`')
printf '%s\n' "$BODY" | sed -n "${MV},$((MV + 1))p" | grep -qF 'kept' || fail "Azure Step 6: a moved origin/<SOURCE> is not kept"
ABD=$(a6_line 'git branch -D <SOURCE>') || fail "Azure Step 6 lacks git branch -D <SOURCE>"
for p in 'KEEP' 'MERGED_SRC'; do
  printf '%s\n' "$BODY" | sed -n "$((ABD - 1)),${ABD}p" | grep -qF "$p" || fail "Azure git branch -D <SOURCE> is not guarded by $p"
done
N=$((N + 7))

# (23) G5 STOPs: deleteBranchOnMerge true and a failed read each STOP (separate messages, no
#      "merge on the host keeping the branch" advice); the GraphQL failed read STOPs.
DB=$(gh_line 'deleteBranchOnMerge --jq') || fail "no deleteBranchOnMerge read"
printf '%s\n' "$BODY" | sed -n "$((DB + 1))p" | grep -qF '`true` → STOP' || fail "deleteBranchOnMerge true is not a STOP"
DBF=$(line_of 'cannot read `deleteBranchOnMerge`' "$DB") || true
[ -n "$DBF" ] && [ "$DBF" -lt "$MERGE" ] || fail "no own STOP message for a failed deleteBranchOnMerge read"
printf '%s\n' "$BODY" | sed -n "$((DBF - 1)),${DBF}p" | grep -qF 'A failed read → STOP with the error verbatim' \
  || fail "a failed deleteBranchOnMerge read is not a STOP with the error"
in_gh 'a merge on the host deletes it too'
printf '%s\n' "$SECTION" | grep -qF 'merge on the host keeping the branch' && fail "G5 still advises a host merge keeping the branch"
GQ=$(gh_line 'unreadable is not "no queue"') || fail "no GraphQL failed-read rule"
printf '%s\n' "$BODY" | sed -n "${GQ}p" | grep -qF 'A failed read → STOP' || fail "the GraphQL failed read is not a STOP"
[ "$GQ" -lt "$MERGE" ] || fail "the GraphQL failed-read STOP does not precede the merge"
N=$((N + 6))

# (24) The rerun MERGE_SHA source, the merged-fallback tip STOP, the Azure quote escape, the
#      Provider STOP scope.
case "$RL" in *'mergeCommit.oid'*) ;; *) fail "the MERGED row does not name mergeCommit.oid" ;; esac
GV=$(line_of '`<n>` → `gh pr view <n>' "$G2") || fail "Step G2 lacks the gh pr view <n> read"
printf '%s\n' "$BODY" | sed -n "${GV}p" | grep -qF ',mergeCommit' || fail "Step G2's gh pr view does not request mergeCommit"
TM=$(line_of 'local tip different or absent' "$G2"); [ -n "$TM" ] && [ "$TM" -lt "$G3" ] || fail "Step G2 lacks the tip-mismatch rule"
printf '%s\n' "$BODY" | sed -n "${TM}p" | grep -qF 'STOP' || fail "the merged-fallback tip mismatch is not a STOP"
# grep, not line_of: awk -v would read the backslash as an escape.
printf '%s\n' "$BODY" | awk -v s="$AZ" -v e="$GH" 'NR > s && NR < e' | grep -qF -- "each \`'\` of the title written as \`'\\''\`" \
  || fail "the Azure message lacks the '\\'' escape rule"
printf '%s\n' "$PSEC" | grep -qF '`none` read from `teams.pr_provider` → STOP' || fail "the Provider STOP is not scoped to teams.pr_provider"
printf '%s\n' "$PSEC" | grep -qF -- '- `none` → STOP' && fail "## Provider still STOPs on any none"
N=$((N + 6))

# (25) KEEP never leaves out the fallback names: an empty protected= falls back as in /push
#      step 2, any other non-zero exit keeps every branch.
for p in 'empty `protected=`' 'block absent or field empty' 'Any other non-zero exit' 'every source/head branch counts as in `KEEP`'; do
  printf '%s\n' "$GSEC" | grep -qF -- "$p" || fail "## Guardrails KEEP lacks: $p"
done
N=$((N + 4))

# (26) Re-run notice on an Azure timeout; reports follow the skip and keep paths.
A5C=$(az_line '**5c. Wait for it**') || fail "no Azure 5c"
TO=$(line_of 'Timeout →' "$A5C"); [ -n "$TO" ] && [ "$TO" -lt "$A7" ] || fail "Azure 5c lacks its timeout exit"
printf '%s\n' "$BODY" | sed -n "${TO},$((TO + 2))p" | grep -qF 're-run after the PR completes' || fail "Azure 5c timeout does not say a re-run deletes the branch"
A7SEC=$(printf '%s\n' "$BODY" | awk -v s="$A7" -v e="$GH" 'NR > s && NR < e')
for p in 'deleted only by a re-run' 'tip ≠ `MERGED_SRC`' 'failed switch'; do
  printf '%s\n' "$A7SEC" | grep -qF -- "$p" || fail "Azure Step 7 lacks: $p"
done
G73=$(line_of '**Base state**' "$G7"); [ -n "$G73" ] && [ "$G73" -lt "$GH_END" ] || fail "Step G7 lacks item 3"
printf '%s\n' "$BODY" | sed -n "${G73}p" | grep -qF 'only when item 2 reached its pull' || fail "Step G7 item 3 is not skipped with item 2"
in_gh 'skipped — why, with no base-state line'
N=$((N + 7))

echo "pr-merge-github-test: OK ($N checks)"
