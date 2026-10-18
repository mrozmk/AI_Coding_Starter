#!/usr/bin/env bash
# Offline smoke for team-pr.sh (the github PR provider): coords, the lifecycle/readiness split,
# identity and forks, the merge-ref parent invariant, and state-dependent `create` idempotence.
# `gh` is a stub on PATH and the origin is a local bare repo, so nothing reaches the network;
# `refs/pull/<n>/merge` is built by the fixture exactly the way GitHub builds it.
# Bash 3.2 compatible (macOS /bin/bash) — run it with /bin/bash, like the harness does.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init

export SMOKE_ORIGIN=github
GH_DIR="$WORK/gh"
GH_LOG="$WORK/gh.log"
export GH_DIR GH_LOG
mkdir -p "$GH_DIR"
: > "$GH_LOG"
smoke_gh_stub
chmod +x "$WORK/bin/gh"

PR="bash .claude/lib/team-pr.sh"
P="$MAIN/.claude/project-profile.json"
TRUNK=develop-netcore7
GH_PROFILE='.teams.pr_provider = "github" | .teams.tracker = "none"
  | .teams.github = {repo: "acme/widgets"}
  | .teams.required_tools = ["git", "jq", "gh"]'
setprofile() { smoke_profile "${1:-$GH_PROFILE}" > "$P"; }
setprofile

creates() { grep -c -- 'pr create' "$GH_LOG" | tr -d ' '; }
bare() { git --git-dir="$WORK/origin.git" "$@"; }
pr_file() {  # pr_file <n> <head> <base> <isDraft> [owner] [closed] [headRefOid]
  jq -n --argjson n "$1" --arg h "$2" --arg b "$3" --argjson d "$4" \
    --arg o "${5:-acme}" --argjson c "${6:-false}" --arg oid "${7:-}" \
    '{number: $n, isDraft: $d, headRefName: $h, baseRefName: $b,
      headRepositoryOwner: {login: $o}, headRepository: {name: "widgets"},
      mergeable: "MERGEABLE", body: "the body\n", closed: $c, headRefOid: $oid}' \
    > "$GH_DIR/pr-$1.json"
}
body_file() { printf '%s\n' "${2:-a pr body}" > "$1"; }
BF="$WORK/body.md"; body_file "$BF"

# ================================================================================================
# (A1) coords — the origin must be a github.com URL AND the profile's repo
# ================================================================================================
run "$MAIN" $PR coords
expect 0 "acme/widgets" "coords reads owner/repo from the origin URL"

SMOKE_ORIGIN=ado
run "$MAIN" $PR coords
expect 2 "origin is not a github.com repo" "an ADO origin is refused, not guessed"
SMOKE_ORIGIN=github

setprofile "${GH_PROFILE//acme\/widgets/acme\/other}"
run "$MAIN" $PR coords
expect 2 "is not teams.github.repo acme/other" "an origin that is not the profile's repo is refused"
setprofile

# ================================================================================================
# (A2) state — lifecycle only; a merged or closed PR with no branch still answers (Amendment 5)
# ================================================================================================
smoke_gh_commit "feature/L1-x" l1
pr_file 8 "feature/L1-x" "$TRUNK" true
run "$MAIN" $PR state 8
expect 0 '"status":"active"' "state of an open PR is active"
has '"draft":true' "$WORK/out" || fail "state lost the draft flag"
has '"source_ref":"refs/heads/feature/L1-x"' "$WORK/out" || fail "state lost the source ref"
has '"target_ref":"refs/heads/develop-netcore7"' "$WORK/out" || fail "state lost the target ref"
has "\"source_sha\":\"$(bare rev-parse refs/heads/feature/L1-x)\"" "$WORK/out" \
  || fail "state lost the head sha"

# Merged on its own base line, then the head branch is deleted — the sha survives in the PR record.
bare branch rel-merged "$TRUNK"
smoke_gh_commit "feature/L2-done" l2
MERGED_OID="$(bare rev-parse refs/heads/feature/L2-done)"
smoke_gh_land "feature/L2-done" rel-merged
bare update-ref -d "refs/heads/feature/L2-done"
pr_file 9 "feature/L2-done" rel-merged false acme false "$MERGED_OID"
run "$MAIN" $PR state 9
expect 0 '"status":"completed"' "a merged PR whose head branch is gone still reads as completed"

