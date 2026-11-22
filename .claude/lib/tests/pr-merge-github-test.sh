#!/usr/bin/env bash
# Offline contract test of /pr-merge's GitHub path: provider routing, the team-run / fork /
# ownership refusals before any write, the Branch-model strategy mapping, a single guarded merge
# call (never --admin / --auto / --delete-branch), required checks only, the rerun route and the
# guarded cleanup order — plus the Azure DevOps strings other tests pin and the /push hint.
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

echo "pr-merge-github-test: OK ($N checks)"
