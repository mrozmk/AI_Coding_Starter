#!/usr/bin/env bash
# Lands a team's starter half: merges the run's starter worktree branch into the starter's `main`
# (--no-ff), pushes exactly that merge commit, then removes the worktree and the local branch.
#
# Usage: bash .claude/lib/team-starter-land.sh <team> [--starter <path>] [--worktree <path>]
#   e.g. bash .claude/lib/team-starter-land.sh alfa
#   --starter <path>:  the starter checkout (default: teams.starter_root, relative to the repo root)
#   --worktree <path>: the registered starter worktree to land (default: <starter>-<team>-<ticket>)
#
# Run from the main checkout of the project that develops the starter (opt-in:
# `teams.starter_root`), after the run's `accepted` event and before team-merge-check.sh.
#
# Order: opt-in · the run is accepted and idle · the starter checkout is the starter_repo (fetch and
# push URL) · the worktree and its branch from git's worktree registry · the starter is clean, on
# main, not mid-merge · fetch, fast-forward, main = origin/main · merge --no-ff of the worktree tip
# · push that merge commit · verify origin main · remove the worktree, delete the branch.
#
# Exit: 0 landed (the cleanup lines tell the rest)
#   2 usage / not configured / starter checkout missing or not the starter_repo (fetch or push URL)
#   3 refused, nothing merged or pushed (main may be fast-forwarded to origin/main) · 4 merged
#   locally, push refused · 5 merge conflict left for the Supervisor
# Never --force, never branch -D, never merge --abort. Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "error: $2" >&2; exit "$1"; }

TEAM=""; ST_OPT=""; WT_OPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --starter)  ST_OPT="${2:-}"; shift 2 || usage; [ -n "$ST_OPT" ] || usage ;;
    --worktree) WT_OPT="${2:-}"; shift 2 || usage; [ -n "$WT_OPT" ] || usage ;;
    -*)         usage ;;
    *)          [ -z "$TEAM" ] || usage; TEAM="$1"; shift ;;
  esac
done
[ -n "$TEAM" ] || usage

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(git rev-parse --show-toplevel 2>/dev/null)" || die 2 "not inside a git checkout"

# ---- 1. opt-in: only the project that develops the starter has a starter half -------------------

SR="$(jq -r '.teams.starter_root // empty' "$root/.claude/project-profile.json" 2>/dev/null)" || SR=""
[ -n "$SR" ] || die 2 "not configured — teams.starter_root names no starter checkout (only the\
 project that develops the starter has a starter half)"
