#!/usr/bin/env bash
# Offline smoke for worker-next.sh (TT-849): refusals, two assignments in one clone, resume.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/team-smoke-lib.sh"
smoke_init

W="bash .claude/lib/worker-next.sh"
SOL="$WORK/main-sol"
WD="$SOL/.git/taketask-worker"
DEV=origin/develop-netcore7
export WORKER_ARTIFACTS="$WORK/artifacts" WORKER_LOCK_SECS=1

pr_done() {  # pr_done <status> <source sha> <branch>
  pr_json false "$2" succeeded refs/heads/develop-netcore7 "$2"
  jq --arg s "$1" --arg b "refs/heads/$3" \
    '.status = $s | .sourceRefName = $b | .repository.name = "fixture"' "$STUB_PR" \
    > "$WORK/pd.json" && mv "$WORK/pd.json" "$STUB_PR"
}
squash() {  # squash <msg> — ADO's squash commit: never an ancestor of a worker branch
  echo "$1" >> "$MAIN/squash.txt"
  git -C "$MAIN" add squash.txt && git -C "$MAIN" commit --quiet -m "$1"
  git -C "$MAIN" push --quiet origin develop-netcore7
}
remote_commit() {  # remote_commit <branch> [start] — a push to origin/<branch> from elsewhere
  git -C "$MAIN" fetch --quiet origin
  git -C "$MAIN" switch --quiet --detach "origin/${2:-$1}"
  echo x >> "$MAIN/other.txt"
  git -C "$MAIN" add other.txt && git -C "$MAIN" commit --quiet -m other
  git -C "$MAIN" push --quiet origin "HEAD:refs/heads/$1"
  git -C "$MAIN" switch --quiet develop-netcore7
}
sol_commit() {  # sol_commit <file>
  echo "$1" > "$SOL/$1"
  git -C "$SOL" add "$1" && git -C "$SOL" commit --quiet -m "add $1"
}
field() { sed -n "s/^$1: *//p" "$WORK/out" | head -n 1; }
start() { run "$MAIN" $W start "$@"; }
release() { run "$MAIN" $W release "$@"; }
head_on() {  # head_on <branch> <sha>
  [ "$(git -C "$SOL" symbolic-ref --short -q HEAD)" = "$1" ] || fail "HEAD is not on $1"
  [ "$(git -C "$SOL" rev-parse HEAD)" = "$2" ] || fail "$1 is not at $2"
}
has_branch() {
  git -C "$SOL" rev-parse --verify --quiet "refs/heads/$1" >/dev/null || fail "branch $1 deleted"
}
count() { ls -d "$@" 2>/dev/null | wc -l | tr -d ' '; }
# pid-scoped: a whole-table scan matches this grep's own argv, which holds the searched command.
# Not -q: an early grep exit under pipefail can SIGPIPE ps and flip the rc.
build_visible() { ps -p "$SPID" -o command= | grep -F -- "$SCMD" >/dev/null; }
fake_build() {  # fake_build <cwd> <argv0> — a build process the probe must judge
  (cd "$1" && exec -a "$2" sleep 30) &
  SPID=$!; SCMD="$2"
  disown "$SPID"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    build_visible && break
    sleep 0.2
  done
  build_visible || fail "fake build '$2' never appeared in ps"
}
stop_build() {  # waits until ps no longer lists it, so the next probe cannot see a dying build
  kill "$SPID" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    build_visible || break
    sleep 0.2
  done
  SPID=""; SCMD=""
}

