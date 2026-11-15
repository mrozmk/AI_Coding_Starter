#!/usr/bin/env bash
# The team PR path on Azure DevOps (team-pr.sh create|publish → team-pr-ado.sh), against an `az`
# stub only — no real call. create is idempotent: the same before/after lookup as github, a
# published PR is never reverted to a draft, a lost create answer never leads to a second PR (every
# case asserts the exact number of `az repos pr create` calls); the body stays ≤ 4000 characters and
# carries no secret-like line; the rendered ADO coder/cli blocks call it; a coder record on a PR
# made this way passes the runner's ADO validation (check_ado).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/team-smoke-lib.sh"
smoke_init
smoke_team AB-2500 feature/AB-2500-x
BR=feature/AB-2500-x; export TD

# The az stub keeps each PR as $ADO_DIR/pr-<id>.json. ADO_LOSE_ANSWER: the create succeeds and then
# fails (a lost answer); ADO_CREATE_FAIL: the create fails before creating anything.
ADO_DIR="$WORK/ado"; mkdir -p "$ADO_DIR"; export ADO_DIR
cat > "$WORK/bin/az" <<'STUB'
#!/usr/bin/env bash
echo "az $*" >> "$STUB_LOG"
arg() { local k="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$1 $2 $3" in
  "repos pr list")
    s="refs/heads/$(arg --source-branch "$@")"
    cat "$ADO_DIR"/pr-*.json 2>/dev/null | jq -s --arg s "$s" '[.[] | select(.sourceRefName == $s and .status == "active")]' ;;
  "repos pr create")
    [ -z "${ADO_CREATE_FAIL:-}" ] || { echo "TF400898: an internal error" >&2; exit 1; }
    n=$(( $(cat "$ADO_DIR/seq" 2>/dev/null || echo 100) + 1 )); echo "$n" > "$ADO_DIR/seq"
    jq -n --argjson n "$n" --arg s "refs/heads/$(arg --source-branch "$@")" \
      --arg t "refs/heads/$(arg --target-branch "$@")" --arg d "$(arg --draft "$@")" \
      --arg sha "${ADO_SOURCE_SHA:-}" --arg desc "$(arg --description "$@")" \
      '{pullRequestId: $n, status: "active", isDraft: ($d == "true"), mergeStatus: "succeeded",
        repository: {name: "fixture"}, sourceRefName: $s, targetRefName: $t, description: $desc,
        lastMergeSourceCommit: {commitId: $sha}}' > "$ADO_DIR/pr-$n.json"
    [ -z "${ADO_LOSE_ANSWER:-}" ] || { echo "the operation timed out" >&2; exit 1; }
    cat "$ADO_DIR/pr-$n.json" ;;
  "repos pr update")
    f="$ADO_DIR/pr-$(arg --id "$@").json"; [ -f "$f" ] || exit 1
    [ "$(arg --draft "$@")" != false ] || { jq '.isDraft = false' "$f" > "$f.t" && mv "$f.t" "$f"; }
    cat "$f" ;;
  "repos pr show") f="$ADO_DIR/pr-$(arg --id "$@").json"; [ -f "$f" ] && cat "$f" || exit 1 ;;
  "account show"*) echo '{}' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/az"
creates() { grep -c -- '^az repos pr create' "$STUB_LOG" || true; }
azcalls() { grep -c -- '^az ' "$STUB_LOG" || true; }
pr() { jq -r ".$2" "$ADO_DIR/pr-$1.json"; }
mkpr() {  # mkpr <id> <head> <target> <isDraft> — an existing active PR
  jq -n --argjson n "$1" --arg s "refs/heads/$2" --arg t "refs/heads/$3" --argjson d "$4" \
    '{pullRequestId: $n, status: "active", isDraft: $d, repository: {name: "fixture"},
      sourceRefName: $s, targetRefName: $t, lastMergeSourceCommit: {commitId: ""}}' > "$ADO_DIR/pr-$1.json"
}
PR="bash .claude/lib/team-pr.sh"
create() { run "$CLONE" $PR create "$1" --head "$2" --base develop --title "AB-2500 export" --body-file "$BF"; }
BF="$WORK/body.md"; printf '## What\nExport button.\n\n## Checklist\n- [x] tests\n' > "$BF"
: > "$STUB_LOG"

# ---- (a) none found → one draft; a rerun returns it ------------------------------------------------
create --draft h1; expect 0 "pr=101" "(a) create draft"
[ "$(creates)" = 1 ] && [ "$(pr 101 isDraft)" = true ] && [ "$(pr 101 targetRefName)" = refs/heads/develop ] \
  || fail "(a) one draft against develop: creates $(creates)"
grep -q -- "--draft true" "$STUB_LOG" && grep -q -- "--description @$BF" "$STUB_LOG" || fail "(a) create flags"
create --draft h1; expect 0 "pr=101" "(a) rerun"
[ "$(creates)" = 1 ] || fail "(a) a rerun created again"
echo "team-smoke-25: (a) create + rerun OK"

# ---- (b) --ready publishes the found draft; --draft never reverts a published PR -------------------
create --ready h1; expect 0 "pr=101" "(b) ready on a found draft"
[ "$(pr 101 isDraft)" = false ] && [ "$(creates)" = 1 ] || fail "(b) not published, or created again"
create --draft h1; expect 3 "PR #101 is already published — not reverting" "(b) draft on a published PR"
[ "$(pr 101 isDraft)" = false ] && [ "$(creates)" = 1 ] || fail "(b) reverted or created"
echo "team-smoke-25: (b) settle rules OK"

