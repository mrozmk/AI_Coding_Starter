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
N=$((N + 1))

echo "pr-merge-github-test: OK ($N checks)"
