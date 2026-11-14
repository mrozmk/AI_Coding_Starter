#!/usr/bin/env bash
# Offline smoke test for rm-in-project.sh. The wrapper finds its roots from its own location, so
# each fixture repo gets a copy of it; sentinels outside every target must survive each case.
# Run: bash .claude/lib/tests/rm-in-project-smoke.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
SRC="$HERE/../rm-in-project.sh"
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
CHECKS=0

fail() { echo "rm-in-project-smoke: FAIL — $*"; [ ! -f "$WORK/out" ] || cat "$WORK/out"; exit 1; }
ok() { CHECKS=$((CHECKS + 1)); echo "OK $*"; }

new_repo() {  # new_repo <dir> [git init args…] — a committed repo carrying the wrapper
  local d="$1"; shift
  mkdir -p "$d"; git init -q "$@" "$d"
  mkdir -p "$d/.claude/lib"; cp "$SRC" "$d/.claude/lib/"
  git -C "$d" add .claude; git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
}

R="$WORK/repo"; new_repo "$R"
WRAP="$R/.claude/lib/rm-in-project.sh"
git -C "$R" worktree add -q "$R/nested/wt" -b wt
mkdir -p "$WORK/outside" "$R/.claude/hooks" "$R/nested/wt/.claude"
touch "$WORK/outside/keep" "$R/keep" "$R/nested/wt/keep" "$R/.env" "$R/.claude/settings.json" \
  "$R/.claude/settings.local.json" "$R/.claude/hooks/guard.sh" "$R/nested/wt/.claude/settings.json"

sentinels() {
  [ -f "$WORK/outside/keep" ] && [ -f "$R/keep" ] && [ -f "$R/nested/wt/keep" ] && [ -f "$R/.env" ] \
    && [ -f "$R/.git/HEAD" ] && [ -f "$R/.claude/settings.json" ] && [ -f "$R/.claude/settings.local.json" ] \
    && [ -f "$R/.claude/hooks/guard.sh" ] && [ -f "$R/nested/wt/.claude/settings.json" ]
}

refused() {  # refused <label> <reason> <path>…
  local label="$1" reason="$2" rc=0; shift 2
  (cd "$R" && bash "$WRAP" "$@") > "$WORK/out" 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "$label accepted"
  grep -qF "refused ($reason" "$WORK/out" || fail "$label: wrong refusal reason"
  sentinels || fail "$label deleted a sentinel"
  ok "refused $label"
}

removed() {  # removed <label> <path>… — every path must be gone afterwards
  local label="$1" p; shift
  (cd "$R" && bash "$WRAP" "$@") > "$WORK/out" 2>&1 || fail "$label refused"
  for p in "$@"; do [ ! -e "$p" ] && [ ! -L "$p" ] || fail "$label: $p survived"; done
  sentinels || fail "$label deleted a sentinel"
  ok "removed $label"
}

# --- refusals ---------------------------------------------------------------------
refused "outside the project" "outside the project" "$WORK/outside/keep"
refused "repo root" "worktree root" "$R"
refused "linked worktree root" "worktree root" "$R/nested/wt"
refused "dir containing a worktree" "contains worktree" "$R/nested"
refused "git dir" "git metadata" "$R/.git"
refused "inside git dir" "git metadata" "$R/.git/config"
touch "$R/.env.local"
refused "env file" ".env file" "$R/.env.local"
mkdir -p "$R/cfg"; touch "$R/cfg/.env"
refused "dir containing an env file" "contains" "$R/cfg"
mkdir -p "$R/vendored/lib/.git"
refused "dir containing a .git" "contains" "$R/vendored"
mkdir -p "$R/ok"; touch "$R/ok/file"
refused "all-or-nothing" "outside the project" "$R/ok/file" "$WORK/outside/keep"
[ -f "$R/ok/file" ] || fail "all-or-nothing deleted the valid target"

# the guard layer: permission profile and hooks, in every worktree
refused "settings.json" "guard layer" "$R/.claude/settings.json"
refused "settings.local.json" "guard layer" "$R/.claude/settings.local.json"
refused "hooks dir" "guard layer" "$R/.claude/hooks"
refused "a hook" "guard layer" "$R/.claude/hooks/guard.sh"
refused ".claude dir" "contains the guard layer" "$R/.claude"
refused "linked worktree settings.json" "guard layer" "$R/nested/wt/.claude/settings.json"
mkdir -p "$R/vendored2/lib/.GIT"
refused "dir containing an upper-case .GIT" "contains" "$R/vendored2"

# case-insensitive file system (macOS default): another spelling reaches the same file
touch "$WORK/ci-probe"
if [ -e "$WORK/CI-PROBE" ]; then
  refused "upper-case git dir" "git metadata" "$R/.GIT"
  refused "file in upper-case git dir" "git metadata" "$R/.GIT/HEAD"
  refused "upper-case env file" ".env file" "$R/.ENV"
  touch "$R/.env.local"
  refused "mixed-case env file" ".env file" "$R/.Env.local"
  refused "upper-case settings.json" "guard layer" "$R/.CLAUDE/SETTINGS.JSON"
  refused "upper-case hooks dir" "guard layer" "$R/.claude/HOOKS"
  refused "upper-case linked worktree root" "worktree root" "$R/nested/WT"
  refused "upper-case dir containing a worktree" "contains worktree" "$R/NESTED"
else
  echo "note: case-sensitive file system — upper-case alias cases skipped"
fi

# git dir moved inside the worktree under another name (`--separate-git-dir`)
S="$WORK/sep"; mkdir -p "$S/meta"; new_repo "$S" --separate-git-dir "$WORK/sep/meta/gd"
SWRAP="$S/.claude/lib/rm-in-project.sh"
for c in "separate git dir|$S/meta/gd|worktree root" "inside a separate git dir|$S/meta/gd/objects|git metadata" \
         "dir containing the git dir|$S/meta|contains"; do
  IFS='|' read -r label path reason <<< "$c"; rc=0
  (cd "$S" && bash "$SWRAP" "$path") > "$WORK/out" 2>&1 || rc=$?
  [ "$rc" != 0 ] && grep -qF "refused ($reason" "$WORK/out" || fail "$label not refused"
  [ -f "$S/meta/gd/HEAD" ] || fail "$label deleted git metadata"
  ok "refused $label"
done
touch "$S/plain"
(cd "$S" && bash "$SWRAP" "$S/plain") > "$WORK/out" 2>&1 && [ ! -e "$S/plain" ] \
  || fail "separate git dir: a plain file in the work tree was refused"
ok "removed a file next to a separate git dir"

# --- deletions --------------------------------------------------------------------
touch "$R/plain" "$R/.claude/scratch.txt"
removed "file" "$R/plain"
removed "non-guard file under .claude" "$R/.claude/scratch.txt"
mkdir -p "$R/dir with spaces/sub"; touch "$R/dir with spaces/sub/f" "$R/-option"
removed "dir with spaces and dash-named file" "$R/dir with spaces" "$R/-option"
ln -s "$WORK/outside" "$R/link"
removed "symlink with trailing slash (link only)" "$R/link/"
[ -f "$WORK/outside/keep" ] || fail "symlink deletion followed the link"
touch "$R/nested/wt/tmp"
removed "file in a linked worktree" "$R/nested/wt/tmp"
(cd "$R" && bash "$WRAP" "$R/absent") > "$WORK/out" 2>&1 || fail "absent path refused"
grep -q '^skip (absent)' "$WORK/out" || fail "absent path not reported"; ok "absent path skipped"

echo "rm-in-project-smoke: OK ($CHECKS checks)"