# ---- (c) a lost create answer: the after-lookup finds the PR, a retry creates nothing ---------------
ADO_LOSE_ANSWER=1 create --draft h2; expect 0 "pr=102" "(c) lost answer"
[ "$(creates)" = 2 ] || fail "(c) creates $(creates), expected 2"
create --draft h2; expect 0 "pr=102" "(c) retry after a lost answer"
[ "$(creates)" = 2 ] && [ "$(ls "$ADO_DIR"/pr-*.json | wc -l | tr -d ' ')" = 2 ] || fail "(c) a second PR"
echo "team-smoke-25: (c) lost answer OK"

# ---- (d) a failed create leaves no PR → 4; two active PRs → 3; another target → 3 -------------------
ADO_CREATE_FAIL=1 create --draft h3; expect 4 "left no active PR for h3 → develop" "(d) failed create"
[ "$(creates)" = 3 ] || fail "(d) creates $(creates), expected 3"
mkpr 201 h4 develop true; mkpr 202 h4 develop true
create --draft h4; expect 3 "ambiguous: 201,202 active for h4" "(d) two active PRs"
mkpr 203 h5 main true
create --draft h5; expect 3 "an active PR of h5 targets another line: #203 → refs/heads/main" "(d) other target"
[ "$(creates)" = 3 ] || fail "(d) a refusal created a PR"
echo "team-smoke-25: (d) refusals OK"

# ---- (e) the body: ≤ 4000 characters, no secret-like line — checked before any az call -------------
n0="$(azcalls)"
awk 'BEGIN { for (i = 0; i < 4001; i++) printf "x"; print "" }' > "$WORK/long.md"
run "$CLONE" $PR create --draft --head h6 --base develop --title T --body-file "$WORK/long.md"
expect 2 "the PR body has 4002 characters — Azure DevOps keeps 4000" "(e) a body over the cap"
printf '## What\nExport.\nAPI_KEY=abc123\n' > "$WORK/secret.md"
run "$CLONE" $PR create --draft --head h6 --base develop --title T --body-file "$WORK/secret.md"
expect 2 "secret-like NAME=value line" "(e) a secret-like line"
[ "$(azcalls)" = "$n0" ] && [ "$(creates)" = 3 ] || fail "(e) az was called for a refused body"
awk 'BEGIN { for (i = 0; i < 3999; i++) printf "x"; print "" }' > "$WORK/cap.md"
run "$CLONE" $PR create --draft --head h6 --base develop --title T --body-file "$WORK/cap.md"
expect 0 "pr=103" "(e) a body at the cap"
echo "team-smoke-25: (e) body rules OK"

# ---- (f) publish: draft → published, idempotent; other ops stay on the team-lib helpers ------------
run "$CLONE" $PR publish 102; expect 0 "pr=102" "(f) publish"
[ "$(pr 102 isDraft)" = false ] || fail "(f) still a draft"
run "$CLONE" $PR publish 102; expect 0 "pr=102" "(f) publish again"
run "$CLONE" $PR state 102; expect 2 "azure-devops uses the team-lib.sh helpers" "(f) state stays on team-lib"
echo "team-smoke-25: (f) publish OK"

# ---- (g) the rendered ADO coder and cli blocks call team-pr.sh, never /pr-create -------------------
render() { ( . "$MAIN/.claude/lib/team-pr-render.sh"
  team_pr_render azure-devops "$MAIN/.claude/team/pr" "Azure DevOps org" "https://dev.azure.com/o" auto \
    "$(cat "$MAIN/.claude/team/prompts/$1.md")" ) > "$WORK/r-$1"; }
render coder; render cli
has 'team-pr.sh create --draft --head {{BRANCH}} --base {{LINE}}' "$WORK/r-coder" || fail "(g) coder block"
has 'team-pr.sh create --ready --head {{BRANCH}} --base {{LINE}}' "$WORK/r-cli" || fail "(g) cli block"
has 'answers.md' "$WORK/r-cli" && has '4000 characters' "$WORK/r-coder" || fail "(g) body rules in the blocks"
! grep -q 'Run `/pr-create`' "$WORK/r-coder" "$WORK/r-cli" || fail "(g) a block still runs /pr-create"
echo "team-smoke-25: (g) prompt blocks OK"

# ---- (h) a coder record on a PR made by team-pr.sh passes the runner's ADO validation --------------
RUN_ID=alfa-20261116-140000; RD="$TD/runs/$RUN_ID"; mkdir -p "$RD"; echo "$RUN_ID" > "$TD/run"
commit_file .agents/plans/active/p.md "# Plan"; P_OUT="$(git -C "$CLONE" rev-parse HEAD)"
jq -n --arg r "$RUN_ID" --arg o "$P_OUT" '{team: "alfa", ticket: "AB-2500", run: $r, role: "planner", attempt: 1,
  seq: 1, input_rev: "", output_rev: $o, verdict: "done", pr_id: null, artifacts: [".agents/plans/active/p.md"],
  evidence: [], notes: "", message: "", written_at: "2026-11-16T14:00:00Z"}' > "$RD/planner-1-1.json"
touch "$RD/planner-1-1.json.accepted"
mkdir -p "$CLONE/.agents/plans/done"; git -C "$CLONE" mv .agents/plans/active/p.md .agents/plans/done/p.md
commit_file src/export.txt "export button"; C1="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" push --quiet origin "$BR"
session coder 1 "$P_OUT"
ADO_SOURCE_SHA="$C1" create --draft "$BR"; expect 0 "pr=104" "(h) the coder's draft"
R="$(record --verdict done --pr 104 --artifacts .agents/plans/done/p.md)"
run "$MAIN" $TR alfa check "$R"; expect 0 "valid: coder-1-1.json" "(h) check_ado accepts the PR"
[ "$(creates)" = 5 ] || fail "(h) creates $(creates), expected 5"
echo "team-smoke-25: (h) coder record on the created PR OK"

echo "team-smoke-25: OK"
