#!/usr/bin/env bash
# Supervisor's merge check for a team PR: wrapup revision = PR source, memory-only after QA,
# then build + test-gate on ADO's merge ref.
#
# Usage: bash .claude/lib/team-merge-check.sh <team> [--memory-reviewed]
#   e.g. bash .claude/lib/team-merge-check.sh alfa
#   --memory-reviewed: the supervisor read a reported memory overlap (or committed a memory-only fix
#   on top of the wrapup) and accepts it.
#   cli mode: the accepted cli record replaces qa + wrapup; no memory checks.
#
# Run from the main checkout; works in ../<repo>-<team>.
# Never merges — github: team-integrate.sh, ADO: /pr-merge.
# Exit: 0 VERDICT ok · 1 VERDICT fail or dirty clone
#   3 refused (identity, stale merge, moved tips, records changed during the check)
#   4 recalculating (github merge ref pending)
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] || usage
case "${2:-}" in "") REVIEWED=0 ;; --memory-reviewed) REVIEWED=1 ;; *) usage ;; esac
TEAM="$1"

root="$(git rev-parse --show-toplevel)"
. "$root/.claude/lib/team-profile.sh"
team_profile_load "$root"
team_profile_require_supported
CLONE="$(team_clone_dir "$TEAM" "$root")"
[ -f "$CLONE/.agents/team/team.json" ] || { echo "error: no team clone at $CLONE" >&2; exit 1; }
cd "$CLONE"
. "$CLONE/.claude/lib/team-lib.sh"
. "$root/.claude/lib/team-modes.sh"
. "$root/.claude/lib/team-integrate-lib.sh"

die() { echo "$2" >&2; exit "$1"; }
TD="$CLONE/.agents/team"
BRANCH="$(team_json branch)"; LINE="$(team_json line)"
RUN="$(cat "$TD/run" 2>/dev/null || true)"
MODE="$(team_mode "$TD/team.json")" || die 1 "cannot read the mode of $TD/team.json"
# Taken BEFORE the qualification and confirmed after the gates: the verdict this writes is only
# about the records that were in the run when it started (Amendment 3 point 2). github only — the
# ADO path keeps exactly the checks it had.
digest0=""
[ "$TEAM_PR_PROVIDER" != github ] || digest0="$(team_records_digest "$TD" "$RUN")"

[ ! -f "$TD/session.json" ] || die 3 "a role is still live ($(jq -r .role "$TD/session.json")) — wait for it to finish"
if [ "$MODE" = cli ]; then
  cl="$(team_accepted_record "$RUN" cli)"
  [ -n "$cl" ] || die 3 "no accepted cli record in run '${RUN:-none}' — run team-run.sh first"
  [ "$(jq -r .verdict "$cl")" = done ] || die 3 "accepted cli record is not done"
  want="$(jq -r .output_rev "$cl")"; pr="$(jq -r .pr_id "$cl")"
else
  qa="$(team_accepted_record "$RUN" qa)"
  [ -n "$qa" ] || die 3 "no accepted qa record in run '${RUN:-none}' — run team-run.sh first"
  [ "$(jq -r .verdict "$qa")" = done ] || die 3 "accepted qa record is not done"
  qa_rev="$(jq -r .output_rev "$qa")"; pr="$(jq -r .pr_id "$qa")"
  wr="$(team_accepted_record "$RUN" wrapup)"
  [ -n "$wr" ] || die 3 "wrapup not done — run /start-team $TEAM"
  [ "$(jq -r .verdict "$wr")" = done ] || die 3 "accepted wrapup record is not done"
  want="$(jq -r .output_rev "$wr")"
fi
# memory_only <from> <to> → prints the changed files; dies on a failed diff or a non-memory file.
# Self-contained on purpose: this sources the clone's team-lib.sh, which may predate any shared helper.
memory_only() {
  local d bad
  # --no-renames: a move from code into memory must list the deleted source path too.
  d="$(git diff --no-renames --name-only "$1" "$2")" || die 3 "cannot diff $1..$2"
  bad="$(printf '%s\n' "$d" | grep -v -e '^\.agents/memory/' -e '^$' || true)"
  [ -z "$bad" ] || die 3 "changes after QA outside .agents/memory/: $(echo $bad)"
  printf '%s\n' "$d" | grep -v '^$' || true
}