# ---- (1) init ---------------------------------------------------------------------------------
echo worker-smoke-marker >> "$MAIN/.git/info/exclude"
run "$MAIN" $W init develop-netcore7
expect 1 "must be origin/<branch>" "init with a bad base"
[ ! -e "$SOL" ] || fail "a refused init created the clone"
mkdir "$WORK/nojq"
printf '#!/bin/sh\nexit 127\n' > "$WORK/nojq/jq" && chmod +x "$WORK/nojq/jq"
run "$MAIN" env PATH="$WORK/nojq:$PATH" $W init $DEV
expect 1 "jq is required" "init without jq"
[ ! -e "$SOL" ] || fail "init without jq created the clone"
run "$MAIN/.claude" bash lib/worker-next.sh init $DEV
expect 0 "clone:" "init from a subdirectory"
grep -qx worker-smoke-marker "$SOL/.git/info/exclude" || fail "init did not copy info/exclude"
SOLP=$(cd "$SOL" && pwd -P)
[ -f "$WD/provisioned.json" ] || fail "init wrote no provisioned.json"
[ ! -e "$SOL/.env" ] || fail "init copied .env"
[ ! -e "$SOL/.agents/team/team.json" ] || fail "init made a team clone"
[ -z "$(git -C "$SOL" status --porcelain)" ] || fail "init left the clone dirty"
run "$MAIN" $W init $DEV
expect 1 "exists" "second init"
run "$MAIN" $W status
expect 0 "last: none (provisioned at" "status after init"

# ---- (2) a base without the contract ----------------------------------------------------------
git -C "$MAIN" switch --quiet -c no-contract
grep -vx '### Worker clone' "$MAIN/AGENTS.md" > "$WORK/a.md" && mv "$WORK/a.md" "$MAIN/AGENTS.md"
git -C "$MAIN" commit --quiet -am "drop contract" && git -C "$MAIN" push --quiet origin no-contract
git -C "$MAIN" switch --quiet develop-netcore7
start TT-900 chore/TT-900-a origin/no-contract --thread t1
expect 1 "no worker contract" "start on a base without the contract"
[ ! -e "$WD/active" ] || fail "a refused start published an assignment"

# ---- (3) happy start A ------------------------------------------------------------------------
start TT-900 chore/TT-900-a $DEV --thread t1
expect 0 "artifacts:" "start A"
ID1=$(field id)
B0=$(git -C "$SOL" rev-parse origin/develop-netcore7)
head_on chore/TT-900-a "$B0"
[ -d "$WORKER_ARTIFACTS/$ID1" ] || fail "start A made no artifacts dir"
run "$MAIN" $W status
expect 0 "state: active" "status while A is active"
has "id: $ID1" "$WORK/out" || fail "status lacks the assignment id"

# ---- (4) refusals while active ----------------------------------------------------------------
start TT-901 chore/TT-901-b $DEV --thread t2
expect 1 "is active — release it first" "start while A is active"
start TT-900 chore/TT-900-a origin/rc --thread t1
expect 1 "base change for active assignment" "base change of A"
chmod 000 "$SOL/.git/index"
release "$ID1"
expect 1 "git status failed in" "release when git status fails"
chmod 644 "$SOL/.git/index"

# ---- (5) check --------------------------------------------------------------------------------
run "$SOL" $W check "$ID1"
expect 0 "diff sha:" "check from the clone"
D1=$(field "diff sha")
run "$SOL" $W check TT-1-x
expect 1 "stale: active assignment is $ID1" "check with a stale id"
echo u > "$SOL/untracked.txt"
run "$SOL" $W check "$ID1"
expect 0 "diff sha:" "check with an untracked file"
[ "$(field "diff sha")" != "$D1" ] || fail "diff sha ignores an untracked file"
run "$MAIN" $W check "$ID1"
expect 0 "head:" "check from the main checkout"

