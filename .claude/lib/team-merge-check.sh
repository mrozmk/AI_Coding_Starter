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
# Run from the main checkout; works in ../<repo>-<team>. Never merges — /pr-merge stays manual.
# Exit: 0 VERDICT ok · 1 VERDICT fail or dirty clone · 3 refused (identity, stale merge, moved tips)
set -euo pipefail

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
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

die() { echo "$2" >&2; exit "$1"; }
TD="$CLONE/.agents/team"
BRANCH="$(team_json branch)"; LINE="$(team_json line)"
RUN="$(cat "$TD/run" 2>/dev/null || true)"
MODE="$(team_mode "$TD/team.json")" || die 1 "cannot read the mode of $TD/team.json"

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

[ -z "$(git status --porcelain)" ] || die 1 "clone $CLONE is dirty — refusing to switch"
echo "fetching refs/pull/$pr/merge"
git fetch --quiet origin "refs/pull/$pr/merge"
[ "$(git rev-parse FETCH_HEAD)" = "$merge_commit" ] || die 3 "FETCH_HEAD is not lastMergeCommit $merge_commit"

orig="$(git rev-parse --abbrev-ref HEAD)"
trap 'git switch --quiet "$orig" || echo "warning: clone left detached — git switch $orig" >&2' EXIT
git switch --quiet --detach FETCH_HEAD

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

git switch --quiet "$orig"
trap - EXIT

old_src="$SRC"; old_tgt="$TGT"
tips
[ "$SRC" = "$old_src" ] && [ "$TGT" = "$old_tgt" ] || die 3 "void: tips moved during check — rerun"

verdict=ok
[ "$build_rc" = 0 ] && [ "$gate_rc" = 0 ] || verdict=fail
echo "VERDICT: $verdict"
echo "build: exit $build_rc (log: $TD/merge-check-build.log)"
grep -E '^test-gate:|NEW FAILURE' <<<"$gate_out" || echo "test-gate: exit $gate_rc"
echo "validated source=$SRC target=$TGT"
[ "$verdict" = ok ]
