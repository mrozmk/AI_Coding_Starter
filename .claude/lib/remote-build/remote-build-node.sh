#!/usr/bin/env bash
# Node half of the remote build check: arrives on ssh stdin (`bash -s -- …`), never stored on the
# node. Fetches the bundle into <repo>, runs the command in a throwaway detached worktree of <sha>
# under <runs>, removes the worktree and the bundle on every exit.
# Args: <repo> <runs> <tag> <sha> <cwd> <nice 0|1> <timeout s> <n env> [NAME=VALUE…] -- <command…>
# Exit: the command's code · 124 timed out · 75 node-side setup failed (no command ran)
set -uo pipefail
repo=$1 runs=$2 tag=$3 sha=$4 cwd=$5 nice=$6 tmo=$7 nenv=$8
shift 8
envs=()
for ((i = 0; i < nenv; i++)); do envs+=("$1"); shift; done
[ "${1:-}" = -- ] && shift
# ssh starts in the node account's home; absolute paths keep cleanup right after the cd below.
repo="$PWD/$repo" runs="$PWD/$runs"
bundle="$runs/$tag.bundle"
wt="$runs/$tag"
pid=""
cleanup() {
  # Whatever the command started is stopped before its worktree goes (an early exit included).
  [ -n "$pid" ] && kill -KILL -- "-$pid" 2>/dev/null
  rm -rf "$wt" "$wt.timeout"
  g worktree prune >/dev/null 2>&1
  rm -f "$bundle"
}
trap cleanup EXIT
# The node repo is shared across runs and a build can write to it: no hooks, no fsmonitor, no
# replace refs from it ever take part in setting up the next run.
g() { GIT_NO_REPLACE_OBJECTS=1 git -c core.hooksPath=/dev/null -c core.fsmonitor=false -C "$repo" "$@"; }
infra() { echo "remote-build node: $*" >&2; exit 75; }

g rev-parse --git-dir >/dev/null 2>&1 || infra "no git repository at $repo — run once on the node: git init <repo>"
if [ -s "$bundle" ]; then
  g fetch -q "$bundle" "refs/mc/$tag" || infra "bundle fetch failed"
fi
g cat-file -e "$sha^{commit}" 2>/dev/null || infra "commit $sha is missing"
# A ref keeps the commit reachable after the worktree goes, so the next bundle can exclude it.
g update-ref refs/remote-build/last "$sha" 2>/dev/null
g worktree add -q --detach "$wt" "$sha" || infra "worktree add failed"
cd "$wt/$cwd" 2>/dev/null || infra "no directory $cwd at $sha"
echo "remote-build node: $(hostname) $wt at $(git rev-parse HEAD)"

run=(env "${envs[@]+"${envs[@]}"}")
[ "$nice" = 1 ] && run=(nice -n 19 "${run[@]}")
# Own process group (job control), so the watchdog stops the command and everything it started.
set -m
"${run[@]}" "$@" < /dev/null &
pid=$!
( sleep "$tmo"; kill -TERM -- "-$pid" 2>/dev/null && : > "$wt.timeout"; sleep 5; kill -KILL -- "-$pid" 2>/dev/null ) &
dog=$!
wait "$pid"
rc=$?
kill -- "-$dog" 2>/dev/null  # the watchdog's whole group: its sleep would hold the output pipe
# The command's group too: a child it left behind (or one that outlived TERM, now that the watchdog
# no longer sends KILL) would keep running and hold ssh's output pipe open.
kill -KILL -- "-$pid" 2>/dev/null
wait "$dog" 2>/dev/null
if [ -e "$wt.timeout" ]; then
  rm -f "$wt.timeout"
  echo "remote-build node: timed out after ${tmo}s" >&2
  exit 124
fi
exit "$rc"
