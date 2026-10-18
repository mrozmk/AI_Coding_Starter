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
# (C) integration — team-merge-check.sh (github branch) and team-integrate.sh
#
# The target branch of the whole part is $TRUNK (the fixture profile's trunk), so "main" in the
# plan means $TRUNK here. Every team is cut from the CURRENT trunk and carries one accepted `cli`
# record, a published PR and a merge ref built the way GitHub builds it.
# ================================================================================================
MC="bash .claude/lib/team-merge-check.sh"
IT="bash .claude/lib/team-integrate.sh"
LOCK="$MAIN/.claude/lib/team-integrate-lock.sh"
GIT_LOG="$WORK/git.log"; : > "$GIT_LOG"; export GIT_LOG
# One state read per integration, no sleeping: the stub answers from the refs immediately.
export TEAM_INTEGRATE_POLL_SECS=0 TEAM_INTEGRATE_MERGED_SECS=0

# `true` as the build check and no test gate: part C is about the integration, not about gates.
C_PROFILE="$GH_PROFILE | .teams.build_check = \"true\" | .teams.test_gate = \"none\""
setprofile "$C_PROFILE"
# The trunk must be a base a github team can be cut from: publish the same profile on it. Through a
# fresh clone, not $SEED — the trunk moved while parts A/B ran, and $SEED is behind it.
rm -rf "$WORK/tpwc"
"$REAL_GIT" clone --quiet "$WORK/origin.git" "$WORK/tpwc"
git -C "$WORK/tpwc" checkout --quiet -B "$TRUNK" "origin/$TRUNK"
smoke_profile "$GH_NONE" > "$WORK/tpwc/.claude/project-profile.json"
git -C "$WORK/tpwc" add .claude/project-profile.json
git -C "$WORK/tpwc" commit --quiet -m "trunk profile: github"
git -C "$WORK/tpwc" push --quiet origin "$TRUNK"

# The protected-branch fixture: GitHub's GH006, as a pre-receive hook in the bare origin.
cat > "$WORK/origin.git/hooks/pre-receive" <<HOOK
#!/bin/sh
[ ! -f "$WORK/protect" ] || {
  echo "remote: error: GH006: Protected branch update failed" >&2
  exit 1
}
HOOK
chmod +x "$WORK/origin.git/hooks/pre-receive"

c_record() {  # c_record <rd> <run> <pr> <output rev> [seq]
  jq -n --arg run "$2" --argjson pr "$3" --arg rev "$4" --argjson seq "${5:-1}" \
    '{team: "c", ticket: "K", run: $run, role: "cli", attempt: 1, seq: $seq, branch: "x",
      input_rev: "", output_rev: $rev, verdict: "done", pr_id: $pr, artifacts: [], evidence: [],
      notes: "", message: "", written_at: "2026-10-18T00:00:00Z"}' > "$1/cli-1-${5:-1}.json"
  touch "$1/cli-1-${5:-1}.json.accepted"
}

# mk_ready <team> <pr> [base] → a team whose work is done, pushed, accepted and PR-ready.
# Sets CL TDC RDC RUNC BRC S1x Sx Tx Mx. Two commits: S1x is the "somebody published part of the
# source" fixture, Sx the PR head.
mk_ready() {
  local t="$1" pr="$2" base="${3:-$TRUNK}"
  rm -rf "$WORK/main-$t" "$WORK/tkt-$t"
  mkdir -p "$WORK/tkt-$t"
  jq -n --arg k "L$pr" '{key: $k, title: "c work", url: "", labels: []}' > "$WORK/tkt-$t/ticket.json"
  printf '# L%s\nc work\n' "$pr" > "$WORK/tkt-$t/ticket.md"
  BRC="feature/L$pr-$t"
  run "$MAIN" $NEW "$t" "L$pr" "$BRC" "origin/$base" cli --ticket-file "$WORK/tkt-$t/ticket.json"
  expect 0 "branch:" "fixture: team $t on $base"
  CL="$WORK/main-$t"; TDC="$CL/.agents/team"
  printf 'one\n' > "$CL/w1-$t.txt"
  git -C "$CL" add "w1-$t.txt" && git -C "$CL" commit --quiet -m "w1 $t"
  S1x="$(git -C "$CL" rev-parse HEAD)"
  printf 'two\n' > "$CL/w2-$t.txt"
  git -C "$CL" add "w2-$t.txt" && git -C "$CL" commit --quiet -m "w2 $t"
  Sx="$(git -C "$CL" rev-parse HEAD)"
  git -C "$CL" push --quiet origin "$BRC"
  RUNC="$t-20261018-000001"; echo "$RUNC" > "$TDC/run"
  RDC="$TDC/runs/$RUNC"; mkdir -p "$RDC"
  rm -f "$TDC/session.json"; rm -rf "$TDC/lock"
  c_record "$RDC" "$RUNC" "$pr" "$Sx"
  pr_file "$pr" "$BRC" "$base" false
  c_refresh "$pr" "$BRC" "$base"
}

c_refresh() {  # c_refresh <pr> <head> <base> — rebuild the merge ref against the live base
  smoke_gh_pull "$1" "$2" "$3"
  Tx="$(bare rev-parse "refs/heads/$3")"
  Mx="$(bare rev-parse "refs/pull/$1/merge")"
}

# (C-setup) delta carries the refusal battery; its trunk pushes move the line, so it comes first.
mk_ready delta 44
run "$MAIN" $IT delta
expect 3 "no merge-check for run" "integrate without a merge check is refused"
[ ! -f "$RDC/merge-check.json" ] || fail "a refused integrate wrote a merge-check"