# ---- (6) release refusals ---------------------------------------------------------------------
release "$ID1"
expect 1 "uncommitted or untracked" "release over an untracked file"
git -C "$SOL" add untracked.txt && git -C "$SOL" commit --quiet -m wip
release "$ID1"
expect 1 "1 commits on chore/TT-900-a but no PR" "release of work without a PR"
git -C "$SOL" push --quiet origin chore/TT-900-a
T1=$(git -C "$SOL" rev-parse HEAD)
pr_done active "$T1" chore/TT-900-a
release "$ID1" --pr 8371
expect 1 "PR #8371 is active" "release with an open PR"
export STUB_PR="$WORK/missing.json"
release "$ID1" --pr 8371
expect 1 "PR #8371 state unknown" "release when az fails"
export STUB_PR="$WORK/pr.json"
pr_done abandoned "$T1" chore/TT-900-a
release "$ID1" --pr 8371
expect 1 "is abandoned — not merged" "release of an abandoned PR without the flag"
sol_commit late.txt
pr_done completed "$T1" chore/TT-900-a
release "$ID1" --pr 8371
expect 1 "commits after PR #8371" "release with a local commit after the PR"
release "$ID1" --pr x1
expect 1 "must be digits" "release with a bad PR id"
release ../x
expect 1 "must be <key>-<yyyymmdd>-<hhmmss>" "release with a malformed id"
[ -e "$WD/active" ] || fail "a malformed id moved the active assignment"

# ---- (7) live remote ahead of the clone -------------------------------------------------------
git -C "$SOL" push --quiet origin chore/TT-900-a
T2=$(git -C "$SOL" rev-parse HEAD)
pr_done completed "$T2" chore/TT-900-a
remote_commit chore/TT-900-a
release "$ID1" --pr 8371
expect 1 "commits after PR #8371" "release with a remote commit after the PR"
git -C "$MAIN" push --quiet origin --delete chore/TT-900-a

# ---- (8) squash merge recognised by the exact tip ---------------------------------------------
squash "squash TT-900"
release "$ID1" --pr 8371
expect 0 "outcome:     merged" "release A merged"
[ -f "$WD/history/$ID1/release.json" ] && [ ! -e "$WD/active" ] || fail "A not moved to history"
[ -f "$WORKER_ARTIFACTS/$ID1/release.json" ] || fail "release.json not copied to the artifacts"
has_branch chore/TT-900-a
rm "$WORKER_ARTIFACTS/$ID1/release.json"
release "$ID1" --pr 8371
expect 0 "already released: merged $T2" "release A again"
[ -f "$WORKER_ARTIFACTS/$ID1/release.json" ] || fail "a rerun did not re-copy release.json"

# ---- (9) a commit after release blocks the next start -----------------------------------------
sol_commit after.txt
start TT-901 chore/TT-901-b $DEV --thread t2
expect 1 "not the last settled tip" "start after a post-release commit"
git -C "$SOL" switch --quiet --detach "$T2"
chmod 000 "$SOL/.git/index"
start TT-901 chore/TT-901-b $DEV --thread t2
expect 1 "git status failed in" "start when git status fails"
chmod 644 "$SOL/.git/index"
[ ! -e "$WD/active" ] || fail "start with a failing git status published an assignment"

# ---- (10) the second assignment in the same clone ---------------------------------------------
start TT-901 chore/TT-901-b $DEV --thread t2
expect 0 "artifacts:" "start B"
ID2=$(field id)
B1=$(git -C "$MAIN" rev-parse develop-netcore7)
head_on chore/TT-901-b "$B1"
sol_commit b.txt
git -C "$SOL" push --quiet origin chore/TT-901-b
T3=$(git -C "$SOL" rev-parse HEAD)
pr_done completed "$T3" chore/TT-901-b
git -C "$MAIN" push --quiet origin --delete chore/TT-901-b
squash "squash TT-901"
release "$ID2" --pr 8371
expect 0 "outcome:     merged" "release B merged"
[ "$(count "$WORK"/*-sol*)" = 1 ] || fail "a second worker clone appeared"
[ "$(count "$WD"/history/*/)" = 2 ] || fail "history does not hold both assignments"
has_branch chore/TT-900-a; has_branch chore/TT-901-b