tips() {
  local out
  out="$(git ls-remote origin "refs/heads/$BRANCH" "refs/heads/$LINE")"
  SRC="$(awk -v r="refs/heads/$BRANCH" '$2 == r {print $1}' <<<"$out")"
  TGT="$(awk -v r="refs/heads/$LINE" '$2 == r {print $1}' <<<"$out")"
}
tips
[ -n "$SRC" ] || die 3 "source branch $BRANCH absent on origin"
git fetch --quiet origin "refs/heads/$BRANCH" "refs/heads/$LINE" || die 3 "cannot fetch $BRANCH / $LINE"
if [ "$MODE" = cli ]; then
  [ "$SRC" = "$want" ] || die 3 "source tip ${SRC:-absent} is not the cli revision $want — someone pushed after the cli role"
elif [ "$SRC" != "$want" ]; then
  # After a reviewed conflict the supervisor may add a memory-only fix on top of the wrapup.
  [ "$REVIEWED" = 1 ] && git merge-base --is-ancestor "$want" "$SRC" 2>/dev/null \
    || die 3 "source tip ${SRC:-absent} is not the wrapup revision $want — someone pushed after wrapup"
  fix="$(memory_only "$want" "$SRC")"
  echo "supervisor memory fix after wrapup: $(echo $fix)"
fi
delta=""
[ "$MODE" = cli ] || delta="$(memory_only "$qa_rev" "$SRC")"
if [ -n "$delta" ]; then
  tr_rev="$(sed -n 's/^target_rev: //p' "$TD/runs/$RUN/wrapup-$(jq -r .attempt "$wr").md" 2>/dev/null)"
  [ -n "$tr_rev" ] || die 3 "wrapup summary has no target_rev"
  tdelta="$(git diff --no-renames --name-only "$tr_rev" "$TGT" -- .agents/memory)" \
    || die 3 "target_rev $tr_rev unknown or not comparable with $TGT"
  # Union merge would splice both versions silently; a human reads them first.
  ov="$(comm -12 <(printf '%s\n' "$delta" | sort) <(printf '%s\n' "$tdelta" | sort) | grep -v '^$' || true)"
  if [ -n "$ov" ]; then
    [ "$REVIEWED" = 1 ] || die 3 "memory overlap: $(echo $ov) changed on $LINE since wrapup — review them in the PR, then rerun with --memory-reviewed"
    echo "memory overlap reviewed: $(echo $ov)"
  fi
fi

if [ "$TEAM_PR_PROVIDER" = github ]; then
  # Same check integrate runs again under the lock, so the gate verdict and the push agree on what
  # "eligible" means. It also leaves the tested merge commit under `refs/team-pr/<pr>/merge`.
  rc=0
  team_integration_eligible "$TEAM" "$CLONE" "$RUN" "$MODE" "$pr" || rc=$?
  case "$rc" in
    0) ;;
    4) die 4 "merge ref recalculating — rerun later" ;;
    *) die 3 "PR #$pr is not eligible for a merge check" ;;
  esac
  merge_commit="$IE_MERGE"
  # readiness read the tips itself; if they disagree with ours, something moved mid-check already.
  [ "$IE_SRC" = "$SRC" ] && [ "$IE_TGT" = "$TGT" ] \
    || die 3 "PR head/base differ from origin tips — rerun"
else
team_ado_coords
j="$(team_pr_json "$pr")"
team_pr_identity "$j" "$BRANCH" "$LINE" || die 3 "PR identity mismatch (#$pr)"
ms="$(jq -r '.mergeStatus // "notSet"' <<<"$j")"
case "$ms" in
  succeeded) ;;
  queued|notSet) die 3 "ADO merge not recalculated yet, rerun later (mergeStatus $ms)" ;;
  *) die 3 "ADO merge status is $ms — resolve on the PR first" ;;
esac
[ "$(jq -r '.lastMergeSourceCommit.commitId // ""' <<<"$j")" = "$SRC" ] \
  || die 3 "ADO merge not recalculated yet, rerun later (lastMergeSourceCommit is not $SRC)"
