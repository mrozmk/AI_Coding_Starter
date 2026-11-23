#!/usr/bin/env bash
# Offline test of .claude/lib/team-starter-land.sh against fixture repositories: a bare starter
# origin, the starter's main checkout with a team worktree beside it, and a minimal main checkout of
# the developing project with its team clone and an accepted run. One fresh tree per case.
set -u
SRC="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$SRC/.claude/lib/team-starter-land.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/starter-land.XXXXXX") || { echo "team-starter-land-test: FAIL — mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
# The live-session check must never see the developer's own sessions or main checkout.
unset HARNESS_MAIN HARNESS_REGISTRY TEAM_PROFILE_LOADED SH_LIB
die() { echo "team-starter-land-test: FAIL — fixture setup: $1"; exit 1; }
fail=0
bad() { echo "FAIL [$1]: $2"; fail=1; }

RUN=alfa-20261123-000001
# fx <name> → a fresh tree under $T/<name>; sets D ST W O CL TIPX.
fx() {
  D="$T/$1"; O="$D/origin.git"; ST="$D/AI_Coding_Starter"; W="$D/AI_Coding_Starter-alfa-254"
  CL="$D/main-alfa"
  mkdir -p "$D/seed/.claude/lib" "$D/main/.claude" "$CL/.agents/team/runs/$RUN" || die "mkdir $1"
  # With global/system config off an unborn HEAD would point at master: name main explicitly.
  git init -q --bare -b main "$O" || die "origin $1"
  cp "$SRC/.claude/lib/branch-model.sh" "$D/seed/.claude/lib/" || die "branch-model $1"
  printf '.agents/jira/\n' > "$D/seed/.gitignore"
  printf 'base\n' > "$D/seed/f.txt"
  git -C "$D/seed" init -q -b main . && git -C "$D/seed" add -A && git -C "$D/seed" commit -qm base \
    && git -C "$D/seed" push -q "$O" main || die "seed $1"
  git clone -q "$O" "$ST" || die "starter clone $1"
  [ "$(git -C "$ST" branch --show-current)" = main ] \
    && [ "$(git -C "$ST" rev-parse HEAD)" = "$(git -C "$D/seed" rev-parse HEAD)" ] \
    || die "starter checkout $1 is not on main at the seeded commit"
  git -C "$ST" worktree add --quiet "$W" -b feat/x --no-track main || die "worktree $1"
  printf 's\n' > "$W/s.txt"
  git -C "$W" add s.txt && git -C "$W" commit -qm s || die "worktree commit $1"
  TIPX="$(git -C "$W" rev-parse HEAD)"
  # The developing project: a profile opted in by starter_root, the starter_repo it names.
  jq -n '{teams: {tracker: "none", pr_provider: "none", gates: "auto", trunk: "main",
      build_check: "true", test_gate: "none", env_file_required: false, branch_types: ["feat"],
      required_tools: ["git"], starter_root: "../AI_Coding_Starter"}}' \
    > "$D/main/.claude/project-profile.json"
  jq -n --arg r "$O" '{starter_repo: $r}' > "$D/main/.claude/.starter-sync.json"
  git -C "$D/main" init -q -b main . && git -C "$D/main" add -A && git -C "$D/main" commit -qm main \
    || die "main $1"
  # The team clone (default name <main>-<team> beside main): an accepted, finished run.
  jq -n '{team: "alfa", ticket: "254", branch: "feat/254-x", line: "main", mode: "brainstorm"}' \
    > "$CL/.agents/team/team.json"
  echo "$RUN" > "$CL/.agents/team/run"
  for r in qa wrapup; do
    jq -n --arg r "$r" '{role: $r, verdict: "done"}' > "$CL/.agents/team/runs/$RUN/$r-1-1.json"
    touch "$CL/.agents/team/runs/$RUN/$r-1-1.json.accepted"
  done
}
land() {  # land [args…] → RC, OUT (stdout + stderr) of the helper run from the fixture main
  OUT="$(cd "$D/main" && bash "$SCRIPT" alfa "$@" 2>&1)"; RC=$?
}
ok() {  # ok <label> <expected rc> [fragment…] → rc 0 when the run matched
  local l="$1" want="$2" f; shift 2
  [ "$RC" = "$want" ] || { bad "$l" "rc=$RC, expected $want; out: $OUT"; return 1; }
  for f in "$@"; do
    printf '%s\n' "$OUT" | grep -qF -- "$f" || { bad "$l" "output lacks '$f'; out: $OUT"; return 1; }
  done
  return 0
}
omain() { git --git-dir="$O" rev-parse refs/heads/main; }
has_branch() { git -C "$ST" rev-parse -q --verify "refs/heads/$1" >/dev/null; }