# ---- (11) empty and abandoned -----------------------------------------------------------------
start TT-902 chore/TT-902-c $DEV --thread t3
expect 0 "artifacts:" "start C"
ID3=$(field id)
remote_commit chore/TT-902-c develop-netcore7
release "$ID3"
expect 1 "reconcile before release" "release C with a foreign remote branch"
git -C "$MAIN" push --quiet origin --delete chore/TT-902-c
release "$ID3"
expect 0 "outcome:     empty" "release C empty"
start TT-902 chore/TT-902-g $DEV --thread t3
expect 0 "artifacts:" "restart TT-902"
ID4=$(field id)
[ "$ID4" != "$ID3" ] || fail "restart reused the id $ID3"
release "$ID4"
expect 0 "outcome:     empty" "release the TT-902 restart"
[ "$(count "$WD"/history/TT-902-*)" = 2 ] || fail "two TT-902 assignments not in history"
start TT-903 chore/TT-903-d $DEV --thread t3
expect 0 "artifacts:" "start D"
ID5=$(field id)
sol_commit d.txt
git -C "$SOL" push --quiet origin chore/TT-903-d
T5=$(git -C "$SOL" rev-parse HEAD)
pr_done abandoned "$T5" chore/TT-903-d
release "$ID5" --pr 8371 --abandoned
expect 0 "outcome:     abandoned" "release D abandoned"
has_branch chore/TT-903-d
jq -e --arg t "$T5" '.remote == $t and .outcome == "abandoned"' \
  "$WD/history/$ID5/release.json" >/dev/null || fail "release.json of D lacks the remote tip"

# ---- (11a) resume before the switch -----------------------------------------------------------
# Fixture surgery (patterns.md exception): an interruption before `switch` needs fault injection.
B3=$(git -C "$MAIN" rev-parse develop-netcore7)
mkdir "$WD/active"
jq -n --arg sha "$B3" --arg art "$WORKER_ARTIFACTS/TT-904-20261007-000000" \
  '{id: "TT-904-20261007-000000", ticket: "TT-904", branch: "chore/TT-904-e",
    line: "develop-netcore7", base_ref: "origin/develop-netcore7", base_sha: $sha, thread: "t4",
    state: "switching", artifacts: $art, started_at: "2026-10-07T00:00:00Z"}' \
  > "$WD/active/assignment.json"
squash "squash moves the origin"
start TT-904 chore/TT-904-e $DEV --thread t9
expect 1 "interrupted transition TT-904-20261007-000000 pending" "resume with other arguments"
sol_commit resume.txt
start TT-904 chore/TT-904-e $DEV --thread t4
expect 1 "not the last settled tip" "resume after a post-release commit"
# sol_commit advanced chore/TT-903-d past its release tip; that branch is evidence only now.
git -C "$SOL" switch --quiet --detach "$T5"
fake_build "$WORK" "dotnet build $SOLP/x.sln"
start TT-904 chore/TT-904-e $DEV --thread t4
expect 1 "a build, gate or review is running against" "resume during a build"
stop_build
jq -e '.state == "switching"' "$WD/active/assignment.json" >/dev/null \
  || fail "a refused resume changed the record"
start TT-904 chore/TT-904-e $DEV --thread t4
expect 0 "id:        TT-904-20261007-000000" "resume before the switch"
head_on chore/TT-904-e "$B3"
[ "$B3" != "$(git -C "$MAIN" rev-parse develop-netcore7)" ] || fail "fixture: origin did not move"
[ -d "$WORKER_ARTIFACTS/TT-904-20261007-000000" ] || fail "resume made no artifacts dir"
release TT-904-20261007-000000
expect 0 "outcome:     empty" "release the resumed assignment"