pr_file 10 "feature/L9-gone" "$TRUNK" false acme true
run "$MAIN" $PR state 10
expect 0 '"status":"abandoned"' "a closed PR with no branch and no merge ref reads as abandoned"

run "$MAIN" $PR state 404
expect 4 "gh pr view #404 failed" "an unreadable PR is recoverable, not a refusal"
run "$MAIN" $PR state abc
expect 2 "must be a number" "a non-numeric PR id is a usage error"

# ================================================================================================
# (A3) identity — active, our repo, both refs exact; a fork is its own refusal
# ================================================================================================
run "$MAIN" $PR identity 8 "feature/L1-x" "$TRUNK"
expect 0 "" "identity accepts the matching active PR"
run "$MAIN" $PR identity 8 "feature/L1-x" rel-merged
expect 3 "PR #8 identity mismatch" "a different base is a refusal"
run "$MAIN" $PR identity 8 "feature/other" "$TRUNK"
expect 3 "PR #8 identity mismatch" "a different source is a refusal"

pr_file 12 "feature/L1-x" "$TRUNK" false evil
run "$MAIN" $PR identity 12 "feature/L1-x" "$TRUNK"
expect 3 "PR #12 is from a fork (evil/widgets)" "a fork is refused before the refs are compared"

# ================================================================================================
# (A4) readiness — `ok` only when the merge ref's parents are the tip we checked and the PR head
# ================================================================================================
run "$MAIN" $PR readiness 8
expect 4 '"merge":"pending"' "no merge ref yet is pending, not a refusal"

smoke_gh_pull 8 "feature/L1-x" "$TRUNK"
run "$MAIN" $PR readiness 8
expect 0 '"merge":"ok"' "a merge ref with the right parents is ready"
has '"parents_ok":true' "$WORK/out" || fail "readiness ok without parents_ok"
has "\"merge_sha\":\"$(bare rev-parse refs/pull/8/merge)\"" "$WORK/out" \
  || fail "readiness reported another merge sha"
# The integrator's contract: the tested commit sits under a ref WE own, not FETCH_HEAD.
[ "$(git -C "$MAIN" rev-parse refs/team-pr/8/merge)" = "$(bare rev-parse refs/pull/8/merge)" ] \
  || fail "readiness ok but the merge commit is not under refs/team-pr/8/merge"

# FETCH_HEAD is global: a concurrent fetch rewriting it must not move the verdict either way.
printf '%s\t\t\n' "$(bare rev-parse refs/heads/develop-netcore7)" > "$MAIN/.git/FETCH_HEAD"
run "$MAIN" $PR readiness 8
expect 0 '"merge":"ok"' "a swapped FETCH_HEAD does not change the verdict"
has '"parents_ok":true' "$WORK/out" || fail "a swapped FETCH_HEAD broke parents_ok"

# An octopus merge M(T,S,X): parent 1 and parent 2 are right, parent 3 never saw a gate.
smoke_gh_commit "feature/LX-extra" lx
smoke_gh_pull_octopus 8 "feature/L1-x" "$TRUNK" "feature/LX-extra"
# Assert the FIXTURE really built three parents: `git merge A B` quietly degrades to a two-parent
# merge (or a fast-forward) whenever it can, and then this case would prove nothing.
[ "$(bare rev-list --parents -n 1 refs/pull/8/merge | awk '{print NF - 1}')" = 3 ] \
  || fail "the octopus fixture built $(bare rev-list --parents -n 1 refs/pull/8/merge \
    | awk '{print NF - 1}') parents, not 3"
run "$MAIN" $PR readiness 8
expect 4 '"merge":"pending"' "an octopus merge ref is never ok, however right its first parents"
has '"parents_ok":false' "$WORK/out" || fail "an octopus merge ref claimed parents_ok"
smoke_gh_pull 8 "feature/L1-x" "$TRUNK"
run "$MAIN" $PR readiness 8
expect 0 '"merge":"ok"' "a two-parent merge ref is ready again after the octopus"

export STUB_GH_MERGEABLE=UNKNOWN
run "$MAIN" $PR readiness 8
expect 4 '"merge":"pending"' "mergeable=UNKNOWN is pending — GitHub is still recomputing"
STUB_GH_MERGEABLE=CONFLICTING
run "$MAIN" $PR readiness 8
expect 3 '"merge":"conflict"' "a conflicting PR is a refusal with the state printed"
unset STUB_GH_MERGEABLE

