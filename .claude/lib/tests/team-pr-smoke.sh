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
# (B1) prompt render per provider — github leaves no {{key}} and no `az`, ADO keeps its text
# ================================================================================================
KEYS='TEAM|TICKET|BRANCH|LINE|BASE_SHA|RUN|ATTEMPT|PLAN|SPEC|PR|ORG_URL|QA_REPORT|BUILD_CHECK|TEST_GATE'
PROMPTS="planner planner-quick cli coder qa wrapup"
b1_render() {  # b1_render <provider> <host kind> <host> <gates> <prompt> <out>
  ( set -e
    . "$MAIN/.claude/lib/team-tracker-render.sh"
    . "$MAIN/.claude/lib/team-pr-render.sh"
    t="$(team_tracker_render none "$MAIN/.claude/team/tracker" \
      "$(cat "$MAIN/.claude/team/prompts/$5.md")")"
    team_pr_render "$1" "$MAIN/.claude/team/pr" "$2" "$3" "$4" "$t" ) > "$6"
}
for p in $PROMPTS; do
  b1_render github "GitHub repo" "https://github.com/acme/widgets" manual-mql5 "$p" "$WORK/b1-$p" \
    || fail "github render of $p failed"
  sed -E "s/\{\{($KEYS)\}\}/x/g" "$WORK/b1-$p" > "$WORK/b1x-$p"
  ! grep -q '{{' "$WORK/b1x-$p" \
    || { grep -o '{{[A-Z_]*}}' "$WORK/b1x-$p" | sort -u | sed 's/^/  | /'
         fail "github render of $p left unrendered keys"; }
  ! grep -q 'az ' "$WORK/b1x-$p" || fail "github render of $p still calls az"
  ! grep -q 'Azure DevOps org' "$WORK/b1x-$p" || fail "github render of $p still names the ADO org"
done
has 'GitHub repo `https://github.com/acme/widgets`' "$WORK/b1-coder" \
  || fail "the github coder prompt lost the PR host"
has 'team-pr.sh create --draft' "$WORK/b1-coder" || fail "the github coder prompt lost create --draft"
has 'team-pr.sh create --ready' "$WORK/b1-cli" || fail "the github cli prompt lost create --ready"
# The blocks tell the role NOT to run it; what must be gone is the step that ran it (Amendment 6).
! grep -q 'Run `/pr-create`' "$WORK/b1-cli" || fail "the github cli prompt still runs /pr-create"
! grep -q 'Run `/pr-create`' "$WORK/b1-coder" || fail "the github coder prompt still runs /pr-create"
has 'Do not run /pr-create' "$WORK/b1-coder" || fail "the github coder block lost its /pr-create ban"
has 'team-pr.sh publish' "$WORK/b1-qa" || fail "the github qa prompt lost publish"
has 'team-pr.sh body-set' "$WORK/b1-qa" || fail "the github qa prompt lost body-set"
has 'team-pr.sh body-get' "$WORK/b1-wrapup" || fail "the github wrapup prompt lost body-get"
has 'gates=manual-mql5: the MT5 compile and backtest are done by the Operator' "$WORK/b1-qa" \
  || fail "gates=manual-mql5 did not add the gate note"
# gates=auto renders that line exactly as it is today — the note is the only difference.
b1_render github "GitHub repo" "https://github.com/acme/widgets" auto qa "$WORK/b1-qa-auto" \
  || fail "github render of qa with gates=auto failed"
! grep -q 'manual-mql5' "$WORK/b1-qa-auto" || fail "gates=auto still carries the gate note"
[ "$(grep -c . "$WORK/b1-qa")" = "$(grep -c . "$WORK/b1-qa-auto")" ] \
  || fail "the gate note changed the qa prompt's line count"
# The ADO blocks keep the az commands (byte identity itself is proven by $S/i5/render-diff.sh).
b1_render azure-devops "Azure DevOps org" "https://dev.azure.com/o" auto qa "$WORK/b1-qa-ado" \
  || fail "ADO render of qa failed"
has 'az repos pr update --org {{ORG_URL}} --id {{PR}} --draft false' "$WORK/b1-qa-ado" \
  || fail "the ADO qa prompt lost its publish command"
b1_render azure-devops "Azure DevOps org" "https://dev.azure.com/o" auto coder "$WORK/b1-coder-ado" \
  || fail "ADO render of coder failed"
has 'Run `/pr-create` — team mode creates an Azure DevOps draft' "$WORK/b1-coder-ado" \
  || fail "the ADO coder prompt lost /pr-create"