# (C2) conflict — readiness says CONFLICTING, so the check never reaches the gates
export STUB_GH_MERGEABLE=CONFLICTING
run "$MAIN" $MC delta
expect 3 "conflicts with $TRUNK" "a conflicting PR fails the merge check"
unset STUB_GH_MERGEABLE
[ ! -f "$RDC/merge-check.json" ] || fail "a conflicting PR still got a merge-check verdict"

# (C3) no merge ref at all, then one built against an older base
bare update-ref -d "refs/pull/44/merge"
run "$MAIN" $MC delta
expect 4 "merge ref recalculating" "a missing merge ref is recoverable, not a refusal"
c_refresh 44 "$BRC" "$TRUNK"
smoke_gh_commit "$TRUNK" "c3-move"
run "$MAIN" $MC delta
expect 4 "merge ref recalculating" "a merge ref whose parent 1 is not the base is recalculating"
c_refresh 44 "$BRC" "$TRUNK"

# (C3b) the merge ref the gates would check out is moved away before the checkout: the commit is
# addressed by sha, and the ref no longer carrying it is enough to void the check.
bare update-ref "refs/pull/44/merge" "$(git -C "$CL" rev-parse HEAD)"
run "$MAIN" $MC delta
expect 4 "merge ref recalculating" "a merge ref pointing somewhere else never reaches the gates"
[ ! -f "$RDC/merge-check.json" ] || fail "a moved merge ref still wrote a verdict"
c_refresh 44 "$BRC" "$TRUNK"

# (C4) the target moves WHILE the gates run; then the merge ref is rebuilt while they run
rm -rf "$WORK/bcwc"
"$REAL_GIT" clone --quiet "$WORK/origin.git" "$WORK/bcwc"
git -C "$WORK/bcwc" checkout --quiet -B "$TRUNK" "origin/$TRUNK"
printf 'race\n' > "$WORK/bcwc/race.txt"
git -C "$WORK/bcwc" add race.txt && git -C "$WORK/bcwc" commit --quiet -m "race"
RACE="$(git -C "$WORK/bcwc" rev-parse HEAD)"
setprofile "$C_PROFILE | .teams.build_check = \"$REAL_GIT -C $WORK/bcwc push --quiet origin $RACE:refs/heads/$TRUNK\""
run "$MAIN" $MC delta
expect 3 "void: tips moved during check" "a target pushed during the gates voids the check"
[ ! -f "$RDC/merge-check.json" ] || fail "a voided check still wrote a verdict"
c_refresh 44 "$BRC" "$TRUNK"
# A rebuilt `refs/pull/44/merge` — here the head commit itself, which is enough for the re-read.
setprofile "$C_PROFILE | .teams.build_check = \"$REAL_GIT -C $CL push --quiet origin +$Sx:refs/pull/44/merge\""
run "$MAIN" $MC delta
expect 4 "merge ref recalculated during check" "a merge ref rebuilt during the gates is recalculating"
[ ! -f "$RDC/merge-check.json" ] || fail "a recalculated merge ref still wrote a verdict"
c_refresh 44 "$BRC" "$TRUNK"

# (C4b) the tips sit still, but a new record appears while the gates run
setprofile "$C_PROFILE | .teams.build_check = \"cp $RDC/cli-1-1.json $RDC/cli-1-2.json\""
run "$MAIN" $MC delta
expect 3 "void: records changed during check" "a record written during the gates voids the check"
[ ! -f "$RDC/merge-check.json" ] || fail "a records-changed check still wrote a verdict"
rm -f "$RDC/cli-1-2.json"
setprofile "$C_PROFILE"

# (C4c) the checkout + gates + restore window is serialised by the TEAM RUNNER LOCK: a runner that
# is already running keeps the check out, and while the check runs nothing else can start.
mkdir -p "$TDC/lock"; echo $$ > "$TDC/lock/pid"
run "$MAIN" $MC delta
expect 3 "runner" "a live runner keeps the merge check out of the clone"
[ ! -f "$RDC/merge-check.json" ] || fail "a check refused for a live runner wrote a verdict"
rm -rf "$TDC/lock"
# The race itself: the lock appears AFTER the eligibility check (the gh stub takes it the moment
# the PR is read), so this run loses the `mkdir` the way a second supervisor would. It must refuse
# WITHOUT touching the checkout — a restore trap armed before the mkdir would `git switch` the
# clone back while the winner's gates are mid-build.
HEAD_BEFORE="$(git -C "$CL" rev-parse HEAD)"
: > "$GIT_LOG"
rm -f "$GH_DIR/on-view"
export STUB_GH_ON_VIEW="mkdir -p $TDC/lock && echo 999999 > $TDC/lock/pid"
run "$MAIN" $MC delta
unset STUB_GH_ON_VIEW
expect 3 "team runner active" "losing the runner-lock race is a refusal"
! grep -q 'git switch' "$GIT_LOG" || { sed 's/^/  | /' "$GIT_LOG"
  fail "the loser of the runner-lock race switched the clone" ; }