# The merge ref was built against an older tip: parent 1 no longer is the base.
smoke_gh_pull_stale 8 "feature/L1-x" "$TRUNK"
run "$MAIN" $PR readiness 8
expect 4 '"merge":"pending"' "a stale merge ref (parent 1 != base) is pending"
has '"parents_ok":false' "$WORK/out" || fail "a stale merge ref claimed parents_ok"

# The second generation of the same ref: GitHub recomputes, the fixture force-pushes it.
smoke_gh_pull 8 "feature/L1-x" "$TRUNK"
run "$MAIN" $PR readiness 8
expect 0 '"merge":"ok"' "a recomputed merge ref is ready again"

# The head moved after the ref was built: parent 2 no longer is the PR head.
smoke_gh_commit "feature/L1-x" l1b
run "$MAIN" $PR readiness 8
expect 4 '"merge":"pending"' "a merge ref whose parent 2 is not the head is pending"
has '"parents_ok":false' "$WORK/out" || fail "a moved head claimed parents_ok"

run "$MAIN" $PR readiness 12
expect 3 "is from a fork" "readiness refuses a fork before it touches any ref"
run "$MAIN" $PR readiness 10
expect 3 "identity mismatch" "readiness refuses a closed PR"

# ================================================================================================
# (A5) create — state-dependent idempotence (Amendment 7); a fork's PR on the same branch is not ours
# ================================================================================================
smoke_gh_commit "feature/L3-new" l3
run "$MAIN" $PR create --draft --head "feature/L3-new" --base "$TRUNK" --title T --body-file "$BF"
expect 0 "pr=41" "create --draft opens the first PR"
[ "$(creates)" = 1 ] || fail "create called gh pr create $(creates) times"

run "$MAIN" $PR create --draft --head "feature/L3-new" --base "$TRUNK" --title T --body-file "$BF"
expect 0 "pr=41" "create --draft on an existing draft returns it"
[ "$(creates)" = 1 ] || fail "the idempotent create opened a second PR"

run "$MAIN" $PR create --ready --head "feature/L3-new" --base "$TRUNK" --title T --body-file "$BF"
expect 0 "pr=41" "create --ready publishes the existing draft and returns it"
grep -q 'pr ready 41' "$GH_LOG" || fail "create --ready did not publish the draft"
[ "$(jq -r .isDraft "$GH_DIR/pr-41.json")" = false ] || fail "PR 41 is still a draft"

run "$MAIN" $PR create --draft --head "feature/L3-new" --base "$TRUNK" --title T --body-file "$BF"
expect 3 "PR #41 is already published — not reverting" "create --draft never un-publishes a PR"

run "$MAIN" $PR create --ready --head "feature/L3-new" --base "$TRUNK" --title T --body-file "$BF"
expect 0 "pr=41" "create --ready on a published PR returns it"
[ "$(creates)" = 1 ] || fail "create opened a PR for an already published pair"

# Two of OUR open PRs for the same pair: refuse, never pick one.
pr_file 42 "feature/L3-new" "$TRUNK" true
C0="$(creates)"
run "$MAIN" $PR create --draft --head "feature/L3-new" --base "$TRUNK" --title T --body-file "$BF"
expect 3 "ambiguous: 41,42 open for feature/L3-new → develop-netcore7" "two open PRs are ambiguous"
[ "$(creates)" = "$C0" ] || fail "an ambiguous create still called gh pr create"
rm -f "$GH_DIR/pr-42.json"

# The uncertain write: the PR really is created, the client gets an error. The retry must find it.
smoke_gh_commit "feature/L5-flaky" l5
export STUB_GH_CREATE_FAIL_AFTER=1
run "$MAIN" $PR create --draft --head "feature/L5-flaky" \
  --base "$TRUNK" --title T --body-file "$BF"
unset STUB_GH_CREATE_FAIL_AFTER
expect 0 "pr=" "a create whose answer was lost still reports the PR it made"
FL="$(sed -n 's/^pr=//p' "$WORK/out")"
[ -f "$GH_DIR/pr-$FL.json" ] || fail "the flaky create reported a PR with no record"
[ "$(for f in "$GH_DIR"/pr-*.json; do jq -r .headRefName "$f"; done | grep -c 'feature/L5-flaky')" = 1 ] \
  || fail "the flaky create left two PRs for feature/L5-flaky"