case "$SR" in /*) ;; *) SR="$root/$SR" ;; esac

# ---- 2. the run is accepted and idle (the same rule integrate applies next) ---------------------

. "$HERE/team-profile.sh"
. "$HERE/team-integrate-lib.sh"
CLONE="$(team_clone_dir "$TEAM" "$root")" || die 2 "cannot resolve the clone of team $TEAM"
TD="$CLONE/.agents/team"
[ -f "$TD/team.json" ] || die 3 "no team clone at $CLONE"
TICKET="$(jq -r '.ticket // ""' "$TD/team.json")" || die 3 "cannot read $TD/team.json"
MODE="$(jq -r '.mode // "brainstorm"' "$TD/team.json")" || die 3 "cannot read $TD/team.json"
RUN="$(cat "$TD/run" 2>/dev/null || true)"
team_run_ready "$TEAM" "$CLONE" "$RUN" "$MODE" || exit 3

# ---- 3. the starter checkout is the starter_repo ------------------------------------------------

ST="${ST_OPT:-$SR}"
[ -d "$ST" ] || die 2 "no starter checkout at $ST"
ST="$(cd "$ST" && pwd -P)"
top="$(git -C "$ST" rev-parse --show-toplevel 2>/dev/null)" || die 2 "$ST is not a git checkout"
[ "$(cd "$top" && pwd -P)" = "$ST" ] || die 2 "$ST is not the top of its checkout ($top)"
gd="$(cd "$ST" && cd "$(git rev-parse --git-dir)" && pwd -P)" || die 2 "cannot read the git dir of $ST"
gcd="$(cd "$ST" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" \
  || die 2 "cannot read the common git dir of $ST"
[ "$gd" = "$gcd" ] || die 2 "$ST is a linked worktree, not the starter's main checkout"

# norm_repo <url> → `gh:<owner>/<repo>` for a GitHub URL, `path:<canonical dir>` for a local
# origin, empty otherwise. Two namespaces that never collide.
norm_repo() {
  local u="$1" p
  case "$u" in
    https://github.com/*|git@github.com:*|ssh://git@github.com/*)
      p="${u#https://github.com/}"; p="${p#git@github.com:}"; p="${p#ssh://git@github.com/}"
      p="${p%/}"; p="${p%.git}"
      case "$p" in
        */*/*|/*|*/|'') ;;
        */*) printf 'gh:%s\n' "$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')" ;;
      esac ;;
    file://*)
      p="${u#file://}"
      if [ -d "$p" ]; then printf 'path:%s\n' "$(cd "$p" && pwd -P)"; fi ;;
    /*)
      if [ -d "$u" ]; then printf 'path:%s\n' "$(cd "$u" && pwd -P)"; fi ;;
  esac
  return 0
}
SREPO="$(jq -r '.starter_repo // ""' "$root/.claude/.starter-sync.json" 2>/dev/null)" || SREPO=""
want="$(norm_repo "$SREPO")"
[ -n "$want" ] || die 2 "no usable starter_repo in .claude/.starter-sync.json ('$SREPO')"
fetch_url="$(git -C "$ST" remote get-url origin 2>/dev/null)" || die 2 "$ST has no origin remote"
push_urls="$(git -C "$ST" remote get-url --push --all origin 2>/dev/null)" \
  || die 2 "cannot read the push URL of origin in $ST"
while IFS= read -r u; do
  [ -n "$u" ] || continue
  [ "$(norm_repo "$u")" = "$want" ] \
    || die 2 "origin of $ST points at $u, not the starter_repo $SREPO"
done <<EOF
$fetch_url
$push_urls
EOF

# ---- 4. the worktree from git's registry --------------------------------------------------------

# reg_records → one line per registered worktree: <canonical path> TAB <path> TAB <head> TAB <branch
# ref or `detached`>. Parsed from `-z` records (an empty field ends a record).
reg_records() {
  local raw l p="" h="" b="" c
  raw="$(git -C "$ST" worktree list --porcelain -z | tr '\0' '\n')" || return 1
  emit() {
    [ -n "$p" ] || return 0
    c="$p"; [ ! -d "$p" ] || c="$(cd "$p" && pwd -P)"
    printf '%s\t%s\t%s\t%s\n' "$c" "$p" "$h" "${b:-detached}"
  }
  while IFS= read -r l; do
    case "$l" in
      "worktree "*) p="${l#worktree }" ;;
      "HEAD "*)     h="${l#HEAD }" ;;
      "branch "*)   b="${l#branch }" ;;
      "")           emit; p=""; h=""; b="" ;;
    esac
  done <<<"$raw"
  emit
}
REG="$(reg_records)" || die 3 "cannot read the worktree registry of $ST"
TAB="$(printf '\t')"
if [ -n "$WT_OPT" ]; then
  [ -d "$WT_OPT" ] || die 3 "--worktree $WT_OPT is not a directory"
  want_wt="$(cd "$WT_OPT" && pwd -P)"
  hits="$(printf '%s\n' "$REG" | awk -F'\t' -v w="$want_wt" '$1 == w')"
  what="the registered worktree $want_wt"
else
  target="$(basename "$ST")-$TEAM-$TICKET"
  hits="$(printf '%s\n' "$REG" | awk -F'\t' -v t="$target" '{ n = split($1, a, "/") } a[n] == t')"
  what="a registered worktree named $target (pass --worktree <path> for another name)"
fi
case "$(printf '%s' "$hits" | grep -c . || true)" in
  0) die 3 "no starter worktree found: expected $what in $ST" ;;
  1) ;;
  *) die 3 "more than one starter worktree matches: $(printf '%s' "$hits" | cut -f2 | tr '\n' ' ')" ;;
esac
WC="$(printf '%s' "$hits" | cut -f1)"; W="$(printf '%s' "$hits" | cut -f2)"
TIP="$(printf '%s' "$hits" | cut -f3)"; wref="$(printf '%s' "$hits" | cut -f4)"
[ "$WC" != "$ST" ] || die 3 "$W is the starter's main checkout, not a team worktree"
case "$wref" in
  refs/heads/*) WB="${wref#refs/heads/}" ;;
  *) die 3 "worktree $W has a detached HEAD at $TIP — no branch to land" ;;
esac
[ -n "$TIP" ] || die 3 "worktree $W names no HEAD"
# The rerun the recovery messages print: the same starter and worktree selection as this run.
RERUN="bash .claude/lib/team-starter-land.sh $(printf '%q' "$TEAM")"
[ -z "$ST_OPT" ] || RERUN="$RERUN --starter $(printf '%q' "$ST")"
[ -z "$WT_OPT" ] || RERUN="$RERUN --worktree $(printf '%q' "$W")"

# KEEP: the starter's long-lived branches are never landed from (nor deleted).
keep="main release master trunk develop"
krc=0; kf="$(cd "$ST" && bash .claude/lib/branch-model.sh fields 2>&1)" || krc=$?
case "$krc" in
  0) keep="$keep $(printf '%s\n' "$kf" | sed -nE 's/^(trunk|integration|maintenance|protected)=//p' \
       | tr '\n' ' ')" ;;
  3) ;;
  *) die 3 "branch model of the starter unreadable: $(printf '%s' "$kf" | head -n 1)" ;;
esac
case " $keep " in *" $WB "*) die 3 "worktree $W is on $WB, a long-lived branch — nothing to land" ;; esac

# ---- 5. the starter checkout is clean, on main, not mid-merge -----------------------------------

st_rc=0; st_out="$(git -C "$ST" status --porcelain 2>&1)" || st_rc=$?
[ "$st_rc" = 0 ] || die 3 "cannot read the status of $ST (git exit $st_rc): $st_out"
[ -z "$st_out" ] || die 3 "starter checkout $ST is dirty — commit or clean it first"
cur="$(git -C "$ST" symbolic-ref --short -q HEAD 2>/dev/null || true)"
[ "$cur" = main ] || die 3 "starter checkout $ST is on ${cur:-a detached HEAD}, not main"
if git -C "$ST" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  die 3 "starter checkout $ST is in the middle of a merge"
fi

# ---- 6. fetch, fast-forward, main = origin/main -------------------------------------------------

tip0="$(git -C "$ST" rev-parse main)"
fo="$(git -C "$ST" fetch --quiet origin main 2>&1)" || die 3 "fetch of origin main failed: $fo"
# Another session may switch the shared checkout while we fetched: nothing has moved yet.
[ "$(git -C "$ST" branch --show-current)" = main ] && [ "$(git -C "$ST" rev-parse main)" = "$tip0" ] \
  || die 3 "starter checkout $ST changed during the fetch — nothing moved, rerun"
mo="$(git -C "$ST" merge --ff-only --no-overwrite-ignore --quiet origin/main 2>&1)" \
  || die 3 "cannot fast-forward main to origin/main: $mo"
if [ "$(git -C "$ST" rev-parse main)" != "$(git -C "$ST" rev-parse origin/main)" ]; then
  echo "local main is ahead of origin/main (unpushed):" >&2
  git -C "$ST" log --oneline origin/main..main | sed 's/^/  /' >&2
  die 3 "push or reconcile the starter's main first — another landing is never published from here"
fi

# ---- 7. the merge (or the one already there) ----------------------------------------------------

FRESH=0
if git -C "$ST" merge-base --is-ancestor "$TIP" main; then
  M="$(git -C "$ST" rev-list --merges --parents --reverse --ancestry-path "$TIP..main" \
    | awk -v t="$TIP" '$3 == t && m == "" { m = $1 } END { if (m != "") print m }')"
  if [ -n "$M" ]; then
    echo "already merged: $WB in main, M=$M"
  else
    echo "already in main: $WB @ $TIP (no merge commit names it as second parent), main at\
 $(git -C "$ST" rev-parse main)"
  fi
else
  echo "$WB @ $TIP"
  git -C "$ST" log --oneline "main..$TIP" | sed 's/^/  /'
  OM="$(git -C "$ST" rev-parse origin/main)"
  [ "$(git -C "$ST" branch --show-current)" = main ] && [ "$(git -C "$ST" rev-parse main)" = "$OM" ] \
    || die 3 "starter checkout $ST changed before the merge — nothing merged, rerun"
  mrc=0
  mout="$(git -C "$ST" merge --no-ff --no-overwrite-ignore --no-edit \
    -m "Merge branch '$WB' (team $TEAM, #$TICKET)" "$TIP" 2>&1)" || mrc=$?
  if [ "$mrc" != 0 ]; then
    if git -C "$ST" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
      echo "CONFLICT: merging $WB into the starter's main stopped — nothing was pushed. Conflicted paths:"
      git -C "$ST" diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/  /' || true
      cat <<EOF
Two ways on:
  (a) resolve the paths, then: git -C $ST commit --no-edit && git -C $ST push origin main
      then rerun: $RERUN   (it finds the merge and cleans up)
  (b) git -C $ST merge --abort, and land the branch by hand
The resolution may change what the port must ship: before the merge-check, compare each resolved
path that the team PR also carries (git -C $CLONE show <PR head>:<path> vs the starter's resolved
file); a difference means the PR needs the same resolution first — stop and bring it to the Operator.
EOF
      exit 5
    fi
    printf '%s\n' "$mout" | sed 's/^/  | /' >&2
    die 3 "git refused to start the merge of $WB — nothing merged"
  fi
  M="$(git -C "$ST" rev-parse HEAD)"
  FRESH=1
fi

# ---- 8. push exactly M, verify origin -----------------------------------------------------------

if [ "$FRESH" = 1 ]; then
  [ "$(git -C "$ST" rev-list --parents -n 1 "$M")" = "$M $OM $TIP" ] \
    || die 4 "merge commit $M does not have the parents $OM $TIP — not pushed, check by hand"
  [ "$(git -C "$ST" branch --show-current)" = main ] \
    || die 4 "starter checkout $ST left main after the merge — M=$M not pushed, check by hand"
  prc=0
  pout="$(git -C "$ST" push --porcelain origin "$M:refs/heads/main" 2>&1)" || prc=$?
  printf '%s\n' "$pout" | sed 's/^/  | /'
  if [ "$prc" != 0 ]; then
    echo "merged locally, not pushed: M=$M. Recovery: git -C $ST pull --no-rebase origin main &&" \
      "git -C $ST push origin main, then rerun: $RERUN (it finds M and cleans up)." >&2
    exit 4
  fi
  ro="$(git -C "$ST" ls-remote origin refs/heads/main 2>&1)" \
    || die 4 "pushed, but origin main is unreadable — check by hand (M=$M)"
  ro="$(printf '%s\n' "$ro" | awk 'NR == 1 { print $1 }')"
  [ "$ro" = "$M" ] || die 4 "pushed, but origin main is $ro, not M=$M — check by hand"
  echo "landed: $WB into main M=$M"
fi

# ---- 8b. the batch gate's due line for the starter gate (never changes the exit) -----------------
report_batch() {
  [ -n "${M:-}" ] || return 0
  [ -f "$HERE/batch-gate.sh" ] || return 0
  bash "$HERE/batch-gate.sh" -C "$root" due --merged "starter=$M@main" || true
}
report_batch

# ---- 9. cleanup: each step its own line, never a failure of the landing --------------------------

now="$(reg_records 2>/dev/null | awk -F'\t' -v w="$WC" '$1 == w')" || now=""
if [ -z "$now" ] || [ "$(printf '%s' "$now" | cut -f4)" != "refs/heads/$WB" ] \
  || [ "$(printf '%s' "$now" | cut -f3)" != "$TIP" ]; then
  echo "kept: worktree $W — changed since the landing (branch $WB kept too)"
  exit 0
fi
ig_rc=0; ig="$(git -C "$W" status --porcelain --ignored 2>&1)" || ig_rc=$?
if [ "$ig_rc" != 0 ]; then
  echo "kept: worktree $W — status unreadable (branch $WB kept too)"; exit 0
fi
# `worktree remove` deletes ignored files silently (local drafts, a developer profile).
# A here-string, not a pipe: under pipefail an early `grep -q` exit can SIGPIPE the writer and read
# as "no ignored files".
if grep -q '^!! ' <<<"$ig"; then
  echo "kept: worktree $W — ignored files (branch $WB kept too)"; exit 0
fi
rrc=0; rout="$(git -C "$ST" worktree remove "$W" 2>&1)" || rrc=$?
if [ "$rrc" != 0 ]; then
  echo "kept: worktree $W — $(printf '%s' "$rout" | head -n 1) (branch $WB kept too)"; exit 0
fi
echo "removed: worktree $W"
btip="$(git -C "$ST" rev-parse -q --verify "refs/heads/$WB" 2>/dev/null || true)"
if [ "$btip" != "$TIP" ]; then
  echo "kept: branch $WB — its tip is ${btip:-gone}, not the landed $TIP"; exit 0
fi
if ! git -C "$ST" merge-base --is-ancestor "$TIP" "$(git -C "$ST" rev-parse origin/main)"; then
  echo "kept: branch $WB — not in origin/main"; exit 0
fi
dout="$(git -C "$ST" branch -d "$WB" 2>&1)" \
  && echo "deleted: branch $WB" \
  || echo "kept: branch $WB — $(printf '%s' "$dout" | head -n 1)"
exit 0