# A missing block file is a hard failure, never a prompt shipped with a live placeholder.
run "$MAIN" /bin/bash -c '. .claude/lib/team-pr-render.sh
  team_pr_render github "$PWD/nowhere" k h auto "x {{PR_CREATE}} y"'
expect 1 "no PR block" "a present placeholder with no block file fails loudly"

# ================================================================================================
# (B2) the base must carry the PR layer: team-new.sh preflight for pr_provider=github
# ================================================================================================
# The guard reads the COMMITTED profile of the base, so each case needs its own published base.
GH_NONE='.teams.pr_provider = "github" | .teams.tracker = "none"
  | .teams.github = {repo: "acme/widgets"}
  | .teams.required_tools = ["git", "jq", "gh"]'
publish_base() {  # publish_base <branch> <profile jq filter>
  git -C "$SEED" switch --quiet -C "$1" develop-netcore7
  smoke_profile "$2" > "$SEED/.claude/project-profile.json"
  git -C "$SEED" add .claude/project-profile.json
  git -C "$SEED" commit --quiet -m "base profile $1"
  git -C "$SEED" push --quiet --force origin "$1"
}
publish_base base-pr "$GH_NONE"
publish_base base-prado '.teams.pr_provider = "azure-devops" | .teams.tracker = "none"'
publish_base base-proth "$GH_NONE | .teams.github.repo = \"acme/elsewhere\""
publish_base base-nopr "$GH_NONE"
git -C "$SEED" rm --quiet .claude/lib/team-pr.sh
git -C "$SEED" commit --quiet -m "no pr layer"
git -C "$SEED" push --quiet --force origin base-nopr
git -C "$SEED" switch --quiet develop-netcore7

no_clone() { [ ! -e "$WORK/main-$1" ] || fail "$2: a refused start left a clone behind"; }
setprofile "$GH_NONE"
chmod 600 "$MAIN/.env"
mkdir -p "$WORK/tkt"
jq -n '{key: "L1", title: "local work", url: "", labels: []}' > "$WORK/tkt/ticket.json"
printf '# L1\nlocal work\n' > "$WORK/tkt/ticket.md"
TKT="--ticket-file $WORK/tkt/ticket.json"

run "$MAIN" $NEW beta L1 feature/L1-pr origin/base-nopr $TKT
expect 1 "cannot run pr_provider=github" "a base without team-pr.sh is refused"
no_clone beta "base without the PR layer"
run "$MAIN" $NEW beta L1 feature/L1-pr origin/base-prado $TKT
expect 1 "cannot run pr_provider=github" "a base whose profile says azure-devops is refused"
no_clone beta "base profile pr_provider=azure-devops"
run "$MAIN" $NEW beta L1 feature/L1-pr origin/base-proth $TKT
expect 1 "cannot run pr_provider=github" "a base pointing at another repo is refused"
no_clone beta "base github repo differs"

export STUB_GH_AUTH=1
run "$MAIN" $NEW beta L1 feature/L1-pr origin/base-pr $TKT
unset STUB_GH_AUTH
expect 1 "gh is not logged in" "a logged-out gh is refused before any clone"
no_clone beta "gh not logged in"

run "$MAIN" $NEW alfa L1 feature/L1-pr origin/base-pr $TKT
expect 0 "branch:" "a base carrying the PR layer and the matching profile starts"
CLONE="$WORK/main-alfa"; TD="$CLONE/.agents/team"
[ -f "$CLONE/.claude/lib/team-pr.sh" ] || fail "the clone has no PR adapter"
[ -f "$CLONE/.claude/team/pr/github-create.md" ] || fail "the clone has no PR blocks"

# ================================================================================================
# (B3) record validation through the runner — check_gh instead of check_ado
# ================================================================================================
BR=feature/L1-pr
LINE0=base-pr
RUN_ID=alfa-20261018-000001; echo "$RUN_ID" > "$TD/run"
RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"
rm -f "$TD/session.json"; rm -rf "$TD/lock" "$TD/acked"
mkdir -p "$CLONE/.agents/plans/active"
printf '# plan\n' > "$CLONE/.agents/plans/active/p.md"
git -C "$CLONE" add .agents/plans/active/p.md
git -C "$CLONE" commit --quiet -m "plan"
PREV="$(git -C "$CLONE" rev-parse HEAD)"
mkdir -p "$CLONE/.agents/plans/done"
git -C "$CLONE" mv .agents/plans/active/p.md .agents/plans/done/p.md
git -C "$CLONE" commit --quiet -m "execute"
REV="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" push --quiet origin "$BR"