# ---- clean land ---------------------------------------------------------------------------------
L="clean land: merged, pushed, worktree and branch removed"
fx clean; land
if ok "$L" 0 "removed: worktree" "deleted: branch feat/x"; then
  M="$(omain)"
  [ "$(git --git-dir="$O" rev-parse "$M^2")" = "$TIPX" ] || bad "$L" "origin main's second parent is not the tip"
  printf '%s\n' "$OUT" | grep -qF "landed: feat/x into main M=$M" || bad "$L" "no landed line naming M=$M"
  [ ! -d "$W" ] || bad "$L" "the worktree is still there"
  ! has_branch feat/x || bad "$L" "the branch is still there"
fi

# ---- dirty worktree -----------------------------------------------------------------------------
L="dirty worktree: merged, worktree kept and named"
fx dirty; printf 'junk\n' > "$W/junk.txt"; land
if ok "$L" 0 "kept: worktree"; then
  printf '%s\n' "$OUT" | grep -qF "AI_Coding_Starter-alfa-254" || bad "$L" "the kept worktree is not named"
  [ "$(git --git-dir="$O" rev-parse "$(omain)^2")" = "$TIPX" ] || bad "$L" "not merged on origin"
  [ -d "$W" ] && has_branch feat/x || bad "$L" "worktree or branch removed"
fi

# ---- ignored local work -------------------------------------------------------------------------
L="ignored local work: worktree kept"
fx ignored; mkdir -p "$W/.agents/jira"; printf 'keep me\n' > "$W/.agents/jira/draft.md"; land
if ok "$L" 0 "kept: worktree" "— ignored files"; then
  [ "$(git --git-dir="$O" rev-parse "$(omain)^2")" = "$TIPX" ] || bad "$L" "not merged on origin"
  [ "$(cat "$W/.agents/jira/draft.md" 2>/dev/null)" = "keep me" ] || bad "$L" "the ignored file is gone"
  has_branch feat/x || bad "$L" "the branch was deleted"
fi

# ---- conflict, then the documented recovery -----------------------------------------------------
L="conflict: stops, nothing pushed"
fx conflict
printf 'worktree\n' > "$W/f.txt"; git -C "$W" commit -qam wt || die "conflict wt"
TIPX="$(git -C "$W" rev-parse HEAD)"
printf 'main\n' > "$ST/f.txt"; git -C "$ST" commit -qam main && git -C "$ST" push -q origin main \
  || die "conflict main"
OM0="$(omain)"; land
if ok "$L" 5 "f.txt"; then
  [ "$(omain)" = "$OM0" ] || bad "$L" "origin main moved"
  git -C "$ST" rev-parse -q --verify MERGE_HEAD >/dev/null || bad "$L" "the merge is not left in progress"
  [ -d "$W" ] && has_branch feat/x || bad "$L" "worktree or branch removed"
fi
L="conflict recovery: resolve, push, rerun cleans up"
printf 'resolved\n' > "$ST/f.txt"
git -C "$ST" add f.txt && git -C "$ST" commit -q --no-edit && git -C "$ST" push -q origin main \
  || die "conflict resolution"
land
if ok "$L" 0 "already merged" "removed: worktree" "deleted: branch feat/x"; then
  [ ! -d "$W" ] && ! has_branch feat/x || bad "$L" "worktree or branch still there"
fi

