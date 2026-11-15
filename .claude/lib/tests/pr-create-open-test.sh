#!/usr/bin/env bash
# Offline test of /pr-create's opt-in opener (Step 7a): off = no host call and no question; the
# create calls stay out of allowed-tools; the preview shows the full description first; the
# existing-PR lookup runs before and after the create with the fork-safe identity filter.
set -euo pipefail

ST=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
F="$ST/.claude/commands/pr-create.md"
fail() { echo "pr-create-open-test: FAIL — $*"; exit 1; }
has() { grep -qF -- "$1" "$F" || fail "pr-create.md lacks: $1"; }
N=0

FRONT=$(awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit } f' "$F")
BODY=$(awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { f = 0; b = 1; next } b' "$F")

# (1) allowed-tools: read-only probes only — never a create, merge or publish.
TOOLS=$(printf '%s\n' "$FRONT" | sed -n 's/^allowed-tools: //p')
[ -n "$TOOLS" ] || fail "no allowed-tools line"
case "$TOOLS" in *"pr create"*|*"pr merge"*|*"pr update"*|*"pr ready"*) fail "allowed-tools pre-approves a PR write: $TOOLS" ;; esac
N=$((N + 1))

# (2) Off path: inside the body, the Step 7a opt-in skip rule comes before every executable host
#     call and before the Create question; the steps before 7a never call a host PR API.
S7A=$(printf '%s\n' "$BODY" | grep -n '^### Step 7a — Open the PR (opt-in)' | cut -d: -f1)
[ -n "$S7A" ] || fail "no Step 7a"
OPT=$(printf '%s\n' "$BODY" | grep -nF '**Opt-in:** `workflow.pr_open`' | head -1 | cut -d: -f1)
[ -n "$OPT" ] && [ "$OPT" -gt "$S7A" ] || fail "the opt-in rule is not inside Step 7a"
FIRST_TEXT=$(printf '%s\n' "$BODY" | awk -v s="$S7A" 'NR > s && NF { print NR; exit }')
[ "$FIRST_TEXT" = "$OPT" ] || fail "the opt-in skip rule is not the first line of Step 7a"
printf '%s\n' "$BODY" | grep -qF 'no host API call, no question' || fail "the skip rule does not rule out calls and questions"
CALLS=$(printf '%s\n' "$BODY" | grep -nE '`(gh (api|pr) |az repos )' | cut -d: -f1)
for l in $CALLS; do [ "$l" -gt "$OPT" ] || fail "a host call at body line $l precedes the opt-in rule"; done
ASK=$(printf '%s\n' "$BODY" | grep -n 'Create PR\*\* · \*\*Create as draft' | cut -d: -f1)
[ -n "$ASK" ] && [ "$ASK" -gt "$OPT" ] || fail "the Create question is not after the opt-in rule"
N=$((N + 5))

# (3) The preview: full description before Create; immediacy named.
has 'the user sees the
   **full** description before Create'
has 'Anything but
   Create → no create call.'
N=$((N + 2))

# (4) Create calls: the body file from the git dir, the lookup before and after, no retry flags.
has 'git rev-parse --git-path PR_DESCRIPTION.md'
has '--body-file <path from 4>'
has '--description @<path from 4>'
L5=$(printf '%s\n' "$BODY" | grep -n '^5\. \*\*Find the PR this branch already has\*\* (before the create, and again after it)' | cut -d: -f1)
L6=$(printf '%s\n' "$BODY" | grep -n '^6\. \*\*Create\*\*' | cut -d: -f1)
[ -n "$L5" ] && [ -n "$L6" ] && [ "$L5" -lt "$L6" ] || fail "the lookup does not precede the create"
has 'run step 5 again'
has 'headRepositoryOwner.login + "/" + headRepository.name'
has 'sourceRefName` = `refs/heads/<BRANCH>`'
has 'not the previewed `DEST`'
N=$((N + 8))

# (5) Bans appear only as prohibitions, never as instructions.
while IFS= read -r line; do
  case "$line" in *[Nn]ever*) ;; *) fail "a ban flag outside a prohibition: $line" ;; esac
done < <(printf '%s\n' "$BODY" | grep -E -- '--auto-complete|--bypass-policy|gh pr merge' || true)
N=$((N + 1))

# (6) Identity is never claimed for Azure; profile example defaults off.
has 'not verified — the identity behind your `az repos` credentials'
jq -e '.workflow.pr_open == false and (.workflow._pr_open_doc | length) > 0' \
  "$ST/.claude/project-profile.json.example" >/dev/null || fail "profile example: workflow.pr_open must default to false, with a doc line"
N=$((N + 2))

echo "pr-create-open-test: OK ($N checks)"