[ "$(git -C "$CL" rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail "the refused check moved the clone"
[ ! -f "$RDC/merge-check.json" ] || fail "the refused check wrote a verdict"
rm -rf "$TDC/lock"

rm -f "$WORK/lockprobe"
: > "$GIT_LOG"
setprofile "$C_PROFILE | .teams.build_check = \"if mkdir $TDC/lock 2>/dev/null; then echo TOOK; else echo BLOCKED; fi > $WORK/lockprobe\""
run "$MAIN" $MC delta
expect 0 "VERDICT: ok" "the merge check runs while holding the runner lock"
[ "$(cat "$WORK/lockprobe")" = BLOCKED ] \
  || fail "a process could take the runner lock during the gates: $(cat "$WORK/lockprobe")"
# The counter-proof for the assertion above: a check that DOES run logs its switches, so the
# "no git switch" assertion in the refused case cannot pass just because nothing is ever logged.
grep -q 'git switch' "$GIT_LOG" || fail "the git stub logs no switch at all — the race assertion is vacuous"
[ ! -e "$TDC/lock" ] || fail "the merge check left the runner lock behind"
rm -f "$RDC/merge-check.json"

# (C4d) the free routine's two rules. A lock whose pid file we emptied (what a failed pid write
# leaves behind) is still OURS to remove, because we created it in this run…
setprofile "$C_PROFILE | .teams.build_check = \": > $TDC/lock/pid\""
run "$MAIN" $MC delta
expect 0 "VERDICT: ok" "a check whose runner lock lost its pid still finishes"
[ ! -e "$TDC/lock" ] || fail "a lock with an empty pid was left behind by its own creator"
rm -f "$RDC/merge-check.json"
# …but a lock carrying somebody ELSE's pid is left in place (the team-run.sh rule), with a warning.
setprofile "$C_PROFILE | .teams.build_check = \"echo 1 > $TDC/lock/pid\""
run "$MAIN" $MC delta
expect 0 "VERDICT: ok" "a check whose runner lock was taken over still finishes"
has "runner lock is pid 1, not ours" "$WORK/out" || fail "the foreign runner lock was not reported"
[ -e "$TDC/lock" ] || fail "a runner lock belonging to another pid was removed"
rm -rf "$TDC/lock"
rm -f "$RDC/merge-check.json"
setprofile "$C_PROFILE"

# (C5) a verdict exists — now the state behind it is what integrate re-checks.
# The build check records the commit it actually ran on: the verdict must name THAT commit.
rm -f "$WORK/tested_head"
setprofile "$C_PROFILE | .teams.build_check = \"$REAL_GIT rev-parse HEAD > $WORK/tested_head\""
run "$MAIN" $MC delta
expect 0 "VERDICT: ok" "the github merge check passes on a clean run"
[ "$(cat "$WORK/tested_head")" = "$(jq -r .merge_sha "$RDC/merge-check.json")" ] \
  || fail "the gates ran on $(cat "$WORK/tested_head"), the verdict names $(jq -r .merge_sha "$RDC/merge-check.json")"
setprofile "$C_PROFILE"
[ "$(jq -r .verdict "$RDC/merge-check.json")" = ok ] || fail "merge-check.json has no ok verdict"
[ "$(jq -r .pr "$RDC/merge-check.json")" = 44 ] || fail "merge-check.json lost the PR"
[ "$(jq -r .repo "$RDC/merge-check.json")" = acme/widgets ] || fail "merge-check.json lost the repo"
[ "$(jq -r .merge_sha "$RDC/merge-check.json")" = "$Mx" ] || fail "merge-check.json lost the merge sha"
[ "$(jq -r .base_ref "$RDC/merge-check.json")" = "$TRUNK" ] || fail "merge-check.json lost the base"
DIG44="$(jq -r .records_digest "$RDC/merge-check.json")"
[ -n "$DIG44" ] && [ "$DIG44" != null ] || fail "merge-check.json has no records digest"
cp "$RDC/merge-check.json" "$WORK/mc-ok"

jq -n '{role: "qa", run: "x", attempt: 1}' > "$TDC/session.json"
run "$MAIN" $IT delta
expect 3 "a role is still live" "integrate refuses while a role is live"
rm -f "$TDC/session.json"
mkdir -p "$TDC/lock"; echo $$ > "$TDC/lock/pid"
run "$MAIN" $IT delta
expect 3 "the runner still holds" "integrate refuses while the runner holds the lock"
rm -rf "$TDC/lock"
# Astra 3: the resumed workflow is caught by name+sha256, not by a timestamp — same `written_at`.
cp "$RDC/cli-1-1.json" "$RDC/cli-1-2.json"
run "$MAIN" $IT delta
expect 3 "workflow resumed after merge-check" "a record added after the verdict invalidates it"
rm -f "$RDC/cli-1-2.json"
jq '.run = "alfa-other-run"' "$RDC/merge-check.json" > "$WORK/mc" && cp "$WORK/mc" "$RDC/merge-check.json"
run "$MAIN" $IT delta
expect 3 "merge-check run is" "a merge-check for another run is refused"
jq '.run = "'"$RUNC"'" | .pr = "99"' "$WORK/mc" > "$RDC/merge-check.json"
run "$MAIN" $IT delta
expect 3 "merge-check pr is '99'" "a merge-check for another PR is refused"
jq '.verdict = "fail"' "$WORK/mc" > "$RDC/merge-check.json"
run "$MAIN" $IT delta
expect 3 "merge-check verdict is 'fail'" "a failed verdict is refused"
# A `git status` that FAILS prints nothing — it must not read as a clean clone.
cp "$WORK/mc-ok" "$RDC/merge-check.json"
export STUB_GIT_STATUS_FAIL=1
run "$MAIN" $IT delta
unset STUB_GIT_STATUS_FAIL
expect 3 "cannot read the status of" "a git status that fails is not an eligible clone"
jq '.verdict = "fail"' "$WORK/mc" > "$RDC/merge-check.json"

# (C6) the base argument and the ADO refusal
run "$MAIN" $IT delta --base other
expect 3 "team line is $TRUNK, not other" "integrate refuses a base that is not the team's line"
setprofile '.teams.pr_provider = "azure-devops"'
run "$MAIN" $IT delta
expect 2 "use the ADO merge (/pr-merge)" "integrate refuses an azure-devops profile"
setprofile "$C_PROFILE"

# (C6) the positive --base: a line other than the trunk, taken explicitly
bare update-ref refs/heads/it-base "refs/heads/$TRUNK"
TRUNK_BEFORE="$(bare rev-parse "refs/heads/$TRUNK")"
mk_ready gamma 43 it-base
run "$MAIN" $MC gamma
expect 0 "VERDICT: ok" "merge check on a non-trunk line"
run "$MAIN" $IT gamma
expect 3 "team line is it-base, not $TRUNK" "integrate defaults to the trunk and refuses"
M_G="$Mx"
run "$MAIN" $IT gamma --base it-base
expect 0 "integrated: PR #43 into it-base" "integrate publishes onto the explicit base"
[ "$(bare rev-parse refs/heads/it-base)" = "$M_G" ] || fail "it-base is not the tested merge commit"
[ "$(bare rev-parse "refs/heads/$TRUNK")" = "$TRUNK_BEFORE" ] || fail "the trunk moved"

# (C1) alfa and beta from one trunk: alfa lands, beta's old readiness is dead, beta re-validates
mk_ready alfa 41
CL_A="$CL"; BR_A="$BRC"; RD_A="$RDC"; S_A="$Sx"; S1_A="$S1x"
mk_ready beta 42
CL_B="$CL"; BR_B="$BRC"; RD_B="$RDC"
run "$MAIN" $MC alfa
expect 0 "VERDICT: ok" "merge check alfa"
M_A="$(jq -r .merge_sha "$RD_A/merge-check.json")"
run "$MAIN" $MC beta
expect 0 "VERDICT: ok" "merge check beta"
T_B0="$(jq -r .target_sha "$RD_B/merge-check.json")"

# (C6) the lock is one per base, shared with the solo worker flow
run "$MAIN" /bin/bash "$LOCK" acquire "$TRUNK" --owner sol:7
expect 0 "" "a solo integrator takes the base lock"
run "$MAIN" $IT alfa
expect 3 "held by sol:7" "integrate refuses while the solo flow holds the base lock"
run "$MAIN" /bin/bash "$LOCK" status "$TRUNK"
expect 0 "sol:7" "the lock status names its owner"
run "$MAIN" /bin/bash "$LOCK" release "$TRUNK" --owner sol:7
expect 0 "" "the solo integrator releases the base lock"

run "$MAIN" $IT alfa
expect 0 "integrated: PR #41 into $TRUNK" "integrate publishes the tested merge commit"
[ "$(bare rev-parse "refs/heads/$TRUNK")" = "$M_A" ] || fail "the trunk is not alfa's merge commit"
run "$MAIN" bash .claude/lib/team-pr.sh state 41
expect 0 '"status":"completed"' "PR 41 reads as merged after the push"
[ "$(jq -r .state "$MAIN/.agents/team/integrate/alfa-$(cat "$CL_A/.agents/team/run").json")" = done ] \
  || fail "alfa's intent is not done"

run "$MAIN" $IT beta
expect 3 "target moved since merge-check" "beta's readiness from the old trunk is dead"
[ ! -f "$MAIN/.agents/team/integrate/beta-$(cat "$CL_B/.agents/team/run").json" ] \
  || fail "a step-5 refusal wrote an intent"
c_refresh 42 "$BR_B" "$TRUNK"
[ "$Tx" = "$M_A" ] || fail "beta's new merge ref was not built against alfa's result"
run "$MAIN" $MC beta
expect 0 "VERDICT: ok" "merge check beta against the new trunk"
M_B="$(jq -r .merge_sha "$RD_B/merge-check.json")"
run "$MAIN" $IT beta
expect 0 "integrated: PR #42 into $TRUNK" "beta integrates after re-validating"
[ "$(bare rev-parse "refs/heads/$TRUNK")" = "$M_B" ] || fail "the trunk is not beta's merge commit"
[ "$(bare rev-list --parents -n 1 "$M_B" | awk '{print $2}')" = "$M_A" ] \
  || fail "beta's merge commit does not sit on alfa's result"

# (C7) the base is moved to part of the source before the integration — refused, base untouched
mk_ready eps 45
run "$MAIN" $MC eps
expect 0 "VERDICT: ok" "merge check eps"
"$REAL_GIT" -C "$CL" push --quiet origin "$S1x:refs/heads/$TRUNK"
run "$MAIN" $IT eps
expect 3 "target moved since merge-check" "a base moved to part of the source is refused"
[ "$(bare rev-parse "refs/heads/$TRUNK")" = "$S1x" ] || fail "the refused integrate moved the base"

# (C8) the race: somebody publishes part of the source DURING our push — the push still lands M
mk_ready zeta 46
run "$MAIN" $MC zeta
expect 0 "VERDICT: ok" "merge check zeta"
M_Z="$Mx"
export STUB_GIT_PRE_PUSH="$REAL_GIT -C $CL push --quiet origin $S1x:refs/heads/$TRUNK"
run "$MAIN" $IT zeta
unset STUB_GIT_PRE_PUSH
expect 0 "base moved during push" "a base moved during the push is reported, not hidden"
[ "$RC" = 0 ] || fail "the raced push did not integrate"
[ "$(bare rev-parse "refs/heads/$TRUNK")" = "$M_Z" ] || fail "the raced push did not land M"

# (C9) the source advances between the validation and the push: M lands, the PR stays open
mk_ready eta 47
run "$MAIN" $MC eta
expect 0 "VERDICT: ok" "merge check eta"
M_E="$Mx"; BR_E="$BRC"; RUN_E="$RUNC"
rm -rf "$WORK/s2wc"
"$REAL_GIT" clone --quiet "$WORK/origin.git" "$WORK/s2wc"
git -C "$WORK/s2wc" checkout --quiet -B "$BR_E" "origin/$BR_E"
printf 's2\n' > "$WORK/s2wc/s2.txt"
git -C "$WORK/s2wc" add s2.txt && git -C "$WORK/s2wc" commit --quiet -m s2
export STUB_GIT_PRE_PUSH="$REAL_GIT -C $WORK/s2wc push --quiet origin HEAD:refs/heads/$BR_E"
run "$MAIN" $IT eta
unset STUB_GIT_PRE_PUSH
expect 4 "source advanced after validation" "a source that moved leaves the PR open"
[ "$(bare rev-parse "refs/heads/$TRUNK")" = "$M_E" ] || fail "the tested M did not land"
[ "$(jq -r .state "$MAIN/.agents/team/integrate/eta-$RUN_E.json")" = published ] \
  || fail "eta's intent is not published"
run "$MAIN" bash .claude/lib/team-pr.sh state 47
expect 0 '"status":"active"' "PR 47 is still open after the partial integration"

# (C10) GH006: the server refuses the push — a STOP, with the base untouched and the PR open
mk_ready theta 48
run "$MAIN" $MC theta
expect 0 "VERDICT: ok" "merge check theta"
T_T="$Tx"; RUN_T="$RUNC"
touch "$WORK/protect"
run "$MAIN" $IT theta
rm -f "$WORK/protect"
expect 4 "server refused the push" "a protected branch is a stop, not a fallback"
has "GH006" "$WORK/out" || fail "the GH006 reason was not reported"
[ "$(bare rev-parse "refs/heads/$TRUNK")" = "$T_T" ] || fail "the refused push moved the base"
[ "$(jq -r .state "$MAIN/.agents/team/integrate/theta-$RUN_T.json")" = rejected ] \
  || fail "theta's intent is not rejected"
run "$MAIN" bash .claude/lib/team-pr.sh state 48
expect 0 '"status":"active"' "PR 48 is still open after the server refused"

# (C11) the push lands and the CLIENT gets an error: recovery sees M, and never pushes twice
mk_ready iota 49
run "$MAIN" $MC iota
expect 0 "VERDICT: ok" "merge check iota"
M_I="$Mx"
: > "$GIT_LOG"
export STUB_GIT_PUSH_FAIL_AFTER=1
run "$MAIN" $IT iota
unset STUB_GIT_PUSH_FAIL_AFTER
expect 0 "integrated: PR #49" "a push whose answer was lost still integrates"
[ "$(bare rev-parse "refs/heads/$TRUNK")" = "$M_I" ] || fail "iota's M is not on the trunk"
[ "$(grep -c ":refs/heads/$TRUNK" "$GIT_LOG")" = 1 ] \
  || fail "the lost-answer push ran $(grep -c ":refs/heads/$TRUNK" "$GIT_LOG") pushes, not 1"

# (C12) killed after the push, before the intent said done: the lock is stale, recovery finishes it
mk_ready kappa 50
run "$MAIN" $MC kappa
expect 0 "VERDICT: ok" "merge check kappa"
M_K="$Mx"; RUN_K="$RUNC"
KINT="$MAIN/.agents/team/integrate/kappa-$RUN_K.json"
: > "$GIT_LOG"
export STUB_GIT_PUSH_KILL=1
run "$MAIN" $IT kappa
unset STUB_GIT_PUSH_KILL
[ "$RC" != 0 ] || fail "the killed integrate reported success"
[ "$(jq -r .state "$KINT")" = pending ] || fail "the killed integrate left state $(jq -r .state "$KINT")"
[ "$(bare rev-parse "refs/heads/$TRUNK")" = "$M_K" ] || fail "the killed integrate did not land M"
run "$MAIN" $IT kappa
expect 3 "stale: team-integrate-lock.sh release" "a dead owner's lock is reported, never taken over"
K_OWNER="$(sed -n 's/.*--owner \([^ ]*\).*/\1/p' "$WORK/out" | tail -n 1)"
[ -n "$K_OWNER" ] || fail "the stale hint named no owner"
run "$MAIN" /bin/bash "$LOCK" release "$TRUNK" --owner other:1
expect 3 "is held by" "release refuses somebody else's lock"
run "$MAIN" /bin/bash "$LOCK" release "$TRUNK" --owner "$K_OWNER"
expect 0 "" "the supervisor releases the dead owner's lock"
# (C12c) the network is down during recovery: no verdict, no second push, state untouched
export STUB_GIT_LSREMOTE_FAIL=1
run "$MAIN" $IT kappa
unset STUB_GIT_LSREMOTE_FAIL
expect 4 "cannot read origin $TRUNK" "a recovery that cannot read the base changes nothing"
[ "$(jq -r .state "$KINT")" = pending ] || fail "the failed recovery changed the intent"
run "$MAIN" $IT kappa
expect 0 "integrated: PR #50" "recovery finishes the integration without a second push"
[ "$(jq -r .state "$KINT")" = done ] || fail "kappa's intent is not done"
[ "$(grep -c ":refs/heads/$TRUNK" "$GIT_LOG")" = 1 ] \
  || fail "the killed-then-recovered run pushed $(grep -c ":refs/heads/$TRUNK" "$GIT_LOG") times"
run "$MAIN" $IT kappa
expect 0 "already integrated: PR #50" "a finished intent is reported, not redone"
[ "$(grep -c ":refs/heads/$TRUNK" "$GIT_LOG")" = 1 ] || fail "the already-integrated run pushed again"

# (C12b) two writers, one free lock: exactly one wins, and neither can release the other's
PB=parallel-base
: > "$WORK/p1"; : > "$WORK/p2"
( cd "$MAIN" && /bin/bash "$LOCK" acquire $PB --owner p:1 > "$WORK/p1" 2>&1; echo "rc=$?" >> "$WORK/p1" ) &
( cd "$MAIN" && /bin/bash "$LOCK" acquire $PB --owner p:2 > "$WORK/p2" 2>&1; echo "rc=$?" >> "$WORK/p2" ) &
wait
WON="$(grep -c '^rc=0$' "$WORK/p1" "$WORK/p2" | awk -F: '{s += $2} END {print s}' || true)"
[ "$WON" = 1 ] || fail "$WON of 2 parallel acquires won the free lock"
run "$MAIN" /bin/bash "$LOCK" status $PB
expect 0 "p:" "the winner's lock is readable"
PO="$(awk '{print $1}' "$WORK/out")"
run "$MAIN" /bin/bash "$LOCK" release $PB --owner p:9
expect 3 "is held by $PO" "release refuses a lock it does not own"
run "$MAIN" /bin/bash "$LOCK" status $PB
expect 0 "$PO" "a refused release left the lock in place"
run "$MAIN" /bin/bash "$LOCK" release $PB --owner "$PO"
expect 0 "" "the owner releases its lock"
run "$MAIN" /bin/bash "$LOCK" status $PB
expect 0 "free" "the base is free again"

# (C12d) the release race, closed by the guard mutex: a delayed releaser A holds the guard for its
# whole read-check-remove sequence, so a release and an acquire staged INSIDE that window (the
# interleaving that used to let a second owner in) are both refused. `TIL_RACE_HOOK` stages it;
# `TIL_GUARD_TRIES=1` makes the nested attempts refuse at once instead of spinning.
run "$MAIN" /bin/bash "$LOCK" acquire $PB --owner a:1
expect 0 "" "the first owner takes the base"
export TIL_RACE_HOOK="TIL_RACE_HOOK= TIL_GUARD_TRIES=1 /bin/bash $LOCK release $PB --owner a:1 \
    > $WORK/g-rel 2>&1; echo \"rc=\$?\" >> $WORK/g-rel
  TIL_RACE_HOOK= TIL_GUARD_TRIES=1 /bin/bash $LOCK acquire $PB --owner b:2 \
    > $WORK/g-acq 2>&1; echo \"rc=\$?\" >> $WORK/g-acq"
run "$MAIN" /bin/bash "$LOCK" release $PB --owner a:1
unset TIL_RACE_HOOK
expect 0 "" "the guarded release completes"
has "lock guard busy" "$WORK/g-rel" || { sed 's/^/  | /' "$WORK/g-rel"; fail "a second release got inside the guarded window"; }
has "rc=3" "$WORK/g-rel" || fail "the raced release did not refuse"
has "lock guard busy" "$WORK/g-acq" || { sed 's/^/  | /' "$WORK/g-acq"; fail "an acquire got inside the guarded window"; }
has "rc=3" "$WORK/g-acq" || fail "the raced acquire did not refuse"
run "$MAIN" /bin/bash "$LOCK" status $PB
expect 0 "free" "the base is free once the owner finished releasing"
# Exactly one owner at any time, and the new owner's lock is never nested inside another lock or
# left behind as a renamed copy (the rename design is gone).
run "$MAIN" /bin/bash "$LOCK" acquire $PB --owner b:2
expect 0 "" "the next owner takes the free base"
run "$MAIN" /bin/bash "$LOCK" acquire $PB --owner c:3
expect 3 "held by b:2" "a third writer is refused while b holds the base"
run "$MAIN" /bin/bash "$LOCK" status $PB
expect 0 "b:2" "b's lock is intact after the refused acquire"
LKD="$MAIN/.agents/team/integrate/locks"
[ -z "$(ls -d "$LKD"/*.lock/*.lock 2>/dev/null)" ] || fail "a lock was nested inside another lock"
[ -z "$(ls -d "$LKD"/*.rel.* 2>/dev/null)" ] || fail "a renamed lock copy was left behind"
[ -z "$(ls -d "$LKD"/*.guard 2>/dev/null)" ] || fail "a guard mutex was left behind"
run "$MAIN" /bin/bash "$LOCK" release $PB --owner b:2
expect 0 "" "b releases its own lock"

# (C12e) an acquire that cannot create its lock must REPORT that, not return 0 on the strength of a
# successful guard release — the integrator calls it as `til_acquire … || exit 3`, which disables
# errexit inside. A plain FILE where the lock directory belongs makes `mkdir` fail for real.
WEDGE=wedge-base
printf 'not a directory\n' > "$LKD/$WEDGE.lock"
run "$MAIN" /bin/bash "$LOCK" acquire $WEDGE --owner w:1
[ "$RC" != 0 ] || fail "an acquire that could not create its lock returned success"
has "cannot take the integration lock" "$WORK/out" || fail "the failed acquire said nothing"
[ -f "$LKD/$WEDGE.lock" ] || fail "the failed acquire deleted a file it did not create"
[ ! -e "$LKD/$WEDGE.lock.guard" ] || fail "the failed acquire leaked its guard"
rm -f "$LKD/$WEDGE.lock"
# The same cleanup path from the middle of the write sequence (injected): no lock, no guard, rc != 0.
export TIL_FAIL_AFTER_MKDIR=1
run "$MAIN" /bin/bash "$LOCK" acquire $WEDGE --owner w:2
unset TIL_FAIL_AFTER_MKDIR
[ "$RC" != 0 ] || fail "an acquire that failed mid-write returned success"
has "injected write failure" "$WORK/out" || fail "the mid-write failure was swallowed"
[ ! -e "$LKD/$WEDGE.lock" ] || fail "the failed acquire left a lock behind"
[ ! -e "$LKD/$WEDGE.lock.guard" ] || fail "the failed acquire leaked its guard"
run "$MAIN" /bin/bash "$LOCK" acquire $WEDGE --owner w:3
expect 0 "" "the base is still usable after the failed acquires"
run "$MAIN" /bin/bash "$LOCK" release $WEDGE --owner w:3
expect 0 "" "and releasable"

# (C12g) a lock directory that CANNOT be removed (its own permissions block it): the release
# reports the failure and still releases the guard — under the CLI's errexit the old code aborted
# before the release and the base needed a by-hand cleanup.
RMB=rmfail-base
run "$MAIN" /bin/bash "$LOCK" acquire $RMB --owner r:1
expect 0 "" "an owner whose lock will refuse to be removed"
mkdir -p "$LKD/$RMB.lock/blocker"
chmod 500 "$LKD/$RMB.lock"
run "$MAIN" /bin/bash "$LOCK" release $RMB --owner r:1
[ "$RC" != 0 ] || fail "a release that could not remove the lock reported success"
has "cannot remove the integration lock" "$WORK/out" || fail "the failed removal was not reported"
[ ! -e "$LKD/$RMB.lock.guard" ] || fail "a failed removal leaked the guard"
chmod 700 "$LKD/$RMB.lock"
rm -rf "$LKD/$RMB.lock"

# (C12f) a catchable signal inside the guarded section drops the guard, so the base does not need a
# by-hand cleanup. The race hook kills the releaser while it holds the guard.
run "$MAIN" /bin/bash "$LOCK" acquire $PB --owner s:1
expect 0 "" "an owner to interrupt"
export TIL_RACE_HOOK='kill -TERM $$'
run "$MAIN" /bin/bash "$LOCK" release $PB --owner s:1
unset TIL_RACE_HOOK
[ "$RC" = 143 ] || fail "the TERMed release exited $RC, not 143 — the guard handler did not run"
[ ! -e "$LKD/$PB.lock.guard" ] || fail "a signal in the guarded section leaked the guard"
run "$MAIN" /bin/bash "$LOCK" status $PB
expect 0 "s:1" "the interrupted release left the lock itself alone"
run "$MAIN" /bin/bash "$LOCK" release $PB --owner s:1
expect 0 "" "and the next release works without a by-hand cleanup"

# (C14) another writer lands on top of our publish: never a clean success, and the recovery that
# follows refuses too — the contract is `base == M`, exactly.
mk_ready lambda 51
run "$MAIN" $MC lambda
expect 0 "VERDICT: ok" "merge check lambda"
M_L="$Mx"; RUN_L="$RUNC"; LINT="$MAIN/.agents/team/integrate/lambda-$RUN_L.json"
rm -rf "$WORK/ontop"
"$REAL_GIT" clone --quiet "$CL" "$WORK/ontop"
git -C "$WORK/ontop" fetch --quiet "$CL" "refs/team-pr/51/merge"
git -C "$WORK/ontop" checkout --quiet --detach FETCH_HEAD
printf 'on top\n' > "$WORK/ontop/ontop.txt"
git -C "$WORK/ontop" add ontop.txt && git -C "$WORK/ontop" commit --quiet -m "on top of M"
ONTOP="$(git -C "$WORK/ontop" rev-parse HEAD)"
git -C "$WORK/ontop" remote add bare "$WORK/origin.git"
export STUB_GIT_POST_PUSH="$REAL_GIT -C $WORK/ontop push --quiet bare HEAD:refs/heads/$TRUNK"
run "$MAIN" $IT lambda
unset STUB_GIT_POST_PUSH
expect 4 "base moved past M — manual check" "a base that only CONTAINS M is not a clean integration"
[ "$(bare rev-parse "refs/heads/$TRUNK")" = "$ONTOP" ] || fail "the on-top writer did not land"
[ "$(jq -r .state "$LINT")" = pending ] || fail "the partial integration claimed published/done"
run "$MAIN" $IT lambda
expect 3 "base moved past M — manual check" "the recovery refuses a base past M instead of guessing"
[ "$(jq -r .state "$LINT")" = pending ] || fail "the refused recovery rewrote the intent"

# (C15) merge-check.json swapped while we work: every field comes from ONE snapshot, so the push
# can only ever carry the M that was read together with the `ok` verdict.
mk_ready mu 52
run "$MAIN" $MC mu
expect 0 "VERDICT: ok" "merge check mu"
M_U="$Mx"; MCJ_U="$RDC/merge-check.json"
# The swap happens at `TEAM_INTEGRATE_SNAPSHOT_HOOK` — immediately after the one `cat`, i.e. inside
# the exact window a field-by-field reader would still have been reading in. The old pattern read
# `verdict` first and the SHAs later, so it would have taken `ok` from the old file and `merge_sha`
# from the new one; a swap at push time (where this test used to sit) came too late to prove that.
export TEAM_INTEGRATE_SNAPSHOT_HOOK="jq '.verdict = \"fail\" | .merge_sha = \"$ONTOP\"' $MCJ_U \
  > $WORK/mcswap && mv $WORK/mcswap $MCJ_U"
run "$MAIN" $IT mu
unset TEAM_INTEGRATE_SNAPSHOT_HOOK
expect 0 "integrated: PR #52" "a merge-check swapped underneath the run does not change the push"
[ "$(jq -r .merge_sha "$MCJ_U")" = "$ONTOP" ] || fail "the fixture never swapped merge-check.json"
[ "$(jq -r .verdict "$MCJ_U")" = fail ] || fail "the fixture never swapped the verdict"
[ "$(bare rev-parse "refs/heads/$TRUNK")" = "$M_U" ] || fail "the swap moved the pushed commit"
# The probe the assertion rests on: a SECOND read of the file at that point would have produced a
# different M (and a `fail` verdict) — so a multi-read implementation could not have passed.
[ "$(jq -r .merge_sha "$MCJ_U")" != "$M_U" ] || fail "the swap did not change what a re-read sees"

# (C16) the base moves between "the PR is MERGED" and the final look: `done` is not written, the
# result is reported as partial. The gh stub fires the writer the moment it answers MERGED.
mk_ready nu 53
run "$MAIN" $MC nu
expect 0 "VERDICT: ok" "merge check nu"
M_N="$Mx"; RUN_N="$RUNC"; NINT="$MAIN/.agents/team/integrate/nu-$RUN_N.json"
rm -rf "$WORK/ontop2"
"$REAL_GIT" clone --quiet "$CL" "$WORK/ontop2"
git -C "$WORK/ontop2" fetch --quiet "$CL" "refs/team-pr/53/merge"
git -C "$WORK/ontop2" checkout --quiet --detach FETCH_HEAD
printf 'on top 2\n' > "$WORK/ontop2/ontop2.txt"
git -C "$WORK/ontop2" add ontop2.txt && git -C "$WORK/ontop2" commit --quiet -m "on top of M (2)"
ONTOP2="$(git -C "$WORK/ontop2" rev-parse HEAD)"
git -C "$WORK/ontop2" remote add bare "$WORK/origin.git"
export STUB_GH_ON_MERGED="$REAL_GIT -C $WORK/ontop2 push --quiet bare HEAD:refs/heads/$TRUNK"
run "$MAIN" $IT nu
unset STUB_GH_ON_MERGED
expect 4 "base moved past M while the PR was closing" "a base that moves during the poll is not a clean done"
[ "$(bare rev-parse "refs/heads/$TRUNK")" = "$ONTOP2" ] || fail "the post-merge writer did not land"
[ "$(jq -r .state "$NINT")" = published ] || fail "nu's intent claims done"

# (C17) a `done` intent is still checked against the base: by now the trunk has moved far past
# kappa's M, and reporting "already integrated" would hide that.
run "$MAIN" $IT kappa
expect 3 "base moved past M — manual check" "a done intent on a base past M is reported, not confirmed"
has "intent done" "$WORK/out" || fail "the done-intent refusal does not say which intent it read"
[ "$(jq -r .state "$KINT")" = done ] || fail "the refused done check rewrote the intent"

# ================================================================================================
# (D1) dashboard attention: a github team awaiting merge gets the integrate command, ADO keeps /pr-merge
# ================================================================================================
(
  . "$SRC/.claude/lib/team-snapshot-teams.sh"
  W="$WORK/snapw"; mkdir -p "$W"
  printf '[{"team":"zeta","state":"awaiting_merge","pr_id":7,"roles":[]}]\n' > "$W/teams.json"
  TEAM_DASH_PR_PROVIDER=github snap_attention | jq -e \
    '.[0].commands == ["bash .claude/lib/team-merge-check.sh zeta", "bash .claude/lib/team-integrate.sh zeta"]' >/dev/null \
    || { echo "FAIL: github attention commands"; exit 1; }
  TEAM_DASH_PR_PROVIDER=azure-devops snap_attention | jq -e \
    '.[0].commands == ["bash .claude/lib/team-merge-check.sh zeta", "/pr-merge 7"]' >/dev/null \
    || { echo "FAIL: ado attention commands"; exit 1; }
) || fail "snap_attention provider commands"

# ================================================================================================
# (C13) nothing in this suite ever merged or forced anything through gh or git
# ================================================================================================
! grep -E 'pr merge|--admin|--force' "$GH_LOG" "$STUB_LOG" "$GIT_LOG" \
  || fail "a stub log contains a merge/admin/force call"
for f in team-pr.sh team-integrate.sh team-integrate-lock.sh team-integrate-lib.sh; do
  ! grep -nE '^[^#]*(pr merge|--admin|--force|git rebase)' "$SRC/.claude/lib/$f" \
    || fail "$f carries a merge/admin/force/rebase call"
done

echo "team-pr-smoke: OK"