# Target-push recompute is undocumented, so a stale merge is detected against the live target tip.
[ "$(jq -r '.lastMergeTargetCommit.commitId // ""' <<<"$j")" = "$TGT" ] \
  || die 3 "stale merge — target moved; in ADO click Restart merge or push nothing and rerun"
merge_commit="$(jq -r '.lastMergeCommit.commitId // ""' <<<"$j")"
fi

[ -z "$(git status --porcelain)" ] || die 1 "clone $CLONE is dirty — refusing to switch"
if [ "$TEAM_PR_PROVIDER" = github ]; then
  # The ref `refs/team-pr/<pr>/merge` is only the delivery vehicle — readiness fetched the commit
  # into a ref we own (FETCH_HEAD is global and any concurrent fetch rewrites it). What we check
  # out is the IMMUTABLE SHA: a ref is mutable, so checking out the ref could put the gates on an
  # M0 while this verdict records an M1.
  echo "tested merge commit: $merge_commit (via refs/team-pr/$pr/merge)"
  [ "$(git rev-parse -q --verify "refs/team-pr/$pr/merge" || true)" = "$merge_commit" ] \
    || die 4 "refs/team-pr/$pr/merge is not $merge_commit — rerun"
  MERGE_OBJ="$merge_commit"
else
  MERGE_OBJ=FETCH_HEAD
  echo "fetching refs/pull/$pr/merge"
  git fetch --quiet origin "refs/pull/$pr/merge"
  [ "$(git rev-parse FETCH_HEAD)" = "$merge_commit" ] || die 3 "FETCH_HEAD is not lastMergeCommit $merge_commit"
fi

# The HEAD assertions below can only DETECT a clone that stayed put; they cannot stop a runner or a
# role from switching it to another commit while the gates read the tree (switch to M0, build,
# switch back to M1 — both assertions pass and the verdict describes a tree nobody tested). So the
# github path takes the TEAM RUNNER LOCK — the very `$TD/lock` directory `team-run.sh cmd_advance`
# takes, same path, same `pid` file, same never-auto-steal rule — and holds it across
# checkout → gates → restore. While it is held, no runner and no role can start in this clone.
#
# It is taken BEFORE `orig` is read and before any trap is armed: a process that LOSES this mkdir
# must not go on to own a restore trap, or its exit would `git switch` the clone back while the
# winner's gates are mid-build. ADO keeps today's behaviour byte for byte (TT is read-only here).
OWN_RUN_LOCK=""
# Only the process whose pid is in the lock removes it — the rule of team-run.sh's own trap.
# `OWN_RUN_LOCK=1` means "WE created this lock in this run", which is also the only case in which a
# lock with no pid in it may be removed (the pid write can fail after the mkdir). Otherwise the
# team-run.sh:429 rule applies: only the process whose pid is in the lock removes it.
mc_run_lock_free() {
  local p
  [ "$OWN_RUN_LOCK" = 1 ] || return 0
  p="$(cat "$TD/lock/pid" 2>/dev/null || true)"
  if [ "$p" = "$$" ] || [ -z "$p" ]; then
    rm -rf "$TD/lock" 2>/dev/null || true
    [ ! -e "$TD/lock" ] || echo "warning: could not remove $TD/lock — remove it by hand" >&2
  else
    echo "warning: runner lock is pid $p, not ours — left in place" >&2
  fi
  OWN_RUN_LOCK=""
}
if [ "$TEAM_PR_PROVIDER" = github ]; then
  mkdir "$TD/lock" 2>/dev/null \
    || die 3 "team runner active — runner lock held by pid $(cat "$TD/lock/pid" 2>/dev/null || echo unknown)"
  # Armed BEFORE the pid is written: a failed write must not leave the lock behind. Until our own
  # checkout succeeds this trap only drops the lock — there is nothing to restore yet.
  OWN_RUN_LOCK=1
  trap 'mc_run_lock_free' EXIT
  echo $$ > "$TD/lock/pid" || die 3 "cannot write $TD/lock/pid"
fi