# ---- local main ahead of origin -----------------------------------------------------------------
L="local main ahead of origin: refused"
fx ahead
printf 'x\n' > "$ST/extra.txt"; git -C "$ST" add extra.txt && git -C "$ST" commit -qm extra || die "ahead"
OM0="$(omain)"; land
if ok "$L" 3 "ahead of origin/main"; then
  [ "$(omain)" = "$OM0" ] || bad "$L" "origin main moved"
  [ -d "$W" ] || bad "$L" "the worktree was removed"
fi

# ---- run not accepted ---------------------------------------------------------------------------
L="run not accepted: refused"
fx notacc; rm -f "$CL/.agents/team/runs/$RUN/wrapup-1-1.json.accepted"
OM0="$(omain)"; land
if ok "$L" 3 "wrapup not done"; then
  [ "$(omain)" = "$OM0" ] && [ "$(git -C "$ST" rev-parse main)" = "$OM0" ] || bad "$L" "main moved"
  [ -d "$W" ] && has_branch feat/x || bad "$L" "worktree or branch removed"
fi

# ---- foreign starter origin ---------------------------------------------------------------------
L="foreign starter origin: refused"
fx forigin; git init -q --bare -b main "$D/other.git" || die "other"
git -C "$ST" remote set-url origin "$D/other.git"
land; ok "$L" 2 "not the starter_repo" || true

# ---- foreign push destination -------------------------------------------------------------------
L="foreign push destination: refused"
fx fpush; git init -q --bare -b main "$D/other.git" || die "other"
git -C "$ST" config remote.origin.pushurl "$D/other.git"
OM0="$(omain)"; land
if ok "$L" 2 "not the starter_repo"; then
  [ "$(omain)" = "$OM0" ] || bad "$L" "origin main moved"
  ! git --git-dir="$D/other.git" rev-parse -q --verify refs/heads/main >/dev/null \
    || bad "$L" "the foreign repository received a push"
fi

# ---- not configured -----------------------------------------------------------------------------
L="not configured: refused"
fx nocfg
jq 'del(.teams.starter_root)' "$D/main/.claude/project-profile.json" > "$D/p.json" \
  && mv "$D/p.json" "$D/main/.claude/project-profile.json" || die "nocfg"
land; ok "$L" 2 "teams.starter_root" || true

# ---- release worktree ---------------------------------------------------------------------------
L="release worktree: refused"
fx release; git -C "$ST" worktree add --quiet "$D/rel" -b release --no-track main || die "release"
OM0="$(omain)"; land --worktree "$D/rel"
if ok "$L" 3 "long-lived branch"; then
  [ "$(omain)" = "$OM0" ] || bad "$L" "origin main moved"
  has_branch release || bad "$L" "release was deleted"
fi

# ---- no matching worktree -----------------------------------------------------------------------
L="no matching worktree: refused"
fx nomatch; git -C "$ST" worktree move "$W" "$D/AI_Coding_Starter-other" || die "move"
land; ok "$L" 3 "AI_Coding_Starter-alfa-254" "--worktree" || true

# ---- already merged: the merge with the tip as second parent is M -------------------------------
L="already merged: cleanup only"
fx merged
git -C "$ST" merge -q --no-ff --no-edit feat/x || die "merged: merge"
MM="$(git -C "$ST" rev-parse HEAD)"
git -C "$ST" switch -q -c other && printf 'o\n' > "$ST/o.txt" && git -C "$ST" add o.txt \
  && git -C "$ST" commit -qm other && git -C "$ST" switch -q main \
  && git -C "$ST" merge -q --no-ff --no-edit other && git -C "$ST" push -q origin main || die "merged: other"
land
if ok "$L" 0 "already merged" "M=$MM" "removed: worktree" "deleted: branch feat/x"; then
  [ "$(omain)" != "$MM" ] || bad "$L" "fixture: the later merge is missing"
fi

# ---- static -------------------------------------------------------------------------------------
! grep -nE '^[^#]*(--force|branch -D)' "$SCRIPT" || bad "no force, no -D" "an executable line forces"

[ "$fail" = 0 ] || exit 1
echo "team-starter-land-test: OK"