# ---- (11b) resume after the switch ------------------------------------------------------------
start TT-905 chore/TT-905-f $DEV --thread t5
expect 0 "artifacts:" "start F"
ID6=$(field id)
A="$WD/active/assignment.json"
jq '.state = "switching"' "$A" > "$WORK/as.json" && mv "$WORK/as.json" "$A"
echo stray > "$SOL/stray.txt"
start TT-905 chore/TT-905-f $DEV --thread t5
expect 1 "interrupted start $ID6 kept for the supervisor" "resume over an untracked file"
jq -e '.state == "switching"' "$A" >/dev/null || fail "a refused resume changed the record"
mv "$SOL/stray.txt" "$WORK/"
chmod 000 "$SOL/.git/index"
start TT-905 chore/TT-905-f $DEV --thread t5
expect 1 "git status failed in" "resume when git status fails"
chmod 644 "$SOL/.git/index"
jq -e '.state == "switching"' "$A" >/dev/null || fail "a refused resume changed the record"
start TT-905 chore/TT-905-f $DEV --thread t5
expect 0 "id:        $ID6" "resume after the switch"
jq -e '.state == "active"' "$A" >/dev/null || fail "resume did not activate"
[ "$(git -C "$SOL" symbolic-ref --short HEAD)" = chore/TT-905-f ] || fail "resume left HEAD"
release "$ID6"
expect 0 "outcome:     empty" "release F"

# ---- (11c) a staging leftover is listed, never deleted ----------------------------------------
mkdir "$WD/staging-TT-999-x"
run "$MAIN" $W status
expect 0 "leftover: staging-TT-999-x" "status lists a staging leftover"
has "state: idle" "$WORK/out" || fail "status is not idle after F"

# ---- (12) stale op.lock -----------------------------------------------------------------------
mkdir "$WD/op.lock"; echo 99999 > "$WD/op.lock/pid"
start TT-906 chore/TT-906-h $DEV --thread t6
expect 1 "stale: check no worker-next.sh runs" "start under a stale lock"
[ -d "$WD/op.lock" ] || fail "the script removed a foreign lock"
rm -f "$WD/op.lock/pid"; rmdir "$WD/op.lock"

# ---- (13) a running build blocks start --------------------------------------------------------
fake_build "$WORK" "dotnet build $SOLP/x.sln"
start TT-906 chore/TT-906-h $DEV --thread t6
expect 1 "a build, gate or review is running against" "start during a build"
stop_build
[ ! -e "$WD/active" ] || fail "start during a build published an assignment"
fake_build "$SOL" "dotnet build TakeTask2.API.sln"
start TT-906 chore/TT-906-h $DEV --thread t6
expect 1 "a build, gate or review is running against" "start during a relative build in the clone"
stop_build
[ ! -e "$WD/active" ] || fail "start during a relative build published an assignment"
fake_build "$SOL" "codex exec review then run bash .claude/lib/worker-next.sh check x"
start TT-906 chore/TT-906-h $DEV --thread t6
expect 1 "a build, gate or review is running against" \
  "start during a codex review quoting the script"
stop_build
[ ! -e "$WD/active" ] || fail "start during a codex review published an assignment"
mkdir "$WORK/main-solo"
fake_build "$WORK/main-solo" "dotnet build $SOLP-solo/x.sln"
start TT-906 chore/TT-906-h $DEV --thread t6
expect 0 "artifacts:" "start during a build in the sibling -solo checkout"
stop_build
ID7=$(field id); B7=$(field "base sha")

# ---- (13a) a deleted assignment branch is refused with a recovery -----------------------------
git -C "$SOL" switch --quiet --detach HEAD
git -C "$SOL" branch -D --quiet chore/TT-906-h
release "$ID7"
expect 1 "is missing in" "release with a deleted assignment branch"
has "HEAD of $SOLP is not on" "$WORK/out" || fail "missing-branch refusal hides the HEAD problem"
git -C "$SOL" branch chore/TT-906-h "$B7"
git -C "$SOL" switch --quiet chore/TT-906-h