orig="$(git rev-parse --abbrev-ref HEAD)"
if [ "$TEAM_PR_PROVIDER" = github ]; then
  git switch --quiet --detach "$MERGE_OBJ" || die 3 "cannot check out $MERGE_OBJ"
  # Armed only now: we hold the lock AND we are the process that moved the clone.
  trap 'git switch --quiet "$orig" || echo "warning: clone left detached — git switch $orig" >&2
        mc_run_lock_free' EXIT
else
  trap 'git switch --quiet "$orig" || echo "warning: clone left detached — git switch $orig" >&2' EXIT
  git switch --quiet --detach "$MERGE_OBJ"
fi
# What the gates are about to run on, by sha. The verdict below reports THIS commit, so if the
# checkout did not land where we think it did, there is no verdict to write. github only: on ADO
# this would be a new refusal on a path that must stay byte-identical.
tested=""
if [ "$TEAM_PR_PROVIDER" = github ]; then
  tested="$(git rev-parse HEAD)"
  [ "$tested" = "$merge_commit" ] \
    || die 3 "the clone is at $tested, not the merge commit $merge_commit"
fi

echo "running build check on the merge ref (minutes): $TEAM_BUILD_CHECK"
set +e
# bash -c, cwd = the clone root: the build check is a project value, never ticket content.
bash -c "$TEAM_BUILD_CHECK" > "$TD/merge-check-build.log" 2>&1
build_rc=$?
# test-gate runs --no-build: after a failed build it would test the previous build's binaries.
gate_out="test-gate: skipped — build failed"; gate_rc=1
if [ "$TEAM_TEST_GATE" = none ]; then
  gate_out="test-gate: none"; gate_rc=0
elif [ "$build_rc" = 0 ]; then
  echo "running test-gate (minutes)"
  gate_out="$(bash "$TEAM_TEST_GATE" 2>&1)"
  gate_rc=$?
fi
set -e

# Still on the commit the gates were started on: a build check that switched the clone underneath
# itself would otherwise have its result recorded against a commit it never built.
[ "$TEAM_PR_PROVIDER" != github ] || [ "$(git rev-parse HEAD)" = "$tested" ] \
  || die 3 "void: the clone moved off $tested during the check — rerun"
git switch --quiet "$orig"
mc_run_lock_free
trap - EXIT

old_src="$SRC"; old_tgt="$TGT"
tips
[ "$SRC" = "$old_src" ] && [ "$TGT" = "$old_tgt" ] || die 3 "void: tips moved during check — rerun"
if [ "$TEAM_PR_PROVIDER" = github ]; then
  # The tips can sit still while the WORK moves: a new accepted record after the verdict means the
  # gates ran on a workflow state that no longer exists.
  [ "$(team_records_digest "$TD" "$RUN")" = "$digest0" ] \
    || die 3 "void: records changed during check — rerun"
  # GitHub may rebuild the synthetic merge ref while the gates run (Amendment 8); the commit we
  # tested would then no longer be the one the integrator could push.
  rc=0
  rr="$(bash .claude/lib/team-pr.sh readiness "$pr")" || rc=$?
  [ "$rc" = 0 ] && [ "$(jq -r '.merge_sha' <<<"$rr")" = "$merge_commit" ] \
    || die 4 "merge ref recalculated during check — rerun"
fi

verdict=ok
[ "$build_rc" = 0 ] && [ "$gate_rc" = 0 ] || verdict=fail
# github only: `merge-check.json` is the integrator's input, and ADO merges by hand through
# /pr-merge. Writing it there would add a failure mode to a path that must stay byte-identical.
[ "$TEAM_PR_PROVIDER" != github ] \
  || team_merge_check_write "$TD/runs/$RUN/merge-check.json" "$RUN" "$pr" "$TEAM_GH_REPO" \
       "$BRANCH" "$LINE" "$SRC" "$TGT" "$tested" "$digest0" "$verdict"
echo "VERDICT: $verdict"
echo "build: exit $build_rc (log: $TD/merge-check-build.log)"
grep -E '^test-gate:|NEW FAILURE' <<<"$gate_out" || echo "test-gate: exit $gate_rc"
echo "validated source=$SRC target=$TGT"
[ "$verdict" = ok ]