# The create raced: the answer was lost AND the PR that landed is in the opposite state to the
# one asked for. The rules of Amendment 7 must apply to that result too, not just to a pre-existing
# PR — otherwise `create` hands back a published PR to a `--draft` caller.
smoke_gh_commit "feature/L7-race" l7
export STUB_GH_CREATE_RACE=ready
run "$MAIN" $PR create --draft --head "feature/L7-race" --base "$TRUNK" --title T --body-file "$BF"
unset STUB_GH_CREATE_RACE
expect 3 "is already published — not reverting" \
  "a raced create that landed published is refused, not returned as a draft"

smoke_gh_commit "feature/L8-race" l8
export STUB_GH_CREATE_RACE=draft
run "$MAIN" $PR create --ready --head "feature/L8-race" --base "$TRUNK" --title T --body-file "$BF"
unset STUB_GH_CREATE_RACE
expect 0 "pr=" "a raced create that landed as a draft is published, not returned as a draft"
RC8="$(sed -n 's/^pr=//p' "$WORK/out")"
[ "$(jq -r .isDraft "$GH_DIR/pr-$RC8.json")" = false ] \
  || fail "the raced --ready create left the PR a draft"
grep -q "pr ready $RC8" "$GH_LOG" || fail "the raced --ready create never published"

# A fork's open PR on an identically named branch must be invisible to create/publish.
smoke_gh_commit "feature/L4-x" l4
pr_file 20 "feature/L4-x" "$TRUNK" true evil
run "$MAIN" $PR create --draft --head "feature/L4-x" --base "$TRUNK" --title T --body-file "$BF"
expect 0 "pr=" "create ignores a fork's PR on the same branch name and opens ours"
MINE="$(sed -n 's/^pr=//p' "$WORK/out")"
[ "$MINE" != 20 ] || fail "create adopted the fork's PR"
[ "$(jq -r .headRepositoryOwner.login "$GH_DIR/pr-$MINE.json")" = acme ] || fail "ours is not ours"
run "$MAIN" $PR create --ready --head "feature/L4-x" --base "$TRUNK" --title T --body-file "$BF"
expect 0 "pr=$MINE" "create --ready publishes ours, not the fork's"
[ "$(jq -r .isDraft "$GH_DIR/pr-20.json")" = true ] || fail "the fork's PR was published"

# ================================================================================================
# (A6) publish / body round-trip, and the ADO refusal
# ================================================================================================
smoke_gh_commit "feature/L6-pub" l6
run "$MAIN" $PR create --draft --head "feature/L6-pub" --base "$TRUNK" --title T --body-file "$BF"
expect 0 "pr=" "a draft to publish by hand"
PUB="$(sed -n 's/^pr=//p' "$WORK/out")"
run "$MAIN" $PR publish "$PUB"
expect 0 "pr=$PUB" "publish readies a draft"
[ "$(jq -r .isDraft "$GH_DIR/pr-$PUB.json")" = false ] || fail "publish left the PR a draft"
run "$MAIN" $PR publish "$PUB"
expect 0 "pr=$PUB" "publish is idempotent — gh pr ready fails on a published PR"

printf 'new body line\nsecond\n' > "$WORK/nb.md"
run "$MAIN" $PR body-set "$PUB" "$WORK/nb.md"
expect 0 "" "body-set writes the file"
run "$MAIN" $PR body-get "$PUB"
expect 0 "new body line" "body-get reads back what body-set wrote"
has "second" "$WORK/out" || fail "body-get lost a line"

setprofile '.teams.pr_provider = "azure-devops"'
for op in coords "state 8" "identity 8 a b" "readiness 8" "publish 8" "body-get 8"; do
  run "$MAIN" $PR $op
  expect 2 "azure-devops uses the team-lib.sh helpers" "team-pr.sh refuses ADO: $op"
done
run "$MAIN" $PR create --draft --head h --base b --title T --body-file "$BF"
expect 2 "azure-devops uses the team-lib.sh helpers" "team-pr.sh refuses ADO: create"
setprofile

# ================================================================================================
# (A7) nothing in this suite ever merged or forced anything through gh
# ================================================================================================
! grep -E 'pr merge|--admin|--force' "$GH_LOG" \
  || fail "the gh log contains a merge/admin/force call"
! grep -nE '^[^#]*(pr merge|--admin|--force)' "$SRC/.claude/lib/team-pr.sh" \
  || fail "team-pr.sh carries a merge/admin/force call"

echo "team-pr-smoke: OK"