# The planner record the coder's artifact is compared against.
jq -n --arg run "$RUN_ID" --arg rev "$PREV" \
  '{team: "alfa", ticket: "L1", run: $run, role: "planner", attempt: 1, seq: 1, branch: "x",
    input_rev: "", output_rev: $rev, verdict: "done",
    artifacts: [".agents/specs/s.md", ".agents/plans/active/p.md"], evidence: [], notes: "",
    message: "", written_at: "2026-10-18T00:00:00Z"}' > "$RD/planner-1-1.json"
touch "$RD/planner-1-1.json.accepted"

mkpr() {  # mkpr <n> <isDraft> [head] [base]
  pr_file "$1" "${3:-$BR}" "${4:-$LINE0}" "$2"
}
mkrecord() {  # mkrecord <role> <pr> → the record path
  session "$1" 1 "$PREV"
  (cd "$CLONE" && $REC --verdict done --pr "$2" \
    --artifacts .agents/plans/done/p.md) | tail -n 1
}
mkpr 70 true
R="$(mkrecord coder 70)"
run "$MAIN" $TR alfa check "$R"
expect 0 "valid:" "a coder record with a draft github PR validates"

# Published while the coder still owes a draft: a refusal, not a pass.
mkpr 70 false
run "$MAIN" $TR alfa check "$R"
expect 4 "PR #70 isDraft is not true" "a published PR fails the coder's draft check"

# The identity refusal must survive the later checks (the `|| return 1` chain).
mkpr 70 true "feature/L9-other" "$LINE0"
run "$MAIN" $TR alfa check "$R"
expect 4 "PR identity mismatch (#70)" "a PR on another head is refused"
mkpr 70 true "$BR" develop-netcore7
run "$MAIN" $TR alfa check "$R"
expect 4 "PR identity mismatch (#70)" "a PR against another base is refused"

# cli: the PR must be published, so a draft is a refusal.
rm -f "$RD"/coder-1-1.json* "$RD"/planner-1-1.json*
setmode() { jq --arg m "$1" '.mode = $m' "$TD/team.json" > "$WORK/tj"; mv "$WORK/tj" "$TD/team.json"; }
setmode cli
mkpr 70 true
R="$(mkrecord cli 70)"
run "$MAIN" $TR alfa check "$R"
expect 4 "PR #70 isDraft is not false" "a draft PR fails the cli's published check"
mkpr 70 false
run "$MAIN" $TR alfa check "$R"
expect 0 "valid:" "a cli record with a published github PR validates"
rm -f "$RD"/cli-1-1.json* "$TD/session.json"

# ================================================================================================
# (B4) team-next.sh reads the previous PR through the adapter
# ================================================================================================
jq -n --arg run "$RUN_ID" --arg rev "$REV" \
  '{team: "alfa", ticket: "L1", run: $run, role: "cli", attempt: 1, seq: 1, branch: "x",
    input_rev: "", output_rev: $rev, verdict: "done", pr_id: 70, artifacts: [], evidence: [],
    notes: "", message: "", written_at: "2026-10-18T00:00:00Z"}' > "$RD/cli-1-1.json"
touch "$RD/cli-1-1.json.accepted"
NEXT="bash .claude/lib/team-next.sh"
run "$MAIN" $NEXT alfa L2 feature/L2-next origin/base-pr $TKT
expect 1 "previous PR #70 of L1 is active" "an open github PR blocks the next ticket"

# Merged: the head is an ancestor of the base, which is exactly what the fixture reports.
smoke_gh_land "$BR" "$LINE0"
mkdir -p "$WORK/tkt2"
jq -n '{key: "L2", title: "next work", url: "", labels: []}' > "$WORK/tkt2/ticket.json"
printf '# L2\nnext work\n' > "$WORK/tkt2/ticket.md"
run "$MAIN" $NEXT alfa L2 feature/L2-next origin/base-pr --ticket-file "$WORK/tkt2/ticket.json"
expect 0 "branch:" "a merged github PR releases the next-ticket guard"

# ================================================================================================
# (C) nothing in this suite ever merged or forced anything through gh
# ================================================================================================
! grep -E 'pr merge|--admin|--force' "$GH_LOG" \
  || fail "the gh log contains a merge/admin/force call"
! grep -nE '^[^#]*(pr merge|--admin|--force)' "$SRC/.claude/lib/team-pr.sh" \
  || fail "team-pr.sh carries a merge/admin/force call"

echo "team-pr-smoke: OK"