# ---- (13b) the artifacts checks are best-effort -----------------------------------------------
head -c 8192 /dev/zero > "$WORKER_ARTIFACTS/$ID7/blob"
mkdir -p "$WORKER_ARTIFACTS/$ID7/locked/x"
chmod 000 "$WORKER_ARTIFACTS/$ID7/locked"
run "$MAIN" env WORKER_ARTIFACT_MAX_MB=0 $W release "$ID7"
expect 1 "over 0 KB" "release over the size limit with an unreadable subdir"
has "could not be fully measured" "$WORK/out" || fail "a partial measurement was not reported"
mkdir "$WORKER_ARTIFACTS/$ID7/bin"
release "$ID7"
expect 1 "contain bin/ or obj/" "release with bin/ next to an unreadable subdir"
has "could not be fully searched" "$WORK/out" || fail "a partial bin/obj search was not reported"
rmdir "$WORKER_ARTIFACTS/$ID7/bin"
mkdir "$WORK/nodu"
printf '#!/bin/sh\nexit 1\n' > "$WORK/nodu/du" && chmod +x "$WORK/nodu/du"
run "$MAIN" env PATH="$WORK/nodu:$PATH" $W release "$ID7"
expect 0 "outcome:     empty" "release when du fails outright"
has "could not be measured" "$WORK/out" || fail "a failed measurement was not reported"
! has "fully measured" "$WORK/out" || fail "du failure printed both warnings"
chmod 755 "$WORKER_ARTIFACTS/$ID7/locked"

# ---- (13c) a caller mentioning a review is not a hit ------------------------------------------
# `&&`, not `;`: the rc is start's, and bash stays alive as the script's $PPID.
run "$MAIN" bash -c "$W start TT-907 chore/TT-907-i $DEV --thread t7 && : codex exec $SOLP"
expect 0 "artifacts:" "start from a caller whose argv mentions a review"
ID8=$(field id)
release "$ID8"
expect 0 "outcome:     empty" "release H"

# ---- (13d) a deeper wrapper mentioning a review is not a hit ----------------------------------
# The subshell is the script's $PPID, so the quoting shell sits at the grandparent.
run "$MAIN" bash -c \
  "( $W start TT-908 chore/TT-908-j $DEV --thread t8; exit \$? ) && : codex exec $SOLP"
expect 0 "artifacts:" "start from a subshell under a caller that mentions a review"
ID9=$(field id)
run "$MAIN" bash -c "( $W release $ID9; exit \$? ) && : codex exec $SOLP"
expect 0 "outcome:     empty" "release from the same wrapper"

# ---- (13e) an unwritable artifacts dir keeps the assignment active ----------------------------
start TT-909 chore/TT-909-k $DEV --thread t9
expect 0 "artifacts:" "start J"
ID10=$(field id)
chmod 555 "$WORKER_ARTIFACTS/$ID10"
release "$ID10"
expect 1 "release not recorded" "release into an unwritable artifacts dir"
[ -f "$WD/active/assignment.json" ] && [ ! -e "$WD/history/$ID10" ] \
  || fail "a failed artifacts copy recorded the release"
chmod 755 "$WORKER_ARTIFACTS/$ID10"
release "$ID10"
expect 0 "outcome:     empty" "rerun after the artifacts dir is fixed"
[ -f "$WORKER_ARTIFACTS/$ID10/release.json" ] && [ -f "$WD/history/$ID10/release.json" ] \
  || fail "the rerun did not record and copy release.json"

# ---- (14) static: no destructive git ----------------------------------------------------------
! grep -nE 'reset --hard|git clean|branch -[dD]|rm -r' "$SRC/.claude/lib/worker-next.sh" \
  "$SRC/.claude/lib/worker-lib.sh" || fail "worker-next.sh or worker-lib.sh: destructive command"

# ---- (15) supervisor-only commands ------------------------------------------------------------
run "$SOL" $W start TT-906 chore/TT-906-h $DEV --thread t6
expect 1 "is a supervisor command" "start from inside the clone"
run "$SOL" $W status
expect 0 "state: idle" "status from inside the clone"

[ -d "$WD/staging-TT-999-x" ] || fail "the staging leftover was deleted"
echo "worker-smoke: OK"
